defmodule BubbleEx.AppTree.Render.StylesTest do
  use ExUnit.Case, async: true

  alias BubbleEx.AppTree.Render.Styles

  test "renders a style table from the fixture" do
    app = BubbleEx.SampleHelper.load_json_sample("synthetic_export")

    text = app["styles"] |> Styles.render() |> IO.iodata_to_binary()

    assert text == """
           # Styles

           _Generated from styles.json — do not edit._

           | Style | Element type | Display | Font | Size | Color |
           |---|---|---|---|---|---|
           | Text__headline_ | Text | .headline | Poppins:::500 | 32 | rgba(32, 32, 32, 1) |
           """
  end

  test "tolerates empty or missing styles" do
    assert Styles.render(nil) |> IO.iodata_to_binary() =~ "# Styles"
    assert Styles.render(%{}) |> IO.iodata_to_binary() =~ "# Styles"
  end
end
