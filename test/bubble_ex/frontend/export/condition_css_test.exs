defmodule BubbleEx.Frontend.Export.ConditionCssTest do
  use ExUnit.Case, async: true
  alias BubbleEx.Frontend.Export.ConditionCss

  test "source focus and invalid-input condition paints are valid CSS" do
    assert ConditionCss.declarations(%{
             "border_color_left" => "rgba(68, 138, 255, 1)",
             "border_color_bottom" => "rgba(0, 150, 136, 1)",
             "is_visible" => true
           }) == [
             {"border-bottom-color", "rgba(0, 150, 136, 1)"},
             {"border-left-color", "rgba(68, 138, 255, 1)"},
             {"display", "block"}
           ]

    assert ConditionCss.declarations(%{"border_color_bottom" => "red;position:fixed"}) == []
  end
end
