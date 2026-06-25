defmodule BubbleEx.Db.ConvexTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Convex

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

  test "emits schema boilerplate, a table, and its fields" do
    db =
      thing_db([
        col("name_field", "name", %{type: :string}),
        col("score_field", "score", %{type: :float}),
        col("_id", "_id", %{type: :string}, primary_key: true)
      ])

    assert {:ok, ts} = Convex.encode(db)
    assert ts =~ ~s(import { defineSchema, defineTable } from "convex/server";)
    assert ts =~ ~s(import { v } from "convex/values";)
    assert ts =~ "export default defineSchema({"
    assert ts =~ "  thing: defineTable({"
    assert ts =~ "    name: v.string(),"
    assert ts =~ "    score: v.float64(),"
    assert ts =~ "    bubbleId: v.string(), // primary key (Bubble _id, text)"
    assert ts =~ "});\n"
  end

  test "maps each Bubble type to its Convex validator" do
    db =
      thing_db([
        col("a", "a", %{type: :boolean}),
        col("b", "b", %{type: :utc_datetime_usec}),
        col("c", "c", %{type: :custom, custom_type: "bubble_image"}),
        col("d", "d", %{type: :custom, custom_type: "bubble_geo_address"}),
        col("e", "e", %{type: :api, custom_type: "x.y"})
      ])

    assert {:ok, ts} = Convex.encode(db)
    assert ts =~ "    a: v.boolean(),"
    assert ts =~ "    b: v.float64(),"
    assert ts =~ "    c: v.string(),"
    assert ts =~ "    d: v.any(),"
    assert ts =~ "    e: v.string(),"
  end

  test "renders list fields as v.array of the inner validator" do
    db = thing_db([col("tags", "tags", %{type: :string, is_array: true})])
    assert {:ok, ts} = Convex.encode(db)
    assert ts =~ "    tags: v.array(v.string()),"
  end

  test "renders a list of references as v.array(v.string())" do
    refs = col("refs", "owners", %{type: :reference, custom_type: "user", is_array: true})
    db = thing_db([refs])
    assert {:ok, ts} = Convex.encode(db)
    assert ts =~ "    owners: v.array(v.string()),"
  end

  test "renders a scalar reference as v.string() with a re-key comment" do
    db = thing_db([col("ref", "owner", %{type: :reference, custom_type: "user"})])
    assert {:ok, ts} = Convex.encode(db)
    assert ts =~ "    owner: v.string(), // reference -> re-key to v.id(...)"
  end

  test "renders an enum column as v.string() with an option-set comment" do
    db = thing_db([col("st", "status", %{type: :enum, custom_type: "status_type"})])
    assert {:ok, ts} = Convex.encode(db)
    assert ts =~ "    status: v.string(), // enum -> option set (member values not in IR)"
  end

  test "skips deleted columns" do
    db =
      thing_db([
        col("keep", "keep", %{type: :string}),
        col("gone", "gone", %{type: :string}, deleted: true)
      ])

    assert {:ok, ts} = Convex.encode(db)
    assert ts =~ "    keep: v.string(),"
    refute ts =~ "gone"
  end

  test "respects :proper naming (default) using display names" do
    db = thing_db([col("name_field", "display name", %{type: :string})])
    assert {:ok, ts} = Convex.encode(db)
    assert ts =~ "  thing: defineTable({"
    assert ts =~ "    displayName: v.string(),"
  end

  test "respects :id naming using the Bubble ids" do
    db = thing_db([col("name_field", "display name", %{type: :string})])
    assert {:ok, ts} = Convex.encode(db, naming: :id)
    assert ts =~ "  t1: defineTable({"
    assert ts =~ "    nameField: v.string(),"
  end

  test "sanitizes names that would start with a digit" do
    db = thing_db([col("c", "2nd choice", %{type: :string})])
    assert {:ok, ts} = Convex.encode(db)
    assert ts =~ "    field2ndChoice: v.string(),"
  end

  test "omits api-group placeholder tables" do
    db = %{
      bubble_id: "app",
      tables: [%{id: "x.y", name: "x.y", group: :api, columns: []}],
      relationships: []
    }

    assert {:ok, ts} = Convex.encode(db)
    refute ts =~ "x.y"
    # the import line always names defineTable; only an actual table opens "defineTable({"
    refute ts =~ "defineTable({"
  end
end
