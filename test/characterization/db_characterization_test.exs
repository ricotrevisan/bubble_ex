defmodule BubbleEx.Characterization.DbTest do
  @moduledoc """
  Characterization tests freezing the current Db.Reader + Db.Dbml output against
  the synthetic fixture (test/support/samples/synthetic_app.json). Captured 2026-06-22.

  The synthetic fixture is author-controlled, so these tests assert stable, intentional
  facts rather than brittle byte sizes or counts derived from a real app.
  """
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Dbml
  alias BubbleEx.Db.Reader

  @app "test/support/samples/synthetic_app.json" |> File.read!() |> Jason.decode!()

  describe "Reader.parse/1" do
    setup do
      assert {:ok, db} = Reader.parse(@app)
      {:ok, db: db}
    end

    test "reads the bubble id", %{db: db} do
      assert db.bubble_id == "synthapp"
    end

    test "reads the stable number of tables and relationships", %{db: db} do
      assert length(db.tables) == 3
      # survey_response references both a custom type and an option set, so it
      # generates two relationships: -> onboarding_answer and -> status_type.
      assert length(db.relationships) == 2
    end

    test "reads the known custom table with its columns", %{db: db} do
      table = Enum.find(db.tables, &(&1.id == "onboarding_answer"))
      assert table.name == "Onboarding Answer"
      assert table.group == :custom
      # 2 custom fields (label, score) + 1 Reader-injected built-in _id column
      assert length(table.columns) == 3
    end

    test "covers the enum/option-set reference path", %{db: db} do
      survey = Enum.find(db.tables, &(&1.id == "survey_response"))
      enum_col = Enum.find(survey.columns, &(&1.id == "field_status"))
      assert enum_col.type == %{type: :enum, custom_type: "status_type"}

      # An option-set reference generates an enum relationship to the option table.
      assert Enum.any?(db.relationships, fn {from, to, _} ->
               from.table_id == "survey_response" and to.table_id == "status_type"
             end)
    end
  end

  describe "Dbml.encode/2" do
    setup do
      {:ok, db} = Reader.parse(@app)
      {:ok, dbml} = Dbml.encode(db)
      {:ok, dbml: dbml}
    end

    test "starts with the project header and includes standard metadata", %{dbml: dbml} do
      assert String.starts_with?(dbml, ~s(Project "synthapp" {))
      assert dbml =~ "database_type: \"Bubble.io\""
      assert dbml =~ "bubble-to-dbml generator by rico.wtf"
    end

    test "emits the known custom table", %{dbml: dbml} do
      assert dbml =~ ~s(Table custom."Onboarding Answer" {)
    end

    test "emits the option-set relationship Ref line", %{dbml: dbml} do
      # Pin the concrete Ref: line, not just "status_type" (which also appears in
      # the enum column type `"status" status_type.id` and would pass even if
      # encode_relationships/2 stopped emitting the option-set ref).
      assert dbml =~
               ~s(Ref: custom."Survey Response"."status" - option."Status Type"."Display")
    end
  end
end
