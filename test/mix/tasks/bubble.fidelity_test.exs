defmodule Mix.Tasks.Bubble.FidelityTest do
  use ExUnit.Case, async: false

  test "raises a usage error on unknown flags" do
    assert_raise Mix.Error, ~r/usage/, fn ->
      Mix.Tasks.Bubble.Fidelity.run(["--username", "x"])
    end
  end

  test "refuses live recapture" do
    assert_raise Mix.Error, ~r/recapture/, fn ->
      Mix.Tasks.Bubble.Fidelity.run(["--recapture"])
    end
  end
end
