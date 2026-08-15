defmodule BubbleEx.Frontend.Export.Css do
  @moduledoc false

  alias BubbleEx.Frontend.Normalized
  alias BubbleEx.Frontend.Normalized.Node

  @spec shared(Normalized.t()) :: String.t()
  def shared(%Normalized{styles: styles}) do
    base = """
    * { box-sizing: border-box; }
    body { margin: 0; }
    button, input { font: inherit; }
    """

    style_rules =
      Enum.map_join(styles, "\n", fn style ->
        decls = declarations_from_paint(style.properties)
        if decls == "", do: "", else: ".#{style.class_name} {\n#{decls}}\n"
      end)

    String.trim_trailing(base <> "\n" <> style_rules) <> "\n"
  end

  @spec page(Node.t(), keyword()) :: String.t()
  def page(node, opts \\ []) do
    nodes = collect(node)

    base =
      nodes
      |> Enum.map(&rule(&1, opts))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    extras =
      nodes
      |> Enum.map(&extra_rule(&1, opts))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    media = responsive_css(nodes, opts)

    [base, extras, media]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> then(fn css -> if css == "", do: "\n", else: String.trim_trailing(css) <> "\n" end)
  end

  defp collect(%Node{} = node) do
    [node | Enum.flat_map(node.children, &collect/1)]
  end

  defp rule(%Node{} = node, opts) do
    id = prefixed_id(node, opts)
    decls = declarations(node)
    if decls == "", do: "", else: "[data-exporter-id=\"#{escape(id)}\"] {\n#{decls}}\n"
  end

  defp prefixed_id(node, opts) do
    case Keyword.get(opts, :id_prefix) do
      nil -> node.exporter_id
      prefix -> prefix <> "/" <> node.map_key
    end
  end

  defp declarations(%Node{} = node) do
    node
    |> css_map()
    |> declarations_from_paint()
  end

  defp css_map(node) do
    %{}
    |> Map.merge(layout_css(node))
    |> Map.merge(box_css(node))
    |> Map.merge(paint_css(node))
    |> Map.merge(placement_css(node))
    |> put_fill_width(node)
    |> put_flex_grow(node)
    |> put_align_self(node)
    |> put_row_cross_axis(node)
    |> put_collapse(node)
  end

  defp layout_css(%Node{layout: nil}), do: %{}

  defp layout_css(%Node{kind: kind, layout: layout})
       when kind in [:page, :group, :reusable_definition] do
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
          "grid-template-columns" => "repeat(3, 1fr)",
          "grid-template-rows" => "repeat(3, 1fr)",
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

    resolved
    |> Map.new(fn {k, v} -> {css_prop_name(k), css_paint_value(k, v)} end)
    |> Map.merge(image_fit(kind, variant))
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp image_fit(:image, :stretch), do: %{"object-fit" => "fill"}
  defp image_fit(:image, :rescale), do: %{"object-fit" => "contain"}
  defp image_fit(:image, :zoom), do: %{"object-fit" => "cover"}
  defp image_fit(:image, :adjust_height), do: %{"height" => "auto", "object-fit" => "contain"}
  defp image_fit(_, _), do: %{}

  defp put_fill_width(css, %Node{layout: layout}) when is_map(layout) do
    if layout[:fill_width?] || layout["fill_width?"] do
      css
      |> Map.put("flex-grow", "1")
      |> Map.put("flex-basis", "auto")
    else
      css
    end
  end

  defp put_fill_width(css, _), do: css

  defp put_row_cross_axis(css, %Node{kind: kind, layout: layout})
       when kind in [:page, :group, :reusable_definition] and is_map(layout) do
    align = layout[:align] || layout["align"]
    mode = layout[:mode] || layout["mode"]

    cond do
      is_binary(align) ->
        Map.put(css, "align-items", align)

      mode in [:row, :column] and not Map.has_key?(css, "align-items") ->
        # Omit an explicit default so CSS stretch applies unless a case sets align.
        css

      true ->
        css
    end
  end

  defp put_row_cross_axis(css, _), do: css

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
      value -> Map.put(css, "align-self", value)
    end
  end

  defp put_align_self(css, _), do: css

  @cell_alignment %{
    "top_end" => {"end", "start"},
    "center" => {"center", "center"},
    "bottom_start" => {"start", "end"}
  }

  defp placement_css(%Node{box: box}) when is_map(box) do
    case box_get(box, :placement) do
      %{"cell" => cell} = placement ->
        {justify, align} = Map.get(@cell_alignment, cell, {"start", "start"})

        %{
          "grid-area" => "1 / 1 / 4 / 4",
          "justify-self" => justify,
          "align-self" => align,
          "width" => placement["width"],
          "height" => placement["height"]
        }
        |> put_translate(placement)
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      %{"x" => _} = placement ->
        %{
          "position" => "absolute",
          "left" => placement["x"] || "0px",
          "top" => placement["y"] || "0px",
          "width" => placement["width"],
          "height" => placement["height"]
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      _ ->
        %{}
    end
  end

  defp placement_css(_), do: %{}

  defp put_translate(props, placement) do
    x = Map.get(placement, "offset-x", "0px")
    y = Map.get(placement, "offset-y", "0px")
    if x == "0px" and y == "0px", do: props, else: Map.put(props, "translate", "#{x} #{y}")
  end

  defp extra_rule(%Node{kind: :input} = node, opts) do
    color =
      get_in(node.style, [:resolved, "placeholder_color"]) ||
        get_in(node.style, ["resolved", "placeholder_color"])

    if is_binary(color) do
      id = prefixed_id(node, opts)

      "[data-exporter-id=\"#{escape(id)}\"]::placeholder {\n  color: #{color};\n  opacity: 1;\n}\n"
    else
      ""
    end
  end

  defp extra_rule(_, _), do: ""

  defp responsive_css(nodes, opts) do
    nodes
    |> Enum.flat_map(fn node ->
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
    |> Enum.map(fn {k, v} -> {css_prop_name(k), v} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("", fn {k, v} -> "  #{k}: #{v};\n" end)
  end

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
