defmodule BubbleEx.Characterization.DbSqlTsqlTest do
  @moduledoc """
  Characterization test freezing Db.Reader + Db.Sql.Tsql output against the
  synthetic fixture (test/support/samples/synthetic_app.json). Asserts stable,
  intentional structural facts rather than byte-for-byte output (column order in
  a table follows unspecified map iteration order).
  """
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Reader
  alias BubbleEx.Db.Sql.Tsql

  @app "test/support/samples/synthetic_app.json" |> File.read!() |> Jason.decode!()

  setup do
    {:ok, db} = Reader.parse(@app)
    {:ok, sql} = Tsql.encode(db)
    {:ok, sql: sql}
  end

  test "creates a bracketed schema per table group, each followed by GO", %{sql: sql} do
    assert sql =~ "CREATE SCHEMA [custom];\nGO"
    assert sql =~ "CREATE SCHEMA [option];\nGO"
  end

  test "emits the known custom table with a named primary-key constraint", %{sql: sql} do
    assert sql =~ "CREATE TABLE [custom].[Onboarding Answer] ("
    assert sql =~ "[label] NVARCHAR(MAX)"
    assert sql =~ "[score] FLOAT"
    assert sql =~ "[_id] NVARCHAR(450)"
    assert sql =~ "CONSTRAINT [PK_onboarding_answer] PRIMARY KEY ([_id])"
  end

  test "emits the option-set table keyed on Display", %{sql: sql} do
    assert sql =~ "CREATE TABLE [option].[Status Type] ("
    assert sql =~ "CONSTRAINT [PK_status_type] PRIMARY KEY ([Display])"
  end

  test "keyed reference and enum columns use NVARCHAR(450)", %{sql: sql} do
    assert sql =~ "[onboarding answer] NVARCHAR(450)"
    assert sql =~ "[status] NVARCHAR(450)"
    assert sql =~ "[answer] NVARCHAR(MAX)"
  end

  test "emits a named foreign key for the scalar custom reference", %{sql: sql} do
    assert sql =~
             "ALTER TABLE [custom].[Survey Response]\n" <>
               "  ADD CONSTRAINT [FK_survey_response_onboarding_answer]\n" <>
               "  FOREIGN KEY ([onboarding answer])\n" <>
               "  REFERENCES [custom].[Onboarding Answer] ([_id]);"
  end

  test "emits a named foreign key for the option-set reference to Display", %{sql: sql} do
    assert sql =~
             "ALTER TABLE [custom].[Survey Response]\n" <>
               "  ADD CONSTRAINT [FK_survey_response_status]\n" <>
               "  FOREIGN KEY ([status])\n" <>
               "  REFERENCES [option].[Status Type] ([Display]);"
  end
end
