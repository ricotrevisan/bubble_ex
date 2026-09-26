defmodule BubbleEx.Plan.Order do
  @moduledoc false

  # Dependency wiring and ordering for BubbleEx.Plan.
  #
  # A subtask is done with its parent, so dependencies are checked for
  # cycles between top-level tasks ("roots"): an edge from a subtask counts
  # as an edge from its root. Candidate edges are added in priority order;
  # one that would close a cycle between roots is kept as a non-blocking
  # `:coordinate` edge (ordering ignores it) and reported in `skipped`.
  # Edges between subtasks of one root only order those subtasks.

  alias BubbleEx.Plan.Task

  # Kind ranks break ties between ready tasks: earlier phases first.
  @rank %{
    generate: 0,
    remove_writes: 0,
    delete_workflows: 0,
    setup_secrets: 1,
    auth: 2,
    styles_residue: 2,
    plugin: 3,
    api_group: 4,
    fragment: 5,
    surface: 5,
    cycle: 5,
    backend: 5,
    acceptance: 6,
    data: 7,
    replay: 8,
    delivery: 9,
    cutover: 10
  }

  @type edge :: %{from: String.t(), to: String.t(), kind: atom(), via: [String.t()]}

  @doc """
  Wires `edges` (in priority order) into `tasks` (a map by ID): returns the
  tasks with `depends_on` set and the skipped edges.
  """
  @spec wire(%{String.t() => Task.t()}, [edge()]) :: {%{String.t() => Task.t()}, [map()]}
  def wire(tasks, edges) do
    root = &root(tasks, &1)

    {kept, skipped, _graph} =
      edges
      |> merge()
      |> Enum.reduce({[], [], %{}}, fn edge, {kept, skipped, graph} ->
        {rf, rt} = {root.(edge.from), root.(edge.to)}

        cond do
          edge.from == edge.to ->
            {kept, skipped, graph}

          rf == rt ->
            {[edge | kept], skipped, graph}

          # Kept for the task's agent as a non-blocking `:coordinate`
          # edge; ordering ignores it.
          reaches?(graph, rt, rf) ->
            {[%{edge | kind: :coordinate} | kept],
             [Map.merge(edge, %{reason: :would_cycle, kept_as: :coordinate}) | skipped], graph}

          true ->
            {[edge | kept], skipped, Map.update(graph, rf, [rt], &[rt | &1])}
        end
      end)

    deps =
      kept
      |> Enum.group_by(& &1.from, &%{task: &1.to, kind: &1.kind, via: &1.via})
      |> Map.new(fn {id, list} -> {id, Enum.sort_by(list, &{&1.task, &1.kind})} end)

    tasks = Map.new(tasks, fn {id, t} -> {id, %{t | depends_on: Map.get(deps, id, [])}} end)
    {tasks, skipped |> Enum.reverse() |> Enum.sort_by(&{&1.from, &1.to, &1.kind})}
  end

  # One edge per (from, to): the first (highest-priority) kind wins; the
  # `via` symbols of all candidates of that kind are merged.
  defp merge(edges) do
    {order, by_pair} =
      Enum.reduce(edges, {[], %{}}, fn e, {order, acc} ->
        key = {e.from, e.to}

        case acc do
          %{^key => %{kind: kind} = prev} when kind == e.kind ->
            {order, Map.put(acc, key, %{prev | via: prev.via ++ e.via})}

          %{^key => _} ->
            {order, acc}

          _ ->
            {[key | order], Map.put(acc, key, e)}
        end
      end)

    order
    |> Enum.reverse()
    |> Enum.map(fn key ->
      edge = Map.fetch!(by_pair, key)
      %{edge | via: edge.via |> Enum.uniq() |> Enum.sort()}
    end)
  end

  defp reaches?(graph, from, to), do: reach(graph, [from], MapSet.new(), to)

  defp reach(_graph, [], _seen, _to), do: false
  defp reach(_graph, [to | _], _seen, to), do: true

  defp reach(graph, [node | rest], seen, to) do
    if MapSet.member?(seen, node),
      do: reach(graph, rest, seen, to),
      else: reach(graph, Map.get(graph, node, []) ++ rest, MapSet.put(seen, node), to)
  end

  @doc "The top-level ancestor of task `id`."
  @spec root(%{String.t() => Task.t()}, String.t()) :: String.t()
  def root(tasks, id) do
    case tasks do
      %{^id => %Task{parent: nil}} -> id
      %{^id => %Task{parent: parent}} -> root(tasks, parent)
      _ -> id
    end
  end

  @doc """
  The tasks in plan order, with `order` set: roots topologically (a ready
  task of the last batch first, then by kind rank, then ID), each followed
  by its subtasks (topologically among themselves, then by ID).
  """
  @spec sort(%{String.t() => Task.t()}) :: [Task.t()]
  def sort(tasks) do
    children = tasks |> Map.values() |> Enum.filter(& &1.parent) |> Enum.group_by(& &1.parent)

    roots =
      for {id, %Task{parent: nil}} <- tasks, into: %{}, do: {id, root_deps(tasks, id, children)}

    roots
    |> kahn(tasks)
    |> Enum.flat_map(&[tasks[&1] | subtasks(tasks, &1, children)])
    |> Enum.with_index()
    |> Enum.map(fn {t, i} -> %{t | order: i} end)
  end

  # A root waits for every root its own and its subtasks' edges point into.
  defp root_deps(tasks, id, children) do
    [tasks[id] | Map.get(children, id, [])]
    |> Enum.flat_map(& &1.depends_on)
    |> Enum.reject(&(&1.kind == :coordinate))
    |> Enum.map(&root(tasks, &1.task))
    |> Enum.reject(&(&1 == id))
    |> MapSet.new()
  end

  defp kahn(deps, tasks), do: kahn(deps, tasks, nil, [])

  defp kahn(deps, _tasks, _batch, acc) when map_size(deps) == 0, do: Enum.reverse(acc)

  defp kahn(deps, tasks, batch, acc) do
    # Roots are acyclic by construction (`wire/2`); among subtasks a
    # leftover cycle is broken at its smallest ID rather than failing.
    ready =
      case for {id, waits} <- deps, MapSet.size(waits) == 0, do: tasks[id] do
        [] -> [tasks[deps |> Map.keys() |> Enum.min()]]
        ready -> ready
      end

    next =
      Enum.min_by(ready, fn t ->
        {if(batch && t.batch == batch, do: 0, else: 1), Map.get(@rank, t.kind, 11), t.id}
      end)

    deps =
      deps
      |> Map.delete(next.id)
      |> Map.new(fn {id, waits} -> {id, MapSet.delete(waits, next.id)} end)

    kahn(deps, tasks, next.batch, [next.id | acc])
  end

  defp subtasks(tasks, parent, children) do
    subs = Map.get(children, parent, [])
    ids = MapSet.new(subs, & &1.id)

    deps =
      Map.new(subs, fn t ->
        {t.id,
         t.depends_on
         |> Enum.reject(&(&1.kind == :coordinate))
         |> Enum.map(& &1.task)
         |> Enum.filter(&MapSet.member?(ids, &1))
         |> MapSet.new()}
      end)

    deps
    |> kahn(tasks)
    |> Enum.map(&tasks[&1])
  end
end
