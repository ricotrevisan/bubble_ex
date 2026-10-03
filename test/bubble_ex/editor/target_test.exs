defmodule BubbleEx.Editor.TargetTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Editor.Target

  test "requires an isolated child version and redacts the cookie" do
    assert {:error, %BubbleEx.Error{context: %{reason: :protected_version}}} =
             Target.new("app", "test", "session=secret")

    assert {:ok, target} = Target.new("app", "dev03", "session=unique-secret")
    inspected = inspect(target)
    assert inspected =~ "dev03"
    assert inspected =~ "[REDACTED]"
    refute inspected =~ "unique-secret"
  end

  test "readable targets retain fixed-origin and header-injection protection" do
    for version <- ["test", "live", "child"] do
      assert {:ok, target} = Target.readable("app", version, "unique-secret")
      refute inspect(target) =~ "unique-secret"

      assert {:error, %BubbleEx.Error{context: %{reason: :invalid_origin}}} =
               Target.readable("app", version, "cookie", origin: "https://evil.example")

      for control <- [<<0>>, "\t", "\r", "\n", <<127>>] do
        assert {:error, %BubbleEx.Error{context: %{reason: :invalid_cookie}}} =
                 Target.readable("app", version, "cookie=" <> control)
      end
    end
  end

  test "rejects unsafe identity and cookie values" do
    assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
             Target.new("../app", "dev03", "cookie=x")

    assert {:error, %BubbleEx.Error{context: %{reason: :invalid_cookie}}} =
             Target.new("app", "dev03", "cookie=x\r\ninjected=y")
  end
end
