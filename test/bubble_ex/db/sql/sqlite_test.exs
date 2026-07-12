defmodule BubbleEx.Db.Sql.SqliteTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Sql.Sqlite

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

  test "emits the pragma preamble, prefixed table, columns, and primary key" do
    db =
      thing_db([
        col("name_field", "name", %{type: :string}),
        col("score_field", "score", %{type: :float}),
        col("_id", "_id", %{type: :string}, primary_key: true)
      ])

    assert {:ok, sql} = Sqlite.encode(db)
    assert sql =~ "PRAGMA foreign_keys = ON;"
    assert sql =~ ~s[CREATE TABLE IF NOT EXISTS "custom__Thing" (]
    assert sql =~ ~s("name" TEXT)
    assert sql =~ ~s("score" REAL)
    assert sql =~ ~s("_id" TEXT NOT NULL)
    assert sql =~ ~s[PRIMARY KEY ("_id")]
  end

  test "marks the primary-key column NOT NULL while leaving others nullable" do
    db =
      thing_db([
        col("name_field", "name", %{type: :string}),
        col("_id", "_id", %{type: :string}, primary_key: true)
      ])

    assert {:ok, sql} = Sqlite.encode(db)
    assert sql =~ ~s("_id" TEXT NOT NULL)
    assert sql =~ ~s[PRIMARY KEY ("_id")]
    # Non-key columns keep no NOT NULL clause.
    refute sql =~ ~s("name" TEXT NOT NULL)
    assert sql =~ ~s("name" TEXT)
  end

  test "maps each Bubble type to its SQLite affinity" do
    db =
      thing_db([
        col("a", "a", %{type: :boolean}),
        col("b", "b", %{type: :utc_datetime_usec}),
        col("c", "c", %{type: :custom, custom_type: "bubble_image"}),
        col("d", "d", %{type: :custom, custom_type: "bubble_geo_address"}),
        col("e", "e", %{type: :api, custom_type: "x.y"}),
        col("f", "f", %{type: :reference, custom_type: "user"}),
        col("g", "g", %{type: :enum, custom_type: "status"})
      ])

    assert {:ok, sql} = Sqlite.encode(db)
    assert sql =~ ~s("a" INTEGER)
    assert sql =~ ~s("b" TEXT)
    assert sql =~ ~s("c" TEXT)
    assert sql =~ ~s("d" TEXT)
    assert sql =~ ~s("e" TEXT)
    assert sql =~ ~s("f" TEXT)
    assert sql =~ ~s("g" TEXT)
  end

  test "renders list fields as TEXT with a JSON comment and no array suffix" do
    db = thing_db([col("tags", "tags", %{type: :string, is_array: true})])
    assert {:ok, sql} = Sqlite.encode(db)
    assert sql =~ ~s("tags" TEXT  -- list<TEXT>; store as JSON)
    refute sql =~ "TEXT[]"
  end

  test "declares a scalar reference as an inline foreign key" do
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
    assert {:ok, sql} = Sqlite.encode(db)

    assert sql =~
             ~s[FOREIGN KEY ("owner") REFERENCES "custom__User" ("_id")]
  end

  test "does not declare a foreign key for a list reference" do
    from = col("refs", "owners", %{type: :reference, custom_type: "user", is_array: true})

    to =
      col("_id", "_id", %{type: :string},
        table_id: "user",
        table_name: "User",
        primary_key: true
      )

    db = thing_db([from], [{from, to, :one_to_many}])
    assert {:ok, sql} = Sqlite.encode(db)
    refute sql =~ "FOREIGN KEY"
    assert sql =~ ~s("owners" TEXT  -- list<TEXT>; store as JSON)
  end

  test "respects :id naming for tables and columns" do
    db = thing_db([col("name_field", "name", %{type: :string})])
    assert {:ok, sql} = Sqlite.encode(db, naming: :id)
    assert sql =~ ~s[CREATE TABLE IF NOT EXISTS "custom__t1" (]
    assert sql =~ ~s("name_field" TEXT)
  end

  test ":id naming also qualifies foreign-key targets by id" do
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
    assert {:ok, sql} = Sqlite.encode(db, naming: :id)

    assert sql =~
             ~s[FOREIGN KEY ("ref") REFERENCES "custom__user" ("_id")]
  end

  test "escapes embedded double quotes in identifiers" do
    db = thing_db([col("q", ~s(a"b), %{type: :string})])
    assert {:ok, sql} = Sqlite.encode(db)
    assert sql =~ ~s("a""b" TEXT)
  end

  test "omits api-group placeholder tables" do
    db = %{
      bubble_id: "app",
      tables: [%{id: "x.y", name: "x.y", group: :api, columns: []}],
      relationships: []
    }

    assert {:ok, sql} = Sqlite.encode(db)
    refute sql =~ "x.y"
  end

  test "skips deleted columns" do
    db =
      thing_db([
        col("keep", "keep", %{type: :string}),
        col("gone", "gone", %{type: :string}, deleted: true)
      ])

    assert {:ok, sql} = Sqlite.encode(db)
    assert sql =~ ~s("keep" TEXT)
    refute sql =~ ~s("gone")
  end

  test "uses nullable-safe JSON validation outside legacy mode" do
    id = "api.apiconnector2.a.call.Shape"

    db =
      thing_db([
        col("payload", "payload", %{type: :external, target: id, cardinality: :one, raw: id})
      ])

    assert {:ok, sql} = Sqlite.encode(db, external_types: :preserve)
    assert sql =~ "\"payload\" TEXT CHECK (\"payload\" IS NULL OR json_valid(\"payload\"))"
    assert {:ok, legacy} = Sqlite.encode(db, external_types: :legacy)
    refute legacy =~ "json_valid"
  end
end
