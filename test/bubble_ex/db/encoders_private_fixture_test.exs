defmodule BubbleEx.Db.EncodersPrivateFixtureTest do
  # Regression anchor for the Reader projection and every encoder against a
  # real app (WTF-365). Like the Model's private test it reads a local export
  # named by BUBBLE_EX_PRIVATE_EXPORT and is excluded by default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
  #
  # It compares aggregate counts (the projected tables, columns and
  # relationships, and each format's output size and diagnostics) with a
  # committed snapshot, by default the mm-137 test version's. The snapshot
  # holds counts only, never names, IDs or output. A changed count means
  # updating the snapshot, with the reason in the PR:
  #
  #     BUBBLE_EX_UPDATE_COUNTS=1 BUBBLE_EX_PRIVATE_EXPORT=… mix test --only private_fixture
  #
  # BUBBLE_EX_DB_COUNTS names another snapshot file (for another app). The
  # SQLite DDL is loaded in memory; with BUBBLE_EX_DDL_PG set (see
  # BubbleEx.Characterization.DbDdlTest) the PostgreSQL DDL is loaded too.
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Model}
  alias BubbleEx.Db.{Encoder, Reader}
  alias BubbleEx.Test.{Ddl, SplitExport}

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  @default_snapshot "test/support/db/counts/mm-137.json"
  @formats ~w(dbml postgres sqlite tsql ecto zod xano convex)a

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    app = SplitExport.load(path)
    {:ok, db} = Reader.parse(app)
    %{app: app, db: db}
  end

  test "matches the recorded count snapshot", %{db: db} do
    snapshot = System.get_env("BUBBLE_EX_DB_COUNTS") || @default_snapshot
    counts = counts(db)

    IO.puts("\ndb: " <> (counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)))

    if System.get_env("BUBBLE_EX_UPDATE_COUNTS") do
      File.mkdir_p!(Path.dirname(snapshot))

      File.write!(
        snapshot,
        (counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"
      )
    end

    recorded = snapshot |> File.read!() |> Jason.decode!()
    assert counts == recorded, "counts changed; update #{snapshot} with a reason"
  end

  test "the projection keeps every live definition", %{app: app, db: db} do
    {:ok, model} = Model.build(app)
    live_types = Enum.count(model.data_types, &(not &1.deleted and is_nil(&1.raw)))
    live_sets = Enum.count(model.option_sets, &(not &1.deleted and is_nil(&1.raw)))

    assert Enum.count(db.tables, &(&1.group == :custom)) == live_types
    assert Enum.count(db.tables, &(&1.group == :option)) == live_sets
    assert Enum.all?(db.diagnostics, &(&1 in model.diagnostics))
  end

  test "the generated SQLite and PostgreSQL DDL loads", %{db: db} do
    for naming <- [:proper, :id], foreign_keys <- [:none, :enforced] do
      opts = [naming: naming, foreign_keys: foreign_keys]
      {:ok, sqlite} = Encoder.render(:sqlite, db, opts)
      assert {"", 0} = Ddl.sqlite(sqlite.content), "SQLite DDL #{inspect(opts)} does not load"

      if url = System.get_env("BUBBLE_EX_DDL_PG") do
        {:ok, postgres} = Encoder.render(:postgres, db, opts)
        assert {_, 0} = Ddl.postgres(url, postgres.content)
      end
    end
  end

  defp counts(db) do
    columns = Enum.flat_map(db.tables, & &1.columns)

    %{
      "tables" => frequencies(db.tables, &Atom.to_string(&1.group)),
      "columns" => frequencies(columns, &column_key/1),
      "option_values" => db.tables |> Enum.map(&length(&1.values)) |> Enum.sum(),
      "relationships" => frequencies(db.relationships, &relationship_key/1),
      "external_types" => frequencies(db.external_types, &Atom.to_string(&1.resolution)),
      "diagnostics" => frequencies(db.diagnostics, &Atom.to_string(&1.code)),
      "formats" => Map.new(@formats, &{Atom.to_string(&1), format_counts(&1, db)})
    }
  end

  defp format_counts(format, db) do
    {:ok, result} = Encoder.render(format, db)
    own = Enum.filter(result.diagnostics, &(&1.stage == {:target, format}))

    %{
      "bytes" => byte_size(result.content),
      "lines" => result.content |> String.split("\n") |> length(),
      "target_diagnostics" => frequencies(own, &Atom.to_string(&1.code))
    }
  end

  defp column_key(%{table_group: group, type: type}),
    do: "#{group} #{type.type}#{if type[:is_array], do: "[]"}"

  defp relationship_key({from, nil, direction}), do: "#{from.table_group} #{direction} unresolved"

  defp relationship_key({from, to, direction}),
    do: "#{from.table_group}->#{to.table_group} #{direction}"

  defp frequencies(list, fun), do: list |> Enum.frequencies_by(fun) |> Map.new()
end
