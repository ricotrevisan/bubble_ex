defmodule BubbleEx.Load.Scan do
  @moduledoc false

  # The loader's first pass over an export (`BubbleEx.Load`): row counts,
  # record IDs per type (for dangling references), the copy of each
  # duplicated ID that loads, the values derived-field drift and the join
  # tables need, users'
  # emails, the Bubble files the rows reference, and the row- and
  # type-level issues. Holds values in memory only; nothing leaves the
  # process.

  alias BubbleEx.Load.{Convert, Export, Files, Issues, Plan}
  alias BubbleEx.Model
  alias BubbleEx.Model.{DataType, Field}

  # Data API members of a row that are not fields.
  @not_fields ~w(_id _type authentication user_signed_up)

  @type t :: %__MODULE__{}

  defstruct keys: %{},
            types: %{},
            winners: %{},
            ids: %{},
            values: %{},
            auth: %{},
            files: MapSet.new(),
            issues: %{}

  @doc false
  def run(%Export{} = export, %Model{} = model, %Plan{} = plan, opts) do
    overrides = Keyword.get(opts, :keys, %{})
    needed = needed(plan, model)
    restricted = restricted_types(model)

    acc = %__MODULE__{issues: type_issues(export, plan)}

    Enum.reduce(plan.tables, acc, fn table, acc ->
      type = Model.data_type(model, table.type)

      keys =
        type
        |> keys(Map.get(overrides, table.type, %{}))
        |> skip(for(%{field: f, reason: :dropped} <- table.skipped, do: f))

      acc = %{acc | keys: Map.put(acc.keys, table.type, keys)}

      ctx = %{
        table: table,
        keys: keys,
        needed: Map.get(needed, table.type, []),
        plan: plan,
        app_hosts: Keyword.get(opts, :app_hosts, []),
        restricted: MapSet.member?(restricted, table.type)
      }

      scan_type(export, ctx, acc)
    end)
    |> finish(plan)
  end

  # --- keys ---------------------------------------------------------------------------

  @doc false
  # Row key => {:field, id} | {:deleted, id} | {:ambiguous, ids}: the
  # owner's explicit `overrides` first; then live fields by ID and by
  # display name, where a key naming two live fields (two fields sharing a
  # display name, or a display name that is another field's ID) is
  # ambiguous, never resolved by order; then deleted fields, for keys no
  # live field claims.
  def keys(%DataType{} = type, overrides) do
    {gone, live} =
      (type.system_fields ++ type.fields)
      |> Enum.split_with(&(&1.deleted or not is_nil(&1.raw)))

    live_keys =
      (Enum.map(live, &{&1.id, &1.id}) ++ Enum.map(live, &{&1.name, &1.id}))
      |> Enum.reject(&is_nil(elem(&1, 0)))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {key, ids} ->
        case Enum.uniq(ids) do
          [id] -> {key, {:field, id}}
          ids -> {key, {:ambiguous, Enum.sort(ids)}}
        end
      end)

    base =
      (Enum.map(gone, &{&1.id, &1.id}) ++ Enum.map(gone, &{&1.name, &1.id}))
      |> Enum.reject(&is_nil(elem(&1, 0)))
      |> Enum.reduce(live_keys, fn {key, id}, acc -> Map.put_new(acc, key, {:deleted, id}) end)

    Map.merge(base, Map.new(overrides, fn {k, f} -> {k, {:field, f}} end))
  end

  def keys(nil, _overrides), do: %{}

  # Keys of fields an owner dropped (WTF-422, the table's `skipped`) are
  # reported, not loaded, like a deleted field's.
  defp skip(keys, []), do: keys

  defp skip(keys, dropped) do
    dropped = MapSet.new(dropped)

    Map.new(keys, fn
      {key, {:field, f}} ->
        {key, if(MapSet.member?(dropped, f), do: {:dropped, f}, else: {:field, f})}

      other ->
        other
    end)
  end

  @doc false
  # Checks the owner's key map: `%{type => %{row key => live field ID}}`.
  def check_keys(%Model{} = model, overrides) when is_map(overrides) do
    bad =
      for {type, map} <- overrides,
          {key, field} <- (is_map(map) && map) || [{nil, nil}],
          not (is_binary(key) and live_field?(model, type, field)),
          do: "#{type}: #{inspect(key)} => #{inspect(field)}"

    if bad == [],
      do: :ok,
      else:
        {:error,
         BubbleEx.Error.new(
           :invalid_input,
           "the :keys map names fields the Model does not have",
           %{
             entries: Enum.take(Enum.sort(bad), 20)
           }
         )}
  end

  def check_keys(_model, _overrides),
    do:
      {:error, BubbleEx.Error.new(:invalid_input, ":keys must be %{type => %{key => field ID}}")}

  defp live_field?(model, type, field) when is_binary(field) do
    case Model.field(model, type, field) do
      {:ok, %Field{deleted: false, raw: nil}} -> true
      _ -> false
    end
  end

  defp live_field?(_model, _type, _field), do: false

  @doc false
  # The row as field ID => stored value, and the keys that name a deleted
  # (or dropped: `{:dropped, field}`) field, no field, or several fields.
  def fields(row, keys) do
    Enum.reduce(row, {%{}, [], [], []}, fn {key, v}, {fields, deleted, unknown, ambiguous} ->
      case Map.get(keys, key) do
        {:field, f} -> {Map.put(fields, f, v), deleted, unknown, ambiguous}
        {:deleted, f} -> {fields, [f | deleted], unknown, ambiguous}
        {:dropped, f} -> {fields, [{:dropped, f} | deleted], unknown, ambiguous}
        {:ambiguous, _} -> {fields, deleted, unknown, [key | ambiguous]}
        nil when key in @not_fields -> {fields, deleted, unknown, ambiguous}
        nil -> {fields, deleted, [key | unknown], ambiguous}
      end
    end)
  end

  # --- types ----------------------------------------------------------------------------

  defp type_issues(export, plan) do
    planned = MapSet.new(plan.tables, & &1.type)
    exported = MapSet.new(Export.types(export), & &1["type"])

    issues =
      Enum.reduce(Export.types(export), Issues.new(), fn entry, acc ->
        cond do
          entry["status"] != "complete" ->
            Issues.add(acc, :load_export_partial, entry["type"], nil, nil, :failed)

          # counted as exported, 0 included: a dropped type is reported
          entry["type"] in plan.dropped ->
            Issues.put_count(acc, :load_type_dropped, entry["type"], nil, rows(entry))

          not MapSet.member?(planned, entry["type"]) ->
            Issues.add_count(
              acc,
              :load_type_unmapped,
              entry["type"],
              nil,
              max(entry["rows"] || 0, 1)
            )

          true ->
            acc
        end
      end)

    Enum.reduce(plan.tables, issues, fn t, acc ->
      if MapSet.member?(exported, t.type),
        do: acc,
        else: Issues.add(acc, :load_type_not_exported, t.type, nil, nil, :missing)
    end)
  end

  defp rows(%{"rows" => n}) when is_integer(n) and n >= 0, do: n
  defp rows(_entry), do: 0

  # Types whose privacy rules do not let every user view attached files.
  defp restricted_types(model) do
    for %DataType{privacy: privacy, rules: rules} = t <- model.data_types,
        privacy == :unavailable or
          (privacy == :present and
             Enum.any?(
               rules,
               &(is_nil(&1.permissions) or &1.permissions.view_attachments != true)
             )),
        into: MapSet.new(),
        do: t.id
  end

  defp scan_type(export, ctx, acc) do
    t = ctx.table.type
    init = %{rows: 0, invalid: 0, modified: %{}}

    {state, acc} =
      export
      |> Export.rows(t)
      |> Stream.with_index()
      |> Enum.reduce({init, acc}, fn {row, idx}, {state, acc} ->
        row(row, idx, ctx, state, acc)
      end)

    %{
      acc
      | types: Map.put(acc.types, t, %{rows: state.rows, invalid: state.invalid}),
        winners: Map.put_new(acc.winners, t, %{})
    }
  end

  defp row(%{"_id" => id} = row, idx, ctx, state, acc) when is_binary(id) and id != "" do
    t = ctx.table.type
    state = %{state | rows: state.rows + 1}
    {fields, deleted, unknown, ambiguous} = fields(row, ctx.keys)
    acc = row_issues(acc, t, id, deleted, unknown, ambiguous)

    acc =
      if Convert.record_id?(id),
        do: acc,
        else: issue(acc, :load_unexpected_id_format, t, nil, id, :shape)

    acc = files(acc, ctx, fields, id)

    modified = modified(fields["Modified Date"])
    winners = Map.get(acc.winners, t, %{})

    {best?, acc} =
      case Map.fetch(winners, id) do
        :error ->
          {true, acc}

        {:ok, _} ->
          acc = issue(acc, :load_duplicate_record, t, nil, id, :duplicate)
          {compare(modified, state.modified[id]) != :lt, acc}
      end

    if best? do
      acc = %{
        acc
        | winners: Map.put(acc.winners, t, Map.put(winners, id, idx)),
          values: put_values(acc.values, t, id, Map.take(fields, ctx.needed)),
          auth: auth(acc.auth, ctx.plan, t, id, row, fields)
      }

      {%{state | modified: Map.put(state.modified, id, modified)}, acc}
    else
      {state, acc}
    end
  end

  defp row(_row, _idx, ctx, state, acc) do
    t = ctx.table.type
    acc = issue(acc, :load_invalid_record_id, t, nil, nil, :missing_id)
    {%{state | rows: state.rows + 1, invalid: state.invalid + 1}, acc}
  end

  defp row_issues(acc, t, id, deleted, unknown, ambiguous) do
    acc = Enum.reduce(deleted, acc, &gone(&2, t, &1, id))
    acc = Enum.reduce(ambiguous, acc, &issue(&2, :load_ambiguous_key, t, nil, id, {:keys, &1}))
    Enum.reduce(unknown, acc, &issue(&2, :load_unmapped_key, t, nil, id, {:keys, &1}))
  end

  # A dropped field's data is counted only: no sample record IDs.
  defp gone(acc, t, {:dropped, f}, _id), do: issue(acc, :load_dropped_field_data, t, f, nil, nil)
  defp gone(acc, t, f, id), do: issue(acc, :load_deleted_field_data, t, f, id, :deleted)

  defp issue(%__MODULE__{} = acc, code, type, field, id, detail),
    do: %{acc | issues: Issues.add(acc.issues, code, type, field, id, detail)}

  defp put_values(values, _t, _id, fields) when map_size(fields) == 0, do: values

  defp put_values(values, t, id, fields),
    do: Map.update(values, t, %{id => fields}, &Map.put(&1, id, fields))

  # Bubble file URLs the file columns reference.
  defp files(acc, ctx, fields, id) do
    Enum.reduce(ctx.table.columns, acc, fn
      %Plan.Column{files: true, field: f}, acc ->
        urls =
          fields
          |> Map.get(f)
          |> List.wrap()
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&Files.normalize/1)

        bubble = Enum.filter(urls, &Files.bubble?(&1, ctx.app_hosts))
        acc = %{acc | files: Enum.into(bubble, acc.files)}

        if ctx.restricted and Enum.any?(bubble, &(Files.visibility(&1) == :public)),
          do: issue(acc, :load_file_public_on_restricted_type, ctx.table.type, f, id, :public),
          else: acc

      _, acc ->
        acc
    end)
  end

  # --- users ------------------------------------------------------------------------------

  defp auth(auth, %Plan{auth: %Plan.Auth{type: t}}, t, id, row, fields) do
    Map.put(auth, id, %{
      email: normalized_email(email(row, fields)),
      confirmed: confirmed(row),
      confirmed_at: confirmed_at(row, fields),
      providers: providers(row)
    })
  end

  defp auth(auth, _plan, _t, _id, _row, _fields), do: auth

  @doc false
  # A user's email: the `email` field, else the Data API's
  # `authentication.email.email`.
  def email(row, fields) do
    case Map.get(fields, "email") do
      e when is_binary(e) -> e
      _ -> get_in(row, ["authentication", "email", "email"])
    end
  end

  @doc false
  def confirmed(row) do
    case get_in(row, ["authentication", "email", "email_confirmed"]) do
      b when is_boolean(b) -> b
      _ -> nil
    end
  end

  @doc false
  # When a user's email was confirmed (WTF-413). Bubble keeps a flag, not
  # a time: a confirmed user's Created Date (stable, so reruns and delta
  # syncs leave the user unchanged), `:undated` for a confirmed user
  # without a readable one, else nil.
  def confirmed_at(row, fields) do
    with true <- confirmed(row),
         {at, []} when is_binary(at) <- Convert.encode(:datetime, fields["Created Date"]) do
      at
    else
      {_nil, _found} -> :undated
      _unconfirmed -> nil
    end
  end

  defp providers(%{"authentication" => %{} = a}),
    do:
      a |> Map.keys() |> Enum.reject(&(&1 == "email")) |> Enum.filter(&is_binary/1) |> Enum.sort()

  defp providers(_), do: []

  defp normalized_email(e) when is_binary(e) do
    case String.trim(e) do
      "" -> nil
      e -> String.downcase(e)
    end
  end

  defp normalized_email(_), do: nil

  # --- modified dates -------------------------------------------------------------------------

  defp modified(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :microsecond)
      _ -> nil
    end
  end

  defp modified(v) when is_integer(v), do: v * 1000
  defp modified(_), do: nil

  defp compare(nil, _), do: :eq
  defp compare(_, nil), do: :gt
  defp compare(a, b) when a > b, do: :gt
  defp compare(a, b) when a < b, do: :lt
  defp compare(_, _), do: :eq

  # --- after the pass ----------------------------------------------------------------------------

  defp finish(acc, plan) do
    ids = Map.new(acc.winners, fn {t, w} -> {t, w |> Map.keys() |> MapSet.new()} end)
    acc = %{acc | ids: ids}
    %{acc | issues: auth_issues(acc, plan.auth)}
  end

  defp auth_issues(%{auth: auth, issues: issues}, _auth) when map_size(auth) == 0, do: issues

  defp auth_issues(acc, %Plan.Auth{type: type}) do
    dupes =
      acc.auth
      |> Enum.filter(fn {_id, a} -> a.email end)
      |> Enum.group_by(fn {_id, a} -> a.email end, fn {id, _} -> id end)
      |> Enum.filter(fn {_e, ids} -> length(ids) > 1 end)
      |> Enum.flat_map(fn {_e, ids} -> Enum.sort(ids) end)

    issues =
      Enum.reduce(
        dupes,
        acc.issues,
        &Issues.add(&2, :load_duplicate_email, type, "email", &1, :duplicate)
      )

    acc.auth
    |> Enum.sort()
    |> Enum.reduce(issues, fn {id, a}, issues ->
      Enum.reduce(
        a.providers,
        issues,
        &Issues.add(&2, :load_auth_provider_unmigrated, type, nil, id, {:providers, &1})
      )
    end)
  end

  # --- derived fields ----------------------------------------------------------------------------

  # The fields whose values drift and the join tables need, per type.
  defp needed(plan, model) do
    joined = for j <- plan.joins, side <- j.sides, do: {side.type, side.field}

    plan.tables
    |> Enum.flat_map(fn table ->
      Enum.flat_map(table.derived, fn d ->
        [{table.type, d.field} | derivation_fields(d.derivation, table.type, model)]
      end)
    end)
    |> Enum.concat(joined)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {t, fs} -> {t, Enum.uniq(fs)} end)
  end

  defp derivation_fields({:related, path, {st, sf}}, t, model),
    do: path_fields(path, t, model) ++ [{st, sf}]

  defp derivation_fields({:count, path}, t, model), do: path_fields(path, t, model)
  defp derivation_fields({:reverse, rt, rf}, _t, _model), do: [{rt, rf}]

  defp path_fields([], _t, _model), do: []

  defp path_fields([{:ref, f} | rest], t, model),
    do: [{t, f} | path_fields(rest, ref_target(model, t, f), model)]

  defp path_fields([{:reverse, rt, rf} | rest], _t, model),
    do: [{rt, rf} | path_fields(rest, rt, model)]

  defp path_fields([{:list, f}], t, _model), do: [{t, f}]

  defp ref_target(model, t, f) do
    case Model.field(model, t, f) do
      {:ok, %Field{type: %{target: target}}} -> target
      :error -> nil
    end
  end

  @doc false
  # Drift between stored copies of derived fields and the derived values.
  def drift(%__MODULE__{} = scan, %Plan{} = plan, %Model{} = model) do
    reverse = reverse_index(scan, plan)

    checks =
      for table <- plan.tables,
          d <- table.derived,
          id <- scan.ids |> Map.get(table.type, MapSet.new()) |> Enum.sort(),
          do: {table.type, d, id}

    Enum.reduce(checks, scan.issues, fn {type, d, id}, issues ->
      stored = get_in(scan.values, [type, id, d.field])

      case compare_derived(d.derivation, type, id, stored, scan, reverse, model) do
        :same -> issues
        {:drift, code, detail} -> Issues.add(issues, code, type, d.field, id, detail)
      end
    end)
  end

  defp reverse_index(scan, plan) do
    pairs =
      for table <- plan.tables,
          d <- table.derived,
          pair <- reverse_pairs(d.derivation),
          uniq: true,
          do: pair

    Map.new(pairs, fn {rt, rf} ->
      index =
        for {id, fields} <- Map.get(scan.values, rt, %{}),
            target = Map.get(fields, rf),
            is_binary(target),
            reduce: %{} do
          acc -> Map.update(acc, target, [id], &[id | &1])
        end

      {{rt, rf}, index}
    end)
  end

  defp reverse_pairs({:reverse, rt, rf}), do: [{rt, rf}]
  defp reverse_pairs({:count, path}), do: for({:reverse, rt, rf} <- path, do: {rt, rf})
  defp reverse_pairs({:related, path, _}), do: for({:reverse, rt, rf} <- path, do: {rt, rf})

  defp compare_derived({:reverse, rt, rf}, _t, id, stored, scan, reverse, _model) do
    stored = stored |> List.wrap() |> Enum.filter(&is_binary/1) |> MapSet.new()
    stored = MapSet.intersection(stored, Map.get(scan.ids, rt, MapSet.new()))
    back = reverse |> Map.get({rt, rf}, %{}) |> Map.get(id, []) |> MapSet.new()

    cond do
      MapSet.equal?(stored, back) ->
        :same

      MapSet.subset?(back, stored) ->
        {:drift, :load_reverse_list_drift, :listed_not_pointing_back}

      MapSet.subset?(stored, back) ->
        {:drift, :load_reverse_list_drift, :pointing_back_not_listed}

      true ->
        {:drift, :load_reverse_list_drift, :both}
    end
  end

  defp compare_derived({:related, path, {st, sf}}, t, id, stored, scan, reverse, model) do
    case follow(path, t, [id], scan, reverse, model) do
      {:ok, ^st, [source]} -> same(stored, get_in(scan.values, [st, source, sf]))
      {:ok, _, []} -> same(stored, nil)
      _ -> :same
    end
  end

  defp compare_derived({:count, path}, t, id, stored, scan, reverse, model) do
    {steps, last} = Enum.split(path, -1)

    derived =
      case {follow(steps, t, [id], scan, reverse, model), last} do
        {{:ok, _t, []}, _} ->
          0

        {{:ok, ct, [record]}, [{:list, f}]} ->
          ids = Map.get(scan.ids, ref_target(model, ct, f), MapSet.new())

          get_in(scan.values, [ct, record, f])
          |> List.wrap()
          |> Enum.count(&MapSet.member?(ids, &1))

        {{:ok, _ct, records}, [{:reverse, rt, rf}]} ->
          index = Map.get(reverse, {rt, rf}, %{})
          records |> Enum.map(&length(Map.get(index, &1, []))) |> Enum.sum()

        _ ->
          nil
      end

    if is_nil(derived), do: :same, else: same(stored || 0, derived)
  end

  # Follows ref steps (one record) and reverse steps (many) from `ids`.
  defp follow([], t, ids, _scan, _reverse, _model), do: {:ok, t, ids}

  defp follow([{:ref, f} | rest], t, ids, scan, reverse, model) do
    target = ref_target(model, t, f)
    known = Map.get(scan.ids, target, MapSet.new())

    next =
      for id <- ids,
          ref = get_in(scan.values, [t, id, f]),
          is_binary(ref) and MapSet.member?(known, ref),
          do: ref

    follow(rest, target, next, scan, reverse, model)
  end

  defp follow([{:reverse, rt, rf} | rest], _t, ids, scan, reverse, model) do
    index = Map.get(reverse, {rt, rf}, %{})
    follow(rest, rt, Enum.flat_map(ids, &Map.get(index, &1, [])), scan, reverse, model)
  end

  defp same(a, b) do
    if canonical(a) == canonical(b), do: :same, else: {:drift, :load_derived_drift, :differs}
  end

  defp canonical(n) when is_number(n), do: n / 1
  defp canonical([]), do: nil
  defp canonical(l) when is_list(l), do: Enum.map(l, &canonical/1)

  defp canonical(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> s
    end
  end

  defp canonical(v), do: v
end
