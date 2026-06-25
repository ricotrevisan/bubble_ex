defmodule BubbleEx.Characterization.DbConvexTest do
  @moduledoc """
  Characterization test freezing Db.Reader + Db.Convex output against the
  synthetic fixture (test/support/samples/synthetic_app.json). Asserts stable,
  intentional structural facts rather than byte-for-byte output (field order in a
  Convex table follows unspecified map iteration order).
  """
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Convex
  alias BubbleEx.Db.Reader

  @app "test/support/samples/synthetic_app.json" |> File.read!() |> Jason.decode!()

  setup do
    {:ok, db} = Reader.parse(@app)
    {:ok, ts} = Convex.encode(db)
    {:ok, ts: ts}
  end

  test "emits the defineSchema boilerplate and validator imports", %{ts: ts} do
    assert ts =~ ~s(import { defineSchema, defineTable } from "convex/server";)
    assert ts =~ ~s(import { v } from "convex/values";)
    assert ts =~ "export default defineSchema({"
    assert ts =~ "});\n"
  end

  test "emits a defineTable per custom table with camelCase identifiers", %{ts: ts} do
    assert ts =~ "  onboardingAnswer: defineTable({"
    assert ts =~ "  surveyResponse: defineTable({"
  end

  test "maps scalar columns to v validators", %{ts: ts} do
    assert ts =~ "    label: v.string(),"
    assert ts =~ "    score: v.float64(),"
    assert ts =~ "    answer: v.string(),"
    assert ts =~ "    rating: v.float64(),"
  end

  test "renders the injected primary key as bubbleId with a comment", %{ts: ts} do
    assert ts =~ "    bubbleId: v.string(), // primary key (Bubble _id, text)"
  end

  test "renders the custom reference as v.string() with a re-key comment", %{ts: ts} do
    assert ts =~ "    onboardingAnswer: v.string(), // reference -> re-key to v.id(...)"
  end

  test "renders the option-set enum column as v.string() with a comment", %{ts: ts} do
    assert ts =~ "    status: v.string(), // enum -> option set (member values not in IR)"
  end

  test "emits the option-set table as a plain defineTable", %{ts: ts} do
    assert ts =~ "  statusType: defineTable({"
    assert ts =~ "    color: v.string(),"
  end
end
