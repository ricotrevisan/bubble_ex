defmodule Mix.Tasks.Bubble.AppTreeTest do
  use ExUnit.Case, async: false

  @fixture "test/support/samples/synthetic_export.json"

  @tag :tmp_dir
  test "runs end-to-end and reports the summary", %{tmp_dir: tmp} do
    out = Path.join(tmp, "tree")

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Bubble.AppTree.run([@fixture, "-o", out])
      end)

    assert output =~ "Wrote"
    assert output =~ "actions rendered: 5/7"
    assert File.exists?(Path.join(out, "MANIFEST.json"))
  end

  test "raises a usage error without arguments" do
    assert_raise Mix.Error, ~r/usage/, fn -> Mix.Tasks.Bubble.AppTree.run([]) end
  end

  @tag :tmp_dir
  test "surfaces generate errors as Mix errors", %{tmp_dir: tmp} do
    assert_raise Mix.Error, ~r/not_found/, fn ->
      Mix.Tasks.Bubble.AppTree.run([Path.join(tmp, "nope.json"), "-o", Path.join(tmp, "out")])
    end
  end
end
