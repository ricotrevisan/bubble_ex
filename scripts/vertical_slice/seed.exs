# Synthetic seed data of a vertical slice (WTF-378): invented records for
# every data type of the Model, written as a data-loader export
# (BubbleEx.Load.Export) and loaded through the loader (BubbleEx.Load with
# the Ash/PostgreSQL adapter), exactly as a Bubble export would be. No
# value comes from the app's data: texts are "Sample <field> <n>", numbers
# and dates are counters, options rotate through the option set, and
# references keep each index one coherent world (WTF-500): record `i` of a
# type points at record `i` of another type (user 1's membership is
# membership 1, whose member is user 1, as an app's own data would be),
# and at the next record of its own type (never itself). Users get emails
# on the reserved `example.test` domain; the first one is the slice's
# sign-in user.
#
# Each world `i` (1 to `n`) holds two records per type (WTF-530): the
# primary record `i`, which the other types reference, and its twin
# `n + i`, which points at the same records (same owner, same world) with
# every boolean negated. So every owner has, per type, a record with each
# boolean true and one with each boolean false, and a list filtered on a
# flag ("not archived", "not a draft") is never empty only because every
# record of the signed-in user carries the same flags. A user's booleans
# are true in odd worlds (the persona's flags); every other primary's are
# false there, Bubble's default for a new record, so what odd worlds reach
# through references (a task's project, a note's team) is not archived
# or a draft either. Even worlds are the opposite. With `n = 1` a
# reference to a record's own type points at primary 1, so primary 1
# references itself (its twin references primary 1 too).
defmodule VerticalSlice.Synthetic do
  @moduledoc false

  alias BubbleEx.Model
  alias BubbleEx.Model.{DataType, Field, Type}
  alias BubbleEx.Verify.{Interpreter, Value}
  alias BubbleEx.Verify.Interpreter.Dataset

  @base_ms 1_767_225_600_000
  @day 86_400_000
  # Record numbers of a type are `t * 1000 + i` with `i` up to `2n`: at
  # most 1000 per type keeps every ID distinct.
  @max_worlds 500

  @doc """
  The Bubble-shaped ID of record `i` (1-based) of the `t`-th type: `1` to
  `n` are the primary records, `n + 1` to `2n` their twins.
  """
  def id(t, i) when i in 1..(2 * @max_worlds)//1,
    do: "1767225600000x" <> String.pad_leading(Integer.to_string(t * 1000 + i), 18, "0")

  def email(i), do: "slice-user-#{i}@example.test"

  @doc """
  The number of synthetic worlds from the seed's `N` argument (default 3):
  1 to #{@max_worlds}, so that record IDs stay distinct across types.
  """
  def worlds(value) do
    case value do
      blank when blank in [nil, ""] ->
        3

      text ->
        case Integer.parse(text) do
          {n, ""} when n in 1..@max_worlds//1 ->
            n

          _ ->
            raise ArgumentError,
                  "N must be a number of worlds from 1 to #{@max_worlds}, got #{inspect(text)}"
        end
    end
  end

  @doc """
  The persona the slice signs in as, from `SLICE_PERSONA`: the index of a
  synthetic user (1, the default, to `n`). Which one matters with enforced
  privacy: user `i`'s booleans are `rem(i, 2) == 1` (user 1's are true,
  user 2's false) and its options the `i`-th of their set. The other
  primary records of its world have the opposite booleans, their twins
  the same ones.
  """
  def persona(value, n) do
    case value do
      blank when blank in [nil, ""] ->
        1

      text ->
        case Integer.parse(text) do
          {i, ""} when i >= 1 and i <= n ->
            i

          _ ->
            raise ArgumentError,
                  "SLICE_PERSONA must be a user index from 1 to #{n}, got #{inspect(text)}"
        end
    end
  end

  @doc """
  `%{type id => [row]}`: `2n` records per live data type, keyed by field
  ID (the loader accepts them), with Data API system members: the `n`
  primary records, then their twins.
  """
  def rows(%Model{} = model, n) do
    check_worlds!(n)
    types = live_types(model)
    index = types |> Enum.with_index(1) |> Map.new(fn {t, i} -> {t.id, i} end)
    options = Map.new(model.option_sets, &{&1.id, live_keys(&1)})
    ctx = %{index: index, options: options, n: n}

    Map.new(types, fn type ->
      t = index[type.id]
      ctx = Map.merge(ctx, %{self: type.id, odd_true: type.id == "user"})
      {type.id, for(i <- 1..records(n), do: row(type, t, i, ctx))}
    end)
  end

  @doc "The records written per type for `n` worlds: a primary and a twin each."
  def records(n), do: 2 * n

  @doc "Every record ID written, by type: `%{type id => [id]}`, primaries first."
  def ids(%Model{} = model, n) do
    check_worlds!(n)

    model
    |> live_types()
    |> Enum.with_index(1)
    |> Map.new(fn {type, t} -> {type.id, for(i <- 1..records(n), do: id(t, i))} end)
  end

  @doc """
  The record of `type_id` the drive visits signed in as `persona`: the
  first of the persona's primary, its twin, then the other records in
  order that the privacy rules let the persona view, as the generated
  policies read them (`BubbleEx.Verify.Interpreter.target/1`). Primaries
  and twins have opposite flags, so a rule that needs a flag either way
  finds one of the two. Without enforced privacy, or when no record is
  known to be viewable (no rule grants it, or the interpreter cannot
  tell), the persona's primary. nil for a type with no records.
  """
  def target(%Model{} = model, n, persona, type_id, privacy) do
    case ids(model, n)[type_id] do
      nil ->
        nil

      ids ->
        primary = Enum.at(ids, persona - 1)
        twin = Enum.at(ids, n + persona - 1)
        candidates = [primary, twin | ids -- [primary, twin]]

        if privacy == :enforced,
          do: Enum.find(candidates, primary, viewable(model, n, persona)),
          else: primary
    end
  end

  # Whether the persona may view a record, under the generated policies'
  # reading; false when the interpreter cannot tell.
  defp viewable(model, n, persona) do
    user = id(Map.fetch!(index(model), "user"), persona)

    case {Interpreter.new(model), dataset(model, n)} do
      {{:ok, interpreter}, {:ok, ds}} ->
        interpreter = Interpreter.target(interpreter)

        fn record ->
          match?({:ok, %{visible: true}}, Interpreter.access(interpreter, ds, user, record))
        end

      _ ->
        fn _record -> false end
    end
  end

  @doc """
  The synthetic rows as the privacy interpreter's dataset: records keyed
  by ID, values in the canonical form of `BubbleEx.Verify.Value`.
  """
  def dataset(%Model{} = model, n) do
    types = Map.new(live_types(model), &{&1.id, &1})

    model
    |> rows(n)
    |> Enum.flat_map(fn {type_id, rows} ->
      fields = types[type_id].fields
      for row <- rows, do: {row["_id"], type_id, canonical(fields, row)}
    end)
    |> Dataset.new()
  end

  @system %{
    created_by: "Created By",
    created_date: "Created Date",
    modified_date: "Modified Date"
  }

  defp canonical(fields, row) do
    for %Field{deleted: false} = f <- fields,
        {:ok, value} <- [cast(f, raw(f, row))],
        value != nil,
        into: %{},
        do: {f.id, value}
  end

  defp raw(%Field{system: nil, id: id}, row), do: row[id]
  defp raw(%Field{system: :email}, row), do: get_in(row, ["authentication", "email", "email"])
  defp raw(%Field{system: system}, row), do: row[@system[system]]

  defp cast(_field, nil), do: {:ok, nil}

  defp cast(%Field{type: %Type{cardinality: :many} = type} = f, values) do
    one = %Field{f | type: %Type{type | cardinality: :one}}
    Value.cast(%{"list" => Enum.map(values, &json(one, &1))})
  end

  defp cast(%Field{system: :created_by}, value), do: Value.cast(%{"ref" => value})

  defp cast(%Field{system: system}, value) when system in [:created_date, :modified_date],
    do: Value.cast(%{"date" => value})

  defp cast(%Field{system: :email}, value), do: Value.cast(%{"text" => value})
  defp cast(f, value), do: Value.cast(json(f, value))

  defp json(%Field{type: %Type{kind: :ref}}, id), do: %{"ref" => id}
  defp json(%Field{type: %Type{kind: :option}}, key), do: %{"option" => key}

  defp json(%Field{type: %Type{kind: :structured, base: :geographic_address}}, v),
    do: %{
      "geographic_address" => %{
        "formatted_address" => v["address"],
        "lat" => v["lat"],
        "lng" => v["lng"]
      }
    }

  defp json(%Field{type: %Type{kind: :structured, base: base}}, v),
    do: %{Atom.to_string(base) => v}

  defp json(%Field{type: %Type{base: base}}, v), do: %{Atom.to_string(base) => v}

  defp index(model),
    do: model |> live_types() |> Enum.with_index(1) |> Map.new(fn {t, i} -> {t.id, i} end)

  defp check_worlds!(n) do
    unless is_integer(n) and n in 1..@max_worlds//1 do
      raise ArgumentError, "the seed writes 1 to #{@max_worlds} worlds, got #{inspect(n)}"
    end
  end

  defp live_types(model),
    do: model.data_types |> Enum.reject(& &1.deleted) |> Enum.sort_by(& &1.id)

  defp live_keys(set),
    do: for(v <- set.values, not v.deleted, is_binary(v.key), do: v.key)

  # Record `i` of world `w`: references, options and the owner come from
  # the world, texts, numbers and dates from the record (twins are told
  # apart), booleans from the world and the type, negated for a twin.
  defp row(%DataType{} = type, t, i, ctx) do
    created = @base_ms + (t * 10 + i) * @day
    ctx = Map.merge(ctx, %{world: world(i, ctx.n), twin: i > ctx.n})

    base = %{
      "_id" => id(t, i),
      "Created Date" => created,
      "Modified Date" => created + @day,
      "Created By" => user_id(ctx, ctx.world)
    }

    base =
      if type.id == "user",
        do:
          Map.merge(base, %{
            "authentication" => %{"email" => %{"email" => email(i), "email_confirmed" => true}}
          }),
        else: base

    # A generator, not a filter: `false` is a value to write, only `nil`
    # is left out.
    for %Field{system: nil, deleted: false} = f <- type.fields,
        {id, value} <- [{f.id, value(f, i, ctx)}],
        value != nil,
        into: base,
        do: {id, value}
  end

  defp world(i, n), do: rem(i - 1, n) + 1

  defp user_id(%{index: index, n: n}, i) do
    case index["user"] do
      nil -> nil
      t -> id(t, rem(i - 1, n) + 1)
    end
  end

  defp value(%Field{type: %Type{cardinality: :many} = type} = f, i, ctx) do
    one = %Field{f | type: %Type{type | cardinality: :one}}
    next = %{ctx | world: world(ctx.world + 1, ctx.n)}

    case [value(one, i, ctx), value(one, i + 1, next)] do
      [nil, _] -> nil
      [a, b] when a == b -> [a]
      pair -> pair
    end
  end

  defp value(%Field{type: %Type{kind: :scalar, base: base}} = f, i, ctx) do
    case base do
      :text -> "Sample #{f.name || f.id} #{i}"
      :number -> i
      :boolean -> (rem(ctx.world, 2) == 1 == ctx.odd_true) != ctx.twin
      :date -> @base_ms + i * @day
      _ -> nil
    end
  end

  defp value(%Field{type: %Type{kind: :option, target: set}}, _i, ctx) do
    case ctx.options[set] do
      [_ | _] = keys -> Enum.at(keys, rem(ctx.world - 1, length(keys)))
      _ -> nil
    end
  end

  defp value(%Field{type: %Type{kind: :ref, target: target}}, _i, ctx) do
    case ctx.index[target] do
      nil -> nil
      t when target == ctx.self -> id(t, world(ctx.world + 1, ctx.n))
      t -> id(t, ctx.world)
    end
  end

  defp value(%Field{type: %Type{kind: :structured, base: base}}, i, _ctx) do
    case base do
      :geographic_address ->
        %{"address" => "#{i} Sample Street", "lat" => 50.0 + i / 100, "lng" => 4.0}

      :date_range ->
        %{"start" => @base_ms + i * @day, "end" => @base_ms + (i + 1) * @day}

      :number_range ->
        %{"min" => i, "max" => i + 10}

      _ ->
        nil
    end
  end

  # Files and images stay empty (no download, no third-party host);
  # API Connector values and opaque types are not synthesized.
  defp value(_field, _i, _ctx), do: nil
