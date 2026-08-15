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
         error: Exception.message(e)
       })}
  end

  def run(payload, _opts) do
    {:error,
     Error.new(:invalid_input, "payload must be a JSON object or an Elixir map", %{
       payload: payload
     })}
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
      attributes: container_attributes(raw, kind)
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
          attributes: element_attributes(raw, kind, variant)
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
          definition_ref: definition_key
        }

        {node, []}

      {:placeholder, reason} ->
        {slots, bindings} = extract_slots(raw, :placeholder, exporter_id)

        plugin_binding = %{
          id: exporter_id <> " :: plugin",
          kind: :plugin,
          slot: "plugin",
          source: source_ref(raw, path, map_key),
          payload: %{"type" => type, "reason" => to_string(reason)}
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
          attributes: %{"data-placeholder-kind" => type || "unknown"}
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
  defp classify("Page", raw), do: {:native, :group, layout_mode(raw)}
  defp classify(type, _raw) when is_binary(type), do: {:placeholder, :unsupported_kind}
  defp classify(_type, _raw), do: {:placeholder, :unknown_kind}

  defp classify_instance(raw) do
    ref =
      Payload.prop(raw, "definition") || Payload.prop(raw, "custom_definition") ||
        raw["definition"]

    {:instance, ref}
  end

  defp classify_text(raw) do
    case Payload.prop(raw, "tag_type") do
      tag when tag in [nil, "normal", "h1", "h2", "h3", "h4"] ->
        variant = if tag in [nil, "normal"], do: :normal, else: String.to_existing_atom(tag)
        {:native, :text, variant}

      _other ->
        {:placeholder, :unsupported_text_variant}
    end
  end

  defp classify_image(raw) do
    mode =
      Payload.prop(raw, "run_mode") || Payload.prop(raw, "image_rendering") ||
        Payload.prop(raw, "rendering")

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
    "CustomElement" => :reusable_instance,
    "ReusableElement" => :reusable_instance
  }

  defp element_kind(type), do: Map.get(@element_kinds, type, :placeholder)

  defp layout_from(raw) do
    mode = layout_mode(raw)

    base = %{
      mode: mode,
      row_gap: numeric_prop(raw, "row_gap"),
      column_gap: numeric_prop(raw, "column_gap"),
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
    sidecar = Payload.prop(raw, "__bp_layout__")
    sidecar = if is_map(sidecar), do: sidecar, else: %{}

    %{
      width: dim(raw, sidecar, "width"),
      height: dim(raw, sidecar, "height"),
      min_width: dim(raw, sidecar, "min_width"),
      max_width: dim(raw, sidecar, "max_width"),
      min_height: dim(raw, sidecar, "min_height"),
      max_height: dim(raw, sidecar, "max_height"),
      padding: Payload.prop(raw, "padding") || sidecar["padding"],
      margin: Payload.prop(raw, "margin") || sidecar["margin"],
      x: dim(raw, sidecar, "left") || dim(raw, sidecar, "x"),
      y: dim(raw, sidecar, "top") || dim(raw, sidecar, "y"),
      rotation: Payload.prop(raw, "rotation") || sidecar["rotation"],
      z_index: Payload.prop(raw, "zindex") || Payload.prop(raw, "z_index"),
      collapsed?: collapsed?(raw),
      hidden?: hidden?(raw)
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) or v == false end)
  end

  defp dim(raw, sidecar, key) do
    Payload.prop(raw, key) || sidecar[key]
  end

  defp collapsed?(raw) do
    Payload.prop(raw, "collapse_when_hidden") == true or Payload.prop(raw, "collapsed") == true
  end

  defp hidden?(raw) do
    Payload.prop(raw, "hidden") == true or Payload.prop(raw, "is_visible") == false
  end

  defp style_from(raw) do
    props = Payload.properties(raw)
    style_key = raw["style"] || Payload.prop(raw, "style")

    layers =
      []
      |> maybe_shared_layer(style_key)
      |> maybe_layer(:local, nil, local_paint(props))

    %{
      style_key: style_key,
      layers: layers,
      resolved: local_paint(props)
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

  defp local_paint(props) do
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

    Map.take(props, keys)
  end

  defp extract_slots(raw, kind, exporter_id) do
    {resolved, bindings} =
      case kind do
        :text -> value_slot(raw, "text", exporter_id, ["text", "content"])
        :button -> value_slot(raw, "label", exporter_id, ["text", "label"])
        :link -> link_slots(raw, exporter_id)
        :input -> input_slots(raw, exporter_id)
        :image -> image_slots(raw, exporter_id)
        _ -> {%{}, %{}}
      end

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
      Payload.prop(raw, "destination") || Payload.prop(raw, "url") ||
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
      value_slot(raw, "value", exporter_id, ["initial_content", "value", "text"])

    {ph_slots, ph_bindings} = value_slot(raw, "placeholder", exporter_id, ["placeholder"])
    {Map.merge(value_slots, ph_slots), Map.merge(value_bindings, ph_bindings)}
  end

  defp image_slots(raw, exporter_id) do
    src = Payload.prop(raw, "src") || Payload.prop(raw, "image") || Payload.prop(raw, "img")
    alt = Payload.prop(raw, "alt") || Payload.prop(raw, "alt_text")

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
    first_binary([raw["name"], Payload.prop(raw, "name"), map_key])
  end

  defp container_name(raw, _kind, map_key) do
    Payload.display_name(raw) || Payload.name(raw) || map_key
  end

  defp first_binary(values) do
    Enum.find(values, &(is_binary(&1) and &1 != ""))
  end

  defp container_attributes(raw, :page) do
    title = Payload.prop(raw, "title") || Payload.display_name(raw)
    if is_binary(title), do: %{"title" => title}, else: %{}
  end

  defp container_attributes(_raw, _), do: %{}

  defp element_attributes(raw, :input, variant) do
    %{
      "type" => input_type(variant),
      "placeholder" => Payload.prop(raw, "placeholder"),
      "disabled" => Payload.prop(raw, "disabled") == true,
      "required" => Payload.prop(raw, "required") == true
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) or v == false end)
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
      "disabled" => Payload.prop(raw, "disabled") == true
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) or v == false end)
  end

  defp element_attributes(raw, :image, _variant) do
    alt = Payload.prop(raw, "alt") || Payload.prop(raw, "alt_text")
    if is_binary(alt), do: %{"alt" => alt}, else: %{}
  end

  defp element_attributes(_raw, :shape, _variant), do: %{"aria-hidden" => "true"}
  defp element_attributes(_raw, _kind, _variant), do: %{}

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

  defp numeric_prop(raw, key) do
    case Payload.prop(raw, key) do
      n when is_number(n) -> n
      _ -> nil
    end
  end

  defp unmapped_keys(raw) when is_map(raw) do
    known =
      MapSet.new([
        "id",
        "_id",
        "%id",
        "type",
        "%x",
        "name",
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
        "placeholder",
        "initial_content",
        "value",
        "tag_type",
        "run_mode",
        "image_rendering",
        "rendering",
        "button_type",
        "show_icon",
        "link_type",
        "content_format",
        "format",
        "disabled",
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
