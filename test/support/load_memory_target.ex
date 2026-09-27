defmodule BubbleEx.Test.LoadMemoryTarget do
  @moduledoc false

  # A BubbleEx.Load.Target that keeps tables in an Agent, for unit tests:
  # the plan is BubbleEx.Target.Ash.Loader's (from a Project), the schema
  # always matches, and upsert has the adapter's semantics (insert,
  # replace, or leave an identical record untouched). `fail_on:` makes the
  # Nth upsert call fail, as a crash mid-run would.

  @behaviour BubbleEx.Load.Target

  alias BubbleEx.Error
  alias BubbleEx.Target.Ash.Loader

  defstruct [:project, :agent]

  def start(project, opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn -> %{tables: %{}, calls: 0, fail_on: Keyword.get(opts, :fail_on)} end)

    {__MODULE__, %__MODULE__{project: project, agent: agent}}
  end

  def fail_on({__MODULE__, %__MODULE__{agent: a}}, n),
    do: Agent.update(a, &%{&1 | fail_on: n, calls: 0})

  def tables({__MODULE__, %__MODULE__{agent: a}}), do: Agent.get(a, & &1.tables)

  def put_rows({__MODULE__, %__MODULE__{agent: a}}, table, rows) do
    Agent.update(a, fn s ->
      %{s | tables: Map.update(s.tables, table, rows, &Map.merge(&1, rows))}
    end)
  end

  # Called before each upsert (e.g. to block or crash mid-run).
  def on_upsert({__MODULE__, %__MODULE__{agent: a}}, fun),
    do: Agent.update(a, &Map.put(&1, :on_upsert, fun))

  @impl true
  def existing(%__MODULE__{agent: a}, table, column) do
    rows = Agent.get(a, &Map.get(&1.tables, table.table, %{}))
    {:ok, for({id, row} <- rows, v = row[column], v != nil, do: {id, v})}
  end

  @impl true
  def clear(%__MODULE__{agent: a}, table, column, ids) do
    Agent.update(a, fn s ->
      rows =
        s.tables
        |> Map.get(table.table, %{})
        |> Map.new(fn {id, row} ->
          {id, if(id in ids, do: Map.put(row, column, nil), else: row)}
        end)

      %{s | tables: Map.put(s.tables, table.table, rows)}
    end)
  end

  @impl true
  def plan(%__MODULE__{project: project}, model),
    do: Loader.plan(%Loader{project: project, query: fn _, _ -> {:ok, %{rows: []}} end}, model)

  @impl true
  def identity(_), do: {:ok, "memory"}

  @impl true
  def check_schema(_, _plan), do: {:ok, []}

  @impl true
  def upsert(%__MODULE__{agent: a}, table, rows) do
    case Agent.get(a, &Map.get(&1, :on_upsert)) do
      nil -> :ok
      fun -> fun.(table, rows)
    end

    Agent.get_and_update(a, fn state ->
      calls = state.calls + 1

      if state.fail_on == calls do
        {{:error, Error.new(:request_failed, "injected failure", %{reason: :injected})},
         %{state | calls: calls}}
      else
        current = Map.get(state.tables, table.table, %{})
        zero = %{inserted: 0, updated: 0, unchanged: 0}
        {counts, current} = Enum.reduce(rows, {zero, current}, &put(&1, &2, table.key))

        commit(state, calls, table, current, counts)
      end
    end)
  end

  # Join tables, keyed by their two ID columns (WTF-352 cut 3).
  @impl true
  def upsert_join(%__MODULE__{} = c, join, rows) do
    key = fn row -> {Map.fetch!(row, join.left.column), Map.fetch!(row, join.right.column)} end
    keyed = Enum.map(rows, &Map.put(&1, :__key__, key.(&1)))
    upsert(c, %{table: join.table, key: :__key__}, keyed)
  end

  @impl true
  def prune_join(%__MODULE__{agent: a}, join, keep, owners) do
    kept =
      MapSet.new(keep, &{Map.fetch!(&1, join.left.column), Map.fetch!(&1, join.right.column)})

    Agent.get_and_update(a, fn state ->
      rows = Map.get(state.tables, join.table, %{})

      {gone, rows} =
        Map.split_with(rows, fn {{l, r} = pair, _row} ->
          not MapSet.member?(kept, pair) and (l in owners.left or r in owners.right)
        end)

      {{:ok, map_size(gone)}, %{state | tables: Map.put(state.tables, join.table, rows)}}
    end)
  end

  # A unique email identity, as the Phoenix project has (ignoring case).
  defp commit(state, calls, table, current, counts) do
    if unique_emails?(current),
      do:
        {{:ok, counts},
         %{state | calls: calls, tables: Map.put(state.tables, table.table, current)}},
      else:
        {{:error, Error.new(:request_failed, "unique email", %{sqlstate: :unique_violation})},
         %{state | calls: calls}}
  end

  defp unique_emails?(rows) do
    emails = for {_id, %{"email" => e}} <- rows, is_binary(e), do: String.downcase(e)
    length(emails) == length(Enum.uniq(emails))
  end

  defp put(row, {c, t}, key) do
    id = Map.fetch!(row, key)

    case Map.fetch(t, id) do
      :error -> {%{c | inserted: c.inserted + 1}, Map.put(t, id, row)}
      {:ok, ^row} -> {%{c | unchanged: c.unchanged + 1}, t}
      {:ok, _} -> {%{c | updated: c.updated + 1}, Map.put(t, id, row)}
    end
  end
end
