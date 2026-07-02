defmodule BubbleEx.AppTree.Render.OutlineTest do
  use ExUnit.Case, async: true

  alias BubbleEx.AppTree.Render.Outline

  setup do
    app = BubbleEx.SampleHelper.load_json_sample("synthetic_export")
    {:ok, app: app}
  end

  test "renders the index page outline exactly", %{app: app} do
    {iodata, coverage} = Outline.render(app["pages"]["pgA"], %{title: "index", raw: "page.json"})

    assert IO.iodata_to_binary(iodata) == """
           # Outline: index

           _Generated from page.json — do not edit._

           - [Group] grp-main
             - [Text] Text A (style: Text__headline_) => "Hello [Current User's name]"
               - when Current Page Width less than breakpoint built-in-mobile-landing: font_size
             - [Button] BTN: Go => "Go"
           """

    # All three expressions render successfully: elTxt's text (:ok), elBtn's "Go" (:ok), the condition (:ok)
    assert coverage.expressions == %{total: 3, rendered: 3}
    assert coverage.actions == %{total: 0, rendered: 0}
  end

  test "renders a component outline", %{app: app} do
    {iodata, coverage} =
      Outline.render(app["element_definitions"]["cmpNav"], %{
        title: "🏠 Left Nav",
        raw: "component.json"
      })

    text = IO.iodata_to_binary(iodata)
    assert text =~ "# Outline: 🏠 Left Nav"
    assert text =~ ~s(- [Text] Text N => "Nav")
    assert coverage.expressions == %{total: 1, rendered: 1}
  end
end
