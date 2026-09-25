defmodule BubbleEx.Characterization.DbSqlSqliteTest do
  @moduledoc """
  Characterization test freezing Db.Reader + Db.Sql.Sqlite output against the
  synthetic fixture (test/support/samples/synthetic_app.json). Asserts stable,
  intentional structural facts rather than byte-for-byte output (column order in
  a SQLite table follows unspecified map iteration order).
  """
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Reader
  alias BubbleEx.Db.Sql.Sqlite

  @app "test/support/samples/synthetic_app.json" |> File.read!() |> Jason.decode!()

  setup do
    {:ok, db} = Reader.parse(@app)
    {:ok, sql} = Sqlite.encode(db)
    {:ok, sql: sql}
  end

  test "emits no foreign-keys pragma by default", %{sql: sql} do
    refute sql =~ "PRAGMA foreign_keys"
  end

  test "prefixes table names with their Bubble group", %{sql: sql} do
    assert sql =~ ~s[CREATE TABLE IF NOT EXISTS "custom__Onboarding Answer" (]
    assert sql =~ ~s[CREATE TABLE IF NOT EXISTS "custom__Survey Response" (]
    assert sql =~ ~s[CREATE TABLE IF NOT EXISTS "option__Status Type" (]
  end

  test "maps the known custom table columns and primary key", %{sql: sql} do
    assert sql =~ ~s("label" TEXT)
    assert sql =~ ~s("score" REAL)
    assert sql =~ ~s("_id" TEXT NOT NULL)
    assert sql =~ ~s[PRIMARY KEY ("_id")]
  end

  test "keys the option-set table on db_value with a NOT NULL column", %{sql: sql} do
    assert sql =~ ~s("db_value" TEXT NOT NULL)
    assert sql =~ ~s[PRIMARY KEY ("db_value")]
  end

  test "declares no foreign key and documents the references", %{sql: sql} do
    refute sql =~ "FOREIGN KEY"

    assert sql =~
             ~s[-- "custom__Survey Response"."onboarding answer" -> "custom__Onboarding Answer"."_id"]

    assert sql =~ ~s[-- "custom__Survey Response"."status" -> "option__Status Type"."db_value"]
  end

  test "with foreign_keys: :enforced, declares the custom and option-set references inline" do
    {:ok, db} = Reader.parse(@app)
    {:ok, sql} = Sqlite.encode(db, foreign_keys: :enforced)

    assert sql =~ "PRAGMA foreign_keys = ON;"

    assert sql =~
             ~s[FOREIGN KEY ("onboarding answer") REFERENCES "custom__Onboarding Answer" ("_id")]

    assert sql =~ ~s[FOREIGN KEY ("status") REFERENCES "option__Status Type" ("db_value")]
  end
end
