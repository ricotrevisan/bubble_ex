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

  @impl true
  def plan(%__MODULE__{project: project}, model),
    do: Loader.plan(%Loader{project: project, query: fn _, _ -> {:ok, %{rows: []}} end}, model)

  @impl true
  def identity(_), do: {:ok, "memory"}

  @impl true
  def check_schema(_, _plan), do: {:ok, []}

  @impl true
  def upsert(%__MODULE__{agent: a}, table, rows) do
    Agent.get_and_update(a, fn state ->
      calls = state.calls + 1

      if state.fail_on == calls do
        {{:error, Error.new(:request_failed, "injected failure", %{reason: :injected})},
         %{state | calls: calls}}
      else
        current = Map.get(state.tables, table.table, %{})
        zero = %{inserted: 0, updated: 0, unchanged: 0}
        {counts, current} = Enum.reduce(rows, {zero, current}, &put(&1, &2, table.key))

        {{:ok, counts},
         %{state | calls: calls, tables: Map.put(state.tables, table.table, current)}}
      end
    end)
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
