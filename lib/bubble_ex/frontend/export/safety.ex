defmodule BubbleEx.Frontend.Export.Safety do
  @moduledoc false

  alias BubbleEx.Frontend.Normalized.{Node, Style}

  @safe_href_schemes ~w(http https mailto tel)
  @css_rule_delimiters ~r/[;{}]/u
  @css_controls ~r/[\x00-\x1F\x7F]/u

  @spec safe_href?(term()) :: boolean()
  def safe_href?(destination) when is_binary(destination) do
    normalized =
      destination
      |> String.trim()
      |> String.replace(~r/[\x00-\x20\x7F]/u, "")

    case Regex.run(~r/^([a-z][a-z0-9+.-]*):/iu, normalized) do
      [_, scheme] -> String.downcase(scheme) in @safe_href_schemes
      nil -> true
    end
  end

  def safe_href?(_destination), do: false

  @spec safe_css_value?(term()) :: boolean()
  def safe_css_value?(value) when is_number(value), do: true
  def safe_css_value?(value) when is_atom(value), do: true

  def safe_css_value?(value) when is_binary(value) do
    safe_embedded_svg?(value) or
      (not Regex.match?(@css_rule_delimiters, value) and
         not Regex.match?(@css_controls, value) and
         not String.contains?(value, ["\\", "/*", "*/"]) and
         not executable_css?(value))
  end

  def safe_css_value?(_value), do: false

  @spec findings([Style.t()], [Node.t()]) :: [map()]
  def findings(styles, nodes) do
    link_findings(nodes) ++ style_findings(styles) ++ node_css_findings(nodes)
  end

  defp link_findings(nodes) do
    nodes
    |> Enum.flat_map(&collect_nodes/1)
    |> Enum.flat_map(&unsafe_link_finding/1)
  end

  defp unsafe_link_finding(node) do
    unsafe_link_finding(node, resolved_destination(node))
  end

  defp unsafe_link_finding(node, destination) when is_binary(destination) do
    if safe_href?(destination) do
      []
    else
      [
        %{
          "severity" => "warning",
          "type" => "unsafe_link_destination",
          "message" => "executable link destination was omitted from the export",
          "refs" => [node.exporter_id],
          "payload" => %{"destination" => destination}
        }
      ]
    end
  end

  defp unsafe_link_finding(_node, _destination), do: []

  defp style_findings(styles) do
    Enum.flat_map(styles, fn style ->
      unsafe_map_findings(style.properties, style.exporter_id)
    end)
  end

  defp node_css_findings(nodes) do
    nodes
    |> Enum.flat_map(&collect_nodes/1)
    |> Enum.flat_map(fn node ->
      resolved = get_in(node.style || %{}, [:resolved]) || get_in(node.style || %{}, ["resolved"])

      [resolved, node.box, node.layout]
      |> Enum.flat_map(&unsafe_map_findings(&1, node.exporter_id))
      |> Enum.uniq_by(&{&1["refs"], &1["payload"]})
    end)
  end

  defp unsafe_map_findings(map, exporter_id) when is_map(map) do
    Enum.flat_map(map, fn {property, value} ->
      cond do
        is_map(value) ->
          unsafe_map_findings(value, exporter_id)

        safe_css_value?(value) ->
          []

        true ->
          [
            %{
              "severity" => "warning",
              "type" => "unsafe_css_value",
              "message" => "CSS property value was omitted because it was unsafe or non-portable",
              "refs" => [exporter_id],
              "payload" => %{"property" => to_string(property)}
            }
          ]
      end
    end)
  end

  defp unsafe_map_findings(_map, _exporter_id), do: []

  defp resolved_destination(%Node{content: %{"destination" => %{resolved: destination}}}),
    do: destination

  defp resolved_destination(%Node{content: %{"destination" => %{"resolved" => destination}}}),
    do: destination

  defp resolved_destination(_node), do: nil

  defp collect_nodes(%Node{} = node), do: [node | Enum.flat_map(node.children, &collect_nodes/1)]

  defp safe_embedded_svg?(value) do
    with [_, encoded] <-
           Regex.run(
             ~r/^url\(["']?data:image\/svg\+xml;base64,([A-Za-z0-9+\/]+={0,2})["']?\)$/u,
             value
           ),
         {:ok, svg} <- Base.decode64(encoded) do
      not Regex.match?(~r/<(?:script|foreignObject|image|iframe|object|embed)\b/iu, svg) and
        not Regex.match?(~r/(?:href|src|style|on[a-z]+)\s*=/iu, svg) and
        not String.contains?(String.downcase(svg), ["url(", "@import"])
    else
      _ -> false
    end
  end

  defp executable_css?(value) do
    compact =
      value
      |> String.downcase()
      |> String.replace(~r/\s/u, "")

    String.contains?(compact, ["url(", "expression(", "@import", "-moz-binding"])
  end
end
