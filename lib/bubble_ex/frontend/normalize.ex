defmodule BubbleEx.Frontend.Normalize do
  @moduledoc false

  alias BubbleEx.Error
  alias BubbleEx.Frontend.{Naming, Payload}
  alias BubbleEx.Frontend.Normalized
  alias BubbleEx.Frontend.Normalized.{Diagnostic, Identity, Node, Source, Style}

  @legacy_markers ["legacy", "old"]

  @raw_background_properties [
    "%b4",
    "%bas",
    "%bgc",
    "%bgf",
    "%bgt",
    "background",
    "background_gradient_direction",
    "background_gradient_from",
    "background_gradient_mid",
    "background_gradient_style",
    "background_gradient_to",
    "background_style",
    "backdrop_background_style",
    "backdrop_bgcolor",
    "bgcolor"
  ]
  @raw_border_properties [
    "%bc",
    "%bos",
    "%br",
    "%bw",
    "border",
    "border-radius",
    "border_color",
    "border_radius",
    "border_roundness",
    "border_style",
    "border_width"
  ]
  @raw_shadow_properties [
    "%bh",
    "%bs",
    "%bsb",
    "%bsc",
    "%bsp",
    "%bv",
    "box-shadow",
    "box_shadow",
    "boxshadow",
    "boxshadow_blur",
    "boxshadow_color",
    "boxshadow_enable",
    "boxshadow_horizontal",
    "boxshadow_spread",
    "boxshadow_style",
    "boxshadow_vertical"
  ]
  @raw_opacity_properties ["opacity"]

  @typography_properties [
    "%fa",
    "%fc",
    "%fs",
    "%ic",
    "%lh",
    "%ls",
    "color",
    "font-family",
    "font-size",
    "font-weight",
    "font_color",
    "font_face",
    "font_family",
    "font_size",
    "font_weight",
    "icon_color",
    "letter-spacing",
    "letter_spacing",
    "line-height",
    "line_height",
    "placeholder_color",
    "text_align",
    "transform",
    "z-index"
  ]
  @compact_control_properties ["%1m", "%c1", "%cf", "%ch", "%ct", "%d1", "%lab", "%ps"]

  @spec run(term(), keyword()) :: {:ok, Normalized.t()} | {:error, Error.t()}
  def run(payload, _opts \\ [])

  def run(payload, opts) when is_binary(payload) do
    trimmed = String.trim(payload)

    if String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") do
      case Jason.decode(payload) do
        {:ok, decoded} -> run(decoded, opts)
        {:error, _} -> {:error, Error.new(:parse_failed, "invalid JSON", %{})}
      end
    else
      {:error, Error.new(:invalid_input, "payload must be a JSON object or an Elixir map", %{})}
    end
  end

  def run(payload, opts) when is_map(payload) and not is_struct(payload) do
    do_run(payload, opts)
  rescue
    e ->
      {:error,
       Error.new(:parse_failed, "payload contains shapes the frontend cannot process", %{
         error: safe_exception_message(e, opts)
       })}
  end

  def run(payload, _opts) do
    {:error,
     Error.new(:invalid_input, "payload must be a JSON object or an Elixir map", %{
       payload: payload
     })}
  end

  defp safe_exception_message(exception, opts) do
    message = Exception.message(exception)
    taints = Keyword.get(opts, :credential_taints, [])

    if Enum.any?(taints, &(is_binary(&1) and &1 != "" and String.contains?(message, &1))) do
      "redacted authenticated payload error"
    else
      message
    end
  end

  defp do_run(payload, _opts) do
    cond do
      not app_payload?(payload) ->
        {:error, Error.new(:invalid_input, "payload is not a Bubble app object", %{})}

      legacy_renderer?(payload) ->
        {:error,
         Error.new(:unsupported_renderer, "app is not using the modern responsive renderer", %{})}

      true ->
        {:ok, build_model(payload)}
    end
  end

  defp app_payload?(payload) do
    is_binary(payload["_id"]) or map_size(Payload.pages(payload)) > 0 or
      map_size(Payload.reusables(payload)) > 0
  end

  defp legacy_renderer?(payload) do
    explicit_legacy?(payload) or
      Enum.any?(Payload.pages(payload), fn {_key, page} ->
        is_map(page) and explicit_legacy?(page)
      end)
  end

  defp explicit_legacy?(map) when is_map(map) do
    map["new_responsive"] == false or Payload.prop(map, "new_responsive") == false or
      map["legacy_responsive"] == true or Payload.prop(map, "legacy_responsive") == true or
      map["responsive_version"] in @legacy_markers or
      Payload.prop(map, "responsive_version") in @legacy_markers or
      map["renderer"] in @legacy_markers or Payload.prop(map, "renderer") in @legacy_markers
  end

  defp explicit_legacy?(_), do: false

  defp build_model(payload) do
    identity = %Identity{
      bubble_id: payload["_id"] || "unknown",
      app_version: payload["app_version"] || "live"
    }

    {styles, style_taken} = normalize_styles(payload, identity)
    {pages, diagnostics} = normalize_pages(payload, identity)
    {reusables, reusable_diags} = normalize_reusables(payload, identity)

    %Normalized{
      identity: identity,
      source: %Source{
        path: [],
        map_key: nil,
        bubble_id: identity.bubble_id,
        payload: payload
      },
      pages: pages,
      reusables: reusables,
      styles: styles,
      diagnostics: diagnostics ++ reusable_diags ++ style_diagnostics(style_taken)
    }
  end

  defp style_diagnostics(_taken), do: []

  defp normalize_styles(payload, identity) do
    Payload.styles(payload)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({[], MapSet.new()}, fn {key, raw}, {acc, taken} ->
      if is_map(raw) do
        display = raw["display"] || Payload.name(raw) || key
        {class_name, taken} = Naming.style_class(display, key, taken)

        style = %Style{
          exporter_id: Naming.exporter_id(identity, :style, ["styles", key]),
          map_key: key,
          slug: Naming.slug(display),
          class_name: class_name,
          display_name: display,
          applies_to: Payload.type(raw),
          properties: shared_style_properties(raw),
          source: %Source{path: ["styles", key], map_key: key, bubble_id: Payload.bubble_id(raw)}
        }

        {[style | acc], taken}
      else
        {acc, taken}
      end
    end)
    |> then(fn {styles, taken} -> {Enum.reverse(styles), taken} end)
  end

  defp normalize_pages(payload, identity) do
    Payload.pages(payload)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({[], []}, fn {key, raw}, {pages, diags} ->
      if is_map(raw) do
        {node, node_diags} = normalize_container(raw, identity, :page, ["pages", key], key)
        {[node | pages], diags ++ node_diags}
      else
        {pages, diags}
      end
    end)
    |> then(fn {pages, diags} -> {Enum.reverse(pages), diags} end)
  end

  defp normalize_reusables(payload, identity) do
    Payload.reusables(payload)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({[], []}, fn {key, raw}, {defs, diags} ->
      if is_map(raw) do
        {node, node_diags} =
          normalize_container(
            raw,
            identity,
            :reusable_definition,
            ["element_definitions", key],
            key
          )

        {[node | defs], diags ++ node_diags}
      else
        {defs, diags}
      end
    end)
    |> then(fn {defs, diags} -> {Enum.reverse(defs), diags} end)
  end

  defp normalize_container(raw, identity, kind, path, map_key) do
    exporter_id = Naming.exporter_id(identity, kind, path)
    layout = layout_from(raw)
    workflows = click_workflows(raw)
    {children, child_diags} = normalize_children(raw, identity, path, workflows)

    node = %Node{
      exporter_id: exporter_id,
      kind: kind,
      variant: layout[:mode],
      name: container_name(raw, kind, map_key),
      map_key: map_key,
      source: source_ref(raw, path, map_key),
      layout: layout,
      box: box_from(raw),
      style: style_from(raw),
      children: children,
      unmapped: unmapped_keys(raw),
      attributes: container_attributes(raw, kind),
      responsive: responsive_from(raw)
    }

    {node, child_diags}
  end

  defp normalize_children(parent, identity, parent_path, workflows) do
    parent_mode = layout_mode(parent)

    Payload.elements(parent)
    |> Enum.sort_by(fn {key, node} -> {order_of(node), key} end)
    |> Enum.reduce({[], []}, fn {key, raw}, {nodes, diags} ->
      if is_map(raw) do
        path = parent_path ++ ["elements", key]
        {node, node_diags} = normalize_element(raw, identity, path, key, workflows)

        node =
          node
          |> put_child_alignment(raw, parent_mode)
          |> put_fixed_parent_offsets(raw, parent_mode)

        {[node | nodes], diags ++ node_diags}
      else
        {nodes, diags}
      end
    end)
    |> then(fn {nodes, diags} -> {Enum.reverse(nodes), diags} end)
  end

  defp put_child_alignment(node, raw, parent_mode) do
    alignment = child_alignment(raw, parent_mode)

    if is_binary(alignment) do
      %{node | box: Map.put(node.box, :align_self, canonical_alignment(alignment))}
    else
      node
    end
  end

  defp child_alignment(raw, :column), do: Payload.prop(raw, "horiz_alignment")
  defp child_alignment(raw, :row), do: Payload.prop(raw, "vert_alignment")
  defp child_alignment(_raw, _parent_mode), do: nil

  defp put_fixed_parent_offsets(node, raw, :fixed) do
    props = Payload.properties(raw)

    fixed_box = %{
      x: props["%l"] || placement_value(node, :x),
      y: props["%t"] || placement_value(node, :y),
      z_index: props["%z"],
      width: props["%w"] || placement_value(node, :width) || fixed_child_default(node, :width),
      height: props["%h"] || placement_value(node, :height) || fixed_child_default(node, :height)
    }

    %{
      node
      | box:
          fixed_box
          |> Map.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.merge(node.box)
    }
  end

  defp put_fixed_parent_offsets(node, _raw, _parent_mode), do: node

  # These are Bubble's runtime defaults for a Shape dropped into a Fixed
  # container. Explicit compact or canonical dimensions always win.
  defp placement_value(%Node{box: box}, key) when is_map(box) do
    placement = box[:placement] || box["placement"] || %{}
    placement[key] || placement[Atom.to_string(key)]
  end

  defp placement_value(_node, _key), do: nil
  defp fixed_child_default(%Node{kind: :shape}, :width), do: 200
  defp fixed_child_default(%Node{kind: :shape}, :height), do: 150
  defp fixed_child_default(_node, _axis), do: nil

  defp normalize_element(raw, identity, path, map_key, workflows) do
    type = Payload.type(raw)
    exporter_id = Naming.exporter_id(identity, element_kind(type), path)
    workflows = merge_click_workflows(workflows, raw)

    case classify(type, raw) do
      {:native, kind, variant} ->
        {children, child_diags} =
          if kind in [:group, :floating_group] do
            normalize_children(raw, identity, path, workflows)
          else
            {[], []}
          end

        {slots, bindings} = extract_slots(raw, kind, exporter_id)

        {kind, variant, slots, bindings, attributes} =
          maybe_navigation_button(raw, kind, variant, slots, bindings, workflows, exporter_id)

        node = %Node{
          exporter_id: exporter_id,
          kind: kind,
          variant: variant,
          name: Payload.name(raw) || map_key,
          map_key: map_key,
          source: source_ref(raw, path, map_key),
          layout: layout_from(raw),
          box: box_from(raw),
          style: style_from(raw),
          content: slots,
          children: children,
          bindings: bindings,
          unmapped: unmapped_keys(raw),
          attributes: Map.merge(element_attributes(raw, kind, variant), attributes),
          responsive: responsive_from(raw)
        }

        {node, child_diags ++ slot_diagnostics(node, kind, variant)}

      {:instance, definition_key} ->
        {slots, bindings} = extract_slots(raw, :reusable_instance, exporter_id)

        node = %Node{
          exporter_id: exporter_id,
          kind: :reusable_instance,
          variant: nil,
          name: Payload.name(raw) || map_key,
          map_key: map_key,
          source: source_ref(raw, path, map_key),
          layout: layout_from(raw),
          box: box_from(raw),
          style: style_from(raw),
          content: slots,
          bindings: bindings,
          unmapped: unmapped_keys(raw),
          definition_ref: definition_key,
          responsive: responsive_from(raw)
        }

        {node, []}

      {:placeholder, reason} ->
        {slots, bindings} = extract_slots(raw, :placeholder, exporter_id)

        plugin_binding = %{
          id: exporter_id <> " :: plugin",
          kind: :plugin,
          slot: "plugin",
          source: source_ref(raw, path, map_key),
          payload: %{
            "type" => type,
            "reason" => to_string(reason),
            "properties" => Payload.properties(raw)
          }
        }

        node = %Node{
          exporter_id: exporter_id,
          kind: :placeholder,
          variant: reason,
          name: Payload.name(raw) || map_key,
          map_key: map_key,
          source: source_ref(raw, path, map_key),
          layout: layout_from(raw),
          box: box_from(raw),
          style: style_from(raw),
          content: slots,
          bindings: Map.put(bindings, "plugin", plugin_binding),
          unmapped: unmapped_keys(raw),
          placeholder?: true,
          attributes: %{"data-placeholder-kind" => type || "unknown"},
          responsive: responsive_from(raw)
        }

        diag = %Diagnostic{
          code: :unsupported_element,
          message: "element lowered as a dimension-preserving placeholder",
          refs: [exporter_id],
          details: %{type: type, reason: reason}
        }

        {node, [diag]}
    end
  end

  defp classify("CustomElement", raw), do: classify_instance(raw)
  defp classify("ReusableElement", raw), do: classify_instance(raw)
  defp classify("CustomDefinition", raw), do: {:native, :group, layout_mode(raw) || :column}
  defp classify("ReusableDefinition", raw), do: {:native, :group, layout_mode(raw) || :column}
  defp classify("Group", raw), do: {:native, :group, layout_mode(raw) || :column}
  defp classify("Text", raw), do: classify_text(raw)
  defp classify("Image", raw), do: classify_image(raw)
  defp classify("Icon", raw), do: classify_icon(raw)
  defp classify("FloatingGroup", raw), do: classify_floating_group(raw)

  defp classify("Shape", _raw), do: {:native, :shape, :decorative}
  defp classify("Button", raw), do: classify_button(raw)
  defp classify("Link", raw), do: classify_link(raw)
  defp classify("Input", raw), do: classify_input(raw)
  defp classify("MultiLineInput", raw), do: classify_multiline_input(raw)
  defp classify("Checkbox", raw), do: classify_checkbox(raw)
  defp classify("Dropdown", raw), do: classify_static_choices(raw, :dropdown)

  defp classify(type, raw)
       when type in ["RadioButtons", "Radio Buttons", "RadioButtonGroup"],
       do: classify_static_choices(raw, :radio_buttons)

  defp classify("Page", raw), do: {:native, :group, layout_mode(raw)}
  defp classify(type, _raw) when is_binary(type), do: {:placeholder, :unsupported_kind}
  defp classify(_type, _raw), do: {:placeholder, :unknown_kind}

  defp classify_instance(raw) do
    ref =
      Payload.prop(raw, "definition") || Payload.prop(raw, "custom_definition") ||
        raw["definition"]

    {:instance, ref}
  end

  @text_tags %{"normal" => :normal, "h1" => :h1, "h2" => :h2, "h3" => :h3, "h4" => :h4}

  defp classify_text(raw) do
    case Payload.prop(raw, "tag_type") do
      tag when tag in [nil, "normal", "h1", "h2", "h3", "h4"] ->
        {:native, :text, Map.get(@text_tags, tag, :normal)}

      _other ->
        {:placeholder, :unsupported_text_variant}
    end
  end

  defp classify_icon(raw) do
    case Payload.prop(raw, "icon") do
      icon when is_binary(icon) ->
        if Regex.match?(~r/^fa fa-[a-z0-9]+(?:-[a-z0-9]+)*$/, icon) and
             static_element?(raw) and Payload.prop(raw, "icon_spin") not in [true, "true"],
           do: {:native, :icon, :fontawesome_4},
           else: {:placeholder, :unsupported_icon_variant}

      _ ->
        {:placeholder, :unsupported_icon_variant}
    end
  end

  defp classify_floating_group(raw) do
    vertical = Payload.prop(raw, "floating_reference")

    horizontal =
      Payload.prop(raw, "floating_reference_horizontal_resp") ||
        Payload.prop(raw, "floating_reference_horizontal")

    if static_element?(raw) and layout_mode(raw) == :column and vertical == "top" and
         horizontal == "right" do
      {:native, :floating_group, :column}
    else
      {:placeholder, :unsupported_floating_group_variant}
    end
  end

  defp static_element?(raw) do
    visible = Payload.prop(raw, "is_visible")
    states = raw["states"] || raw["%st"]

    visible in [nil, true] and Payload.workflows(raw) == %{} and
      (is_nil(states) or states == %{})
  end

  defp classify_image(raw) do
    mode =
      Payload.prop(raw, "run_mode") || Payload.prop(raw, "stretch_or_rescale") ||
        Payload.prop(raw, "image_rendering") || Payload.prop(raw, "rendering")

    case mode do
      m when m in [nil, "stretch"] ->
        {:native, :image, :stretch}

      "rescale" ->
        {:native, :image, :rescale}

      "zoom" ->
        {:native, :image, :zoom}

      adj when adj in ["adjust_height", "adjust-element-height", "adjust_element_height"] ->
        {:native, :image, :adjust_height}

      _ ->
        {:placeholder, :unsupported_image_variant}
    end
  end

  defp classify_button(raw) do
    case Payload.prop(raw, "button_type") do
      t when t in [nil, "label", "text"] -> {:native, :button, :label}
      _ -> {:placeholder, :unsupported_button_variant}
    end
  end

  defp classify_link(raw) do
    cond do
      Payload.prop(raw, "show_icon") == true ->
        {:placeholder, :unsupported_link_variant}

      icon_only_link?(raw) ->
        {:placeholder, :unsupported_link_variant}

      true ->
        {:native, :link, :text}
    end
  end

  defp classify_input(raw) do
    case Payload.prop(raw, "content_format") || Payload.prop(raw, "format") do
      f when f in [nil, "text"] -> {:native, :input, :text}
      "email" -> {:native, :input, :email}
      "password" -> {:native, :input, :password}
      _ -> {:placeholder, :unsupported_input_variant}
    end
  end

  defp classify_multiline_input(raw) do
    fit_height? = Payload.prop(raw, "fit_height") == true
    auto_height? = Payload.prop(raw, "auto_height") == true
    stretch? = Payload.prop(raw, "stretch_to_fit") == true

    if fit_height? or auto_height? or stretch?,
      do: {:placeholder, :unsupported_multiline_input_variant},
      else: {:native, :multiline_input, :fixed}
  end

  defp classify_checkbox(raw) do
    case Payload.prop(raw, "contents") do
      contents when contents in ["checked", "unchecked"] ->
        {:native, :checkbox, :static}

      _ ->
        {:placeholder, :unsupported_checkbox_variant}
    end
  end

  defp classify_static_choices(raw, kind) do
    if Payload.prop(raw, "choices_style") in [nil, "static"] and static_choices?(raw) do
      {:native, kind, :static}
    else
      reason =
        if kind == :dropdown,
          do: :unsupported_dropdown_variant,
          else: :unsupported_radio_buttons_variant

      {:placeholder, reason}
    end
  end

  defp static_choices?(raw) do
    case first_property(raw, ["choices", "static_choices", "options"]) do
      :missing -> true
      {:found, choices} when is_binary(choices) -> true
      {:found, choices} when is_list(choices) -> match?({:ok, _}, normalize_choices(choices))
      {:found, _dynamic} -> false
    end
  end

  defp icon_only_link?(raw) do
    Payload.prop(raw, "link_type") in ["icon", "icon_only"]
  end

  @element_kinds %{
    "Group" => :group,
    "Text" => :text,
    "Image" => :image,
    "Icon" => :icon,
    "FloatingGroup" => :floating_group,
    "Shape" => :shape,
    "Button" => :button,
    "Link" => :link,
    "Input" => :input,
    "MultiLineInput" => :multiline_input,
    "Checkbox" => :checkbox,
    "Dropdown" => :dropdown,
    "RadioButtons" => :radio_buttons,
    "Radio Buttons" => :radio_buttons,
    "RadioButtonGroup" => :radio_buttons,
    "CustomElement" => :reusable_instance,
    "ReusableElement" => :reusable_instance
  }

  defp element_kind(type), do: Map.get(@element_kinds, type, :placeholder)

  defp layout_from(raw) do
    mode = layout_mode(raw)

    base = %{
      mode: mode,
      row_gap: gap_prop(raw, "row_gap"),
      column_gap: gap_prop(raw, "column_gap"),
      wrap: wrap_from(raw, mode),
      justify: justify_from(raw, mode),
      align: align_from(raw, mode),
      fill_width?: fill_axis?(raw, :width),
      fill_height?: fill_axis?(raw, :height) || legacy_fixed_fill_height?(raw, mode)
    }

    Map.reject(base, fn {_k, v} -> is_nil(v) end)
  end

  defp layout_mode(raw) do
    case Payload.prop(raw, "container_layout") do
      "column" -> :column
      "row" -> :row
      "fixed" -> :fixed
      "relative" -> :align_to_parent
      "align_to_parent" -> :align_to_parent
      "align-to-parent" -> :align_to_parent
      _ -> nil
    end
  end

  defp wrap_from(raw, mode) do
    case Payload.prop(raw, "container_wrap") || Payload.prop(raw, "wrap") do
      true -> :wrap
      "wrap" -> :wrap
      false -> :nowrap
      "nowrap" -> :nowrap
      _ when mode == :row -> :wrap
      _ -> nil
    end
  end

  defp justify_from(raw, :column) do
    alignment_prop(raw, "container_vert_alignment", "justify")
  end

  defp justify_from(raw, _mode) do
    alignment_prop(raw, "container_horiz_alignment", "justify")
  end

  defp align_from(raw, :column) do
    alignment_prop(raw, "container_horiz_alignment", "align")
  end

  defp align_from(raw, _mode) do
    alignment_prop(raw, "container_vert_alignment", "align")
  end

  defp alignment_prop(raw, primary, fallback) do
    case Payload.prop(raw, primary) || Payload.prop(raw, fallback) do
      value when is_binary(value) -> canonical_alignment(value)
      _ -> nil
    end
  end

  defp canonical_alignment(value) do
    case String.replace(value, "_", "-") do
      value when value in ["left", "top", "start"] -> "flex-start"
      value when value in ["right", "bottom", "end"] -> "flex-end"
      value -> value
    end
  end

  defp fill_axis?(raw, axis) do
    fit = Payload.prop(raw, "fit_#{axis}")
    single = Payload.prop(raw, "single_#{axis}")
    behavior = Payload.prop(raw, "#{axis}_behavior")

    sizing =
      Payload.prop(raw, if(axis == :width, do: "horizontal_sizing", else: "vertical_sizing"))

    if Enum.any?([fit, behavior, sizing], &(&1 == "fill")) do
      true
    else
      fill_axis_from_flags(fit, single)
    end
  end

  defp fill_axis_from_flags(fit, false) when fit != true, do: true
  defp fill_axis_from_flags(_fit, true), do: false
  defp fill_axis_from_flags(true, _single), do: false
  defp fill_axis_from_flags(_fit, _single), do: nil

  defp legacy_fixed_fill_height?(raw, :fixed) do
    props = Payload.properties(raw)

    is_nil(props["%h"]) and is_nil(Payload.prop(raw, "height")) and
      is_nil(Payload.prop(raw, "min_height")) and is_nil(Payload.prop(raw, "max_height")) and
      is_nil(Payload.prop(raw, "fit_height")) and is_nil(Payload.prop(raw, "single_height"))
  end

  defp legacy_fixed_fill_height?(_raw, _mode), do: false

  defp box_from(raw) do
    sidecar = box_sidecar(raw)

    raw
    |> box_dimensions(sidecar)
    |> put_fixed_container_dimensions(raw)
    |> Map.merge(box_offsets(raw, sidecar))
    |> Map.merge(box_flags(raw))
    |> Map.reject(fn {_k, v} -> is_nil(v) or v == false end)
  end

  defp box_sidecar(raw) do
    case Payload.prop(raw, "__bp_layout__") do
      sidecar when is_map(sidecar) -> sidecar
      _ -> %{}
    end
  end

  defp box_dimensions(raw, sidecar) do
    %{
      width: dim(raw, sidecar, "width"),
      height: dim(raw, sidecar, "height"),
      min_width: dim(raw, sidecar, "min_width"),
      max_width: dim(raw, sidecar, "max_width"),
      min_height: dim(raw, sidecar, "min_height"),
      max_height: dim(raw, sidecar, "max_height"),
      padding: spacing(raw, sidecar, "padding"),
      margin: spacing(raw, sidecar, "margin"),
      overflow: Payload.prop(raw, "overflow") || sidecar["overflow"]
    }
  end

  # Bubble supplies compact %w/%h values for legacy Fixed containers without
  # the single_* flags used by responsive nodes. Its runtime also gives a
  # heightless Fixed Group the editor/runtime default height of 250px.
  defp put_fixed_container_dimensions(box, raw) do
    if layout_mode(raw) == :fixed and Payload.type(raw) == "Group" do
      props = Payload.properties(raw)

      default_width = if Payload.prop(raw, "fit_width") == true, do: nil, else: 400

      default_height =
        if is_nil(Payload.prop(raw, "fit_height")) and
             is_nil(Payload.prop(raw, "single_height")),
           do: 250

      box
      |> put_fixed_axis(:width, props["%w"], default_width)
      |> put_fixed_axis(:height, props["%h"], default_height)
    else
      box
    end
  end

  defp put_fixed_axis(box, axis, compact_value, default) do
    min_key = String.to_existing_atom("min_#{axis}")
    max_key = String.to_existing_atom("max_#{axis}")
    value = box[axis] || compact_value

    cond do
      not is_nil(value) ->
        box
        |> put_if_nil(axis, value)
        |> put_if_nil(min_key, value)
        |> put_if_nil(max_key, value)

      not is_nil(default) and is_nil(box[max_key]) ->
        fixed = fixed_default_at_least(default, box[min_key])

        box
        |> Map.put(axis, fixed)
        |> Map.put(min_key, fixed)
        |> Map.put(max_key, fixed)

      true ->
        box
    end
  end

  defp fixed_default_at_least(default, minimum) when is_number(minimum),
    do: max(default, minimum)

  defp fixed_default_at_least(default, minimum) when is_binary(minimum) do
    case Regex.run(~r/^(-?(?:\d+(?:\.\d+)?|\.\d+))px$/, String.trim(minimum),
           capture: :all_but_first
         ) do
      [number] ->
        case Float.parse(number) do
          {parsed, ""} -> max(default, parsed)
          _ -> default
        end

      _ ->
        default
    end
  end

  defp fixed_default_at_least(default, _minimum), do: default

  defp put_if_nil(map, key, value) do
    if is_nil(map[key]), do: Map.put(map, key, value), else: map
  end

  defp box_offsets(raw, sidecar) do
    %{
      x: first_truthy([dim(raw, sidecar, "left"), dim(raw, sidecar, "x")]),
      y: first_truthy([dim(raw, sidecar, "top"), dim(raw, sidecar, "y")]),
      rotation:
        first_truthy([
          Payload.prop(raw, "rotation"),
          Payload.prop(raw, "rotation_angle"),
          sidecar["rotation"]
        ]),
      z_index:
        first_truthy([
          Payload.prop(raw, "zindex"),
          Payload.prop(raw, "z_index"),
          Payload.prop(raw, "z-index"),
          compact_floating_z(raw)
        ]),
      align_self:
        first_truthy([Payload.prop(raw, "align-self"), Payload.prop(raw, "align_self")]),
      flex_grow: first_truthy([Payload.prop(raw, "flex-grow"), Payload.prop(raw, "flex_grow")]),
      placement: first_truthy([Payload.prop(raw, "placement"), nonant_placement(raw)])
    }
  end

  defp first_truthy(values), do: Enum.find(values, & &1)

  @nonant_cells %{
    "aa" => "top_start",
    "ba" => "top_center",
    "ca" => "top_end",
    "ab" => "center_start",
    "bb" => "center",
    "cb" => "center_end",
    "ac" => "bottom_start",
    "bc" => "bottom_center",
    "cc" => "bottom_end"
  }

  defp nonant_placement(raw) do
    case Payload.prop(raw, "nonant_alignment") do
      cell when is_binary(cell) ->
        case Map.fetch(@nonant_cells, String.downcase(cell)) do
          {:ok, canonical} -> %{"cell" => canonical}
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp compact_floating_z(raw) do
    if Payload.type(raw) == "FloatingGroup", do: Payload.properties(raw)["%z"]
  end

  defp spacing(raw, sidecar, key) do
    Payload.prop(raw, key) || sidecar[key] || directional_spacing(raw, key)
  end

  defp directional_spacing(raw, key) do
    values =
      Enum.map(["top", "right", "bottom", "left"], fn side ->
        Payload.prop(raw, "#{key}_#{side}")
      end)

    if Enum.any?(values, &(not is_nil(&1))) do
      Enum.map_join(values, " ", &spacing_part/1)
    end
  end

  defp spacing_part(nil), do: "0px"
  defp spacing_part(value) when is_number(value), do: "#{value}px"

  defp spacing_part(value) when is_binary(value) do
    if Regex.match?(~r/^-?(?:\d+(?:\.\d+)?|\.\d+)$/, value), do: value <> "px", else: value
  end

  defp spacing_part(value), do: to_string(value)

  defp box_flags(raw) do
    %{collapsed?: collapsed?(raw), hidden?: hidden?(raw)}
  end

  defp responsive_from(raw) do
    case Payload.prop(raw, "responsive") do
      rules when is_list(rules) -> rules
      _ -> compact_responsive_from(raw)
    end
  end

  defp compact_responsive_from(raw) do
    states = raw["%s"]

    if Payload.prop(raw, "collapse_when_hidden") == true and
         Payload.prop(raw, "is_visible") == true and is_map(states) and map_size(states) == 1 do
      states
      |> Map.values()
      |> Enum.flat_map(&compact_responsive_rule/1)
    else
      []
    end
  end

  defp compact_responsive_rule(%{
         "%x" => "State",
         "%c" => %{
           "%x" => "PageData",
           "%p" => %{"%nm" => "Current Page Width"},
           "%n" => %{
             "%x" => "Message",
             "%nm" => "less_or_equal_than",
             "%a" => width
           }
         },
         "%p" => %{"%iv" => false} = overrides
       })
       when is_number(width) and width >= 0 and map_size(overrides) == 1 do
    [%{"when" => %{"max_viewport_width" => width}, "visibility" => "collapsed"}]
  end

  defp compact_responsive_rule(_state), do: []

  defp gap_prop(raw, key) do
    Payload.prop(raw, key) || Payload.prop(raw, String.replace(key, "_", "-"))
  end

  defp dim(raw, sidecar, key) do
    Payload.prop(raw, key) || Payload.prop(raw, "#{key}_css") ||
      Payload.prop(raw, "#{key}_px") || sidecar[key] || fixed_aliased_dimension(raw, key)
  end

  defp fixed_aliased_dimension(raw, "width") do
    if Payload.prop(raw, "single_width") == true, do: Payload.properties(raw)["%w"]
  end

  defp fixed_aliased_dimension(raw, "height") do
    if Payload.prop(raw, "single_height") == true, do: Payload.properties(raw)["%h"]
  end

  defp fixed_aliased_dimension(_raw, _key), do: nil

  defp collapsed?(raw), do: Payload.prop(raw, "collapsed") == true

  defp hidden?(raw) do
    Payload.prop(raw, "hidden") == true or Payload.prop(raw, "is_visible") == false
  end

  defp style_from(raw) do
    style_key = raw["style"] || Payload.prop(raw, "style")
    paint = local_paint(raw)

    layers =
      []
      |> maybe_shared_layer(style_key)
      |> maybe_layer(:local, nil, paint)

    %{
      style_key: style_key,
      layers: layers,
      resolved: paint
    }
  end

  defp maybe_shared_layer(layers, nil), do: layers

  defp maybe_shared_layer(layers, key) do
    layers ++ [%{origin: :shared_style, key: key, properties: %{}, provenance: :shared_style}]
  end

  defp maybe_layer(layers, _origin, _key, paint) when paint == %{}, do: layers

  defp maybe_layer(layers, origin, key, paint) do
    layers ++ [%{origin: origin, key: key, properties: paint, provenance: origin}]
  end

  defp local_paint(raw) do
    legacy_keys = [
      "font_face",
      "font_size",
      "font_color",
      "font_weight",
      "icon_color",
      "letter_spacing",
      "line_height",
      "color",
      "placeholder_color",
      "font-family",
      "font-size",
      "font-weight",
      "line-height",
      "letter-spacing",
      "text_align",
      "transform",
      "z-index"
    ]

    legacy_keys
    |> Map.new(&{&1, paint_prop(raw, &1)})
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.merge(canonical_paint(raw))
  end

  defp shared_style_properties(raw) do
    raw
    |> local_paint()
    |> put_shared_property("text_align", Payload.prop(raw, "text_align"))
    |> put_shared_length("padding_top", Payload.prop(raw, "padding_top"))
    |> put_shared_length("padding_right", Payload.prop(raw, "padding_right"))
    |> put_shared_length("padding_bottom", Payload.prop(raw, "padding_bottom"))
    |> put_shared_length("padding_left", Payload.prop(raw, "padding_left"))
  end

  defp put_shared_property(properties, _key, nil), do: properties
  defp put_shared_property(properties, key, value), do: Map.put(properties, key, value)

  defp put_shared_length(properties, key, value) do
    put_shared_property(properties, key, css_length(value))
  end

  defp canonical_paint(raw) do
    %{}
    |> put_paint("background", canonical_background(raw))
    |> put_paint("border", canonical_border(raw))
    |> put_paint("border-radius", canonical_border_radius(raw))
    |> put_paint("box-shadow", canonical_box_shadow(raw))
    |> put_paint("opacity", canonical_opacity(raw))
  end

  defp put_paint(paint, _key, nil), do: paint
  defp put_paint(paint, key, value), do: Map.put(paint, key, value)

  defp canonical_background(raw) do
    case Payload.prop(raw, "background") do
      value when is_binary(value) -> value
      value when not is_nil(value) -> nil
      nil -> background_from_bubble(raw)
    end
  end

  defp background_from_bubble(raw) do
    style =
      Payload.prop(raw, "background_style") || Payload.prop(raw, "backdrop_background_style")

    color = Payload.prop(raw, "bgcolor") || Payload.prop(raw, "backdrop_bgcolor")

    case style do
      "none" -> "none"
      "gradient" -> canonical_gradient(raw)
      value when value in [nil, "bgcolor"] and is_binary(color) -> color
      _ -> nil
    end
  end

  defp canonical_gradient(raw) do
    from = Payload.prop(raw, "background_gradient_from")
    mid = Payload.prop(raw, "background_gradient_mid")
    to = Payload.prop(raw, "background_gradient_to")
    style = Payload.prop(raw, "background_gradient_style")

    if style in [nil, "linear"] and is_binary(from) and is_binary(to) and
         (is_nil(mid) or is_binary(mid)) do
      direction = gradient_direction(Payload.prop(raw, "background_gradient_direction"))
      stops = [from, mid, to] |> Enum.reject(&is_nil/1) |> Enum.join(", ")
      "linear-gradient(#{direction}#{stops})"
    end
  end

  defp gradient_direction("bottom"), do: "to top, "
  defp gradient_direction("top"), do: "to bottom, "
  defp gradient_direction("left"), do: "to right, "
  defp gradient_direction("right"), do: "to left, "
  defp gradient_direction("bottom_left"), do: "to top right, "
  defp gradient_direction("bottom_right"), do: "to top left, "
  defp gradient_direction("top_left"), do: "to bottom right, "
  defp gradient_direction("top_right"), do: "to bottom left, "
  defp gradient_direction(_), do: ""

  defp canonical_border(raw) do
    case Payload.prop(raw, "border") do
      value when is_binary(value) -> value
      nil -> canonical_border_parts(raw)
      _value -> nil
    end
  end

  defp canonical_border_parts(raw) do
    case Payload.prop(raw, "border_style") do
      "none" ->
        "none"

      style when is_binary(style) ->
        width = css_length(Payload.prop(raw, "border_width"))
        color = Payload.prop(raw, "border_color")

        if is_binary(width) and is_binary(color), do: "#{width} #{style} #{color}"

      _ ->
        nil
    end
  end

  defp canonical_border_radius(raw) do
    direct = Payload.prop(raw, "border-radius")
    radius = Payload.prop(raw, "border_radius") || Payload.prop(raw, "border_roundness")
    css_length(if(is_nil(direct), do: radius, else: direct))
  end

  defp canonical_box_shadow(raw) do
    direct =
      Payload.prop(raw, "box-shadow") || Payload.prop(raw, "box_shadow") ||
        Payload.prop(raw, "boxshadow")

    cond do
      is_binary(direct) -> direct
      is_nil(direct) -> bubble_box_shadow(raw)
      true -> nil
    end
  end

  defp bubble_box_shadow(raw) do
    enabled = Payload.prop(raw, "boxshadow_enable")
    style = Payload.prop(raw, "boxshadow_style")

    cond do
      enabled == false or style == "none" -> "none"
      enabled == true or style in ["outset", "inset"] -> build_box_shadow(raw, style)
      true -> nil
    end
  end

  defp build_box_shadow(raw, style) do
    color = Payload.prop(raw, "boxshadow_color")

    if is_binary(color) do
      x = css_length(Payload.prop(raw, "boxshadow_horizontal") || 0)
      y = css_length(Payload.prop(raw, "boxshadow_vertical") || 0)
      blur = css_length(Payload.prop(raw, "boxshadow_blur") || 0)
      spread = Payload.prop(raw, "boxshadow_spread")

      parts =
        []
        |> maybe_prepend_inset(style)
        |> Kernel.++([x, y, blur])
        |> maybe_append_spread(spread)
        |> Kernel.++([color])

      if Enum.all?(parts, &is_binary/1), do: Enum.join(parts, " ")
    end
  end

  defp maybe_prepend_inset(parts, "inset"), do: parts ++ ["inset"]
  defp maybe_prepend_inset(parts, _style), do: parts

  defp maybe_append_spread(parts, spread) when spread in [nil, 0, 0.0, "0", "0px"], do: parts
  defp maybe_append_spread(parts, spread), do: parts ++ [css_length(spread)]

  defp canonical_opacity(raw) do
    raw
    |> Payload.prop("opacity")
    |> normalize_opacity()
  end

  defp normalize_opacity(opacity) when is_number(opacity) and opacity >= 0 and opacity <= 1,
    do: opacity

  defp normalize_opacity(opacity) when is_number(opacity) and opacity > 1 and opacity <= 100,
    do: opacity / 100

  defp normalize_opacity(opacity) when is_binary(opacity) do
    case Float.parse(String.trim(opacity)) do
      {number, ""} -> normalize_opacity(number)
      _ -> nil
    end
  end

  defp normalize_opacity(_opacity), do: nil

  defp css_length(nil), do: nil
  defp css_length(0), do: "0"
  defp css_length(value) when is_number(value), do: "#{value}px"

  defp css_length(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/^-?\d+(?:\.\d+)?$/, value) do
      if value in ["0", "0.0"], do: "0", else: value <> "px"
    else
      value
    end
  end

  defp css_length(_value), do: nil

  defp paint_prop(raw, "font_face") do
    Payload.prop(raw, "font_face") || Payload.prop(raw, "font_family")
  end

  defp paint_prop(raw, key), do: Payload.prop(raw, key)

  defp extract_slots(raw, kind, exporter_id) do
    {resolved, bindings} = primary_slots(kind, raw, exporter_id)

    {condition, condition_bindings} = condition_slot(raw, exporter_id)
    {workflow, workflow_bindings} = workflow_slot(raw, exporter_id)
    {custom, custom_bindings} = named_map_slot(raw, exporter_id, "custom_states", :custom_state)
    {api, api_bindings} = named_map_slot(raw, exporter_id, "api_actions", :api_action)

    slots =
      resolved
      |> Map.merge(condition)
      |> Map.merge(workflow)
      |> Map.merge(custom)
      |> Map.merge(api)

    extra =
      condition_bindings
      |> Map.merge(workflow_bindings)
      |> Map.merge(custom_bindings)
      |> Map.merge(api_bindings)

    {slots, Map.merge(bindings, extra)}
  end

  defp primary_slots(:text, raw, id), do: value_slot(raw, "text", id, ["text", "content"])
  defp primary_slots(:button, raw, id), do: value_slot(raw, "label", id, ["text", "label"])
  defp primary_slots(:link, raw, id), do: link_slots(raw, id)

  defp primary_slots(kind, raw, id) when kind in [:input, :multiline_input],
    do: input_slots(raw, id)

  defp primary_slots(:checkbox, raw, id), do: checkbox_slots(raw, id)
  defp primary_slots(:dropdown, raw, id), do: choice_control_slots(raw, id, false)
  defp primary_slots(:radio_buttons, raw, id), do: choice_control_slots(raw, id, true)
  defp primary_slots(:image, raw, id), do: image_slots(raw, id)
  defp primary_slots(_kind, _raw, _id), do: {%{}, %{}}

  defp named_map_slot(raw, exporter_id, key, kind) do
    value = raw[key] || Payload.prop(raw, key)

    if is_map(value) and map_size(value) > 0 do
      binding = binding(exporter_id, to_string(kind), kind, value)
      {%{to_string(kind) => %{binding_id: binding.id}}, %{to_string(kind) => binding}}
    else
      {%{}, %{}}
    end
  end

  defp value_slot(raw, slot, exporter_id, keys) do
    value = Enum.find_value(keys, &Payload.prop(raw, &1))

    case literal_or_binding(value, exporter_id, slot, raw) do
      {:resolved, lit} -> {%{slot => %{resolved: lit}}, %{}}
      {:binding, binding} -> {%{slot => %{binding_id: binding.id}}, %{slot => binding}}
      :empty -> {%{}, %{}}
    end
  end

  defp link_slots(raw, exporter_id) do
    {text_slots, text_bindings} = value_slot(raw, "text", exporter_id, ["text", "label"])

    dest =
      Payload.prop(raw, "destination") || Payload.prop(raw, "url") || Payload.prop(raw, "page") ||
        Payload.prop(raw, "internal_page")

    {dest_slots, dest_bindings} =
      case literal_or_binding(dest, exporter_id, "destination", raw) do
        {:resolved, lit} ->
          {%{"destination" => %{resolved: lit}}, %{}}

        {:binding, binding} ->
          {%{"destination" => %{binding_id: binding.id}}, %{"destination" => binding}}

        :empty ->
          {%{}, %{}}
      end

    {Map.merge(text_slots, dest_slots), Map.merge(text_bindings, dest_bindings)}
  end

  defp input_slots(raw, exporter_id) do
    {value_slots, value_bindings} =
      value_slot(raw, "value", exporter_id, ["content", "initial_content", "value", "text"])

    {ph_slots, ph_bindings} = value_slot(raw, "placeholder", exporter_id, ["placeholder"])
    {Map.merge(value_slots, ph_slots), Map.merge(value_bindings, ph_bindings)}
  end

  defp checkbox_slots(raw, exporter_id) do
    {label_slots, label_bindings} =
      value_slot(raw, "label", exporter_id, ["label", "text", "caption"])

    {checked_slots, checked_bindings} = checkbox_checked_slot(raw, exporter_id)

    {Map.merge(label_slots, checked_slots), Map.merge(label_bindings, checked_bindings)}
  end

  defp checkbox_checked_slot(raw, exporter_id) do
    case Payload.prop(raw, "contents") do
      "checked" ->
        {%{"checked" => %{resolved: true}}, %{}}

      "unchecked" ->
        {%{"checked" => %{resolved: false}}, %{}}

      nil ->
        property_slot(raw, "checked", exporter_id, [
          "checked",
          "default_checked",
          "initial_status"
        ])

      value ->
        bound_slot(exporter_id, "checked", value)
    end
  end

  defp choice_control_slots(raw, exporter_id, labeled?) do
    {choices_slots, choices_bindings} = choices_slot(raw, exporter_id)

    {value_slots, value_bindings} =
      property_slot(raw, "value", exporter_id, [
        "value",
        "default",
        "default_value",
        "initial_value"
      ])

    {placeholder_slots, placeholder_bindings} =
      value_slot(raw, "placeholder", exporter_id, ["placeholder"])

    {label_slots, label_bindings} =
      if labeled?,
        do: value_slot(raw, "label", exporter_id, ["label", "text", "caption"]),
        else: {%{}, %{}}

    slots =
      choices_slots
      |> Map.merge(value_slots)
      |> Map.merge(placeholder_slots)
      |> Map.merge(label_slots)

    bindings =
      choices_bindings
      |> Map.merge(value_bindings)
      |> Map.merge(placeholder_bindings)
      |> Map.merge(label_bindings)

    {slots, bindings}
  end

  defp choices_slot(raw, exporter_id) do
    case first_property(raw, ["choices", "static_choices", "options"]) do
      {:found, choices} when is_binary(choices) ->
        normalized =
          choices
          |> String.split(~r/\r?\n/, trim: true)
          |> Enum.map(&%{"label" => &1, "value" => &1})

        {%{"choices" => %{resolved: normalized}}, %{}}

      {:found, choices} when is_list(choices) ->
        case normalize_choices(choices) do
          {:ok, normalized} -> {%{"choices" => %{resolved: normalized}}, %{}}
          :error -> bound_slot(exporter_id, "choices", choices)
        end

      {:found, value} ->
        bound_slot(exporter_id, "choices", value)

      :missing ->
        {%{}, %{}}
    end
  end

  defp normalize_choices(choices) do
    Enum.reduce_while(choices, {:ok, []}, fn
      value, {:ok, acc} when is_binary(value) or is_number(value) ->
        choice = %{"label" => to_string(value), "value" => to_string(value)}
        {:cont, {:ok, [choice | acc]}}

      %{"label" => label, "value" => value}, {:ok, acc}
      when (is_binary(label) or is_number(label)) and
             (is_binary(value) or is_number(value)) ->
        choice = %{"label" => to_string(label), "value" => to_string(value)}
        {:cont, {:ok, [choice | acc]}}

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      :error -> :error
    end
  end

  defp property_slot(raw, slot, exporter_id, keys) do
    case first_property(raw, keys) do
      {:found, value} ->
        case literal_or_binding(value, exporter_id, slot, raw) do
          {:resolved, literal} -> {%{slot => %{resolved: literal}}, %{}}
          {:binding, binding} -> {%{slot => %{binding_id: binding.id}}, %{slot => binding}}
          :empty -> {%{}, %{}}
        end

      :missing ->
        {%{}, %{}}
    end
  end

  defp first_property(raw, keys) do
    props = Payload.properties(raw)

    Enum.find_value(keys, :missing, &fetch_property(props, raw, &1))
  end

  defp fetch_property(props, raw, key) do
    case Map.fetch(props, key) do
      {:ok, value} ->
        {:found, value}

      :error ->
        case Payload.prop(raw, key) do
          nil -> fetch_raw_property(raw, key)
          value -> {:found, value}
        end
    end
  end

  defp fetch_raw_property(raw, key) do
    if Map.has_key?(raw, key), do: {:found, Map.get(raw, key)}
  end

  defp bound_slot(exporter_id, slot, value) do
    binding = binding(exporter_id, slot, :value, value)
    {%{slot => %{binding_id: binding.id}}, %{slot => binding}}
  end

  defp image_slots(raw, exporter_id) do
    src = image_src(raw)

    alt =
      Payload.prop(raw, "alt") || Payload.prop(raw, "alt_text") || Payload.prop(raw, "alt_tag")

    {src_slots, src_bindings} =
      case literal_or_binding(src, exporter_id, "src", raw) do
        {:resolved, lit} -> {%{"src" => %{resolved: lit}}, %{}}
        {:binding, binding} -> {%{"src" => %{binding_id: binding.id}}, %{"src" => binding}}
        :empty -> {%{}, %{}}
      end

    alt_slots = if is_binary(alt), do: %{"alt" => %{resolved: alt}}, else: %{}
    {Map.merge(src_slots, alt_slots), src_bindings}
  end

  defp condition_slot(raw, exporter_id) do
    states = raw["states"] || raw["%st"] || Payload.prop(raw, "states")

    if is_map(states) and map_size(states) > 0 do
      binding = %{
        id: exporter_id <> " :: condition",
        kind: :condition,
        slot: "condition",
        source: %{exporter_id: exporter_id},
        payload: states
      }

      {%{"condition" => %{binding_id: binding.id}}, %{"condition" => binding}}
    else
      {%{}, %{}}
    end
  end

  defp maybe_navigation_button(raw, :button, :label, slots, bindings, workflows, exporter_id) do
    case navigation_from_workflows(raw, workflows) do
      {:ok, dest, workflow, action} ->
        slots = Map.put(slots, "destination", %{resolved: dest})
        binding = binding(exporter_id, "workflow", :workflow, workflow)
        bindings = Map.put(bindings, "workflow", binding)
        {:button, :navigation, slots, bindings, navigation_attributes(action)}

      :error ->
        {:button, :label, slots, bindings, %{}}
    end
  end

  defp maybe_navigation_button(_raw, kind, variant, slots, bindings, _workflows, _exporter_id) do
    {kind, variant, slots, bindings, %{}}
  end

  defp navigation_from_workflows(raw, workflows) do
    id = Payload.bubble_id(raw)
    matches = if is_binary(id), do: Map.get(workflows, id, []), else: []

    with true <- Payload.prop(raw, "disabled") != true,
         [workflow] <- matches,
         false <- conditioned?(workflow),
         [action] <- workflow_actions(workflow),
         false <- conditioned?(action),
         dest when is_binary(dest) <- navigation_destination(action),
         true <- not parameterized?(action) do
      {:ok, dest, workflow, action}
    else
      _ -> :error
    end
  end

  defp click_workflows(raw) do
    raw
    |> Payload.workflows()
    |> Enum.reduce(%{}, fn {_key, wf}, acc -> index_click_workflow(acc, wf) end)
  end

  defp merge_click_workflows(parent, raw) do
    Map.merge(parent, click_workflows(raw), fn _id, left, right -> left ++ right end)
  end

  defp index_click_workflow(acc, wf) when is_map(wf) do
    if Payload.type(wf) == "ButtonClicked" do
      case Payload.prop(wf, "element_id") do
        id when is_binary(id) and id != "" -> Map.update(acc, id, [wf], &(&1 ++ [wf]))
        _ -> acc
      end
    else
      acc
    end
  end

  defp index_click_workflow(acc, _wf), do: acc

  defp workflow_actions(wf) when is_map(wf) do
    (wf["actions"] || %{})
    |> Enum.reject(fn {key, _} -> to_string(key) == "length" end)
    |> Enum.filter(fn {_key, action} -> is_map(action) end)
    |> Enum.sort_by(fn {key, _} -> index_key(key) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp workflow_actions(_), do: []

  defp conditioned?(node) when is_map(node) do
    Enum.any?(
      [
        node["condition"],
        node["only_when"],
        node["%c"],
        Payload.prop(node, "condition"),
        Payload.prop(node, "only_when")
      ],
      &present_condition?/1
    )
  end

  defp present_condition?(nil), do: false
  defp present_condition?(""), do: false
  defp present_condition?(value) when is_map(value), do: map_size(value) > 0
  defp present_condition?(false), do: false
  defp present_condition?(_), do: true

  defp parameterized?(action) do
    params = Payload.prop(action, "params") || Payload.prop(action, "url_parameters")

    case params do
      nil -> false
      "" -> false
      params when is_map(params) -> map_size(params) > 0
      _ -> true
    end
  end

  defp navigation_destination(action) when is_map(action) do
    case Payload.type(action) || action["type"] do
      "OpenURL" ->
        static_destination(Payload.prop(action, "url"))

      "ChangePage" ->
        Enum.find_value(
          ["page", "dest_page", "destination", "internal_page", "page_name"],
          &static_destination(Payload.prop(action, &1) || action[&1])
        )

      _ ->
        nil
    end
  end

  defp static_destination(value) when is_binary(value) and value != "", do: value
  defp static_destination(_), do: nil

  defp navigation_attributes(action) do
    if Payload.prop(action, "open_in_new_tab") == true do
      %{"target" => "_blank", "rel" => "noopener"}
    else
      %{}
    end
  end

  defp workflow_slot(raw, exporter_id) do
    workflows = Payload.workflows(raw)

    if is_map(workflows) and map_size(workflows) > 0 do
      binding = %{
        id: exporter_id <> " :: workflow",
        kind: :workflow,
        slot: "workflow",
        source: %{exporter_id: exporter_id},
        payload: workflows
      }

      {%{"workflow" => %{binding_id: binding.id}}, %{"workflow" => binding}}
    else
      {%{}, %{}}
    end
  end

  defp literal_or_binding(nil, _id, _slot, _raw), do: :empty
  defp literal_or_binding("", _id, _slot, _raw), do: :empty

  defp literal_or_binding(value, _id, _slot, _raw)
       when is_binary(value) or is_number(value) or is_boolean(value) do
    {:resolved, value}
  end

  defp literal_or_binding(
         %{"type" => "TextExpression", "entries" => entries} = expr,
         id,
         slot,
         _raw
       ) do
    case flatten_text_expression(entries) do
      {:ok, text} -> {:resolved, text}
      :unresolved -> {:binding, binding(id, slot, :value, expr)}
    end
  end

  defp literal_or_binding(
         %{"%x" => "TextExpression", "%e" => entries} = expr,
         id,
         slot,
         _raw
       ) do
    case flatten_text_expression(entries) do
      {:ok, text} -> {:resolved, text}
      :unresolved -> {:binding, binding(id, slot, :value, expr)}
    end
  end

  defp literal_or_binding(value, id, slot, _raw) when is_map(value) do
    {:binding, binding(id, slot, :value, value)}
  end

  defp literal_or_binding(value, id, slot, _raw) do
    {:binding, binding(id, slot, :value, value)}
  end

  defp flatten_text_expression(entries) when is_map(entries) do
    entries
    |> Enum.sort_by(fn {k, _} -> index_key(k) end)
    |> Enum.reduce_while({:ok, ""}, fn {_k, part}, {:ok, acc} ->
      cond do
        is_binary(part) -> {:cont, {:ok, acc <> part}}
        is_number(part) -> {:cont, {:ok, acc <> to_string(part)}}
        true -> {:halt, :unresolved}
      end
    end)
  end

  defp flatten_text_expression(_), do: :unresolved

  # Bubble can append Current Page Width to an otherwise fixed public image URL.
  # The value only refreshes the same image as the viewport changes. Keep the
  # expression as a binding, but expose its fixed prefix for the static asset
  # pipeline.
  defp public_image_src_fallback(%{"type" => "TextExpression", "entries" => entries}),
    do: public_image_src_fallback_entries(entries)

  defp public_image_src_fallback(%{"%x" => "TextExpression", "%e" => entries}),
    do: public_image_src_fallback_entries(entries)

  defp public_image_src_fallback(_), do: nil

  defp public_image_src_fallback_entries(entries) when is_map(entries) do
    case entries |> Enum.sort_by(fn {key, _} -> index_key(key) end) |> Enum.map(&elem(&1, 1)) do
      [url, page_width] when is_binary(url) ->
        if public_http_url?(url) and terminal_query_value?(url) and
             current_page_width?(page_width),
           do: url

      _ ->
        nil
    end
  end

  defp public_image_src_fallback_entries(_), do: nil

  defp current_page_width?(%{"type" => "PageData", "properties" => properties})
       when is_map(properties),
       do: properties["name"] == "Current Page Width"

  defp current_page_width?(%{"%x" => "PageData", "%p" => properties}) when is_map(properties),
    do: properties["%nm"] == "Current Page Width" or properties["name"] == "Current Page Width"

  defp current_page_width?(_), do: false

  defp public_http_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp terminal_query_value?(url) do
    case URI.parse(url) do
      %URI{query: query, fragment: nil} when is_binary(query) -> String.ends_with?(url, "=")
      _ -> false
    end
  rescue
    _ -> false
  end

  defp image_src(raw),
    do: Payload.prop(raw, "src") || Payload.prop(raw, "image") || Payload.prop(raw, "img")

  defp index_key(k) when is_integer(k), do: k

  defp index_key(k) when is_binary(k) do
    case Integer.parse(k) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp index_key(_), do: 0

  defp binding(exporter_id, slot, kind, payload) do
    %{
      id: exporter_id <> " :: " <> slot,
      kind: kind,
      slot: slot,
      source: %{exporter_id: exporter_id},
      payload: payload
    }
  end

  defp slot_diagnostics(%Node{bindings: bindings} = node, :link, _variant) do
    if Map.has_key?(bindings, "destination") do
      [
        %Diagnostic{
          code: :unresolved_link,
          message: "link destination is unresolved and will not navigate",
          refs: [node.exporter_id],
          details: %{}
        }
      ]
    else
      []
    end
  end

  defp slot_diagnostics(_node, _kind, _variant), do: []

  defp container_name(raw, :page, map_key) do
    # Page directory names slug the Bubble page path, not the display title (#29 Q5).
    Payload.name(raw) || map_key
  end

  defp container_name(raw, _kind, map_key) do
    Payload.display_name(raw) || Payload.name(raw) || map_key
  end

  defp container_attributes(raw, :page) do
    title = Payload.prop(raw, "title") || Payload.display_name(raw)
    if is_binary(title), do: %{"title" => title}, else: %{}
  end

  defp container_attributes(_raw, _), do: %{}

  defp element_attributes(raw, :input, variant) do
    raw
    |> common_control_attributes()
    |> Map.put("type", input_type(variant))
    |> Map.put("placeholder", Payload.prop(raw, "placeholder"))
    |> reject_empty_attributes()
  end

  defp element_attributes(raw, :multiline_input, _variant) do
    raw
    |> common_control_attributes()
    |> Map.put("placeholder", Payload.prop(raw, "placeholder"))
    |> Map.put("maxlength", multiline_maxlength(raw))
    |> reject_empty_attributes()
  end

  defp element_attributes(raw, kind, _variant)
       when kind in [:checkbox, :dropdown, :radio_buttons] do
    raw
    |> common_control_attributes()
    |> reject_empty_attributes()
  end

  defp element_attributes(raw, :button, :navigation) do
    if Payload.prop(raw, "disabled") == true, do: %{"disabled" => true}, else: %{}
  end

  defp element_attributes(raw, :button, _variant) do
    if Payload.prop(raw, "disabled") == true,
      do: %{"disabled" => true},
      else: %{"type" => "button"}
  end

  defp element_attributes(raw, :link, _variant) do
    %{
      "target" => if(Payload.prop(raw, "open_in_new_tab") == true, do: "_blank"),
      "rel" => link_rel(raw),
      "disabled" =>
        Payload.prop(raw, "disabled") == true or Payload.prop(raw, "link_disabled") == true
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) or v == false end)
  end

  defp element_attributes(raw, :image, _variant) do
    alt =
      Payload.prop(raw, "alt") || Payload.prop(raw, "alt_text") || Payload.prop(raw, "alt_tag")

    %{
      "alt" => if(is_binary(alt), do: alt),
      "asset_src" => raw |> image_src() |> public_image_src_fallback()
    }
    |> reject_empty_attributes()
  end

  defp element_attributes(raw, :icon, :fontawesome_4) do
    "fa fa-" <> name = Payload.prop(raw, "icon")

    %{
      "aria-hidden" => "true",
      "asset_fragment" => "fa-" <> name,
      "asset_src" => "/static/icon_libraries/fontawesome-4.7.0.svg",
      "icon_set" => "fa"
    }
  end

  defp element_attributes(raw, :floating_group, _variant) do
    %{
      "data-floating-horizontal" =>
        Payload.prop(raw, "floating_reference_horizontal_resp") ||
          Payload.prop(raw, "floating_reference_horizontal"),
      "data-floating-vertical" => Payload.prop(raw, "floating_reference")
    }
    |> reject_empty_attributes()
  end

  defp element_attributes(_raw, :shape, _variant), do: %{"aria-hidden" => "true"}
  defp element_attributes(_raw, _kind, _variant), do: %{}

  defp multiline_maxlength(raw) do
    case Payload.prop(raw, "limit_number_of_characters") do
      false -> nil
      _ -> Payload.prop(raw, "character_limit") || Payload.prop(raw, "maxlength")
    end
  end

  defp common_control_attributes(raw) do
    %{
      "disabled" => Payload.prop(raw, "disabled") == true,
      "required" =>
        Payload.prop(raw, "required") == true or Payload.prop(raw, "mandatory") == true or
          Payload.prop(raw, "required_checked") == true
    }
  end

  defp reject_empty_attributes(attributes) do
    Map.reject(attributes, fn {_key, value} -> is_nil(value) or value == false end)
  end

  defp input_type(:email), do: "email"
  defp input_type(:password), do: "password"
  defp input_type(_), do: "text"

  defp link_rel(raw) do
    parts =
      []
      |> then(fn acc ->
        if Payload.prop(raw, "nofollow") == true, do: ["nofollow" | acc], else: acc
      end)
      |> then(fn acc ->
        if Payload.prop(raw, "open_in_new_tab") == true, do: ["noopener" | acc], else: acc
      end)

    if parts == [], do: nil, else: Enum.join(Enum.reverse(parts), " ")
  end

  defp source_ref(raw, path, map_key) do
    %Source{path: path, map_key: map_key, bubble_id: Payload.bubble_id(raw)}
  end

  defp order_of(node) when is_map(node) do
    case Payload.prop(node, "order") do
      n when is_number(n) -> n
      _ -> 0
    end
  end

  defp order_of(_), do: 0

  defp consumed_paint_properties(raw) do
    []
    |> consume_paint_properties(canonical_background(raw), @raw_background_properties)
    |> consume_paint_properties(canonical_border(raw), @raw_border_properties)
    |> consume_paint_properties(canonical_box_shadow(raw), @raw_shadow_properties)
    |> consume_paint_properties(canonical_opacity(raw), @raw_opacity_properties)
  end

  defp consume_paint_properties(properties, nil, _keys), do: properties
  defp consume_paint_properties(properties, _canonical, keys), do: properties ++ keys

  defp unmapped_keys(raw) when is_map(raw) do
    known =
      MapSet.new([
        "id",
        "_id",
        "%id",
        "type",
        "%x",
        "name",
        "%nm",
        "default_name",
        "display",
        "properties",
        "%p",
        "elements",
        "%el",
        "style",
        "states",
        "%st",
        "workflows",
        "%w",
        "%wf",
        "new_responsive",
        "legacy_responsive"
      ])

    leftover =
      raw
      |> Enum.reject(fn {k, _} -> MapSet.member?(known, k) end)
      |> Map.new()

    known_props =
      MapSet.new(
        [
          "container_layout",
          "row_gap",
          "column_gap",
          "container_wrap",
          "wrap",
          "container_horiz_alignment",
          "justify",
          "container_vert_alignment",
          "align",
          "fit_width",
          "fit_height",
          "single_width",
          "single_height",
          "width_behavior",
          "height_behavior",
          "horizontal_sizing",
          "vertical_sizing",
          "width",
          "height",
          "%w",
          "%h",
          "min_width",
          "max_width",
          "min_height",
          "max_height",
          "min_width_css",
          "max_width_css",
          "min_height_css",
          "max_height_css",
          "min_width_px",
          "max_width_px",
          "min_height_px",
          "max_height_px",
          "padding",
          "padding_top",
          "padding_right",
          "padding_bottom",
          "padding_left",
          "margin",
          "margin_top",
          "margin_right",
          "margin_bottom",
          "margin_left",
          "left",
          "top",
          "%l",
          "%t",
          "x",
          "y",
          "rotation",
          "rotation_angle",
          "zindex",
          "z_index",
          "%z",
          "horiz_alignment",
          "vert_alignment",
          "nonant_alignment",
          "collapse_when_hidden",
          "collapsed",
          "hidden",
          "is_visible",
          "style",
          "font_family",
          "backdrop_background_style",
          "backdrop_bgcolor",
          "title",
          "original_name",
          "name",
          "order",
          "text",
          "label",
          "src",
          "image",
          "img",
          "alt",
          "alt_text",
          "destination",
          "url",
          "internal_page",
          "page",
          "placeholder",
          "content",
          "initial_content",
          "value",
          "tag_type",
          "run_mode",
          "%2f",
          "2f",
          "image_rendering",
          "rendering",
          "button_type",
          "show_icon",
          "link_type",
          "linktype",
          "content_format",
          "format",
          "auto_height",
          "stretch_to_fit",
          "character_limit",
          "limit_number_of_characters",
          "maxlength",
          "caption",
          "contents",
          "dynamic",
          "checked",
          "default_checked",
          "initial_status",
          "choices_style",
          "choices",
          "static_choices",
          "options",
          "default",
          "default_value",
          "initial_value",
          "mandatory",
          "required_checked",
          "disabled",
          "link_disabled",
          "required",
          "open_in_new_tab",
          "nofollow",
          "%1l",
          "%3f",
          "%9i",
          "%ci",
          "%pa",
          "custom_id",
          "definition",
          "custom_definition",
          "floating_reference",
          "floating_reference_horizontal",
          "floating_reference_horizontal_resp",
          "icon",
          "internal_page",
          "link_type",
          "__bp_layout__"
        ] ++
          @typography_properties ++ @compact_control_properties ++ consumed_paint_properties(raw)
      )

    leftover_props =
      raw
      |> Payload.properties()
      |> Enum.reject(fn {k, _} -> MapSet.member?(known_props, k) end)
      |> Map.new()

    if leftover_props == %{}, do: leftover, else: Map.put(leftover, "properties", leftover_props)
  end
end
