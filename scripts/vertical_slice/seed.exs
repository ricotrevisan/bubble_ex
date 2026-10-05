# Synthetic seed data of a vertical slice (WTF-378): invented records for
# every data type of the Model, written as a data-loader export
# (BubbleEx.Load.Export) and loaded through the loader (BubbleEx.Load with
# the Ash/PostgreSQL adapter), exactly as a Bubble export would be. No
# value comes from the app's data: texts are "Sample <field> <n>", numbers
# and dates are counters, options rotate through the option set, and
# references keep each index one coherent world (WTF-500): record `i` of a
# type points at record `i` of another type (user 1's role is role 1, whose
# account is user 1, as an app's own data would be), and at the next record
# of its own type (never itself). Users get emails on the reserved
# `example.test` domain; the first one is the slice's sign-in user.
defmodule VerticalSlice.Synthetic do
  @moduledoc false

  alias BubbleEx.Model
  alias BubbleEx.Model.{DataType, Field, Type}

  @base_ms 1_767_225_600_000
  @day 86_400_000

  @doc "The Bubble-shaped ID of record `i` (1-based) of the `t`-th type."
  def id(t, i),
    do: "1767225600000x" <> String.pad_leading(Integer.to_string(t * 1000 + i), 18, "0")

  def email(i), do: "slice-user-#{i}@example.test"

  @doc """
  The persona the slice signs in as, from `SLICE_PERSONA`: the index of a
  synthetic user (1, the default, to `n`). Which one matters with enforced
  privacy: user `i`'s booleans are `rem(i, 2) == 1` (user 1's are true,
  user 2's false) and its options the `i`-th of their set.
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
  `%{type id => [row]}`: `n` records per live data type, keyed by field ID
  (the loader accepts them), with Data API system members.
  """
  def rows(%Model{} = model, n) do
    types = live_types(model)
    index = types |> Enum.with_index(1) |> Map.new(fn {t, i} -> {t.id, i} end)
    options = Map.new(model.option_sets, &{&1.id, live_keys(&1)})
    ctx = %{index: index, options: options, n: n}

    Map.new(types, fn type ->
      t = index[type.id]
      {type.id, for(i <- 1..n, do: row(type, t, i, Map.put(ctx, :self, type.id)))}
    end)
  end

  @doc "Every record ID written, by type: `%{type id => [id]}`."
  def ids(%Model{} = model, n) do
    model
    |> live_types()
    |> Enum.with_index(1)
    |> Map.new(fn {type, t} -> {type.id, for(i <- 1..n, do: id(t, i))} end)
  end

  defp live_types(model),
    do: model.data_types |> Enum.reject(& &1.deleted) |> Enum.sort_by(& &1.id)

  defp live_keys(set),
    do: for(v <- set.values, not v.deleted, is_binary(v.key), do: v.key)

  defp row(%DataType{} = type, t, i, ctx) do
    created = @base_ms + (t * 10 + i) * @day

    base = %{
      "_id" => id(t, i),
      "Created Date" => created,
      "Modified Date" => created + @day,
      "Created By" => user_id(ctx, i)
    }

    base =
      if type.id == "user",
        do:
          Map.merge(base, %{
            "authentication" => %{"email" => %{"email" => email(i), "email_confirmed" => true}}
          }),
        else: base

    for %Field{system: nil, deleted: false} = f <- type.fields,
        value = value(f, i, ctx),
        value != nil,
        into: base,
        do: {f.id, value}
  end

  defp user_id(%{index: index, n: n}, i) do
    case index["user"] do
      nil -> nil
      t -> id(t, rem(i - 1, n) + 1)
    end
  end

  defp value(%Field{type: %Type{cardinality: :many} = type} = f, i, ctx) do
    one = %Field{f | type: %Type{type | cardinality: :one}}

    case [value(one, i, ctx), value(one, i + 1, ctx)] do
      [nil, _] -> nil
      [a, b] when a == b -> [a]
      pair -> pair
    end
  end

  defp value(%Field{type: %Type{kind: :scalar, base: base}} = f, i, _ctx) do
    case base do
      :text -> "Sample #{f.name || f.id} #{i}"
      :number -> i
      :boolean -> rem(i, 2) == 1
      :date -> @base_ms + i * @day
      _ -> nil
    end
  end

  defp value(%Field{type: %Type{kind: :option, target: set}}, i, ctx) do
    case ctx.options[set] do
      [_ | _] = keys -> Enum.at(keys, rem(i - 1, length(keys)))
      _ -> nil
    end
  end

  defp value(%Field{type: %Type{kind: :ref, target: target}}, i, ctx) do
    case ctx.index[target] do
      nil -> nil
      t when target == ctx.self -> id(t, rem(i, ctx.n) + 1)
      t -> id(t, rem(i - 1, ctx.n) + 1)
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
