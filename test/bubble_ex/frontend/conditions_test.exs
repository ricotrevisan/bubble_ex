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

  describe "the compact form's \"%s\" states (WTF-477)" do
    defp width_state do
      %{
        "%x" => "State",
        "%p" => %{"%fs" => 24},
        "%c" => %{
          "%x" => "PageData",
          "%p" => %{"%nm" => "Current Page Width"},
          "%n" => %{
            "%x" => "Message",
            "%nm" => "less_than",
            "%a" => %{"%x" => "Breakpoint", "%p" => %{"breakpoint_id" => "mobile"}}
          }
        }
      }
    end

    defp logged_in_state do
      %{
        "%x" => "State",
        "%p" => %{"%iv" => true},
        "%c" => %{"%x" => "CurrentUser", "%n" => %{"%x" => "Message", "%nm" => "logged_in"}}
      }
    end

    defp compact(states) do
      payload = %{
        "_id" => "compact-conditions",
        "settings" => %{
          "client_safe" => %{"responsive_breakpoints" => %{"mobile" => %{"size" => 768}}}
        },
        "pages" => %{
          "index" => %{
            "type" => "Page",
            "elements" => %{
              "label" => %{
                "id" => "label",
                "%x" => "Text",
                "%p" => %{"%3" => "Label", "%iv" => false},
                "%s" => states
              }
            }
          }
        }
      }

      {:ok, model} = BubbleEx.Frontend.normalize(payload)
      [%{children: [label]}] = model.pages
      label
    end

    test "are conditionals, except the ones lowered as breakpoint rules" do
      label = compact(%{"0" => width_state(), "1" => logged_in_state()})

      assert [%{"media" => %{"operator" => "<", "width" => 768}}] = label.responsive
      assert %{kind: :condition, payload: payload} = label.bindings["condition"]
      assert Map.keys(payload) == ["1"]
      assert [{%{"%x" => "CurrentUser"}, true}] = Conditions.visibility(payload)
    end

    test "only breakpoint states leave no conditional" do
      label = compact(%{"0" => width_state()})
      refute Map.has_key?(label.bindings, "condition")
      refute Map.has_key?(label.content || %{}, "condition")
    end
  end
end
