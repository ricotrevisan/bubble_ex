defmodule BubbleEx.Frontend.ReusableParametersTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.FrontendFixtures

  @tag :tmp_dir
  test "two reusable instances resolve distinct literal text and image parameters", %{
    tmp_dir: tmp
  } do
    assets =
      Map.new([{"one", "red"}, {"two", "blue"}], fn {name, color} ->
        image = Path.join(tmp, name <> ".svg")

        File.write!(
          image,
          ~s(<svg xmlns="http://www.w3.org/2000/svg"><path fill="#{color}" d="M0 0h20v10H0z"/></svg>)
        )

        {"https://example.test/#{name}.svg", image}
      end)

    payload = payload()

    assert {:ok, result} =
             Frontend.export_payload(payload, Path.join(tmp, "export"),
               secret_scan_adapter: FrontendFixtures.clean_scanner(),
               asset_files: assets
             )

    html =
      File.read!(Path.join(result.out_dir, "pages/index/index.html")) |> Floki.parse_document!()

    assert Floki.text(Floki.find(html, "[data-bubble-id=label]")) == "Hello oneHello two"
    assert length(Floki.find(html, "img[data-bubble-id=photo][src]")) == 2
    assert length(Enum.uniq(Floki.attribute(html, "img[data-bubble-id=photo]", "src"))) == 2
    assert Floki.attribute(html, "img[data-bubble-id=photo]", "alt") == ["one", "two"]
    ids = Floki.attribute(html, "[data-exporter-id]", "data-exporter-id")
    assert ids == Enum.uniq(ids)
    assert result.model.source.payload == payload

    resolved_labels = Enum.filter(result.bindings, &(&1["slot"] == "text"))

    assert Enum.any?(
             resolved_labels,
             &(&1["payload"] == text(["Hello ", parameter("param_name")]))
           )
  end

  @tag :tmp_dir
  test "nested reusable parameters forward only through the referenced definition", %{
    tmp_dir: tmp
  } do
    base = payload()
    card = update_in(base["element_definitions"]["card"], ["%el"], &Map.delete(&1, "photo"))

    wrapper = %{
      "id" => "wrapper-id",
      "%x" => "CustomDefinition",
      "%p" => %{"container_layout" => "column"},
      "%el" => %{
        "nested" => %{
          "%x" => "CustomElement",
          "%p" => %{
            "definition" => "card",
            "param_name" => text([parameter("param_name", "wrapper-id")])
          }
        },
        "unrelated" => %{
          "id" => "unrelated",
          "%x" => "Text",
          "%p" => %{"text" => text([parameter("param_name", "wrong-definition")])}
        }
      }
    }

    payload =
      base
      |> Map.put("element_definitions", %{"card" => card, "wrapper" => wrapper})
      |> update_in(["pages", "index", "elements"], fn elements ->
        Map.new(elements, fn {key, element} ->
          {key, put_in(element, ["%p", "definition"], "wrapper")}
        end)
      end)

    assert {:ok, result} =
             Frontend.export_payload(payload, tmp,
               secret_scan_adapter: FrontendFixtures.clean_scanner()
             )

    html =
      File.read!(Path.join(result.out_dir, "pages/index/index.html")) |> Floki.parse_document!()

    assert Floki.text(Floki.find(html, "[data-bubble-id=label]")) == "Hello oneHello two"
    assert Floki.text(Floki.find(html, "[data-bubble-id=unrelated]")) == ""
  end

  defp parameter(name, ref \\ "card"),
    do: %{
      "%x" => "GetElement",
      "%p" => %{"%ei" => ref},
      "%n" => %{"%nm" => name, "%x" => "Message"}
    }

  @tag :tmp_dir
  test "resolved parameters retain HTML escaping and asset URL protections", %{tmp_dir: tmp} do
    payload =
      update_in(payload(), ["pages", "index", "elements"], fn elements ->
        Map.new(elements, fn {key, element} ->
          {key,
           element
           |> put_in(["%p", "param_name"], text(["<script>bad()</script>"]))
           |> put_in(["%p", "param_image"], text(["javascript:bad()"]))}
        end)
      end)

    payload =
      put_in(payload, ["element_definitions", "card", "%el", "link"], %{
        "%x" => "Link",
        "id" => "link",
        "%p" => %{"text" => "Go", "destination" => text([parameter("param_image")])}
      })

    assert {:ok, result} =
             Frontend.export_payload(payload, tmp,
               secret_scan_adapter: FrontendFixtures.clean_scanner()
             )

    html =
      File.read!(Path.join(result.out_dir, "pages/index/index.html")) |> Floki.parse_document!()

    assert Floki.find(html, "script") == []
    assert Floki.find(html, "img[src]") == []
    assert Floki.text(Floki.find(html, "[data-bubble-id=label]")) =~ "<script>bad()</script>"
    assert Enum.any?(result.findings, &(&1["type"] == "asset_failure"))
    assert Floki.find(html, "[data-bubble-id=link][href]") == []
    assert Enum.any?(result.findings, &(&1["type"] == "unsafe_link_destination"))
  end

  defp text(parts),
    do: %{
      "%x" => "TextExpression",
      "%e" => parts |> Enum.with_index() |> Map.new(fn {v, i} -> {to_string(i), v} end)
    }

  defp payload do
    %{
      "_id" => "parameter-app",
      "pages" => %{
        "index" => %{
          "type" => "Page",
          "name" => "index",
          "properties" => %{"container_layout" => "column"},
          "elements" =>
            Map.new(["one", "two"], fn value ->
              {value,
               %{
                 "id" => value,
                 "%x" => "CustomElement",
                 "%p" => %{
                   "definition" => "card",
                   "param_name" => text([value]),
                   "param_image" => text(["https://example.test/#{value}.svg"])
                 }
               }}
            end)
        }
      },
      "element_definitions" => %{
        "card" => %{
          "id" => "card",
          "%x" => "CustomDefinition",
          "%p" => %{"container_layout" => "column"},
          "%el" => %{
            "label" => %{
              "id" => "label",
              "%x" => "Text",
              "%p" => %{"text" => text(["Hello ", parameter("param_name")])}
            },
            "photo" => %{
              "id" => "photo",
              "%x" => "Image",
              "%p" => %{
                "src" => text([parameter("param_image")]),
                "alt_tag" => text([parameter("param_name")])
              }
            }
          }
        }
      }
    }
  end
end
