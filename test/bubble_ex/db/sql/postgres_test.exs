defmodule BubbleEx.Db.Sql.PostgresTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Sql.Postgres

  defp col(id, name, type, opts \\ []) do
    %{
      table_id: Keyword.get(opts, :table_id, "t1"),
      table_name: Keyword.get(opts, :table_name, "Thing"),
      table_group: Keyword.get(opts, :table_group, :custom),
      id: id,
      name: name,
      type: type,
      primary_key: Keyword.get(opts, :primary_key, false),
      deleted: Keyword.get(opts, :deleted, false)
    }
  end

  defp thing_db(columns, relationships \\ []) do
    %{
      bubble_id: "app",
      tables: [%{id: "t1", name: "Thing", group: :custom, columns: columns}],
      relationships: relationships
    }
  end

  test "emits schema, table, columns, and primary key" do
    db =
      thing_db([
        col("name_field", "name", %{type: :string}),
        col("score_field", "score", %{type: :float}),
        col("_id", "_id", %{type: :string}, primary_key: true)
      ])

    assert {:ok, sql} = Postgres.encode(db)
    assert sql =~ ~s(CREATE SCHEMA IF NOT EXISTS "custom";)
    assert sql =~ ~s[CREATE TABLE "custom"."Thing" (]
    assert sql =~ ~s("name" text)
    assert sql =~ ~s("score" double precision)
    assert sql =~ ~s[PRIMARY KEY ("_id")]
  end

  test "maps each Bubble type to its Postgres type" do
    db =
      thing_db([
        col("a", "a", %{type: :boolean}),
        col("b", "b", %{type: :utc_datetime_usec}),
        col("c", "c", %{type: :custom, custom_type: "bubble_image"}),
        col("d", "d", %{type: :custom, custom_type: "bubble_geo_address"}),
        col("e", "e", %{type: :api, custom_type: "x.y"})
      ])

    assert {:ok, sql} = Postgres.encode(db)
    assert sql =~ ~s("a" boolean)
    assert sql =~ ~s("b" timestamptz)
    assert sql =~ ~s("c" text)
    assert sql =~ ~s("d" jsonb)
    assert sql =~ ~s("e" text)
  end

  test "renders list fields as native array columns" do
    db = thing_db([col("tags", "tags", %{type: :string, is_array: true})])
    assert {:ok, sql} = Postgres.encode(db)
    assert sql =~ ~s("tags" text[])
  end

  test "emits a foreign key for a scalar reference" do
    from =
      col("ref", "owner", %{type: :reference, custom_type: "user"},
        table_id: "t1",
        table_name: "Thing"
      )

    to =
      col("_id", "_id", %{type: :string},
        table_id: "user",
        table_name: "User",
        primary_key: true
      )

    db = thing_db([from], [{from, to, :one_to_one}])
    assert {:ok, sql} = Postgres.encode(db)

    assert sql =~
             ~s[ALTER TABLE "custom"."Thing" ADD FOREIGN KEY ("owner") REFERENCES "custom"."User" ("_id");]
  end

  test "does not emit a foreign key for a list reference" do
    from = col("refs", "owners", %{type: :reference, custom_type: "user", is_array: true})

    to =
      col("_id", "_id", %{type: :string},
        table_id: "user",
        table_name: "User",
        primary_key: true
      )

    db = thing_db([from], [{from, to, :one_to_many}])
    assert {:ok, sql} = Postgres.encode(db)
    refute sql =~ "ADD FOREIGN KEY"
    assert sql =~ ~s("owners" text[])
  end

  test "respects :id naming" do
    db = thing_db([col("name_field", "name", %{type: :string})])
    assert {:ok, sql} = Postgres.encode(db, naming: :id)
    assert sql =~ ~s[CREATE TABLE "custom"."t1" (]
    assert sql =~ ~s("name_field" text)
  end

  test "escapes embedded double quotes in identifiers" do
    db = thing_db([col("q", ~s(a"b), %{type: :string})])
    assert {:ok, sql} = Postgres.encode(db)
    assert sql =~ ~s("a""b" text)
  end

  test "omits api-group placeholder tables" do
    db = %{
      bubble_id: "app",
      tables: [%{id: "x.y", name: "x.y", group: :api, columns: []}],
      relationships: []
    }

    assert {:ok, sql} = Postgres.encode(db)
    refute sql =~ "x.y"
  end

  test "preserves resolved external shapes and keeps legacy output compatible" do
    id = "api.apiconnector2.a.call.Shape"
    column = col("payload", "payload", %{type: :external, target: id, cardinality: :one, raw: id})

    db =
      thing_db([column])
      |> Map.put(:external_types, [
        %{
          id: id,
          caption: "Shape",
          resolution: :resolved,
          fields: [
            %{
              id: "value",
              caption: "Value",
              type: %{type: :scalar, scalar: :text, cardinality: :one}
            }
          ]
        }
      ])

    assert {:ok, sql} = Postgres.encode(db, external_types: :preserve)
    assert sql =~ ~s(CREATE TYPE "Shape" AS)
    assert sql =~ ~s("payload" "Shape")
    assert {:ok, legacy} = Postgres.encode(db, external_types: :legacy)
    assert legacy =~ ~s("payload" text)
  end
end
