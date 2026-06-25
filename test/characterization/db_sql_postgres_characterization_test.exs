defmodule BubbleEx.Characterization.DbSqlPostgresTest do
  @moduledoc """
  Characterization test freezing Db.Reader + Db.Sql.Postgres output against the
  synthetic fixture (test/support/samples/synthetic_app.json). Asserts stable,
  intentional structural facts rather than byte-for-byte output (column order in
  a Postgres table follows unspecified map iteration order).
  """
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Reader
  alias BubbleEx.Db.Sql.Postgres

  @app "test/support/samples/synthetic_app.json" |> File.read!() |> Jason.decode!()

  setup do
    {:ok, db} = Reader.parse(@app)
    {:ok, sql} = Postgres.encode(db)
    {:ok, sql: sql}
  end

  test "creates a schema per table group", %{sql: sql} do
    assert sql =~ ~s(CREATE SCHEMA IF NOT EXISTS "custom";)
    assert sql =~ ~s(CREATE SCHEMA IF NOT EXISTS "option";)
  end

  test "emits the known custom table with its primary key", %{sql: sql} do
    assert sql =~ ~s[CREATE TABLE "custom"."Onboarding Answer" (]
    assert sql =~ ~s("label" text)
    assert sql =~ ~s("score" double precision)
    assert sql =~ ~s[PRIMARY KEY ("_id")]
  end

  test "emits the option-set table keyed on Display", %{sql: sql} do
    assert sql =~ ~s[CREATE TABLE "option"."Status Type" (]
    assert sql =~ ~s[PRIMARY KEY ("Display")]
  end

  test "emits a foreign key for the scalar custom reference", %{sql: sql} do
    assert sql =~
             ~s[ALTER TABLE "custom"."Survey Response" ADD FOREIGN KEY ("onboarding answer") REFERENCES "custom"."Onboarding Answer" ("_id");]
  end

  test "emits a foreign key for the option-set reference to Display", %{sql: sql} do
    assert sql =~
             ~s[ALTER TABLE "custom"."Survey Response" ADD FOREIGN KEY ("status") REFERENCES "option"."Status Type" ("Display");]
  end
end
