defmodule BubbleEx.Frontend.ConditionsTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend.Conditions

  defp state(condition, properties),
    do: %{"condition" => condition, "properties" => properties, "type" => "State"}

  test "states apply in Bubble's order: numeric keys by value, then other keys" do
    payload = %{
      "10" => state("ten", %{"is_visible" => true}),
      "2" => state("two", %{"is_visible" => false}),
      "bXyzq" => state("random", %{"is_visible" => true}),
      "0" => state("zero", %{"bgcolor" => "#fff"})
    }

    assert Enum.map(Conditions.states(payload), & &1.condition) ==
             ["zero", "two", "ten", "random"]

    assert Conditions.visibility(payload) == [{"two", false}, {"ten", true}, {"random", true}]
    assert Conditions.other_properties(payload) == 1
  end

  test "the compact key form, and a visibility that is not a yes/no literal" do
    payload = %{
      "0" => %{"%c" => "c0", "%p" => %{"%iv" => true, "font_color" => "#000"}},
      "1" => state("c1", %{"is_visible" => %{"type" => "CurrentUser"}})
    }

    assert Conditions.visibility(payload) == [{"c0", true}, {"c1", nil}]
    assert Conditions.other_properties(payload) == 1
  end

  test "no states" do
    assert Conditions.states(nil) == []
    assert Conditions.visibility(%{}) == []
    assert Conditions.other_properties("x") == 0
  end
end
