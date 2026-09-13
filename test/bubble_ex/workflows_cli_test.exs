defmodule BubbleEx.WorkflowsCliTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  @tag :tmp_dir
  test "CLI exports supplied data and rejects missing, malformed and unknown arguments", %{
    tmp_dir: dir
  } do
    input = Path.join(dir, "app.json")
    out = Path.join(dir, "out")
    File.write!(input, ~s({"workflows":{"w":{"type":"CustomEvent","actions":{}}}}))

    assert capture_io(fn -> Mix.Tasks.Bubble.Workflows.run([input, "-o", out]) end) =~
             "1 workflow entries"

    assert File.exists?(Path.join(out, "inventory.json"))
    assert File.exists?(Path.join(out, "WORKFLOWS.md"))
    assert_raise Mix.Error, fn -> Mix.Tasks.Bubble.Workflows.run([input, "-o", out]) end

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Bubble.Workflows.run([input, "--unknown", "-o", out])
    end

    assert_raise Mix.Error, fn -> Mix.Tasks.Bubble.Workflows.run([]) end
    File.write!(input, "not json")

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Bubble.Workflows.run([input, "-o", Path.join(dir, "bad")])
    end
  end
end
