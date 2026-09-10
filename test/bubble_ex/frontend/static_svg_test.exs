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
