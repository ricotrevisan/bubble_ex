defmodule BubbleEx.Characterization.DeepSearchTest do
  @moduledoc """
  Characterization tests freezing BubbleEx.DeepSearch.find_all_paths/2 output,
  including against the synthetic fixture (test/support/samples/synthetic_app.json).
  Captured 2026-06-22.

  The synthetic fixture is author-controlled, so the asserted counts reflect
  intentional data: 3 fields typed "text" appear as string values in the JSON.
  Note: field ids are JSON *keys*, not values — DeepSearch matches string values only,
  so searching for "field_" yields 0 results despite having fields with that prefix.
  """
  use ExUnit.Case, async: true

  alias BubbleEx.DeepSearch

  @app "test/support/samples/synthetic_app.json" |> File.read!() |> Jason.decode!()

  test "finds all matching paths in a nested map/list structure" do
    data = %{
      "user" => %{"name" => "John", "email" => "john@example.com"},
      "posts" => [%{"title" => "First Post"}, %{"title" => "Second Post"}]
    }

    assert Enum.sort(DeepSearch.find_all_paths(data, "Post")) == [
             ["posts", 0, "title"],
             ["posts", 1, "title"]
           ]
  end

  test "returns an empty list when nothing matches" do
    assert DeepSearch.find_all_paths(%{"a" => "b"}, "zzz") == []
  end

  test "finds the known text-typed field count in the synthetic fixture" do
    # Three fields in the fixture have type "text" (stored as the %v value).
    # DeepSearch matches string values, not keys, so this count is stable.
    assert length(DeepSearch.find_all_paths(@app, "text")) == 3
  end
end
