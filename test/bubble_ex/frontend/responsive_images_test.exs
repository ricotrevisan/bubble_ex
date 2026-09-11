defmodule BubbleEx.Frontend.ResponsiveImagesTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.FrontendFixtures

  @tag :tmp_dir
  test "literal width conditions select local images in last-condition order", %{tmp_dir: tmp} do
    payload = payload()
    {html, result} = export(payload, tmp)

    assert [picture] = Floki.find(html, "picture")
    assert Floki.attribute(picture, "style") == ["display: contents"]
    sources = Floki.find(picture, "source")

    assert Enum.flat_map(sources, &Floki.attribute(&1, "media")) ==
             ["(width < 400px)", "(width <= 600px)"]

    assert Enum.map(sources, &asset_contents(&1, "srcset", tmp)) == ["small", "mobile"]
    assert [image] = Floki.find(picture, "img[data-bubble-id=art]")
    assert asset_contents(image, "src", tmp) == "desktop"
    assert result.model.source.payload == payload
  end

  @tag :tmp_dir
  test "responsive assets are available within each reusable instance", %{tmp_dir: tmp} do
    payload = payload()
    elements = get_in(payload, ["pages", "index", "%el"])

    definition = %{
      "%x" => "CustomDefinition",
      "id" => "component",
      "%el" => elements,
      "%p" => %{"container_layout" => "column"}
    }

    instances =
      Map.new(["left", "right"], fn name ->
        {name, %{"%x" => "CustomElement", "%p" => %{"definition" => "component"}}}
      end)

    payload =
      payload
      |> put_in(["pages", "index", "%el"], instances)
      |> Map.put("element_definitions", %{"component" => definition})

    {html, _} = export(payload, tmp)
    assert length(Floki.find(html, "picture")) == 2

    assert Enum.map(Floki.find(html, "source"), &asset_contents(&1, "srcset", tmp)) ==
             ["small", "mobile", "small", "mobile"]

    ids = Floki.find(html, "img") |> Floki.attribute("data-exporter-id")
    assert length(Enum.uniq(ids)) == 2
  end

  @tag :tmp_dir
  test "runtime image expressions and compound conditions are not treated as literal sources", %{
    tmp_dir: tmp
  } do
    runtime = %{
      "%x" => "TextExpression",
      "%e" => %{
        "0" => "https://example.invalid/",
        "1" => %{"%x" => "CurrentUser"}
      }
    }

    payload =
      payload()
      |> put_in(["pages", "index", "%el", "art", "%s", "2", "%p", "src"], runtime)
      |> put_in(
        ["pages", "index", "%el", "art", "%s", "1", "%c", "%n", "%n"],
        %{"%nm" => "and", "%a" => true}
      )

    {html, result} = export(payload, tmp)
    assert Floki.find(html, "picture") == []
    assert [image] = Floki.find(html, "img")
    assert asset_contents(image, "src", tmp) == "desktop"
    assert result.model.source.payload == payload
  end

  @tag :tmp_dir
  test "a rejected responsive URL stays failed instead of falling back to the desktop image", %{
    tmp_dir: tmp
  } do
    payload =
      put_in(
        payload(),
        ["pages", "index", "%el", "art", "%s", "2", "%p", "src"],
        "javascript:alert(1)"
      )

    {html, result} = export(payload, tmp)
    assert [source | _] = Floki.find(html, "source")
    assert Floki.attribute(source, "srcset") == ["data:,"]
    refute Floki.raw_html(html) =~ "javascript:"
    assert Enum.any?(result.findings, &(&1["type"] == "asset_failure"))
  end

  defp export(payload, tmp) do
    assets =
      Map.new(["desktop", "mobile", "small"], fn name ->
        file = Path.join(tmp, name <> ".png")
        File.write!(file, name)
        {"https://example.invalid/" <> name <> ".png", file}
      end)

    assert {:ok, result} =
             Frontend.export_payload(payload, Path.join(tmp, "export"),
               secret_scan_adapter: FrontendFixtures.clean_scanner(),
               asset_files: assets
             )

    html =
      Path.join(tmp, "export/pages/index/index.html") |> File.read!() |> Floki.parse_document!()

    {html, result}
  end

  defp asset_contents(node, attribute, tmp) do
    [relative] = Floki.attribute(node, attribute)
    tmp |> Path.join("export/pages/index") |> Path.join(relative) |> File.read!()
  end

  defp payload do
    %{
      "_id" => "responsive-images",
      "pages" => %{
        "index" => %{
          "%x" => "Page",
          "%nm" => "index",
          "%p" => %{"container_layout" => "column"},
          "%el" => %{
            "art" => %{
              "%x" => "Image",
              "id" => "art",
              "%p" => %{
                "src" => "https://example.invalid/desktop.png",
                "single_width" => true,
                "min_width_css" => "200px",
                "single_height" => true,
                "min_height_css" => "100px"
              },
              "%s" => %{
                "1" => state("less_or_equal_than", 600, "mobile"),
                "2" => state("less_than", 400, "small")
              }
            }
          }
        }
      }
    }
  end

  defp state(operator, width, image) do
    %{
      "%c" => %{
        "%x" => "PageData",
        "%p" => %{"%nm" => "Current Page Width"},
        "%n" => %{"%nm" => operator, "%a" => width}
      },
      "%p" => %{
        "src" => %{
          "%x" => "TextExpression",
          "%e" => %{"0" => "https://example.invalid/" <> image <> ".png"}
        }
      }
    }
  end
end