end

defmodule VerticalSlice.Seed do
  @moduledoc false

  alias BubbleEx.Load
  alias BubbleEx.Load.Export
  alias BubbleEx.Load.Storage.Local
  alias BubbleEx.Target.Ash.Loader
  alias VerticalSlice.Synthetic

  @doc """
  Writes the synthetic export under `dir/export` (replacing it) and loads
  it into the database of `pool` (a Postgrex pool), with its ledger and
  file storage under `dir`. Returns the loader's report.
  """
  def run(built, pool, dir, n) do
    export_dir = Path.join(dir, "export")
    File.rm_rf!(export_dir)

    {:ok, export} =
      Export.write(export_dir, %{
        app: built.model.bubble_id || "slice",
        model_sha256: BubbleEx.Model.sha256(built.model),
        source: %{"kind" => "synthetic", "base_url" => "https://slice.example.test"},
        created_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        types:
          for(
            {type, rows} <- Enum.sort(Synthetic.rows(built.model, n)),
            do: %{type: type, path: type, rows: rows}
          ),
        files: []
      })

    target =
      Loader.target(built.project,
        query: fn sql, params ->
          Postgrex.query(Process.get(:slice_conn, pool), sql, params)
        end,
        checkout: fn fun ->
          DBConnection.run(
            pool,
            fn conn ->
              Process.put(:slice_conn, conn)

              try do
                fun.()
              after
                Process.delete(:slice_conn)
              end
            end,
            timeout: :infinity
          )
        end
      )

    storage =
      Local.new(root: Path.join(dir, "storage"), public_url: "http://127.0.0.1/uploads")

    opts = [storage: storage, ledger_dir: Path.join(dir, "ledger")]
    File.rm_rf!(Path.join(dir, "ledger"))

    with {:ok, dry} <- Load.dry_run(export, built.model, target, []) do
      if dry.blocked != [] do
        {:blocked, dry}
      else
        Load.run(export, built.model, target, opts)
      end
    end
  end
end
