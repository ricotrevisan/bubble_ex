defmodule BubbleEx.Frontend.StaticRepeating do
  @moduledoc false

  alias BubbleEx.Frontend.{Payload, StaticExpression}
  alias BubbleEx.Frontend.Normalized.{Node, Source}

  @spec items(map()) :: {:ok, [term()]} | :unsupported
  def items(raw) do
    children = Payload.elements(raw)

    with true <- horizontal?(raw),
         true <- map_size(children) > 0,
         true <- Enum.all?(Map.values(children), &leaf?/1),
         {:ok, values} when is_list(values) and values != [] <-
           StaticExpression.resolve(data_source(raw)),
         true <- length(values) * map_size(children) <= 1_000,
         true <- Enum.all?(values, &(is_binary(&1) or is_number(&1))) do
      {:ok, values}
    else
      _ -> :unsupported
    end
  end

  @spec data_source(map()) :: term()
  def data_source(raw), do: Payload.prop(raw, "data_source") || Payload.properties(raw)["%ds"]

  defp horizontal?(raw) do
    rows = Payload.prop(raw, "rows") || Payload.properties(raw)["%rs"]

    rows == 1 and Payload.prop(raw, "fixed_rows") == true and
      Payload.prop(raw, "fixed_columns") != true and Payload.prop(raw, "show_all_items") == true and
      Payload.prop(raw, "scroll_direction") in [nil, "horizontal"]
  end

  defp leaf?(raw) do
    Payload.type(raw) in ["Image", "Text", "Shape", "Icon"] and Payload.elements(raw) == %{}
  end

  @spec layout(map(), map()) :: map()
  def layout(layout, raw) do
    Map.merge(layout, %{
      cell_min_width: Payload.prop(raw, "cell_min_width_css") || "0px",
      cell_min_height: Payload.prop(raw, "cell_min_height_css") || "0px"
    })
  end

  @spec expand([Node.t()]) :: [Node.t()]
  def expand(nodes), do: Enum.map(nodes, &expand_node/1)

  defp expand_node(%Node{kind: :repeating_group, variant: :static_list} = node) do
    values = node.content["items"][:resolved]

    cells =
      values |> Enum.with_index() |> Enum.map(fn {value, index} -> cell(node, value, index) end)

    %{node | children: cells}
  end

  defp expand_node(node), do: %{node | children: expand(node.children)}

  defp cell(list, value, index) do
    %Node{
      exporter_id: list.exporter_id <> "/cells/#{index}",
      kind: :group,
      variant: :repeating_cell,
      map_key: "cell-#{index}",
      source: %Source{path: list.source.path},
      occurrence: [index],
      layout:
        Map.drop(list.layout, [:fill_width?, :fill_height?, :cell_min_width, :cell_min_height]),
      box: %{min_width: "0px", min_height: list.layout[:cell_min_height]},
      children: Enum.map(list.children, &project(&1, value, index))
    }
  end

  defp project(node, value, index) do
    id = node.exporter_id <> "/items/#{index}"

    bindings =
      Map.new(node.bindings, fn {slot, binding} ->
        {slot,
         %{binding | id: id <> " :: " <> slot, source: Map.put(binding.source, :exporter_id, id)}}
      end)

    content =
      Map.new(node.content || %{}, fn {slot, content} ->
        {slot, project_content(content, bindings[slot], value)}
      end)

    %{node | exporter_id: id, bindings: bindings, content: content, occurrence: [index]}
  end

  defp project_content(content, nil, _value), do: content

  defp project_content(content, binding, value) do
    updated = Map.put(content, :binding_id, binding.id)

    case StaticExpression.resolve(binding.payload, value) do
      {:ok, resolved} when is_binary(resolved) or is_number(resolved) ->
        Map.put(updated, :resolved, resolved)

      _ ->
        updated
    end
  end
end
