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

  test "emits the foreign-keys pragma preamble", %{sql: sql} do
    assert sql =~ "PRAGMA foreign_keys = ON;"
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

  test "keys the option-set table on Display with a NOT NULL column", %{sql: sql} do
    assert sql =~ ~s("Display" TEXT NOT NULL)
    assert sql =~ ~s[PRIMARY KEY ("Display")]
  end

  test "declares the scalar custom reference as an inline foreign key", %{sql: sql} do
    assert sql =~
             ~s[FOREIGN KEY ("onboarding answer") REFERENCES "custom__Onboarding Answer" ("_id")]
  end

  test "declares the option-set reference to Display as an inline foreign key", %{sql: sql} do
    assert sql =~
             ~s[FOREIGN KEY ("status") REFERENCES "option__Status Type" ("Display")]
  end
end
