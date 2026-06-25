defmodule BubbleEx.Db.Sql.TsqlTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Sql.Tsql

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

  test "emits schema, GO, table, columns, and a named primary-key constraint" do
    db =
      thing_db([
        col("name_field", "name", %{type: :string}),
        col("score_field", "score", %{type: :float}),
        col("_id", "_id", %{type: :string}, primary_key: true)
      ])

    assert {:ok, sql} = Tsql.encode(db)
    assert sql =~ "CREATE SCHEMA [custom];\nGO"
    assert sql =~ "CREATE TABLE [custom].[Thing] ("
    assert sql =~ "[name] NVARCHAR(MAX)"
    assert sql =~ "[score] FLOAT"
    assert sql =~ "[_id] NVARCHAR(450)"
    assert sql =~ "CONSTRAINT [PK_thing] PRIMARY KEY ([_id])"
  end

  test "maps each Bubble type to its T-SQL type" do
    db =
      thing_db([
        col("a", "a", %{type: :boolean}),
        col("b", "b", %{type: :utc_datetime_usec}),
        col("c", "c", %{type: :custom, custom_type: "bubble_image"}),
        col("d", "d", %{type: :custom, custom_type: "bubble_geo_address"}),
        col("e", "e", %{type: :api, custom_type: "x.y"})
      ])

    assert {:ok, sql} = Tsql.encode(db)
    assert sql =~ "[a] BIT"
    assert sql =~ "[b] DATETIME2"
    assert sql =~ "[c] NVARCHAR(MAX)"
    assert sql =~ "[d] NVARCHAR(MAX)"
    assert sql =~ "[e] NVARCHAR(MAX)"
  end

  test "keyed reference and enum columns use NVARCHAR(450)" do
    db =
      thing_db([
        col("ref", "owner", %{type: :reference, custom_type: "user"}),
        col("st", "status", %{type: :enum, custom_type: "status_type"})
      ])

    assert {:ok, sql} = Tsql.encode(db)
    assert sql =~ "[owner] NVARCHAR(450)"
    assert sql =~ "[status] NVARCHAR(450)"
  end

  test "renders list fields as a single text column with a junction-table hint" do
    db = thing_db([col("tags", "tags", %{type: :string, is_array: true})])
    assert {:ok, sql} = Tsql.encode(db)
    assert sql =~ "[tags] NVARCHAR(MAX)  -- list<text>: consider a junction table"
  end

  test "emits a named foreign key for a scalar reference" do
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
    assert {:ok, sql} = Tsql.encode(db)

    assert sql =~
             "ALTER TABLE [custom].[Thing]\n" <>
               "  ADD CONSTRAINT [FK_thing_owner]\n" <>
               "  FOREIGN KEY ([owner])\n" <>
               "  REFERENCES [custom].[User] ([_id]);"
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
    assert {:ok, sql} = Tsql.encode(db)
    refute sql =~ "ADD CONSTRAINT [FK"
    assert sql =~ "[owners] NVARCHAR(MAX)  -- list<ref>: consider a junction table"
  end

  test "respects :id naming for tables, columns, and constraint names" do
    db =
      thing_db([
        col("name_field", "name", %{type: :string}),
        col("_id", "_id", %{type: :string}, primary_key: true)
      ])

    assert {:ok, sql} = Tsql.encode(db, naming: :id)
    assert sql =~ "CREATE TABLE [custom].[t1] ("
    assert sql =~ "[name_field] NVARCHAR(MAX)"
    assert sql =~ "CONSTRAINT [PK_t1] PRIMARY KEY ([_id])"
  end

  test "escapes embedded closing brackets in identifiers" do
    db = thing_db([col("q", "a]b", %{type: :string})])
    assert {:ok, sql} = Tsql.encode(db)
    assert sql =~ "[a]]b] NVARCHAR(MAX)"
  end

  test "omits api-group placeholder tables" do
    db = %{
      bubble_id: "app",
      tables: [%{id: "x.y", name: "x.y", group: :api, columns: []}],
      relationships: []
    }

    assert {:ok, sql} = Tsql.encode(db)
    refute sql =~ "x.y"
  end
end
