defmodule BubbleEx.Secrets.Native.TraversalTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Secrets.Native.Traversal

  test "enumerates string leaves with path and nearest map key" do
    data = %{
      "config" => %{"api_key" => "secret-value"},
      "tokens" => ["t-one", "t-two"],
      "count" => 3
    }

    leaves = Enum.sort(Traversal.string_leaves(data))

    assert leaves == [
             {["config", "api_key"], "api_key", "secret-value"},
             {["tokens", 0], "tokens", "t-one"},
             {["tokens", 1], "tokens", "t-two"}
           ]
  end

  test "ignores non-string and empty structures" do
    assert Traversal.string_leaves(%{}) == []
    assert Traversal.string_leaves(%{"n" => 1, "b" => true, "x" => nil}) == []
    assert Traversal.string_leaves("bare string") == []
  end

  test "normalizes atom map keys to strings in both path and key" do
    data = %{config: %{api_key: "secret-value"}, tags: ["x"]}

    assert Enum.sort(Traversal.string_leaves(data)) == [
             {["config", "api_key"], "api_key", "secret-value"},
             {["tags", 0], "tags", "x"}
           ]
  end
end
