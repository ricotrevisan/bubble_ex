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
        %{
          tables: %{},
          calls: 0,
          fail_on: Keyword.get(opts, :fail_on),
          prunes: 0,
          fail_prune: nil,
          marker: nil,
          locked: nil,
          auth: auth(project)
        }
      end)

    {__MODULE__, %__MODULE__{project: project, agent: agent}}
  end

  def fail_on({__MODULE__, %__MODULE__{agent: a}}, n),
    do: Agent.update(a, &%{&1 | fail_on: n, calls: 0})

  # The database's load marker: `set_marker(target, nil)` drops it, as a
  # recreated database would not have it.
  def set_marker({__MODULE__, %__MODULE__{agent: a}}, marker),
    do: Agent.update(a, &%{&1 | marker: marker})

  def marker_of({__MODULE__, %__MODULE__{agent: a}}), do: Agent.get(a, & &1.marker)

  # Another load (process `pid`) holding the lock; nil releases it.
  def hold_lock({__MODULE__, %__MODULE__{agent: a}}, pid),
    do: Agent.update(a, &%{&1 | locked: pid})

  @impl true
  def marker(%__MODULE__{agent: a}, :read), do: {:ok, Agent.get(a, & &1.marker)}

  def marker(%__MODULE__{agent: a}, :ensure) do
    Agent.get_and_update(a, fn
      %{marker: nil} = s ->
        m =
          "00000000-0000-4000-8000-" <>
            String.pad_leading("#{System.unique_integer([:positive])}", 12, "0")

        {{:ok, m}, %{s | marker: m}}

      s ->
        {{:ok, s.marker}, s}
    end)
  end

  @impl true
  def with_lock(%__MODULE__{agent: a}, fun) do
    # As a session lock: a process that died (killed mid-run) holds none.
    taken =
      Agent.get_and_update(a, fn
        %{locked: pid} = s when is_pid(pid) and pid != self() ->
          if Process.alive?(pid), do: {false, s}, else: {true, %{s | locked: self()}}

        s ->
          {true, %{s | locked: self()}}
      end)

    if taken do
      try do
        fun.()
      after
        Agent.update(a, &%{&1 | locked: nil})
      end
    else
      {:error,
       BubbleEx.Error.new(:invalid_input, "another load holds this target's lock", %{
         reason: :locked
       })}
    end
  end

  # Makes the Nth delete/prune_join call fail (a crash mid-prune).
  def fail_prune({__MODULE__, %__MODULE__{agent: a}}, n),
    do: Agent.update(a, &%{&1 | fail_prune: n, prunes: 0})

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

  @impl true
  def join_members(%__MODULE__{agent: a}, join, side, owners) do
    owner = if side.owner == :left, do: join.left.column, else: join.right.column
    owners = if owners == :all, do: :all, else: MapSet.new(owners)

    rows =
      for {{l, r}, row} <- Agent.get(a, &Map.get(&1.tables, join.table, %{})),
          member?(row[side.column], side.kind),
          owners == :all or MapSet.member?(owners, row[owner]),
          do: {l, r}

    {:ok, Enum.sort(rows)}
  end

  defp member?(true, :flag), do: true
  defp member?(_, :flag), do: false
  defp member?(value, :position), do: value != nil

  # Join tables, keyed by their two ID columns (WTF-352 cut 3): a list's
  # upsert sets only its own column of an existing row.
  @impl true
  def upsert_join(%__MODULE__{agent: a}, join, side, rows) do
    key = fn row -> {Map.fetch!(row, join.left.column), Map.fetch!(row, join.right.column)} end

    Agent.get_and_update(a, fn state ->
      calls = state.calls + 1

      if state.fail_on == calls do
        {{:error, Error.new(:request_failed, "injected failure", %{reason: :injected})},
         %{state | calls: calls}}
      else
        current = Map.get(state.tables, join.table, %{})
        zero = %{inserted: 0, updated: 0, unchanged: 0}

        {counts, current} =
          Enum.reduce(rows, {zero, current}, &put_member(&1, &2, key.(&1), side.column))

        {{:ok, counts},
         %{state | calls: calls, tables: Map.put(state.tables, join.table, current)}}
      end
    end)
  end

  # Pruning (WTF-414). `fail_prune/2` makes the Nth `delete/3` or
  # `prune_join/4` call fail (a crash mid-prune); a failing batch changes
  # nothing, as one statement would not.
  @impl true
  def keys(%__MODULE__{agent: a}, table),
    do: {:ok, a |> Agent.get(&Map.get(&1.tables, table.table, %{})) |> Map.keys() |> Enum.sort()}

  @impl true
  def delete(%__MODULE__{agent: a}, table, ids) do
    failing(a, fn state ->
      current = Map.get(state.tables, table.table, %{})
      gone = Enum.count(ids, &Map.has_key?(current, &1))
      {{:ok, gone}, put_table(state, table.table, Map.drop(current, ids))}
    end)
  end

  @impl true
  def prune_join(%__MODULE__{agent: a}, join, side, pairs) do
    others = for s <- join.sides, s.column != side.column, do: s

    failing(a, fn state ->
      zero = {%{deleted: 0, cleared: 0}, Map.get(state.tables, join.table, %{})}
      {counts, current} = Enum.reduce(pairs, zero, &remove_member(&1, &2, side, others))
      {{:ok, counts}, put_table(state, join.table, current)}
    end)
  end

  # One list's row: its column cleared, or the row deleted when no other
  # list holds it.
  defp remove_member(pair, {counts, t}, side, others) do
    row = Map.get(t, pair)

    cond do
      row == nil or not member?(row[side.column], side.kind) ->
        {counts, t}

      Enum.any?(others, &member?(row[&1.column], &1.kind)) ->
        {%{counts | cleared: counts.cleared + 1},
         Map.put(t, pair, Map.put(row, side.column, nil))}

      true ->
        {%{counts | deleted: counts.deleted + 1}, Map.delete(t, pair)}
    end
  end

  defp failing(agent, fun) do
    Agent.get_and_update(agent, fn state ->
      state = %{state | prunes: state.prunes + 1}

      if state.fail_prune == state.prunes,
        do:
          {{:error, Error.new(:request_failed, "injected failure", %{reason: :injected})}, state},
        else: fun.(state)
    end)
  end

  defp put_table(state, name, rows), do: %{state | tables: Map.put(state.tables, name, rows)}

  # One list's row: inserted, or only the list's column updated.
  defp put_member(row, {c, t}, k, column) do
    case Map.fetch(t, k) do
      :error ->
        {%{c | inserted: c.inserted + 1}, Map.put(t, k, row)}

      {:ok, %{^column => value}} when value == :erlang.map_get(column, row) ->
        {%{c | unchanged: c.unchanged + 1}, t}

      {:ok, old} ->
        {%{c | updated: c.updated + 1}, Map.put(t, k, Map.put(old, column, row[column]))}
    end
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
