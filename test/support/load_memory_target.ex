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
      Agent.start_link(fn ->
        %{tables: %{}, calls: 0, fail_on: Keyword.get(opts, :fail_on), auth: auth(project)}
      end)

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
        keep = keep_confirmed(state, table)
        {counts, current} = Enum.reduce(rows, {zero, current}, &put(&1, &2, table.key, keep))

        commit(state, calls, table, current, counts)
      end
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

  defp auth(project) do
    case Enum.find(project.resources, &(&1.source.type == "user")) do
      nil ->
        nil

      user ->
        column = fn a -> a && (a.column || a.name) end

        %{
          type: "user",
          email_column: column.(Enum.find(user.attributes, &(&1.source[:field] == "email"))),
          confirmed_column:
            column.(Enum.find(user.attributes, &(&1.source[:auth] == "confirmed_at")))
        }
    end
  end

  # As Target.Ash.Loader: a nil confirmed_at does not clear a stored one
  # while the email is unchanged.
  defp keep_confirmed(%{auth: %{type: type, confirmed_column: c, email_column: e}}, %{type: type})
       when is_binary(c) and is_binary(e),
       do: {c, e}

  defp keep_confirmed(_state, _table), do: nil

  defp put(row, {c, t}, key, keep) do
    id = Map.fetch!(row, key)

    row =
      case {keep, Map.fetch(t, id)} do
        {{conf, email}, {:ok, old}} ->
          if is_nil(row[conf]) and old[email] == row[email],
            do: Map.put(row, conf, old[conf]),
            else: row

        _ ->
          row
      end

    case Map.fetch(t, id) do
      :error -> {%{c | inserted: c.inserted + 1}, Map.put(t, id, row)}
      {:ok, ^row} -> {%{c | unchanged: c.unchanged + 1}, t}
      {:ok, _} -> {%{c | updated: c.updated + 1}, Map.put(t, id, row)}
    end
  end
end
