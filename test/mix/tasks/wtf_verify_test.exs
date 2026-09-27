defmodule Mix.Tasks.Wtf.VerifyTest do
  # Mix.shell/1 is global. The checks themselves are tested through
  # BubbleEx.Target.Phoenix.Structural.project/2 (with a scripted `mix`).
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  defp verify(args), do: Mix.Tasks.Wtf.Verify.run(args)

  test "structural is the only command, and it needs the Bubble app ID", %{tmp_dir: root} do
    assert_raise Mix.Error, ~r/usage: mix wtf.verify structural/, fn -> verify([]) end
    assert_raise Mix.Error, ~r/usage/, fn -> verify(["behavioural", "--app", "acme"]) end
    assert_raise Mix.Error, ~r/unknown options/, fn -> verify(["structural", "--bogus"]) end

    assert_raise Mix.Error, ~r/--app APP_ID is required/, fn ->
      verify(["structural", "--root", root])
    end
  end

  test "a directory that is not a generated project is refused", %{tmp_dir: root} do
    assert_raise Mix.Error, ~r/no .wtf\/generated.json/, fn ->
      verify(["structural", "--app", "acme", "--root", root])
    end
  end
end
