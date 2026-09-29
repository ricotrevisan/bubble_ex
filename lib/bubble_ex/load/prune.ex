defmodule BubbleEx.Load.Prune do
  @moduledoc false

  # Pruning (`BubbleEx.Load.run/4` with `prune:`, WTF-414): what a complete
  # export no longer holds, among the rows the loader itself wrote
  # (`BubbleEx.Load.Written`). Planned before any write (from the target's
  # keys and join rows, read only), reported and hashed in the dry run,
  # confirmed by that hash in the real run, and done after the upserts, one
  # batch per statement (all or nothing), each batch recorded after it
  # succeeded. Refused, before anything is written, for an export that may
  # not be the one the target was loaded from (see `check_binding/4`) and,
  # unless named in `allow_mass_delete`, when a type or list would lose all
  # or most of the loader's rows. Holds IDs only.

  alias BubbleEx.{CanonicalJson, Error}
  alias BubbleEx.Load.{Export, Issues, Ledger, Plan, Written}

  defstruct written: nil,
            marker: nil,
            options: %{},
            records: %{},
            owned: %{},
            unowned: %{},
            forget: %{},
            lists: %{},
            owned_lists: %{},
            unowned_lists: %{}

  @type pairs :: [{String.t(), String.t()}]
  @type t :: %__MODULE__{
          written: Written.t(),
          marker: String.t() | nil,
          options: map(),
          records: %{String.t() => [String.t()]},
          owned: %{String.t() => non_neg_integer()},
          unowned: %{String.t() => [String.t()]},
          forget: %{String.t() => [String.t()]},
          lists: %{String.t() => pairs()},
          owned_lists: %{String.t() => non_neg_integer()},
          unowned_lists: %{String.t() => pairs()}
        }

  @doc false
  # The `prune:` option: nil (no pruning), or its settings. `true` plans
  # and reports only (a dry run); a real run needs `expect:`, the dry run's
  # `report.prune.sha256`.
  @spec options(keyword()) :: {:ok, map() | nil} | {:error, Error.t()}
  def options(opts) do
    case Keyword.get(opts, :prune) do
      p when p in [nil, false] -> {:ok, nil}
      true -> {:ok, settings([])}
      kw when is_list(kw) -> validate(kw)
      _ -> {:error, invalid("prune: must be true or a keyword list")}
    end
  end

  @known [:expect, :allow_mass_delete, :acknowledge_unowned]

  defp validate(kw) do
    checks = [
      {Keyword.keyword?(kw) and Enum.all?(Keyword.keys(kw), &(&1 in @known)),
       "prune: takes :expect, :allow_mass_delete and :acknowledge_unowned"},
      {is_nil(kw[:expect]) or is_binary(kw[:expect]),
       "prune: expect: must be the dry run's report.prune.sha256"},
      {texts?(kw[:allow_mass_delete] || []),
       "prune: allow_mass_delete: must list data types or join list keys"},
      {acknowledgement?(kw[:acknowledge_unowned] || %{}),
       "prune: acknowledge_unowned: must map join list keys to their [left ID, right ID] rows"}
    ]

    case Enum.find(checks, &(not elem(&1, 0))) do
      nil -> {:ok, settings(kw)}
      {false, message} -> {:error, invalid(message)}
    end
  end

  defp texts?(list), do: is_list(list) and Enum.all?(list, &is_binary/1)

  defp acknowledgement?(ack),
    do:
      is_map(ack) and
        Enum.all?(ack, fn {k, rows} ->
          is_binary(k) and is_list(rows) and
            Enum.all?(rows, &match?([l, r] when is_binary(l) and is_binary(r), &1))
        end)

  defp settings(kw),
    do: %{
      expect: kw[:expect],
      allow_mass_delete: MapSet.new(kw[:allow_mass_delete] || []),
      acknowledge_unowned:
        Map.new(kw[:acknowledge_unowned] || %{}, fn {k, rows} ->
          {k, MapSet.new(rows, &List.to_tuple/1)}
        end)
    }

  defp invalid(message), do: Error.new(:invalid_input, message)

  @doc false
  # Pruning needs a complete export (no `allow_partial`), a ledger
  # directory (where `Written` lives), and for a real run the dry run's
  # hash.
  @spec check_options(Export.t(), keyword(), map(), boolean()) :: :ok | {:error, Error.t()}
  def check_options(export, opts, settings, dry?) do
    cond do
      Keyword.get(opts, :allow_partial, false) ->
        {:error, invalid("pruning refuses allow_partial: it needs a complete export")}

      not Export.complete?(export) ->
        {:error,
         Error.new(
           :invalid_input,
           "pruning needs a complete export: some types did not export completely",
           %{
             types:
               for(%{"status" => s, "type" => t} <- Export.types(export), s != "complete", do: t)
           }
         )}

      Keyword.get(opts, :ledger_dir) in [nil, ""] ->
        {:error, invalid("pruning needs :ledger_dir: it records which rows the loader wrote")}

      not dry? and settings.expect == nil ->
        {:error,
         invalid(
           "a pruning run needs confirmation: dry-run with prune: true, check report.prune, " <>
             "then run with prune: [expect: report.prune.sha256]"
         )}

      true ->
        :ok
    end
  end

  @doc false
  # The export and the database must be the ones the record describes:
  #   * the database: its marker is the record's (a recreated database has
  #     another, or none while the record holds IDs)
  #   * the export: the record's app and base URL (not another app, not
  #     another version), created no earlier than the newest export loaded
  @spec check_binding(Written.t(), String.t() | nil, Export.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def check_binding(%Written{} = written, marker, %Export{} = export, _opts) do
    if Written.empty?(written),
      do: :ok,
      else:
        with(
          :ok <- check_database(Written.bound(written), marker),
          do: check_export(Written.bound(written), export)
        )
  end

  defp check_database(_bound, nil),
    do:
      refuse(
        "the target has no load marker but the written record holds rows: it is not the " <>
          "database the loader wrote (recreated?)",
        :marker_missing
      )

  defp check_database(%{marker: marker}, marker), do: :ok

  defp check_database(_bound, _marker),
    do:
      refuse(
        "the target's load marker is not the written record's: it is not the database the " <>
          "loader wrote",
        :marker_mismatch
      )

  defp check_export(b, export) do
    created = export.manifest["created_at"]

    cond do
      b.app != export.manifest["app"] ->
        refuse("the export is of another app than the one loaded into this target", :app)

      b.base_url != get_in(export.manifest, ["source", "base_url"]) ->
        refuse(
          "the export is of another app version or host (source.base_url) than the one loaded",
          :base_url
        )

      not is_binary(created) or match?({:error, _}, DateTime.from_iso8601(created)) ->
        refuse("the export has no readable created_at; pruning cannot tell its age", :created_at)

      is_binary(b.newest_export) and Written.later?(b.newest_export, created) ->
        refuse(
          "the export is older than one already loaded into this target; export again",
          :older_export
        )

      true ->
        :ok
    end
  end

  defp refuse(message, reason),
    do: {:error, Error.new(:invalid_input, "pruning refused: " <> message, %{reason: reason})}

  @doc false
  # The records to delete, per type: the target's keys the loader wrote
  # that the export does not hold. Refused when a type the loader wrote
  # is not in the export (pruning would delete every record of it).
  @spec plan(
          Written.t(),
          String.t() | nil,
          map(),
          Plan.t(),
          map(),
          Export.t(),
          {module(), term()}
        ) ::
          {:ok, t()} | {:error, Error.t()}
  def plan(%Written{} = written, marker, settings, %Plan{} = plan, scan, export, {tmod, tconf}) do
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
         "pruning refused: the export lacks types the loader wrote, and pruning would " <>
           "delete all of their records; export them",
         %{types: missing}
       )}
    else
      acc = %__MODULE__{written: written, marker: marker, options: settings}

      Enum.reduce_while(plan.tables, {:ok, acc}, fn table, {:ok, acc} ->
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
    forget = Enum.reject(wrote, &(MapSet.member?(held, &1) or MapSet.member?(exported, &1)))
    present = Enum.count(wrote, &MapSet.member?(held, &1))

    %{
      acc
      | records: put(acc.records, type, owned),
        owned: if(present > 0, do: Map.put(acc.owned, type, present), else: acc.owned),
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
  # gives it) into those the loader wrote (pruned), those the caller
  # acknowledged in `acknowledge_unowned` (kept, a warning), and the
  # others, returned: they block the run (`:load_join_stale_member`).
  @spec stale(t(), map(), pairs(), pairs()) :: {t(), pairs()}
  def stale(%__MODULE__{} = p, built, stale, stored) do
    wrote = Written.pairs(p.written, built.key)
    {owned, unowned} = Enum.split_with(stale, &MapSet.member?(wrote, &1))
    ack = Map.get(p.options.acknowledge_unowned, built.key, MapSet.new())
    {acknowledged, blocking} = Enum.split_with(unowned, &MapSet.member?(ack, &1))
    present = Enum.count(stored, &MapSet.member?(wrote, &1))

    p = %{
      p
      | lists: put(p.lists, built.key, owned),
        owned_lists:
          if(present > 0, do: Map.put(p.owned_lists, built.key, present), else: p.owned_lists),
        unowned_lists: put(p.unowned_lists, built.key, acknowledged)
    }

    {p, blocking}
  end

  @doc false
  # The recorded rows of a list its target rows no longer hold (the app
  # removed them, or a crash between a prune and its record): forgotten,
  # so a row the app adds back later is not the loader's.
  @spec missing(Written.t(), String.t(), pairs()) :: pairs()
  def missing(%Written{} = written, key, stored) do
    held = MapSet.new(stored)
    written |> Written.pairs(key) |> Enum.reject(&MapSet.member?(held, &1)) |> Enum.sort()
  end

  @doc false
  # The prune diagnostics: records and members pruned (info), rows kept
  # because the loader did not write them (warning), and types or lists
  # that would lose all or most of the loader's rows (error, blocking
  # unless named in `allow_mass_delete`). IDs only.
  @spec issues(t(), [map()], Issues.t()) :: Issues.t()
  def issues(%__MODULE__{} = p, joins, issues) do
    issues =
      Enum.reduce(p.records, issues, fn {type, ids}, acc ->
        acc =
          Enum.reduce(
            ids,
            acc,
            &Issues.add(&2, :load_prune_record, type, nil, &1, :deleted_in_bubble)
          )

        mass(acc, p, type, nil, ids, Map.get(p.owned, type, 0))
      end)

    issues =
      Enum.reduce(p.unowned, issues, fn {type, ids}, acc ->
        Enum.reduce(ids, acc, &Issues.add(&2, :load_prune_unowned, type, nil, &1, :not_written))
      end)

    Enum.reduce(joins, issues, &list_issues(p, &1, &2))
  end

  # All, or more than half, of the loader's rows of a type or list.
  defp mass(issues, p, key_or_type, field_or_nil, samples, owned, key \\ nil) do
    key = key || key_or_type
    n = length(samples)

    if n > 0 and (n >= owned or 2 * n > owned) and
         not MapSet.member?(p.options.allow_mass_delete, key) do
      issues =
        Enum.reduce(samples, issues, fn id, acc ->
          Issues.add(acc, :load_prune_mass_delete, key_or_type, field_or_nil, id, nil)
        end)

      Issues.put_details(issues, :load_prune_mass_delete, key_or_type, field_or_nil, %{
        owned: owned,
        key: key
      })
    else
      issues
    end
  end

  defp list_issues(p, %{side: side} = built, issues) do
    owner = fn {l, r} -> if side.owner == :left, do: l, else: r end
    add = &Issues.add(&2, &3, side.type, side.field, owner.(&1), &4)
    removing = Map.get(p.lists, built.key, [])

    issues =
      removing
      |> Enum.reduce(issues, &add.(&1, &2, :load_prune_join_member, :not_listed_now))
      |> mass(
        p,
        side.type,
        side.field,
        Enum.map(removing, owner),
        Map.get(p.owned_lists, built.key, 0),
        built.key
      )

    case Map.get(p.unowned_lists, built.key, []) do
      [] ->
        issues

      unowned ->
        issues = Enum.reduce(unowned, issues, &add.(&1, &2, :load_prune_unowned, :not_written))

        # The kept rows, as `:load_join_stale_member` gives them (IDs only,
        # capped).
        Issues.put_details(
          issues,
          :load_prune_unowned,
          side.type,
          side.field,
          Issues.stale_members(built.join, side, unowned)
        )
    end
  end

  @doc false
  # The plan's hash, which confirms it (`prune: [expect: sha256]`): the
  # export, the database (identity and marker) and every row it deletes.
  @spec sha256(t(), Export.t(), String.t()) :: String.t()
  def sha256(%__MODULE__{} = p, %Export{} = export, identity) do
    CanonicalJson.sha256(%{
      "export" => export.sha256,
      "target" => identity,
      "marker" => p.marker,
      "records" => p.records,
      "lists" => lists_json(p.lists)
    })
  end

  defp lists_json(lists),
    do: Map.new(lists, fn {k, pairs} -> {k, Enum.map(pairs, &Tuple.to_list/1)} end)

  @doc false
  # A real run prunes the plan its caller confirmed: `expect` is this
  # plan's hash, or, resuming an interrupted run, the hash of the plan
  # the run's ledger recorded, of which this plan is what is left.
  @spec confirm(t(), String.t(), map() | nil) :: :ok | {:error, Error.t()}
  # A refusal names neither hash: the confirming one comes only from a dry
  # run, whose report the caller reads before confirming.
  def confirm(%__MODULE__{} = p, sha, confirmed) do
    expect = p.options.expect

    cond do
      expect == sha ->
        :ok

      is_map(confirmed) and confirmed["sha256"] == expect and within?(p, confirmed) ->
        :ok

      true ->
        {:error,
         Error.new(
           :invalid_input,
           "pruning refused: the prune plan is not the one confirmed (prune: [expect: ...]). " <>
             "Dry-run with prune: true, check report.prune, and confirm with its sha256",
           %{reason: :unconfirmed}
         )}
    end
  end

  defp within?(p, confirmed) do
    records = confirmed["records"] || %{}
    lists = confirmed["lists"] || %{}

    Enum.all?(p.records, fn {t, ids} ->
      MapSet.subset?(MapSet.new(ids), MapSet.new(records[t] || []))
    end) and
      Enum.all?(p.lists, fn {k, pairs} ->
        MapSet.subset?(
          MapSet.new(pairs, &Tuple.to_list/1),
          MapSet.new(lists[k] || [])
        )
      end)
  end

  @doc false
  # Prunes, after the upserts: the joins' lists, then the records, in
  # batches of `size`, each one statement, recorded in `Written` (the IDs
  # forgotten) and the run's ledger (the counts) after it succeeded.
  # Recorded IDs already gone from the target are forgotten first.
  @spec run(t(), {module(), term()}, Plan.t(), [map()], pos_integer(), {Ledger.t(), Written.t()}) ::
          {:ok, {Ledger.t(), Written.t()}} | {:error, Error.t(), {Ledger.t(), Written.t()}}
  def run(%__MODULE__{} = p, {tmod, tconf}, %Plan{} = plan, joins, size, {ledger, written}) do
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
  # The report's `prune` section: the plan's `sha256`, and per type and
  # list what pruning deletes (`delete`, `remove`), the loader's rows the
  # target holds (`owned`) and what it keeps (`unowned`), and for a real
  # run what it did over the run (`deleted`, `cleared`).
  @spec summary(t() | nil, String.t() | nil, Plan.t(), [map()], Ledger.t() | nil) :: map() | nil
  def summary(nil, _sha, _plan, _joins, _ledger), do: nil

  def summary(%__MODULE__{} = p, sha, %Plan{} = plan, joins, ledger) do
    types =
      for %{type: type} <- plan.tables,
          entry =
            Map.merge(
              %{
                delete: length(Map.get(p.records, type, [])),
                owned: Map.get(p.owned, type, 0),
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
                owned: Map.get(p.owned_lists, built.key, 0),
                unowned: length(Map.get(p.unowned_lists, built.key, []))
              },
              done(ledger, built.key)
            ),
          any?(entry),
          into: %{},
          do: {built.key, entry}

    %{sha256: sha, types: types, joins: lists}
  end

  # An entry with anything to delete, keep or report.
  defp any?(entry), do: entry |> Map.delete(:owned) |> Map.values() |> Enum.sum() > 0

  defp done(%Ledger{} = ledger, key) do
    counts = Ledger.pruned_counts(ledger, key)
    %{deleted: counts["rows_deleted"] || 0, cleared: counts["cleared"] || 0}
  end

  defp done(_ledger, _key), do: %{}
end
