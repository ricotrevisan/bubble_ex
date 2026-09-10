defmodule BubbleEx.Frontend.StaticRepeatingTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.FrontendFixtures

  @tag :tmp_dir
  test "literal horizontal image lists export every item with traceable unique instances", %{
    tmp_dir: tmp
  } do
    payload = payload()
    image = Path.join(tmp, "image.svg")

    File.write!(
      image,
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><path d="M0 0h20v10H0z"/></svg>)
    )

    opts = [
      secret_scan_adapter: FrontendFixtures.clean_scanner(),
      asset_files: %{
        "https://example.test/one.svg" => image,
        "https://example.test/two.svg" => image
      }
    ]

    assert {:ok, result} = Frontend.export_payload(payload, Path.join(tmp, "export"), opts)
    [list] = hd(result.model.pages).children
    assert list.kind == :repeating_group
    assert list.variant == :static_list
    assert result.model.source.payload == payload
    assert length(list.children) == 2
    [first, second] = Enum.map(list.children, &hd(&1.children))
    assert first.content["src"][:resolved] == "https://example.test/one.svg"
    assert second.content["src"][:resolved] == "https://example.test/two.svg"
    assert first.source.path == second.source.path
    assert first.source.bubble_id == second.source.bubble_id
    assert first.exporter_id != second.exporter_id
    assert first.bindings["src"].payload == parent_expression()
    assert first.content["src"][:binding_id] == first.bindings["src"].id

    html =
      File.read!(Path.join(result.out_dir, "pages/index/index.html")) |> Floki.parse_document!()

    images = Floki.find(html, "img[data-bubble-id=logo][src]")
    assert length(images) == 2
    ids = Enum.flat_map(images, &Floki.attribute(&1, "data-exporter-id"))
    assert Enum.uniq(ids) == ids
  end

  test "runtime data and unsupported list layouts remain placeholders" do
    for props <- [%{"%ds" => %{"%x" => "Search"}}, %{"%rs" => 2}, %{"fixed_columns" => true}] do
      payload =
        update_in(payload(), ["pages", "index", "elements", "logos", "%p"], &Map.merge(&1, props))

      assert {:ok, model} = Frontend.normalize(payload)
      assert hd(hd(model.pages).children).placeholder?
    end
  end

  @tag :tmp_dir
  test "repeated items keep unique identifiers across two reusable instances", %{tmp_dir: tmp} do
    base = payload()
    list = get_in(base, ["pages", "index", "elements", "logos"])

    payload =
      base
      |> Map.put("element_definitions", %{
        "strip" => %{
          "id" => "strip",
          "%x" => "CustomDefinition",
          "%p" => %{"container_layout" => "column"},
          "%el" => %{"logos" => list}
        }
      })
      |> put_in(
        ["pages", "index", "elements"],
        Map.new(["first", "second"], fn name ->
          {name, %{"id" => name, "%x" => "CustomElement", "%p" => %{"definition" => "strip"}}}
        end)
      )

    image = Path.join(tmp, "image.svg")

    File.write!(
      image,
      ~s(<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0h20v10H0z"/></svg>)
    )

    assert {:ok, result} =
             Frontend.export_payload(payload, Path.join(tmp, "export"),
               secret_scan_adapter: FrontendFixtures.clean_scanner(),
               asset_files: Map.new(["one", "two"], &{"https://example.test/#{&1}.svg", image})
             )

    html =
      File.read!(Path.join(result.out_dir, "pages/index/index.html")) |> Floki.parse_document!()

    assert length(Floki.find(html, "img[data-bubble-id=logo][src]")) == 4
    ids = Floki.attribute(html, "[data-exporter-id]", "data-exporter-id")
    assert Enum.uniq(ids) == ids
  end

  defp parent_expression,
    do: %{"%x" => "TextExpression", "%e" => %{"0" => %{"%x" => "ElementParent"}}}

  defp payload do
    %{
      "_id" => "lists",
      "pages" => %{
        "index" => %{
          "type" => "Page",
          "name" => "index",
          "properties" => %{"container_layout" => "column"},
          "elements" => %{
            "logos" => %{
              "id" => "logos",
              "%x" => "RepeatingGroup",
              "%p" => %{
                "%rs" => 1,
                "fixed_rows" => true,
                "fixed_columns" => false,
                "show_all_items" => true,
                "container_layout" => "column",
                "single_width" => false,
                "cell_min_width_css" => "0px",
                "cell_min_height_css" => "10px",
                "%ds" => %{
                  "%x" => "ArbitraryText",
                  "%p" => %{
                    "arbitrary_text" => %{
                      "%x" => "TextExpression",
                      "%e" => %{
                        "0" => "https://example.test/one.svg\nhttps://example.test/two.svg"
                      }
                    }
                  },
                  "%n" => %{
                    "%nm" => "split_by",
                    "%p" => %{"separator" => %{"%x" => "TextExpression", "%e" => %{"0" => "\n"}}}
                  }
                }
              },
              "%el" => %{
                "logo" => %{
                  "id" => "logo",
                  "%x" => "Image",
                  "%p" => %{
                    "src" => parent_expression(),
                    "single_height" => true,
                    "single_width" => true,
                    "min_width_css" => "20px",
                    "min_height_css" => "10px"
                  }
                }
              }
            }
          }
        }
      }
    }
  end
end
