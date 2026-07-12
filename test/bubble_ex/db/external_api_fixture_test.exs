defmodule BubbleEx.Db.ExternalApiFixtureTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Reader
  alias BubbleEx.Test.ExternalApiTypeFixture

  test "sanitized fixture resolves offline through the public Reader seam" do
    assert {:ok, db} = Reader.parse(ExternalApiTypeFixture.app())
    assert db.bubble_id == "synthetic-external-api-types"
    assert Enum.map(db.external_types, & &1.id) == Enum.sort(Enum.map(db.external_types, & &1.id))
    assert Enum.any?(db.external_types, &(&1.resolution == :resolved))
    assert Enum.any?(db.external_types, &(&1.resolution == :opaque))
    assert Enum.any?(db.warnings, &(&1.category == :invalid_descriptor))

    refute inspect(ExternalApiTypeFixture.app()) =~
             ~r/(password|authorization|api[_-]?key|secret)/i
  end

  test "fixture drives every registered encoder without network or credentials" do
    {:ok, db} = Reader.parse(ExternalApiTypeFixture.app())

    results =
      Map.new([:dbml, :postgres, :sqlite, :tsql, :ecto, :ash, :zod, :xano, :convex], fn format ->
        assert {:ok, result} = BubbleEx.Db.Encoder.render(format, db, external_types: :preserve)
        assert is_binary(result.content) and result.content != ""
        assert Enum.any?(result.warnings, &(Map.get(&1, :category) == :invalid_descriptor))

        for mode <- [:opaque, :legacy] do
          assert {:ok, mode_result} = BubbleEx.Db.Encoder.render(format, db, external_types: mode)
          assert is_binary(mode_result.content) and mode_result.content != ""
          assert Enum.any?(mode_result.warnings, &(Map.get(&1, :mode) == mode))
        end

        {format, result.content}
      end)

    assert results.dbml =~ "json"
    assert results.postgres =~ "CREATE TYPE"
    assert results.sqlite =~ "json_valid"
    assert results.tsql =~ "ISJSON"
    assert results.ecto =~ "embedded_schema"
    assert results.ash =~ "data_layer: :embedded"
    assert results.zod =~ "z.looseObject"
    assert results.xano =~ ~s("type": "object")
    assert results.convex =~ "Validator = v.object"
  end

  test "nested resolution failures retain the first failed stage and root occurrence" do
    app = ExternalApiTypeFixture.app()
    app = update_in(app, ["settings", "client_safe", "apiconnector2"], &Map.delete(&1, "compass"))
    assert {:ok, db} = Reader.parse(app)
    warning = Enum.find(db.warnings, &(&1.category == :connector_missing))
    assert warning

    assert [%{root: %{table_id: "parcel", field_id: "destination"}, path: [_ | _]}] =
             warning.occurrences
  end
end
