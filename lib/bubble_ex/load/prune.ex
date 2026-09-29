defmodule BubbleEx.Load.Prune do
  @moduledoc false

  # Pruning (`BubbleEx.Load.run/4` with `prune: true`, WTF-414): what a
  # complete export no longer holds, among the rows the loader itself wrote
  # (`BubbleEx.Load.Written`). Planned before any write (from the target's
  # keys and join rows, read only), reported in the dry run, and done
  # after the upserts, one batch per statement (all or nothing), each
  # batch recorded after it succeeded. Rows the loader did not write are
  # kept and reported (`:load_prune_unowned`, a warning). Holds IDs only.

  alias BubbleEx.Error
  alias BubbleEx.Load.{Export, Issues, Ledger, Plan, Written}

  defstruct written: nil,
            records: %{},
            unowned: %{},
            forget: %{},
            lists: %{},
            unowned_lists: %{},
            forget_lists: %{}

  @type pairs :: [{String.t(), String.t()}]
  @type t :: %__MODULE__{
          written: Written.t(),
          records: %{String.t() => [String.t()]},
          unowned: %{String.t() => [String.t()]},
          forget: %{String.t() => [String.t()]},
          lists: %{String.t() => pairs()},
          unowned_lists: %{String.t() => pairs()},
          forget_lists: %{String.t() => pairs()}
        }

  @doc false
  # Pruning needs a complete export (no `allow_partial`) and a ledger
  # directory (where `Written` lives).
  @spec check_options(Export.t(), keyword()) :: :ok | {:error, Error.t()}
  def check_options(export, opts) do
    cond do
      Keyword.get(opts, :allow_partial, false) ->
        {:error,
         Error.new(
           :invalid_input,
           "prune: true refuses allow_partial: it needs a complete export"
         )}

      not Export.complete?(export) ->
        {:error,
         Error.new(
           :invalid_input,
           "prune: true needs a complete export: some types did not export completely",
           %{
             types:
               for(%{"status" => s, "type" => t} <- Export.types(export), s != "complete", do: t)
           }
         )}

      Keyword.get(opts, :ledger_dir) in [nil, ""] ->
        {:error,
         Error.new(
           :invalid_input,
           "prune: true needs :ledger_dir: it records which rows the loader wrote"
         )}

      true ->
        :ok
    end
  end

  @doc false
  # The records to delete, per type: the target's keys the loader wrote
  # that the export does not hold. Refused when a type the loader wrote
  # is not in the export (pruning would delete every record of it).
  @spec plan(Written.t(), Plan.t(), map(), Export.t(), {module(), term()}) ::
          {:ok, t()} | {:error, Error.t()}
  def plan(%Written{} = written, %Plan{} = plan, scan, export, {tmod, tconf}) do
    exported = MapSet.new(Export.types(export), & &1["type"])
    planned = MapSet.new(plan.tables, & &1.type)

    missing =
      for t <- Written.types(written),
          MapSet.member?(planned, t),
          not MapSet.member?(exported, t),
          do: t

    if missing != [] do
      {:error,
       Error.new(
         :invalid_input,
         "prune: true refused: the export lacks types the loader wrote, and pruning would " <>
           "delete all of their records; export them",
         %{types: missing}
       )}
    else
      Enum.reduce_while(plan.tables, {:ok, %__MODULE__{written: written}}, fn table, {:ok, acc} ->
        tconf |> tmod.keys(table) |> keys_step(acc, table, scan)
      end)
    end
  end

  defp keys_step({:ok, keys}, acc, table, scan),
    do: {:cont, {:ok, records(acc, table.type, keys, scan)}}

  defp keys_step({:error, _} = error, _acc, _table, _scan), do: {:halt, error}

  defp records(acc, type, keys, scan) do
    exported = Map.get(scan.ids, type, MapSet.new())
    wrote = Written.records(acc.written, type)
    held = MapSet.new(keys)
    extra = Enum.reject(keys, &MapSet.member?(exported, &1))
    {owned, unowned} = Enum.split_with(extra, &MapSet.member?(wrote, &1))

    forget =
      Enum.reject(wrote, &(MapSet.member?(held, &1) or MapSet.member?(exported, &1)))

    %{
      acc
      | records: put(acc.records, type, owned),
        unowned: put(acc.unowned, type, unowned),
        forget: put(acc.forget, type, forget)
    }
  end

  defp put(map, _key, []), do: map
  defp put(map, key, list), do: Map.put(map, key, Enum.sort(list))

  @doc false
  # The IDs of `type` pruning deletes.
  @spec deleting(t() | nil, String.t()) :: MapSet.t()
  def deleting(nil, _type), do: MapSet.new()
  def deleting(%__MODULE__{records: r}, type), do: MapSet.new(Map.get(r, type, []))

  @doc false
  # Splits a list's stale rows (the target's members the export no longer
  # gives it) into those the loader wrote (pruned) and the others (kept,
  # reported); also the recorded rows already gone (forgotten).
  @spec stale(t(), map(), pairs(), MapSet.t(), pairs()) :: t()
  def stale(%__MODULE__{} = p, built, stale, loaded, stored) do
    wrote = Written.pairs(p.written, built.key)
    {owned, unowned} = Enum.split_with(stale, &MapSet.member?(wrote, &1))
    held = MapSet.new(stored)
    forget = Enum.reject(wrote, &(MapSet.member?(held, &1) or MapSet.member?(loaded, &1)))

    %{
      p
      | lists: put(p.lists, built.key, owned),
        unowned_lists: put(p.unowned_lists, built.key, unowned),
        forget_lists: put(p.forget_lists, built.key, forget)
    }
  end

  @doc false
  # The prune diagnostics: records and members pruned (info), rows kept
  # because the loader did not write them (warning). IDs only.
  @spec issues(t(), [map()], Issues.t()) :: Issues.t()
  def issues(%__MODULE__{} = p, joins, issues) do
    issues =
      Enum.reduce(p.records, issues, fn {type, ids}, acc ->
        Enum.reduce(
          ids,
          acc,
          &Issues.add(&2, :load_prune_record, type, nil, &1, :deleted_in_bubble)
        )
      end)

    issues =
      Enum.reduce(p.unowned, issues, fn {type, ids}, acc ->
        Enum.reduce(ids, acc, &Issues.add(&2, :load_prune_unowned, type, nil, &1, :not_written))
      end)

    Enum.reduce(joins, issues, &list_issues(p, &1, &2))
  end

  defp list_issues(p, %{side: side} = built, issues) do
    owner = fn {l, r} -> if side.owner == :left, do: l, else: r end
    add = &Issues.add(&2, &3, side.type, side.field, owner.(&1), &4)

    issues =
      p.lists
      |> Map.get(built.key, [])
      |> Enum.reduce(issues, &add.(&1, &2, :load_prune_join_member, :not_listed_now))

    case Map.get(p.unowned_lists, built.key, []) do
      [] ->
        issues

      unowned ->
        issues = Enum.reduce(unowned, issues, &add.(&1, &2, :load_prune_unowned, :not_written))

        # Every kept row, as `:load_join_stale_member` gives them (IDs only).
        Issues.put_details(issues, :load_prune_unowned, side.type, side.field, %{
          stale_members: %{
            table: built.join.table,
            left_column: built.join.left.column,
            right_column: built.join.right.column,
            membership_column: side.column,
            rows: Enum.map(unowned, fn {l, r} -> [l, r] end)
          }
        })
    end
  end

  @doc false
  # Prunes, after the upserts: the joins' lists, then the records, in
  # batches of `size`, each one statement, recorded in `Written` (the IDs
  # forgotten) and the run's ledger (the counts) after it succeeded.
  # Recorded IDs already gone from the target are forgotten first.
  @spec run(t(), {module(), term()}, Plan.t(), [map()], pos_integer(), {Ledger.t(), Written.t()}) ::
          {:ok, {Ledger.t(), Written.t()}} | {:error, Error.t(), {Ledger.t(), Written.t()}}
  def run(%__MODULE__{} = p, {tmod, tconf}, %Plan{} = plan, joins, size, {ledger, written}) do
    written =
      Enum.reduce(p.forget_lists, written, fn {k, pairs}, w ->
        Written.pruned_join(w, k, pairs)
      end)

    written = Enum.reduce(p.forget, written, fn {t, ids}, w -> Written.pruned(w, t, ids) end)

    list_steps =
      for built <- joins, pairs = Map.get(p.lists, built.key, []), pairs != [] do
        {built.key, pairs, fn batch -> tmod.prune_join(tconf, built.join, built.side, batch) end,
         &Written.pruned_join(&1, built.key, &2)}
      end

    record_steps =
      for table <- plan.tables, ids = Map.get(p.records, table.type, []), ids != [] do
        {table.type, ids, &delete(tmod, tconf, table, &1), &Written.pruned(&1, table.type, &2)}
      end

    Enum.reduce_while(list_steps ++ record_steps, {:ok, {ledger, written}}, fn step, {:ok, acc} ->
      case step(step, size, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _error, _acc} = error -> {:halt, error}
      end
    end)
  end

  defp delete(tmod, tconf, table, batch) do
    with {:ok, n} <- tmod.delete(tconf, table, batch), do: {:ok, %{deleted: n, cleared: 0}}
  end

  defp step({key, items, prune, forget}, size, acc) do
    items
    |> Enum.chunk_every(size)
    |> Enum.reduce_while({:ok, acc}, fn batch, {:ok, {ledger, written}} ->
      case prune.(batch) do
        {:ok, counts} ->
          written = forget.(written, batch)
          {:cont, {:ok, {Ledger.pruned(ledger, key, counts), written}}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error, {ledger, written}}}

        {:error, _} ->
          {:halt,
           {:error, Error.new(:request_failed, "the target refused a prune batch", %{type: key}),
            {ledger, written}}}
      end
    end)
  end

  @doc false
  # The report's `prune` section: per type and list, what pruning deletes
  # (`delete`, `remove`) and keeps (`unowned`), and for a real run what it
  # did over the run (`deleted`, `cleared`).
  @spec summary(t() | nil, Plan.t(), [map()], Ledger.t() | nil) :: map() | nil
  def summary(nil, _plan, _joins, _ledger), do: nil

  def summary(%__MODULE__{} = p, %Plan{} = plan, joins, ledger) do
    types =
      for %{type: type} <- plan.tables,
          entry =
            Map.merge(
              %{
                delete: length(Map.get(p.records, type, [])),
                unowned: length(Map.get(p.unowned, type, []))
              },
              done(ledger, type)
            ),
          any?(entry),
          into: %{},
          do: {type, entry}

    lists =
      for built <- joins,
          entry =
            Map.merge(
              %{
                remove: length(Map.get(p.lists, built.key, [])),
                unowned: length(Map.get(p.unowned_lists, built.key, []))
              },
              done(ledger, built.key)
            ),
          any?(entry),
          into: %{},
          do: {built.key, entry}

    %{types: types, joins: lists}
  end

  # An entry with anything to report, this invocation or earlier in the run.
  defp any?(entry), do: entry |> Map.values() |> Enum.sum() > 0

  defp done(%Ledger{} = ledger, key) do
    counts = Ledger.pruned_counts(ledger, key)
    %{deleted: counts["rows_deleted"] || 0, cleared: counts["cleared"] || 0}
  end

  defp done(_ledger, _key), do: %{}
end
