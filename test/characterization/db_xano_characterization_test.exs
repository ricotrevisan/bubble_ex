defmodule BubbleEx.Characterization.DbXanoTest do
  @moduledoc """
  Characterization test freezing Db.Reader + Db.Xano output against the synthetic
  fixture (test/support/samples/synthetic_app.json). Asserts stable, intentional
  facts: field types, the list `style`, the native `enum` type, and the
  reference/enum `description` strings. Decodes the JSON and checks per-field facts
  rather than byte-for-byte output, because JSON object key order and table/column
  iteration order follow unspecified map iteration order.
  """
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Reader
  alias BubbleEx.Db.Xano

  @app "test/support/samples/synthetic_app.json" |> File.read!() |> Jason.decode!()

  setup do
    {:ok, db} = Reader.parse(@app)
    {:ok, json} = Xano.encode(db)
    {:ok, json: json, decoded: Jason.decode!(json)}
  end

  defp table(decoded, name), do: Enum.find(decoded, &(&1["name"] == name))
  defp field(table, name), do: Enum.find(table["fields"], &(&1["name"] == name))

  test "leads the output with a format-caveat note", %{decoded: decoded} do
    note = Enum.find(decoded, &Map.has_key?(&1, "_note"))
    assert note["_note"] =~ "Metadata API"
  end

  test "emits one table object per non-api table", %{decoded: decoded} do
    names =
      decoded
      |> Enum.reject(&Map.has_key?(&1, "_note"))
      |> Enum.map(& &1["name"])
      |> Enum.sort()

    assert names == ["onboarding_answer", "status_type", "survey_response"]
  end

  test "maps scalar columns to their Xano types", %{decoded: decoded} do
    survey = table(decoded, "survey_response")
    assert field(survey, "answer") == %{"name" => "answer", "type" => "text", "style" => "single"}

    assert field(survey, "rating") == %{
             "name" => "rating",
             "type" => "decimal",
             "style" => "single"
           }
  end

  test "describes the primary key on the custom table without a primary flag", %{decoded: decoded} do
    survey = table(decoded, "survey_response")

    assert field(survey, "_id") == %{
             "name" => "_id",
             "type" => "text",
             "style" => "single",
             "description" => "Bubble primary key (link manually in Xano)"
           }
  end

  test "describes the option-set table's display key", %{decoded: decoded} do
    status = table(decoded, "status_type")

    assert field(status, "display") == %{
             "name" => "display",
             "type" => "text",
             "style" => "single",
             "description" => "Bubble primary key (link manually in Xano)"
           }
  end

  test "degrades a scalar custom reference to text with a ref description", %{decoded: decoded} do
    survey = table(decoded, "survey_response")

    assert field(survey, "onboarding_answer") == %{
             "name" => "onboarding_answer",
             "type" => "text",
             "style" => "single",
             "description" => "ref:onboarding_answer._id (link manually in Xano)"
           }
  end

  test "renders an option-set reference as the native enum type", %{decoded: decoded} do
    survey = table(decoded, "survey_response")

    assert field(survey, "status") == %{
             "name" => "status",
             "type" => "enum",
             "style" => "single",
             "values" => [],
             "description" => "enum:status_type (option values not in IR)"
           }
  end

  test "renders pretty JSON with the expected literal fragments", %{json: json} do
    assert json =~ ~s("name": "survey_response")
    assert json =~ ~s("type": "decimal")
    assert json =~ ~s("style": "single")
    assert json =~ "\"description\": \"ref:onboarding_answer._id (link manually in Xano)\""
    assert json =~ "\"description\": \"enum:status_type (option values not in IR)\""
    assert String.ends_with?(json, "\n")
  end
end
