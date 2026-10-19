defmodule BubbleEx.Frontend.Export.ConditionCssTest do
  use ExUnit.Case, async: true
  alias BubbleEx.Frontend.Export.ConditionCss

  test "source viewport margin overrides use safe CSS lengths" do
    assert ConditionCss.declarations(%{"margin_left" => 0, "margin_right" => 12}) ==
             [{"margin-left", "0px"}, {"margin-right", "12px"}]

    assert ConditionCss.declarations(%{"margin_left" => "0;position:fixed"}) == []
  end

  test "visibility and collapse remain separate, and showing restores native flow display" do
    assert ConditionCss.declarations(%{"is_visible" => false}) == [{"visibility", "hidden"}]

    assert ConditionCss.declarations(%{"is_visible" => false}, collapse_when_hidden?: true) ==
             [{"display", "none"}, {"visibility", "hidden"}]

    assert ConditionCss.declarations(%{"is_visible" => true},
             collapse_when_hidden?: true,
             display: "flex"
           ) == [{"display", "flex"}, {"visibility", "visible"}]
  end

  test "source focus and invalid-input condition paints are valid CSS" do
    assert ConditionCss.declarations(%{
             "border_color_left" => "rgba(68, 138, 255, 1)",
             "border_color_bottom" => "rgba(0, 150, 136, 1)",
             "is_visible" => true
           }) == [
             {"border-bottom-color", "rgba(0, 150, 136, 1)"},
             {"border-left-color", "rgba(68, 138, 255, 1)"},
             {"visibility", "visible"}
           ]

    assert ConditionCss.declarations(%{"border_color_bottom" => "red;position:fixed"}) == []
  end
end
