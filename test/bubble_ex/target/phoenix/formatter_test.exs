defmodule BubbleEx.Target.Phoenix.FormatterTest do
  # The LiveView the rendered HEEx is formatted with (WTF-425): bubble_ex
  # accepts patch releases, the render checks the loaded one against the pin.
  use ExUnit.Case, async: true

  alias BubbleEx.Target.Phoenix.Formatter

  test "the loaded LiveView is the pinned one here" do
    assert Formatter.live_view_check() == :ok
    assert Formatter.ensure_live_view() == :ok

    assert {:phoenix_live_view, "== " <> Formatter.live_view_version()} in BubbleEx.Target.Phoenix.deps()
  end

  test "another patch warns, another minor or none refuses" do
    %Version{major: major, minor: minor, patch: patch} =
      Version.parse!(Formatter.live_view_version())

    assert {:warn, message} = Formatter.live_view_check("#{major}.#{minor}.#{patch + 1}")
    assert message =~ "generator pins #{Formatter.live_view_version()}"

    for other <- ["#{major}.#{minor + 1}.0", "#{major + 1}.0.0", nil, "garbage"] do
      assert {:error, %BubbleEx.Error{kind: :invalid_input}} = Formatter.live_view_check(other)
    end
  end
end
