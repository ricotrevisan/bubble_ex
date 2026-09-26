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

  test "emits the option-set table keyed on its db_value", %{sql: sql} do
    assert sql =~ ~s[CREATE TABLE "option"."Status Type" (]
    assert sql =~ ~s("Display" text)
    assert sql =~ ~s[PRIMARY KEY ("db_value")]
  end

  test "declares no foreign key and documents the references", %{sql: sql} do
    refute sql =~ "FOREIGN KEY"

    assert sql =~
             ~s[-- "custom"."Survey Response"."onboarding answer" -> "custom"."Onboarding Answer"."_id"]

    assert sql =~ ~s[-- "custom"."Survey Response"."status" -> "option"."Status Type"."db_value"]

    assert sql =~
             ~s[COMMENT ON COLUMN "custom"."Survey Response"."status" IS E'References "option"."Status Type"."db_value" (no foreign key: Bubble does not enforce referential integrity)';]
  end

  test "with foreign_keys: :enforced, emits foreign keys for the custom and option-set references" do
    {:ok, db} = Reader.parse(@app)
    {:ok, sql} = Postgres.encode(db, foreign_keys: :enforced)

    assert sql =~
             ~s[ALTER TABLE "custom"."Survey Response" ADD FOREIGN KEY ("onboarding answer") REFERENCES "custom"."Onboarding Answer" ("_id");]

    assert sql =~
             ~s[ALTER TABLE "custom"."Survey Response" ADD FOREIGN KEY ("status") REFERENCES "option"."Status Type" ("db_value");]

    assert sql =~ ~s[-- "custom"."Survey Response"."Created By" -> "custom"."User"."_id"]
    assert sql =~ ~s[COMMENT ON COLUMN "custom"."Survey Response"."Created By" IS E'References]
    refute sql =~ ~s[COMMENT ON COLUMN "custom"."Survey Response"."status"]
  end
end
