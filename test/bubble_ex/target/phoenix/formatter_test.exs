defmodule BubbleEx.Target.Phoenix.FormatterTest do
  # The LiveView the rendered HEEx is formatted with (WTF-425): bubble_ex
  # accepts patch releases, the render checks the loaded one against the pin.
  use ExUnit.Case, async: true

  alias BubbleEx.Target.Phoenix.Formatter

  test "the loaded LiveView is the pinned one here" do
    assert Formatter.live_view_check() == :ok
    assert Formatter.ensure_live_view() == {:ok, nil}

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

  test "another patch is recorded in the manifest, not only logged" do
    %Version{major: major, minor: minor, patch: patch} =
      Version.parse!(Formatter.live_view_version())

    other = "#{major}.#{minor}.#{patch + 1}"

    ExUnit.CaptureLog.capture_log(fn ->
      assert Formatter.ensure_live_view(other) == {:ok, other}
    end)

    assert {:error, _} = Formatter.ensure_live_view("#{major}.#{minor + 1}.0")

    {:ok, model} =
      "test/support/target/workflows/backend.json"
      |> File.read!()
      |> Jason.decode!()
      |> BubbleEx.Model.build()

    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    ctx = %{app: "acme", module: "Acme", bubble_ex_version: "0", live_view: other}
    manifest = BubbleEx.Target.Phoenix.Manifest.build(project, ctx, %{}, %{})
    assert manifest["inputs"]["phoenix_live_view"] == other

    at_pin = BubbleEx.Target.Phoenix.Manifest.build(project, %{ctx | live_view: nil}, %{}, %{})
    refute Map.has_key?(at_pin["inputs"], "phoenix_live_view")
  end
end
