defmodule BubbleEx.Characterization.DbZodTest do
  @moduledoc """
  Characterization test freezing Db.Reader + Db.Zod output against the synthetic
  fixture (test/support/samples/synthetic_app.json). Asserts stable, intentional
  structural facts via substrings rather than byte-for-byte output (field order
  within a `z.object` follows unspecified map iteration order).
  """
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Reader
  alias BubbleEx.Db.Zod

  @app "test/support/samples/synthetic_app.json" |> File.read!() |> Jason.decode!()

  setup do
    {:ok, db} = Reader.parse(@app)
    {:ok, schema} = Zod.encode(db)
    {:ok, schema: schema}
  end

  test "imports zod once at the top", %{schema: schema} do
    assert schema =~ "import { z } from 'zod';"
  end

  test "emits the custom table schema, its scalar fields, and a non-null PK", %{schema: schema} do
    assert schema =~ "// Onboarding Answer"
    assert schema =~ "export const OnboardingAnswerSchema = z.object({"
    assert schema =~ "  label: z.string().nullish(),"
    assert schema =~ "  score: z.number().nullish(),"
    assert schema =~ "  _id: z.string(),"
    assert schema =~ "export type OnboardingAnswer = z.infer<typeof OnboardingAnswerSchema>;"
  end

  test "quotes field keys that are not valid identifiers", %{schema: schema} do
    assert schema =~ "  'onboarding answer': z.string().nullish(),"
  end

  test "renders a scalar reference as z.string() with a target comment", %{schema: schema} do
    assert schema =~
             "  'onboarding answer': z.string().nullish(), // reference -> onboarding_answer"
  end

  test "renders an option-set reference as z.string() with an enum comment", %{schema: schema} do
    assert schema =~
             "  status: z.string().nullish(), // enum -> status_type option set (values not in IR)"
  end

  test "emits the option-set table schema keyed on its Display PK", %{schema: schema} do
    assert schema =~ "export const StatusTypeSchema = z.object({"
    assert schema =~ "  Color: z.string().nullish(),"
    assert schema =~ "  Display: z.string(),"
    assert schema =~ "export type StatusType = z.infer<typeof StatusTypeSchema>;"
  end
end
