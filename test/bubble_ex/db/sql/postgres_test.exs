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

  test "documents a scalar reference in a comment without a foreign key by default" do
    {db, _from} = owner_db()
    assert {:ok, sql} = Postgres.encode(db)

    refute sql =~ "FOREIGN KEY"
    assert sql =~ ~s[-- "custom"."Thing"."owner" -> "custom"."User"."_id"]
  end

  test "escapes line terminators in names inside the reference comment" do
    name = "own\nA\rB\vC\fD\u0085E\u2028F\u2029G\\H"
    {db, _from} = owner_db(name)
    assert {:ok, sql} = Postgres.encode(db)

    assert sql =~
             ~S[-- "custom"."Thing"."own\nA\rB\vC\fD\u0085E\u2028F\u2029G\\H" -> "custom"."User"."_id"]

    [_tables, rest] = String.split(sql, "-- References")
    [comments, _column_comments] = String.split(rest, "\n\nCOMMENT ON COLUMN ")
    refute comments =~ ~r/[\x{0D}\x{0B}\x{0C}\x{0085}\x{2028}\x{2029}]/u
    assert comments |> String.split("\n", trim: true) |> length() == 2
  end

  test "emits a foreign key for a scalar reference with foreign_keys: :enforced" do
    {db, _from} = owner_db()
    assert {:ok, sql} = Postgres.encode(db, foreign_keys: :enforced)

    assert sql =~
             ~s[ALTER TABLE "custom"."Thing" ADD FOREIGN KEY ("owner") REFERENCES "custom"."User" ("_id");]

    refute sql =~ "-- References"
    refute sql =~ "COMMENT ON"
  end

  test "stores a documented reference as a column comment in the catalog" do
    {db, _from} = owner_db()
    assert {:ok, sql} = Postgres.encode(db)

    assert sql =~
             ~s[COMMENT ON COLUMN "custom"."Thing"."owner" IS E'References "custom"."User"."_id" (no foreign key: Bubble does not enforce referential integrity)';]
  end

  test "quotes hostile names in the column comment as one escape string literal" do
    name = "o'wn\nA\rB\vC\fD\u0085E\u2028F\u2029G\\H'); DROP TABLE x; -- */"
    {db, _from} = owner_db(name, "Us'er\\")
    assert {:ok, sql} = Postgres.encode(db)

    [_before, statement] = String.split(sql, "COMMENT ON COLUMN ")

    assert statement ==
             ~s["custom"."Thing"."#{name}" IS ] <>
               ~S[E'References "custom"."Us''er\\"."_id" (no foreign key: Bubble does not enforce referential integrity)';] <>
               "\n"
  end

  test "string_literal/1 doubles quotes and backslashes and escapes line breaks" do
    assert Postgres.string_literal("plain") == "E'plain'"
    assert Postgres.string_literal("it's") == "E'it''s'"
    assert Postgres.string_literal(~S[a\'b]) == ~S[E'a\\''b']
    assert Postgres.string_literal("');--*/") == "E''');--*/'"

    assert Postgres.string_literal("a\nb\rc\vd\fe\u0085f\u2028g\u2029h") ==
             ~S[E'a\nb\rc\u000Bd\fe\u0085f\u2028g\u2029h']
  end

  defp owner_db(name \\ "owner", target_table \\ "User") do
    from =
      col("ref", name, %{type: :reference, custom_type: "user"},
        table_id: "t1",
        table_name: "Thing"
      )

    to =
      col("_id", "_id", %{type: :string},
        table_id: "user",
        table_name: target_table,
        primary_key: true
      )

    {thing_db([from], [{from, to, :one_to_one}]), from}
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
    assert {:ok, sql} = Postgres.encode(db, foreign_keys: :enforced)
    refute sql =~ "ADD FOREIGN KEY"
    refute sql =~ "-- References"
    refute sql =~ "COMMENT ON"
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

  test "encode/2 rejects an unknown foreign_keys mode" do
    for mode <- [:bogus, "enforced", nil] do
      assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
               Postgres.encode(thing_db([]), foreign_keys: mode)
    end
  end
end
