defmodule BubbleEx.CanonicalJsonTest do
  use ExUnit.Case, async: true

  alias BubbleEx.CanonicalJson

  test "key order and whitespace do not change the canonical form" do
    a = Jason.decode!(~s({"b": 1, "a": {"d": [2, 1], "c": null}}))
    b = Jason.decode!(~s({"a":{"c":null,"d":[2,1]},"b":1}))
    assert CanonicalJson.encode(a) == ~s({"a":{"c":null,"d":[2,1]},"b":1})
    assert CanonicalJson.sha256(a) == CanonicalJson.sha256(b)
  end

  test "nulls and array order are significant" do
    refute CanonicalJson.sha256(%{"a" => nil}) == CanonicalJson.sha256(%{})
    refute CanonicalJson.sha256([1, 2]) == CanonicalJson.sha256([2, 1])
  end
end
