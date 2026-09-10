defmodule BubbleEx.Frontend.Export.Css do
  @moduledoc false

  alias BubbleEx.Frontend.{Naming, Normalized}
  alias BubbleEx.Frontend.Export.{Bbcode, Safety}
  alias BubbleEx.Frontend.Normalized.Node

  @spec shared(Normalized.t(), String.t()) :: String.t()
  def shared(%Normalized{} = model, font_css \\ "") when is_binary(font_css) do
    styles = model.styles

    base = """
    * { box-sizing: border-box; }
    html { -webkit-font-smoothing: antialiased; }
    body { margin: 0; }
    p, h1, h2, h3, h4, fieldset, legend { margin: 0; font: inherit; }
    fieldset { min-width: 0; padding: 0; border: 0; }
    button, input, textarea, select { font: inherit; }
    button { border: none; background: none; padding: 0; line-height: 1; }
    textarea { resize: none; }
    .bubbleex-text-default { font-family: var(--font_default); font-size: 14px; }
    .bubbleex-button-default { line-height: 1; }
    """

    style_rules =
      Enum.map_join(styles, "\n", fn style ->
        decls = style |> shared_paint(model) |> declarations_from_paint()
        base = if decls == "", do: "", else: ".#{style.class_name} {\n#{decls}}\n"
        base <> shared_breakpoint_css(style)
      end)

    [font_css, token_css(model), base, style_rules]
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp shared_breakpoint_css(style) do
    Enum.map_join(style.responsive || [], "\n", fn
      %{"media" => %{"operator" => operator, "width" => width}, "paint" => paint}
      when operator in ["<", "<=", ">", ">="] and is_number(width) and width >= 0 ->
        decls = declarations_from_paint(paint)
        "@media (width #{operator} #{width}px) {\n  .#{style.class_name} {\n#{decls}  }\n}\n"

      _ ->
        ""
    end)
  end

  defp shared_paint(style, model) do
    font = get_in(payload_client(model.source), ["font_tokens", "%d1"])

    if style.applies_to in [
         "Text",
         "Button",
         "Link",
         "Input",
         "MultilineInput",
         "Dropdown",
         "SearchBox"
       ] do
      properties =
        style.properties |> Map.put_new("font_size", 14) |> button_line_height(style.applies_to)

      if is_binary(font),
        do: Map.put_new(properties, "font_face", "var(--font_default)"),
        else: properties
    else
      style.properties
    end
  end

  defp button_line_height(properties, "Button"), do: Map.put_new(properties, "line_height", 1)
  defp button_line_height(properties, _type), do: properties

  @spec page(Node.t(), keyword()) :: String.t()
  def page(node, opts \\ []) do
    entries = collect(node, Keyword.get(opts, :parent_mode))

    base =
      entries
      |> Enum.map(&rule(&1, opts))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    extras =
      entries
      |> Enum.map(fn {node, _parent_mode} -> extra_rule(node, opts) end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    media = responsive_css(entries, opts) <> breakpoint_css(entries, opts)

    [base, extras, media]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> then(fn css -> if css == "", do: "\n", else: String.trim_trailing(css) <> "\n" end)
  end

  # Chromium can initialize a select's displayed option before stylesheet fonts
  # settle. Bubble supplies its local typography inline. Keep the same values
  # available during element creation, without overriding responsive font rules.
  @spec inline_control_font(Node.t()) :: String.t()
  def inline_control_font(%Node{responsive: [], style: style}) when is_map(style) do
    (style[:resolved] || style["resolved"] || %{})
    |> stringify_keys()
    |> Map.take(~w(font_face font_family font-family font_size font-size font_weight font-weight))
    |> declarations_from_paint()
    |> String.trim()
  end

  def inline_control_font(_node), do: ""

  @spec expanded_definition(Node.t(), String.t(), Node.t() | nil) :: String.t()
  def expanded_definition(%Node{} = definition, instance_id, instance \\ nil)
      when is_binary(instance_id) do
    root_opts = [exporter_id_override: instance_id]

    child_opts = [
      id_prefix: instance_id,
      parent_mode: layout_value(definition.layout || %{}, :mode)
    ]

    root_definition =
      definition
      |> instance_position(instance)
      |> instance_dimensions(instance)
      |> drop_instance_root_alignment()

    root =
      [
        rule({root_definition, nil}, root_opts),
        extra_rule(root_definition, root_opts),
        responsive_css([{root_definition, nil}], root_opts),
        breakpoint_css([{root_definition, nil}], root_opts)
      ]

    children = Enum.map(definition.children, &page(&1, child_opts))

    (root ++ children)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> then(fn css ->
      if String.trim(css) == "", do: "\n", else: String.trim_trailing(css) <> "\n"
    end)
  end

  defp instance_position(%Node{variant: :floating_group} = definition, %Node{} = instance) do
    %{
      definition
      | attributes: Map.merge(definition.attributes, instance.attributes),
        box: Map.put(definition.box, :z_index, instance.box[:z_index] || definition.box[:z_index])
    }
  end

  defp instance_position(definition, _instance), do: definition

  defp instance_dimensions(definition, %Node{} = instance) do
    Enum.reduce(
      [
        {:width, :fill_width?, [:width, :min_width, :max_width]},
        {:height, :fill_height?, [:height, :min_height, :max_height]}
      ],
      definition,
      fn {axis, fill, keys}, current ->
        layout = instance.layout || %{}

        if Map.has_key?(layout, fill) or Map.has_key?(layout, Atom.to_string(fill)) or
             Map.has_key?(instance.box, axis) do
          %{
            current
            | box: current.box |> Map.drop(keys) |> Map.merge(Map.take(instance.box, keys)),
              layout: Map.drop(current.layout || %{}, [fill, Atom.to_string(fill)])
          }
        else
          current
        end
      end
    )
  end

  defp instance_dimensions(definition, _instance), do: definition

  @color_token_names %{
    "%3" => "text",
    "alert" => "alert",
    "background" => "background",
    "destructive" => "destructive",
    "primary" => "primary",
    "primary_contrast" => "primary_contrast",
    "success" => "success",
    "surface" => "surface"
  }

  defp token_css(%Normalized{source: source}) do
    client = payload_client(source)
    colors = client["color_tokens"] || %{}
    font = get_in(client, ["font_tokens", "%d1"])

    decls =
      color_token_decls(colors) ++
        font_token_decls(font) ++
        user_token_decls(client["color_tokens_user"], :color) ++
        user_token_decls(client["font_tokens_user"], :font)

    if decls == [] do
      ""
    else
      ":root {\n" <> Enum.map_join(decls, "\n", &("  " <> &1)) <> "\n}\n"
    end
  end

  defp token_css(_), do: ""

  defp payload_client(%{payload: payload}) when is_map(payload) do
    get_in(payload, ["settings", "client_safe"]) || %{}
  end

  defp payload_client(_), do: %{}

  defp color_token_decls(colors) when is_map(colors) do
    Enum.flat_map(@color_token_names, fn {key, name} ->
      value = get_in(colors, [key, "%d1"])

      case parse_rgba(value) do
        {css, rgb} ->
          [
            "--color_#{name}_default: #{css};",
            "--color_#{name}_default_rgb: #{rgb};"
          ]

        nil ->
          []
      end
    end)
  end

  defp color_token_decls(_), do: []

  defp user_token_decls(%{"%d1" => tokens}, kind) when is_map(tokens) do
    tokens
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {id, token} ->
      if is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id) and is_map(token),
        do: user_token_declaration(kind, id, token),
        else: []
    end)
  end

  defp user_token_decls(_tokens, _kind), do: []

  defp user_token_declaration(:color, id, token) do
    case parse_rgba(token["rgba"]) do
      {css, rgb} ->
        ["--color_#{id}_default: #{css};", "--color_#{id}_default_rgb: #{rgb};"]

      nil ->
        []
    end
  end

  defp user_token_declaration(:font, id, token) do
    case token["font_family"] do
      family when is_binary(family) ->
        family = family |> String.split(":::", parts: 2) |> hd()

        if Regex.match?(~r/\A[A-Za-z0-9 ._-]+\z/, family),
          do: [~s(--font_#{id}_default: "#{family}";)],
          else: []

      _ ->
        []
    end
  end

  defp font_token_decls(family) when is_binary(family) and family != "" do
    user_token_declaration(:font, "", %{"font_family" => family})
    |> Enum.map(&String.replace(&1, "--font__default:", "--font_default:"))
  end

  defp font_token_decls(_), do: []

  defp parse_rgba("#" <> hex) when byte_size(hex) in [3, 6] do
    if Regex.match?(~r/\A[0-9a-fA-F]+\z/, hex) do
      hex = if byte_size(hex) == 3, do: String.replace(hex, ~r/./, "\\0\\0"), else: hex
      <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = hex
      rgb = Enum.map_join([r, g, b], ", ", &(String.to_integer(&1, 16) |> Integer.to_string()))
      {"rgb(#{rgb})", rgb}
    end
  end

  defp parse_rgba(value) when is_binary(value) do
    case Regex.run(
           ~r/^rgba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([0-9.]+)\s*\)$/,
           String.trim(value)
         ) do
      [_, r, g, b, a] ->
        css = if a == "1", do: "rgb(#{r}, #{g}, #{b})", else: "rgba(#{r}, #{g}, #{b}, #{a})"
        {css, "#{r}, #{g}, #{b}"}

      _ ->
        nil
    end
  end

  defp parse_rgba(_), do: nil

  defp drop_instance_root_alignment(%Node{layout: layout} = definition)
       when is_map(layout) do
    %{definition | layout: Map.drop(layout, [:align, "align"])}
  end

  defp drop_instance_root_alignment(definition), do: definition

  # Parent layout affects how Bubble's fill sizing maps to CSS. Keep that
  # context in the traversal rather than duplicating it in the normalized model.
  defp collect(%Node{} = node, parent_mode) do
    mode = layout_value(node.layout, :mode)

    [{node, parent_mode} | Enum.flat_map(node.children, &collect(&1, mode))]
  end

  defp rule({%Node{} = node, parent_mode}, opts) do
    id = prefixed_id(node, opts)
    decls = declarations(node, parent_mode)
    if decls == "", do: "", else: "[data-exporter-id=\"#{escape(id)}\"] {\n#{decls}}\n"
  end

  defp prefixed_id(node, opts) do
    case Keyword.get(opts, :exporter_id_override) do
      id when is_binary(id) ->
        id

      _ ->
        case Keyword.get(opts, :id_prefix) do
          nil -> node.exporter_id
          prefix -> Naming.expanded_id(prefix, node)
        end
    end
  end

  defp declarations(%Node{} = node, parent_mode) do
    node
    |> css_map(parent_mode)
    |> declarations_from_paint()
  end

  defp css_map(node, parent_mode) do
    %{}
    |> Map.merge(layout_css(node))
    |> Map.merge(native_position_css(node))
    |> Map.merge(box_css(node))
    |> Map.merge(paint_css(node))
    |> Map.merge(runtime_boundary_css(node))
    |> Map.merge(placement_css(node, parent_mode))
    |> Map.merge(floating_css(node))
    |> base_margin_variables(node)
    |> put_fill_sizing(node, parent_mode)
    |> aspect_image_box(node)
    |> put_flex_grow(node)
    |> put_align_self(node)
    |> put_container_alignment(node)
    |> put_collapse(node)
  end

  defp runtime_boundary_css(%Node{variant: :runtime_overlay}),
    do: %{"display" => "none"}

  defp runtime_boundary_css(%Node{
         kind: :placeholder,
         attributes: %{"data-placeholder-kind" => "RepeatingGroup"}
       }),
       do: %{"color" => "#000000", "display" => "grid"}

  defp runtime_boundary_css(_node), do: %{}

  defp native_position_css(%Node{kind: :page}), do: %{}
  defp native_position_css(%Node{kind: :reusable_instance}), do: %{}
  defp native_position_css(_node), do: %{"position" => "relative"}

  defp floating_css(%Node{kind: :floating_group, attributes: attributes}) do
    %{"position" => "fixed"}
    |> put_floating_axis(attributes["data-floating-vertical"], :vertical)
    |> put_floating_axis(attributes["data-floating-horizontal"], :horizontal)
  end

  defp floating_css(%Node{kind: :reusable_definition, variant: :floating_group} = node),
    do: floating_css(%{node | kind: :floating_group})

  defp floating_css(_node), do: %{}

  defp put_floating_axis(css, value, :vertical) when value in ["top", "bottom"],
    do: Map.put(css, value, "0")

  defp put_floating_axis(css, "both", :vertical),
    do: css |> Map.put("top", "0") |> Map.put("bottom", "0")

  defp put_floating_axis(css, value, :horizontal) when value in ["left", "right"],
    do: Map.put(css, value, "0")

  defp put_floating_axis(css, "both", :horizontal),
    do: css |> Map.put("left", "0") |> Map.put("right", "0")

  defp put_floating_axis(css, _value, _axis), do: css

  defp layout_css(%Node{layout: nil}), do: %{}

  defp layout_css(%Node{kind: :repeating_group, layout: layout}) do
    %{
      "display" => "grid",
      "grid-auto-flow" => "column",
      "grid-auto-columns" => "minmax(max-content, #{layout[:cell_min_width]})",
      "grid-template-rows" => "repeat(1, minmax(#{layout[:cell_min_height]}, auto))",
      "overflow" => "auto"
    }
  end

  defp layout_css(%Node{kind: kind, layout: layout})
       when kind in [:page, :group, :floating_group, :reusable_definition] do
    case layout[:mode] || layout["mode"] do
      :row ->
        %{
          "display" => "flex",
          "flex-direction" => "row",
          "flex-wrap" => wrap_value(layout),
          "justify-content" => justify_value(layout),
          "row-gap" => gap(layout, :row_gap),
          "column-gap" => gap(layout, :column_gap)
        }

      :column ->
        %{
          "display" => "flex",
          "flex-direction" => "column",
          "justify-content" => justify_value(layout),
          "row-gap" => gap(layout, :row_gap),
          "column-gap" => gap(layout, :column_gap)
        }

      :align_to_parent ->
        %{
          "display" => "grid",
          "grid-template-columns" => "repeat(3, minmax(0, 1fr))",
          "grid-template-rows" => "repeat(3, minmax(0, 1fr))",
          "position" => "relative"
        }

      :fixed ->
        %{"position" => "relative"}

      _ ->
        %{}
    end
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp layout_css(_), do: %{}

  @box_css_keys [
    {"width", :width},
    {"height", :height},
    {"min-width", :min_width},
    {"max-width", :max_width},
    {"min-height", :min_height},
    {"max-height", :max_height},
    {"padding", :padding},
    {"margin", :margin},
    {"overflow", :overflow},
    {"left", :x},
    {"top", :y}
  ]

  defp box_css(%Node{box: box}) when is_map(box) do
    @box_css_keys
    |> Map.new(fn {css_key, box_key} -> {css_key, css_size(box_get(box, box_key))} end)
    |> Map.put("transform", rotation(box_get(box, :rotation)))
    |> Map.put("z-index", z(box_get(box, :z_index)))
    |> maybe_absolute(box)
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp box_css(_), do: %{}

  defp box_get(box, key) do
    box[key] || box[Atom.to_string(key)]
  end

  defp maybe_absolute(css, box) do
    if Map.has_key?(box, :x) or Map.has_key?(box, "x") or Map.has_key?(box, :y) or
         Map.has_key?(box, "y") do
      Map.put(css, "position", "absolute")
    else
      css
    end
  end

  defp paint_css(%Node{style: style, kind: kind, variant: variant}) do
    resolved = (style[:resolved] || style["resolved"] || %{}) |> stringify_keys()

    paint = Map.new(resolved, fn {k, v} -> {css_prop_name(k), css_paint_value(k, v)} end)

    kind
    |> native_default_paint()
    |> Map.merge(native_control(kind))
    |> Map.merge(paint)
    |> Map.merge(image_fit(kind, variant))
    |> Map.merge(native_display(kind))
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp native_default_paint(kind)
       when kind in [:floating_group, :reusable_definition, :reusable_instance],
       do: %{"color" => "#000000"}

  defp native_default_paint(_kind), do: %{}

  defp image_fit(:image, :stretch),
    do: %{"object-fit" => "fill", "display" => "block", "overflow" => "hidden"}

  defp image_fit(:image, :rescale),
    do: %{"object-fit" => "contain", "display" => "block", "overflow" => "hidden"}

  defp image_fit(:image, :zoom),
    do: %{"object-fit" => "cover", "display" => "block", "overflow" => "hidden"}

  defp image_fit(:image, :adjust_height),
    do: %{
      "height" => "auto",
      "object-fit" => "contain",
      "display" => "block",
      "overflow" => "hidden"
    }

  defp image_fit(_, _), do: %{}

  defp aspect_image_box(css, %Node{kind: :image}) do
    if css["aspect-ratio"] do
      css
      |> Map.put("box-sizing", "content-box")
      |> image_border_variables(true)
      |> inset_image_dimensions(~w(width min-width max-width), ~w(left right))
      |> inset_image_dimensions(~w(height min-height max-height), ~w(top bottom))
    else
      css
    end
  end

  defp aspect_image_box(css, _node), do: css

  defp image_border_variables(css, defaults? \\ false) do
    Enum.reduce(~w(top right bottom left), css, fn side, acc ->
      if defaults? or Map.has_key?(css, "border-#{side}") or Map.has_key?(css, "border"),
        do: Map.put(acc, "--bubble-image-border-#{side}", "#{border_pixels(css, side)}px"),
        else: acc
    end)
  end

  defp border_pixels(css, side) do
    case Regex.run(~r/^(\d+(?:\.\d+)?)px\s/, css["border-#{side}"] || css["border"] || "none") do
      [_, number] -> number |> Float.parse() |> elem(0)
      _ -> 0
    end
  end

  defp inset_image_dimensions(css, keys, sides) do
    Enum.reduce(keys, css, fn key, acc ->
      case acc[key] do
        size when is_binary(size) -> inset_image_dimension(acc, key, size, sides)
        _ -> acc
      end
    end)
  end

  defp inset_image_dimension(css, key, size, sides) do
    insets = Enum.map_join(sides, " - ", &"var(--bubble-image-border-#{&1})")

    if Regex.match?(~r/^-?[0-9.]+(?:px|%)$/, size) or String.starts_with?(size, "calc("),
      do: Map.put(css, key, "calc(#{size} - #{insets})"),
      else: css
  end

  defp native_display(:link), do: %{"display" => "block", "text-decoration" => "none"}
  defp native_display(:text), do: %{"white-space" => "pre-wrap"}

  defp native_display(:icon),
    do: %{"align-items" => "center", "display" => "flex", "justify-content" => "center"}

  defp native_display(_), do: %{}

  defp native_control(:input) do
    %{
      "appearance" => "none",
      "background" => "#ffffff",
      "border" => "1px solid #cccccc",
      "display" => "block"
    }
  end

  defp native_control(:file_input) do
    %{
      "display" => "block"
    }
  end

  defp native_control(:slider) do
    %{
      "display" => "block",
      "width" => "100%",
      "margin" => "0"
    }
  end

  defp native_control(:search) do
    %{
      "appearance" => "none",
      "background" => "#ffffff",
      "border" => "1px solid #cccccc",
      "display" => "block"
    }
  end

  defp native_control(:multiline_input), do: %{"display" => "block"}

  defp native_control(:dropdown) do
    %{
      "appearance" => "none",
      "background-image" =>
        ~s|url("data:image/svg+xml;base64,PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPCFET0NUWVBFIHN2ZyBQVUJMSUMgIi0vL1czQy8vRFREIFNWRyAxLjEvL0VOIiAiaHR0cDovL3d3dy53My5vcmcvR3JhcGhpY3MvU1ZHLzEuMS9EVEQvc3ZnMTEuZHRkIj4KPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHhtbG5zOnhsaW5rPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5L3hsaW5rIiB2ZXJzaW9uPSIxLjEiICB3aWR0aD0iMjQiIGhlaWdodD0iMjQiIHZpZXdCb3g9IjAgMCAyNCAyNCI+CiAgIDxwYXRoIGZpbGw9IiM5OTk5OTkiIGQ9Ik03LjQxLDguNThMMTIsMTMuMTdMMTYuNTksOC41OEwxOCwxMEwxMiwxNkw2LDEwTDcuNDEsOC41OFoiIC8+Cjwvc3ZnPgo=")|,
      "background-position" => "right 0 top 50%, 0 0",
      "background-repeat" => "no-repeat, repeat",
      "background-size" => "1em, 100%",
      "display" => "block"
    }
  end

  defp native_control(:checkbox), do: %{"display" => "block"}

  defp native_control(:radio_buttons) do
    %{
      "display" => "grid",
      "gap" => "10px 20px",
      "grid-auto-rows" => "max-content",
      "grid-template-columns" => "repeat(1, 1fr)",
      "justify-items" => "stretch",
      "line-height" => "1",
      "overflow" => "hidden",
      "padding" => "3px 0 3px 20px",
      "position" => "relative"
    }
  end

  defp native_control(_), do: %{}

  defp put_fill_sizing(css, %Node{layout: layout}, parent_mode) when is_map(layout) do
    css
    |> put_fill_width(layout_value(layout, :fill_width?), parent_mode)
    |> put_fill_height(layout_value(layout, :fill_height?), parent_mode)
  end

  defp put_fill_sizing(css, _node, _parent_mode), do: css

  defp put_fill_width(css, true, :row) do
    css
    |> Map.put("flex-basis", "0")
    |> Map.put("flex-grow", "1")
    |> Map.put("flex-shrink", "1")
  end

  defp put_fill_width(css, true, _parent_mode),
    do: put_fill_extent(css, "width", ~w(left right))

  defp put_fill_width(css, _fill?, _parent_mode), do: css

  defp put_fill_height(css, true, :column) do
    css
    |> Map.put("flex-basis", "0")
    |> Map.put("flex-grow", "1")
    |> Map.put("flex-shrink", "1")
  end

  defp put_fill_height(css, true, :row), do: Map.put(css, "align-self", "stretch")

  defp put_fill_height(css, true, _parent_mode),
    do: put_fill_extent(css, "height", ~w(top bottom))

  defp put_fill_height(css, _fill?, _parent_mode), do: css

  defp put_fill_extent(css, axis, sides) do
    if margin_variables?(css, sides) do
      insets = Enum.map_join(sides, " - ", &"var(--bubble-margin-#{&1}, 0px)")
      Map.put(css, axis, "calc(100% - #{insets})")
    else
      Map.put(css, axis, "100%")
    end
  end

  defp margin_variables?(css, sides),
    do: Enum.any?(sides, &Map.has_key?(css, "--bubble-margin-#{&1}"))

  defp base_margin_variables(css, node) do
    css = margin_variables(css)

    responsive? =
      Enum.any?(node.responsive || [], fn rule ->
        rule
        |> Map.get("paint", %{})
        |> Map.keys()
        |> Enum.any?(&String.starts_with?(&1, "margin"))
      end)

    if responsive? or margin_variables?(css, ~w(top right bottom left)),
      do:
        Enum.reduce(
          ~w(top right bottom left),
          css,
          &Map.put_new(&2, "--bubble-margin-#{&1}", "0px")
        ),
      else: css
  end

  defp margin_variables(css) do
    sides = ~w(top right bottom left)
    defaults = Map.new(Enum.zip(sides, margin_sides(css["margin"])))

    Enum.reduce(sides, css, fn side, acc ->
      value = css["margin-#{side}"] || defaults[side]

      if is_binary(value) and
           Regex.match?(~r/^(?:0|-?(?:\d+(?:\.\d+)?|\.\d+)(?:px|%|em|rem|vh|vw))$/, value),
         do: Map.put(acc, "--bubble-margin-#{side}", value),
         else: acc
    end)
  end

  defp margin_sides(value) when is_binary(value) do
    case String.split(value) do
      [all] -> [all, all, all, all]
      [vertical, horizontal] -> [vertical, horizontal, vertical, horizontal]
      [top, horizontal, bottom] -> [top, horizontal, bottom, horizontal]
      [top, right, bottom, left] -> [top, right, bottom, left]
      _ -> []
    end
  end

  defp margin_sides(_value), do: []

  defp put_container_alignment(css, %Node{kind: kind, layout: layout})
       when kind in [:page, :group, :floating_group, :reusable_definition] and is_map(layout) do
    case {layout_value(layout, :align), layout_value(layout, :mode)} do
      {align, _mode} when is_binary(align) ->
        Map.put(css, "align-items", flex_alignment(align))

      {nil, mode} when mode in [:row, :column, "row", "column"] ->
        Map.put(css, "align-items", "flex-start")

      _ ->
        css
    end
  end

  defp put_container_alignment(css, _node), do: css

  defp put_flex_grow(css, %Node{box: box}) when is_map(box) do
    case box_get(box, :flex_grow) || box_get(box, :"flex-grow") do
      nil -> css
      n when is_number(n) -> Map.put(css, "flex-grow", n)
      s -> Map.put(css, "flex-grow", s)
    end
  end

  defp put_flex_grow(css, _), do: css

  defp put_align_self(css, %Node{box: box}) when is_map(box) do
    case box_get(box, :align_self) || box_get(box, :"align-self") do
      nil -> css
      value -> Map.put(css, "align-self", flex_alignment(value))
    end
  end

  defp put_align_self(css, _), do: css

  @cell_alignment %{
    "top_start" => {"start", "start"},
    "top_center" => {"center", "start"},
    "top_end" => {"end", "start"},
    "center_start" => {"start", "center"},
    "center" => {"center", "center"},
    "center_end" => {"end", "center"},
    "bottom_start" => {"start", "end"},
    "bottom_center" => {"center", "end"},
    "bottom_end" => {"end", "end"}
  }

  # Bubble's Fixed containers absolutely position every direct child. When
  # offsets are absent Bubble uses the fixed canvas origin; nonant placement is
  # only meaningful for Align-to-Parent containers.
  defp placement_css(%Node{box: box}, :fixed) when is_map(box) do
    %{
      "position" => "absolute",
      "left" => css_size(box_get(box, :x) || 0),
      "top" => css_size(box_get(box, :y) || 0),
      "margin" => "0px"
    }
  end

  defp placement_css(%Node{box: box}, _parent_mode) when is_map(box) do
    case box_get(box, :placement) do
      placement when is_map(placement) -> placement_properties(box, placement)
      _ -> %{}
    end
  end

  defp placement_css(_, _parent_mode), do: %{}

  defp placement_properties(box, placement) do
    case box_get(placement, :cell) do
      cell when is_binary(cell) ->
        {justify, align} = Map.get(@cell_alignment, cell, {"start", "start"})

        %{
          "grid-area" => "1 / 1 / 4 / 4",
          "justify-self" => justify,
          "align-self" => align
        }
        |> put_placement_dimensions(box, placement)
        |> put_translate(placement)

      _ ->
        absolute_placement(box, placement)
    end
  end

  defp absolute_placement(box, placement) do
    if box_get(placement, :x) || box_get(placement, :y) do
      %{
        "position" => "absolute",
        "left" => css_size(box_get(placement, :x) || "0px"),
        "top" => css_size(box_get(placement, :y) || "0px")
      }
      |> put_placement_dimensions(box, placement)
    else
      %{}
    end
  end

  # Older normalized payloads kept dimensions in placement. Prefer canonical
  # box dimensions when both forms are present.
  defp put_placement_dimensions(props, box, placement) do
    props
    |> maybe_put_placement_dimension("width", box, placement, :width)
    |> maybe_put_placement_dimension("height", box, placement, :height)
  end

  defp maybe_put_placement_dimension(props, css_key, box, placement, key) do
    if is_nil(box_get(box, key)) do
      case css_size(box_get(placement, key)) do
        nil -> props
        value -> Map.put(props, css_key, value)
      end
    else
      props
    end
  end

  defp put_translate(props, placement) do
    x = box_get(placement, :"offset-x") || box_get(placement, :offset_x) || "0px"
    y = box_get(placement, :"offset-y") || box_get(placement, :offset_y) || "0px"
    if x == "0px" and y == "0px", do: props, else: Map.put(props, "translate", "#{x} #{y}")
  end

  defp extra_rule(%Node{kind: :icon, variant: :inline_svg} = node, opts) do
    id = prefixed_id(node, opts) |> escape()

    """
    [data-exporter-id="#{id}"] > svg {
      width: 100%;
      height: 100%;
    }
    """
  end

  defp extra_rule(%Node{kind: :icon} = node, opts) do
    id = prefixed_id(node, opts) |> escape()

    """
    [data-exporter-id="#{id}"] > svg {
      width: 100%;
      height: 100%;
      fill: currentColor;
    }
    """
  end

  defp extra_rule(%Node{kind: :multiline_input, variant: :fit_height} = node, opts) do
    id = prefixed_id(node, opts) |> escape()

    """
    [data-exporter-id="#{id}"] {
      field-sizing: content;
      min-height: 0;
      overflow: hidden;
    }
    """ <> extra_rule(%{node | variant: :fixed}, opts)
  end

  defp extra_rule(%Node{kind: kind} = node, opts)
       when kind in [:input, :multiline_input, :search] do
    color =
      get_in(node.style, [:resolved, "placeholder_color"]) ||
        get_in(node.style, ["resolved", "placeholder_color"])

    if is_binary(color) and Safety.safe_css_value?(color) do
      id = prefixed_id(node, opts)

      "[data-exporter-id=\"#{escape(id)}\"]::placeholder {\n  color: #{color};\n  opacity: 1;\n}\n"
    else
      ""
    end
  end

  defp extra_rule(%Node{kind: :radio_buttons} = node, opts) do
    id = prefixed_id(node, opts) |> escape()
    selector = "[data-exporter-id=\"#{id}\"]"

    """
    #{selector} > input[type="radio"] {
      display: block;
      position: absolute;
      left: -20px;
      top: 0;
      opacity: 0;
    }
    #{selector} > label {
      display: inline-block;
      position: relative;
      padding: 0 6px;
      vertical-align: middle;
      cursor: pointer;
    }
    #{selector} > label::before {
      content: "";
      display: inline-block;
      position: absolute;
      left: 0;
      top: 0;
      width: 15px;
      height: 15px;
      margin: -2px 0 0 -20px;
      border: 1px solid #CCCCCC;
      border-radius: 50%;
      background: #FFFFFF;
      transition: border 0.15s ease-in-out;
    }
    #{selector} > label::after {
      content: " ";
      display: inline-block;
      position: absolute;
      left: 4px;
      top: 4px;
      width: 9px;
      height: 9px;
      margin: -2px 0 0 -20px;
      border-radius: 50%;
      background-color: #337AB7;
      transform: scale(0);
      transition: transform 0.1s cubic-bezier(0.8, -0.33, 0.2, 1.33);
    }
    #{selector} > input[type="radio"]:checked + label::before {
      border-color: #337AB7;
    }
    #{selector} > input[type="radio"]:checked + label::after {
      transform: scale(1);
    }
    """
  end

  defp extra_rule(%Node{kind: kind, variant: variant} = node, opts)
       when kind in [:button, :link] and variant in [:icon, :label_icon] do
    id = prefixed_id(node, opts) |> escape()
    selector = "[data-exporter-id=\"#{id}\"]"

    """
    #{selector} {
      align-items: center;
      display: inline-flex;
      gap: var(--bubble-button-gap, 8px);
    }
    #{selector} > svg {
      fill: currentColor;
      color: var(--bubble-icon-color, currentColor);
      flex-shrink: 0;
      height: var(--bubble-icon-size, 24px);
      width: var(--bubble-icon-size, 24px);
    }
    """
  end

  defp extra_rule(%Node{kind: :text} = node, opts) do
    raw = text_slot(node)
    id = prefixed_id(node, opts) |> escape()
    selector = "[data-exporter-id=\"#{id}\"]"

    block_whitespace =
      if Bbcode.block?(raw), do: "#{selector} { white-space: normal; }\n", else: ""

    bbcode =
      if Bbcode.present?(raw) do
        """
        #{selector} a {
          color: inherit;
          text-decoration: none;
        }
        #{selector} ul,
        #{selector} ol {
          margin: 1.4em 0 0 0;
          padding-left: 40px;
        }
        #{selector} li {
          margin: 0;
        }
        """
      else
        ""
      end

    block_whitespace <> bbcode
  end

  defp extra_rule(%Node{kind: :slider, variant: :range} = node, opts) do
    id = prefixed_id(node, opts) |> escape()

    # Bubble paints the track and handles, leaving the outer SliderInput box
    # transparent and borderless. The paired native controls approximate those
    # internals; painting the wrapper adds a panel absent from the source.
    """
    [data-exporter-id="#{id}"] {
      align-items: center;
      background: transparent;
      border: 0;
      border-radius: 0;
      display: flex;
      gap: 8px;
    }
    [data-exporter-id="#{id}"] > input {
      flex: 1 1 0;
      margin: 0;
      min-width: 0;
      width: auto;
    }
    """
  end

  defp extra_rule(_, _), do: ""

  defp text_slot(%Node{content: content}) when is_map(content) do
    slot = content["text"] || content[:text] || %{}
    slot[:resolved] || slot["resolved"] || ""
  end

  defp text_slot(_), do: ""

  defp responsive_css(entries, opts) do
    entries
    |> Enum.flat_map(fn {node, _parent_mode} ->
      Enum.map(node.responsive || [], fn rule -> {media_width(rule), node, rule} end)
    end)
    |> Enum.reject(fn {width, _, _} -> is_nil(width) end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.map_join("\n", fn {width, entries} ->
      inner =
        Enum.map_join(entries, "\n", fn {_w, node, rule} ->
          decls = responsive_decls(rule)
          id = prefixed_id(node, opts)
          "  [data-exporter-id=\"#{escape(id)}\"] {\n#{indent_decls(decls)}  }"
        end)

      "@media (max-width: #{width}px) {\n#{inner}\n}\n"
    end)
  end

  defp media_width(%{"when" => %{"max_viewport_width" => w}}), do: w
  defp media_width(%{"when" => %{max_viewport_width: w}}), do: w
  defp media_width(_), do: nil

  defp breakpoint_css(entries, opts) do
    Enum.map_join(entries, "\n", fn {node, parent} ->
      Enum.map_join(node.responsive || [], "\n", fn
        %{"media" => %{"operator" => operator, "width" => width}, "paint" => paint}
        when operator in ["<", "<=", ">", ">="] and is_number(width) and width >= 0 ->
          id = prefixed_id(node, opts)

          decls =
            paint
            |> margin_variables()
            |> breakpoint_fill(node, parent)
            |> image_breakpoint_paint(node)
            |> declarations_from_paint()

          "@media (width #{operator} #{width}px) {\n  [data-exporter-id=\"#{escape(id)}\"] {\n#{decls}  }\n}\n"

        _ ->
          ""
      end)
    end)
  end

  defp breakpoint_fill(paint, %Node{layout: layout}, parent) when is_map(layout) do
    paint =
      if margin_variables?(paint, ~w(left right)),
        do: put_fill_width(paint, layout_value(layout, :fill_width?), parent),
        else: paint

    if margin_variables?(paint, ~w(top bottom)),
      do: put_fill_height(paint, layout_value(layout, :fill_height?), parent),
      else: paint
  end

  defp breakpoint_fill(paint, _node, _parent), do: paint

  defp image_breakpoint_paint(paint, %Node{kind: :image} = node) do
    if paint_css(node)["aspect-ratio"],
      do:
        paint
        |> image_border_variables()
        |> inset_image_dimensions(~w(width min-width max-width), ~w(left right))
        |> inset_image_dimensions(~w(height min-height max-height), ~w(top bottom)),
      else: paint
  end

  defp image_breakpoint_paint(paint, _node), do: paint

  defp responsive_decls(%{"visibility" => "collapsed"}), do: %{"display" => "none"}
  defp responsive_decls(%{visibility: "collapsed"}), do: %{"display" => "none"}
  defp responsive_decls(_), do: %{}

  defp indent_decls(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("", fn {k, v} -> "    #{k}: #{v};\n" end)
  end

  defp put_collapse(css, %Node{box: box}) when is_map(box) do
    if box[:collapsed?] || box["collapsed?"] || box[:hidden?] || box["hidden?"] do
      Map.put(css, "display", "none")
    else
      css
    end
  end

  defp put_collapse(css, _), do: css

  defp declarations_from_paint(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Enum.map(fn {k, v} -> {css_prop_name(k), css_paint_value(k, v)} end)
    |> Enum.filter(fn {_k, value} -> Safety.safe_css_value?(value) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("", fn {k, v} -> "  #{k}: #{v};\n" end)
  end

  defp layout_value(layout, key) when is_map(layout) do
    Map.get(layout, key) || Map.get(layout, Atom.to_string(key))
  end

  defp layout_value(_layout, _key), do: nil

  defp flex_alignment(value) when value in [:start, "start"], do: "flex-start"
  defp flex_alignment(value) when value in [:end, "end"], do: "flex-end"
  defp flex_alignment(value) when is_atom(value), do: Atom.to_string(value)
  defp flex_alignment(value), do: value

  defp wrap_value(layout) do
    case layout[:wrap] || layout["wrap"] do
      :wrap -> "wrap"
      :nowrap -> "nowrap"
      "wrap" -> "wrap"
      _ -> nil
    end
  end

  defp justify_value(layout) do
    case layout[:justify] || layout["justify"] do
      nil -> nil
      "space-between" -> "space-between"
      "center" -> "center"
      "end" -> "flex-end"
      "start" -> "flex-start"
      other when is_binary(other) -> other
      _ -> nil
    end
  end

  defp gap(layout, key) do
    case layout[key] || layout[to_string(key)] do
      n when is_number(n) -> "#{n}px"
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  defp css_size(nil), do: nil
  defp css_size(n) when is_number(n), do: "#{n}px"
  defp css_size("hidden"), do: "hidden"
  defp css_size("visible"), do: "visible"
  defp css_size("auto"), do: "auto"
  defp css_size(s) when is_binary(s), do: s
  defp css_size(_), do: nil

  defp rotation(nil), do: nil
  defp rotation(n) when is_number(n) and n != 0, do: "rotate(#{n}deg)"
  defp rotation(_), do: nil

  defp z(nil), do: nil
  defp z(n) when is_number(n), do: n
  defp z(_), do: nil

  defp css_prop_name("bgcolor"), do: "background"
  defp css_prop_name("background"), do: "background"
  defp css_prop_name("font_face"), do: "font-family"
  defp css_prop_name("font_size"), do: "font-size"
  defp css_prop_name("font_color"), do: "color"
  defp css_prop_name("font_weight"), do: "font-weight"
  defp css_prop_name("icon_color"), do: "color"
  defp css_prop_name("letter_spacing"), do: "letter-spacing"
  defp css_prop_name("line_height"), do: "line-height"
  defp css_prop_name("border_color"), do: "border-color"
  defp css_prop_name("border_width"), do: "border-width"
  defp css_prop_name("border_style"), do: "border-style"
  defp css_prop_name("border_roundness"), do: "border-radius"
  defp css_prop_name("border_radius"), do: "border-radius"
  defp css_prop_name("boxshadow"), do: "box-shadow"
  defp css_prop_name("box_shadow"), do: "box-shadow"
  defp css_prop_name("placeholder_color"), do: "--placeholder-color"
  defp css_prop_name(name) when is_atom(name), do: css_prop_name(Atom.to_string(name))
  defp css_prop_name(name) when is_binary(name), do: String.replace(name, "_", "-")

  defp css_paint_value(key, n) when key in ["font_size", "letter_spacing"] and is_number(n),
    do: "#{n}px"

  defp css_paint_value(_key, value), do: value

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_keys(_), do: %{}

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
