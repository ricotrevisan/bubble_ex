# PROTOTYPE: throwaway renderer for GitHub issue #28. Not production code.
# It intentionally supports only the normalized fixture beside this file.

Mix.install([{:jason, "== 1.4.4"}])

prototype_dir = __DIR__
out_dir = Path.join(prototype_dir, "dist")
model = prototype_dir |> Path.join("normalized-page.json") |> File.read!() |> Jason.decode!()

escape = fn value ->
  value
  |> to_string()
  |> String.replace("&", "&amp;")
  |> String.replace("<", "&lt;")
  |> String.replace(">", "&gt;")
  |> String.replace("\"", "&quot;")
end

css_declarations = fn values ->
  values
  |> Enum.sort_by(fn {name, _value} -> name end)
  |> Enum.map_join("", fn {name, value} -> "  #{name}: #{value};\n" end)
end

layout_properties = fn
  nil ->
    %{}

  %{"mode" => "row"} = layout ->
    %{
      "display" => "flex",
      "flex-direction" => "row",
      "align-items" => Map.get(layout, "align", "stretch"),
      "justify-content" => Map.get(layout, "justify", "flex-start"),
      "gap" => Map.get(layout, "gap", "0px"),
      "flex-wrap" => Map.get(layout, "wrap", "nowrap")
    }

  %{"mode" => "column"} = layout ->
    %{
      "display" => "flex",
      "flex-direction" => "column",
      "align-items" => Map.get(layout, "align", "stretch"),
      "justify-content" => Map.get(layout, "justify", "flex-start"),
      "gap" => Map.get(layout, "gap", "0px")
    }

  %{"mode" => "align_to_parent"} ->
    %{
      "display" => "grid",
      "grid-template-columns" => "repeat(3, 1fr)",
      "grid-template-rows" => "repeat(3, 1fr)",
      "position" => "relative"
    }

  %{"mode" => "fixed"} ->
    %{"position" => "relative"}
end

cell_alignment = %{
  "top_end" => {"end", "start"},
  "center" => {"center", "center"},
  "bottom_start" => {"start", "end"}
}

placement_properties = fn
  nil ->
    %{}

  %{"cell" => cell} = placement ->
    {justify, align} = Map.fetch!(cell_alignment, cell)

    %{
      "grid-area" => "1 / 1 / 4 / 4",
      "justify-self" => justify,
      "align-self" => align
    }
    |> Map.merge(Map.take(placement, ["width", "height"]))
    |> then(fn props ->
      x = Map.get(placement, "offset-x", "0px")
      y = Map.get(placement, "offset-y", "0px")
      if x == "0px" and y == "0px", do: props, else: Map.put(props, "translate", "#{x} #{y}")
    end)

  placement ->
    %{
      "position" => "absolute",
      "left" => Map.get(placement, "x", "0px"),
      "top" => Map.get(placement, "y", "0px")
    }
    |> Map.merge(Map.take(placement, ["width", "height"]))
end

node_properties = fn node ->
  node
  |> Map.get("box", %{})
  |> Map.merge(layout_properties.(Map.get(node, "layout")))
  |> Map.merge(placement_properties.(Map.get(node, "placement")))
  |> Map.merge(Map.get(node, "style", %{}))
end

rule_properties = fn rule ->
  rule
  |> Map.get("box", %{})
  |> Map.merge(layout_properties.(Map.get(rule, "layout")))
  |> Map.merge(Map.get(rule, "style", %{}))
  |> then(fn props ->
    if Map.get(rule, "visibility") == "collapsed",
      do: Map.put(props, "display", "none"),
      else: props
  end)
end

collect_nodes = fn collect_nodes, node ->
  [node | Enum.flat_map(Map.get(node, "children", []), &collect_nodes.(collect_nodes, &1))]
end

nodes = collect_nodes.(collect_nodes, model["page"])

node_css =
  Enum.map_join(nodes, "\n", fn node ->
    ".e-#{node["id"]} {\n#{css_declarations.(node_properties.(node))}}\n"
  end)

responsive_css =
  nodes
  |> Enum.flat_map(fn node ->
    Enum.map(Map.get(node, "responsive", []), fn rule ->
      width = get_in(rule, ["when", "max_viewport_width"])
      {width, ".e-#{node["id"]} {\n#{css_declarations.(rule_properties.(rule))}}"}
    end)
  end)
  |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  |> Enum.sort_by(fn {width, _rules} -> width end, :desc)
  |> Enum.map_join("\n\n", fn {width, rules} ->
    "@media (max-width: #{width}px) {\n#{Enum.map_join(rules, "\n", &("  " <> String.replace(&1, "\n", "\n  ")))}\n}"
  end)

base_css = """
:root {
  color-scheme: light;
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  font-synthesis: none;
}

* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body { margin: 0; min-width: 320px; }
button, input { font: inherit; }
button, a { cursor: pointer; }
button:focus-visible, a:focus-visible, input:focus-visible { outline: 3px solid #8f84f3; outline-offset: 3px; }
"""

attributes = fn node ->
  node
  |> Map.get("attributes", %{})
  |> then(fn attrs ->
    if node["kind"] == "shape", do: Map.put_new(attrs, "aria-hidden", "true"), else: attrs
  end)
  |> Map.put("class", "node node-#{node["kind"]} e-#{node["id"]}")
  |> Map.put("data-exporter-id", node["id"])
  |> Enum.sort_by(fn {name, _value} -> name end)
  |> Enum.map_join("", fn {name, value} -> " #{name}=\"#{escape.(value)}\"" end)
end

render_node = fn render_node, node ->
  tag = Map.get(node, "semantic", "div")
  attrs = attributes.(node)

  if tag == "input" do
    "<input#{attrs}>"
  else
    content = escape.(Map.get(node, "content", ""))
    children = Enum.map_join(Map.get(node, "children", []), "\n", &render_node.(render_node, &1))
    inner = Enum.reject([content, children], &(&1 == "")) |> Enum.join("\n")
    "<#{tag}#{attrs}>#{inner}</#{tag}>"
  end
end

html = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="generator" content="BubbleEx responsive-layout prototype">
  <title>Northstar — responsive layout slice</title>
  <link rel="stylesheet" href="styles.css">
</head>
<body>
#{render_node.(render_node, model["page"])}
</body>
</html>
"""

File.mkdir_p!(out_dir)
File.write!(Path.join(out_dir, "index.html"), html)

File.write!(
  Path.join(out_dir, "styles.css"),
  base_css <> "\n" <> node_css <> "\n" <> responsive_css <> "\n"
)

IO.puts("Rendered #{length(nodes)} normalized nodes to #{Path.relative_to(out_dir, File.cwd!())}")
