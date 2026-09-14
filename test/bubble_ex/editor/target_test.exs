defmodule BubbleEx.Editor.TargetTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Editor.Target

  test "requires an isolated child version and redacts the cookie" do
    assert {:error, %BubbleEx.Error{context: %{reason: :protected_version}}} =
             Target.new("app", "test", "session=secret")

    assert {:ok, target} = Target.new("app", "43jvs", "session=unique-secret")
    inspected = inspect(target)
    assert inspected =~ "43jvs"
    assert inspected =~ "[REDACTED]"
    refute inspected =~ "unique-secret"
  end

  test "rejects unsafe identity and cookie values" do
    assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
             Target.new("../app", "43jvs", "cookie=x")

    assert {:error, %BubbleEx.Error{context: %{reason: :invalid_cookie}}} =
             Target.new("app", "43jvs", "cookie=x\r\ninjected=y")
  end
end
