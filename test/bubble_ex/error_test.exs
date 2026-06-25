defmodule BubbleEx.ErrorTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Error

  doctest BubbleEx.Error

  test "new/3 builds a struct with kind, message, context" do
    err = Error.new(:invalid_input, "bad slug", %{value: "a b"})
    assert %Error{kind: :invalid_input, message: "bad slug", context: %{value: "a b"}} = err
  end

  test "new/2 defaults context to an empty map" do
    assert %Error{kind: :not_found, context: %{}} = Error.new(:not_found, "missing")
  end

  test "from_http/3 maps known status codes to specific kinds" do
    assert %Error{kind: :unauthorized} = Error.from_http(401, "nope", %{})
    assert %Error{kind: :forbidden} = Error.from_http(403, "nope", %{})
    assert %Error{kind: :not_found} = Error.from_http(404, "nope", %{})
  end

  test "from_http/3 maps other status codes to :http_error and keeps the status in context" do
    err = Error.from_http(500, "boom", %{url: "https://x"})
    assert %Error{kind: :http_error, context: %{status: 500, url: "https://x"}} = err
  end

  test "implements Exception so it can be raised at a boundary if needed" do
    msg = Exception.message(Error.new(:parse_failed, "bad json"))
    assert msg =~ "parse_failed"
    assert msg =~ "bad json"
  end
end
