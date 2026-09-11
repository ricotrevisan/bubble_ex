defmodule BubbleEx.Frontend.ResponsiveImages do
  @moduledoc false

  alias BubbleEx.Frontend.{Payload, StaticExpression}
  alias BubbleEx.Frontend.Normalized.Node

  @spec source(Node.t(), map()) :: map()
  def source(%Node{kind: :image}, overrides) do
    case StaticExpression.resolve(Payload.prop(%{"properties" => overrides}, "src")) do
      {:ok, url} when is_binary(url) and url != "" -> %{"src" => url}
      _ -> %{}
    end
  end

  def source(_node, _overrides), do: %{}

  @spec variants(Node.t()) :: [map()]
  def variants(%Node{kind: :image} = node) do
    node.responsive
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"src" => src, "media" => %{"operator" => operator, "width" => width}}, index}
      when is_binary(src) and operator in ["<", "<=", ">", ">="] and
             is_number(width) and width >= 0 ->
        [
          %{
            id: node.exporter_id <> "/responsive-sources/#{index}",
            src: src,
            media: "(width #{operator} #{width}px)"
          }
        ]

      _ ->
        []
    end)
  end

  def variants(_node), do: []

  @spec asset_nodes(Node.t()) :: [Node.t()]
  def asset_nodes(node) do
    Enum.map(variants(node), fn variant ->
      %{
        node
        | exporter_id: variant.id,
          content: %{"src" => %{resolved: variant.src}},
          attributes: %{},
          children: [],
          responsive: []
      }
    end)
  end
end
