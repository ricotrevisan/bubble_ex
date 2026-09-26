defmodule BubbleEx.Tasks.StoreTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Tasks.Store

  @moduletag :tmp_dir

  test "writes through an exclusive temporary file, then renames it", %{tmp_dir: dir} do
    path = Path.join(dir, ".wtf/tasks/a.json")
    :ok = Store.write_atomic(path, "one")
    :ok = Store.write_atomic(path, "two")

    assert File.read!(path) == "two"
    assert File.ls!(Path.dirname(path)) == ["a.json"]
  end

  test "a symlink planted at the temporary path is refused, never followed", %{tmp_dir: dir} do
    path = Path.join(dir, "state.json")
    victim = Path.join(dir, "victim.txt")
    File.write!(victim, "untouched")
    File.ln_s!(victim, Path.join(dir, ".state.json.fixed.tmp"))

    assert_raise File.Error, ~r/create the temporary file/, fn ->
      Store.write_atomic(path, "payload", "fixed")
    end

    assert File.read!(victim) == "untouched"
    refute File.exists?(path)
  end

  test "an existing file at the temporary path is refused too", %{tmp_dir: dir} do
    path = Path.join(dir, "state.json")
    File.write!(Path.join(dir, ".state.json.fixed.tmp"), "someone else's")

    assert_raise File.Error, fn -> Store.write_atomic(path, "payload", "fixed") end
    assert File.read!(Path.join(dir, ".state.json.fixed.tmp")) == "someone else's"
  end
end
