defmodule BubbleEx.Frontend.StaticSvgTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.Frontend.Export.Html

  test "static path-only HTML SVGs preserve their geometry and stroke" do
    svg =
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"></path></svg>)

    assert {:ok, model} = Frontend.normalize(payload(svg))
    node = hd(hd(model.pages).children)
    refute node.placeholder?
    assert node.variant == :inline_svg
    html = node |> Html.render_node([]) |> IO.iodata_to_binary()
    assert html =~ ~s(viewBox="0 0 24 24")
    assert html =~ ~s(stroke-width="2")
    assert html =~ ~s(d="M20 6 9 17l-5-5")
    css = BubbleEx.Frontend.Export.Css.page(hd(model.pages))
    refute css =~ "fill: currentColor;"
  end

  test "active, external, or unsupported HTML stays an explicit placeholder" do
    for inner <- [
          ~s|<script>alert(1)</script>|,
          ~s|<image href="https://example.test/tracker"/>|,
          ~s|<use href="https://example.test/sprite#icon"/>|,
          ~s|<foreignObject><div>HTML</div></foreignObject>|,
          ~s|<path d="M1 2" onload="alert(1)"/>|,
          ~s|<path d="M1 2" fill="url(https://example.test/paint)"/>|
        ] do
      assert {:ok, model} = Frontend.normalize(payload("<svg>#{inner}</svg>"))
      assert hd(hd(model.pages).children).placeholder?
    end
  end

  test "groups preserve safe paint inheritance and reject nested active content" do
    assert {:ok, svg} =
             BubbleEx.Frontend.StaticSvg.parse(
               ~s|<svg><g fill="none"><path stroke="currentColor" d="M1 2L3 4"/></g></svg>|
             )

    assert svg =~ ~s(<g fill="none">)

    for inner <- [
          ~s|<g onclick="alert(1)"><path d="M1 2"/></g>|,
          ~s|<g><image href="https://example.test/tracker"/></g>|,
          ~s|<g fill="url(https://example.test/paint)"><path d="M1 2"/></g>|,
          String.duplicate("<g>", 20) <> ~s|<path d="M1 2"/>| <> String.duplicate("</g>", 20)
        ] do
      assert BubbleEx.Frontend.StaticSvg.parse("<svg>#{inner}</svg>") == :unsupported
    end
  end

  test "basic circle and rectangle geometry retain bounded numeric rotations" do
    for transform <- ["rotate(-45 128 128)", "rotate(90, 128, 128)", "rotate(90)"] do
      assert {:ok, svg} =
               BubbleEx.Frontend.StaticSvg.parse("""
               <svg viewBox="0 0 256 256"><g fill="none" stroke="currentColor">
               <circle cx="-2" cy="128" r="36"/>
               <rect x="32" y="32" width="192" height="192" rx="48" ry="24" transform="#{transform}"/>
               </g></svg>
               """)

      assert svg =~ ~s(transform="#{transform}")
      assert svg =~ ~s(cx="-2")
      assert svg =~ ~s(ry="24")
    end
  end

  test "basic shapes cannot introduce active content, resource loads or malformed geometry" do
    for shape <- [
          ~s|<circle r="2" onload="alert(1)"/>|,
          ~s|<circle r="2" style="fill:url(https://example.test/paint)"/>|,
          ~s|<circle r="2"><animate attributeName="r" values="2;999"/></circle>|,
          ~s|<circle r="-2"/>|,
          ~s|<rect width="20" height="20" href="https://example.test/image"/>|,
          ~s|<rect width="20" height="20" fill="url(#paint)"/>|,
          ~s|<rect width="20px" height="20"/>|,
          ~s|<rect width="20" height="-20"/>|,
          ~s|<rect width="20" height="20" transform="rotate(90) translate(1 2)"/>|,
          ~s|<rect width="20" height="20" transform="rotate(90,,128,128)"/>|,
          ~s|<rect width="20" height="20" transform="rotate(90 128)"/>|,
          ~s|<rect width="20" height="20" transform="url(https://example.test/transform)"/>|
        ] do
      assert BubbleEx.Frontend.StaticSvg.parse("<svg>#{shape}</svg>") == :unsupported
    end
  end

  defp payload(svg) do
    %{
      "_id" => "svg",
      "pages" => %{
        "index" => %{
          "type" => "Page",
          "elements" => %{
            "icon" => %{
              "id" => "icon",
              "type" => "HTML",
              "%p" => %{
                "%ht" => %{"%x" => "TextExpression", "%e" => %{"0" => svg}},
                "single_width" => true,
                "single_height" => true,
                "min_width_css" => "24px",
                "min_height_css" => "24px"
              }
            }
          }
        }
      }
    }
  end
end
