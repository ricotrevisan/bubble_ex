defmodule BubbleEx.Frontend.Normalize do
  @moduledoc false

  alias BubbleEx.Error
  alias BubbleEx.Frontend.{Naming, Payload}
  alias BubbleEx.Frontend.Normalized
  alias BubbleEx.Frontend.Normalized.{Diagnostic, Identity, Node, Source, Style}

  @legacy_markers ["legacy", "old"]

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
          properties: Payload.properties(raw),
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
    {children, child_diags} = normalize_children(raw, identity, path)

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

  defp normalize_children(parent, identity, parent_path) do
    Payload.elements(parent)
    |> Enum.sort_by(fn {key, node} -> {order_of(node), key} end)
    |> Enum.reduce({[], []}, fn {key, raw}, {nodes, diags} ->
      if is_map(raw) do
        path = parent_path ++ ["elements", key]
        {node, node_diags} = normalize_element(raw, identity, path, key)
        {[node | nodes], diags ++ node_diags}
      else
        {nodes, diags}
      end
    end)
    |> then(fn {nodes, diags} -> {Enum.reverse(nodes), diags} end)
  end

  defp normalize_element(raw, identity, path, map_key) do
    type = Payload.type(raw)
    exporter_id = Naming.exporter_id(identity, element_kind(type), path)

    case classify(type, raw) do
      {:native, kind, variant} ->
        {children, child_diags} =
          if kind == :group do
            normalize_children(raw, identity, path)
          else
            {[], []}
          end

        {slots, bindings} = extract_slots(raw, kind, exporter_id)

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
          attributes: element_attributes(raw, kind, variant),
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
    if Payload.prop(raw, "choices_style") in [nil, "static"] do
      {:native, kind, :static}
    else
      reason =
        if kind == :dropdown,
          do: :unsupported_dropdown_variant,
          else: :unsupported_radio_buttons_variant

      {:placeholder, reason}
    end
  end

  defp icon_only_link?(raw) do
    Payload.prop(raw, "link_type") in ["icon", "icon_only"]
  end

  @element_kinds %{
    "Group" => :group,
    "Text" => :text,
    "Image" => :image,
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
      wrap: wrap_from(raw),
      justify: justify_from(raw),
      align: align_from(raw),
      fill_width?: fill_width?(raw)
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

  defp wrap_from(raw) do
    case Payload.prop(raw, "container_wrap") || Payload.prop(raw, "wrap") do
      true -> :wrap
      "wrap" -> :wrap
      false -> :nowrap
      "nowrap" -> :nowrap
      _ -> nil
    end
  end

  defp justify_from(raw) do
    case Payload.prop(raw, "container_horiz_alignment") || Payload.prop(raw, "justify") do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp align_from(raw) do
    case Payload.prop(raw, "container_vert_alignment") || Payload.prop(raw, "align") do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp fill_width?(raw) do
    Payload.prop(raw, "fit_width") == "fill" or Payload.prop(raw, "width_behavior") == "fill" or
      Payload.prop(raw, "horizontal_sizing") == "fill"
  end

  defp box_from(raw) do
    sidecar = box_sidecar(raw)

    raw
    |> box_dimensions(sidecar)
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
      padding: Payload.prop(raw, "padding") || sidecar["padding"],
      margin: Payload.prop(raw, "margin") || sidecar["margin"],
      overflow: Payload.prop(raw, "overflow") || sidecar["overflow"]
    }
  end

  defp box_offsets(raw, sidecar) do
    %{
      x: dim(raw, sidecar, "left") || dim(raw, sidecar, "x"),
      y: dim(raw, sidecar, "top") || dim(raw, sidecar, "y"),
      rotation: Payload.prop(raw, "rotation") || sidecar["rotation"],
      z_index:
        Payload.prop(raw, "zindex") || Payload.prop(raw, "z_index") ||
          Payload.prop(raw, "z-index"),
      align_self: Payload.prop(raw, "align-self") || Payload.prop(raw, "align_self"),
      flex_grow: Payload.prop(raw, "flex-grow") || Payload.prop(raw, "flex_grow"),
      placement: Payload.prop(raw, "placement")
    }
  end

  defp box_flags(raw) do
    %{collapsed?: collapsed?(raw), hidden?: hidden?(raw)}
  end

  defp responsive_from(raw) do
    case Payload.prop(raw, "responsive") do
      rules when is_list(rules) -> rules
      _ -> []
    end
  end

  defp gap_prop(raw, key) do
    Payload.prop(raw, key) || Payload.prop(raw, String.replace(key, "_", "-"))
  end

  defp dim(raw, sidecar, key) do
    Payload.prop(raw, key) || sidecar[key] || fixed_aliased_dimension(raw, key)
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
    keys = [
      "bgcolor",
      "background",
      "background_style",
      "font_face",
      "font_size",
      "font_color",
      "font_weight",
      "letter_spacing",
      "line_height",
      "border_style",
      "border_width",
      "border_color",
      "border_roundness",
      "border_radius",
      "boxshadow",
      "box_shadow",
      "opacity",
      "color",
      "placeholder_color"
    ]

    css_ready = [
      "background",
      "color",
      "border",
      "border-radius",
      "box-shadow",
      "font-family",
      "font-size",
      "font-weight",
      "line-height",
      "letter-spacing",
      "transform",
      "z-index",
      "opacity"
    ]

    (keys ++ css_ready)
    |> Map.new(&{&1, Payload.prop(raw, &1)})
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

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
      {:ok, value} -> {:found, value}
      :error -> fetch_raw_property(raw, key)
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
    src = Payload.prop(raw, "src") || Payload.prop(raw, "image") || Payload.prop(raw, "img")

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

  defp workflow_slot(raw, exporter_id) do
    workflows = raw["workflows"] || raw["%w"]

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

  defp element_attributes(raw, :button, _variant) do
    if Payload.prop(raw, "disabled") == true,
      do: %{"disabled" => true},
      else:
        %{"type" => "button"}
        |> then(fn attrs -> Map.put(attrs, "type", "button") end)
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

    if is_binary(alt), do: %{"alt" => alt}, else: %{}
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
        "new_responsive",
        "legacy_responsive"
      ])

    leftover =
      raw
      |> Enum.reject(fn {k, _} -> MapSet.member?(known, k) end)
      |> Map.new()

    known_props =
      MapSet.new([
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
        "width_behavior",
        "horizontal_sizing",
        "width",
        "height",
        "min_width",
        "max_width",
        "min_height",
        "max_height",
        "padding",
        "margin",
        "left",
        "top",
        "x",
        "y",
        "rotation",
        "zindex",
        "z_index",
        "collapse_when_hidden",
        "collapsed",
        "hidden",
        "is_visible",
        "style",
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
        "definition",
        "custom_definition",
        "__bp_layout__"
      ])

    leftover_props =
      raw
      |> Payload.properties()
      |> Enum.reject(fn {k, _} -> MapSet.member?(known_props, k) end)
      |> Map.new()

    if leftover_props == %{}, do: leftover, else: Map.put(leftover, "properties", leftover_props)
  end
end
