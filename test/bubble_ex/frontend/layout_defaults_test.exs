defmodule BubbleEx.Frontend.LayoutDefaultsTest do
  use ExUnit.Case, async: true
  alias BubbleEx.Frontend
  alias BubbleEx.Frontend.Export.Css

  test "an empty group in Align to Parent fills the available height by default" do
    assert {:ok, model} =
             Frontend.normalize(
               payload("relative", "Group", %{
                 "container_layout" => "column",
                 "nonant_alignment" => "bb",
                 "min_height_css" => "40px"
               })
             )

    assert Css.page(hd(model.pages)) =~ "height: 100%;"
  end

  test "a button fills a column unless fit or fixed width is authored" do
    assert {:ok, model} =
             Frontend.normalize(
               payload("column", "Button", %{"text" => "Continue", "fit_height" => true})
             )

    assert hd(hd(model.pages).children).layout[:fill_width?]
  end

  test "a solid border with no width uses Bubble's one-pixel default" do
    assert {:ok, model} =
             Frontend.normalize(
               payload("column", "Button", %{
                 "text" => "Continue",
                 "border_style" => "solid",
                 "border_color" => "#202020"
               })
             )

    assert Css.page(hd(model.pages)) =~ "border: 1px solid #202020;"
  end

  test "an opaque plugin keeps compact dimensions when no sizing overrides exist" do
    assert {:ok, model} =
             Frontend.normalize(payload("row", "123456x123456-ABC", %{"%w" => 20, "%h" => 20}))

    node = hd(hd(model.pages).children)
    assert node.placeholder?
    assert node.box[:width] == 20
    assert node.box[:height] == 20
  end

  test "modern overlapping elements retain their stacking order" do
    assert {:ok, model} =
             Frontend.normalize(
               payload("relative", "Group", %{"container_layout" => "column", "%z" => 3})
             )

    css = Css.page(hd(model.pages))
    assert css =~ "z-index: 3;"
    assert css =~ "grid-template-columns: repeat(3, minmax(0, 1fr));"
  end

  test "fit-height aspect images ignore stale vertical bounds while fixed-height images retain them" do
    properties = %{
      "%w" => 240,
      "%h" => 240,
      "min_width_css" => "24px",
      "min_height_css" => "240px",
      "single_width" => true,
      "single_height" => false,
      "fit_height" => true,
      "use_aspect_ratio" => true,
      "aspect_ratio_width" => 1,
      "aspect_ratio_height" => 1
    }

    assert {:ok, model} = Frontend.normalize(payload("row", "Image", properties))
    image = hd(hd(model.pages).children)
    assert image.box[:width] == "24px"
    refute image.box[:height]
    refute image.box[:min_height]
    refute image.box[:max_height]

    fixed = Map.merge(properties, %{"single_height" => true, "fit_height" => false})
    assert {:ok, model} = Frontend.normalize(payload("row", "Image", fixed))
    assert hd(hd(model.pages).children).box[:min_height] == "240px"
  end

  defp payload(layout, type, properties) do
    %{
      "_id" => "defaults",
      "pages" => %{
        "index" => %{
          "type" => "Page",
          "properties" => %{"container_layout" => layout},
          "elements" => %{"child" => %{"type" => type, "id" => "child", "%p" => properties}}
        }
      }
    }
  end
end
