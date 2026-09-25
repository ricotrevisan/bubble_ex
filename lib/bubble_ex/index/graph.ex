defmodule BubbleEx.Index.Graph do
  @moduledoc false

  # Tarjan's strongly connected components over a directed graph given as
  # `%{node => [successor]}`. Nodes and successors are visited in sorted
  # order, so the result is deterministic.

  @spec sccs(%{term() => [term()]}) :: [[term()]]
  def sccs(graph) do
    nodes =
      graph
      |> Map.keys()
      |> Enum.concat(Enum.flat_map(graph, &elem(&1, 1)))
      |> Enum.uniq()
      |> Enum.sort()

    graph = Map.new(nodes, &{&1, graph |> Map.get(&1, []) |> Enum.uniq() |> Enum.sort()})
    state = %{index: 0, indices: %{}, low: %{}, stack: [], on_stack: MapSet.new(), sccs: []}

    nodes
    |> Enum.reduce(state, fn node, st ->
      if Map.has_key?(st.indices, node), do: st, else: connect(node, graph, st)
    end)
    |> Map.fetch!(:sccs)
    |> Enum.map(&Enum.sort/1)
    |> Enum.sort()
  end

  @doc "Components that form a cycle: more than one node, or a node calling itself."
  @spec cycles(%{term() => [term()]}) :: [[term()]]
  def cycles(graph) do
    graph
    |> sccs()
    |> Enum.filter(fn
      [node] -> node in Map.get(graph, node, [])
      _ -> true
    end)
  end

  defp connect(node, graph, st) do
    st = %{
      st
      | indices: Map.put(st.indices, node, st.index),
        low: Map.put(st.low, node, st.index),
        index: st.index + 1,
        stack: [node | st.stack],
        on_stack: MapSet.put(st.on_stack, node)
    }

    st =
      Enum.reduce(Map.fetch!(graph, node), st, fn succ, st ->
        cond do
          not Map.has_key?(st.indices, succ) ->
            st = connect(succ, graph, st)
            %{st | low: Map.put(st.low, node, min(st.low[node], st.low[succ]))}

          MapSet.member?(st.on_stack, succ) ->
            %{st | low: Map.put(st.low, node, min(st.low[node], st.indices[succ]))}

          true ->
            st
        end
      end)

    if st.low[node] == st.indices[node], do: pop(node, st, []), else: st
  end

  defp pop(node, %{stack: [top | rest]} = st, acc) do
    st = %{st | stack: rest, on_stack: MapSet.delete(st.on_stack, top)}
    if top == node, do: %{st | sccs: [[top | acc] | st.sccs]}, else: pop(node, st, [top | acc])
  end
end
