defmodule BubbleEx.Frontend.StaticGroupDataTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.FrontendFixtures

  @tag :tmp_dir
  test "literal group data passes through explicit parent bindings without leaking across groups",
       %{tmp_dir: tmp} do
    payload = %{
      "_id" => "group-data",
      "pages" => %{
        "index" => %{
          "%x" => "Page",
          "%nm" => "index",
          "%p" => %{"container_layout" => "column"},
          "%el" => %{
            "card" =>
              group("Example app", %{
                "forward" => group(parent(), %{"label" => label("name")}),
                "category" => group("Marketplace", %{"label" => label("category")}),
                "untyped" => group(nil, %{"label" => label("empty")})
              }),
            "runtime" => group(%{"%x" => "Search"}, %{"label" => label("runtime")}),
            "number" =>
              group(12.5, %{"label" => label("number")})
              |> put_in(["%p", "%gt"], "number"),
            "wrong_type" => group(12.5, %{"label" => label("wrong-type")}),
            "missing_type" =>
              group("Invalid source", %{"label" => label("missing-type")})
              |> update_in(["%p"], &Map.delete(&1, "%gt"))
          }
        }
      }
    }

    assert {:ok, result} =
             Frontend.export_payload(payload, tmp,
               secret_scan_adapter: FrontendFixtures.clean_scanner()
             )

    html = File.read!(Path.join(tmp, "pages/index/index.html")) |> Floki.parse_document!()
    assert Floki.text(Floki.find(html, "[data-bubble-id=name]")) == "Example app"
    assert Floki.text(Floki.find(html, "[data-bubble-id=category]")) == "Marketplace"
    assert Floki.text(Floki.find(html, "[data-bubble-id=empty]")) == ""
    assert Floki.text(Floki.find(html, "[data-bubble-id=runtime]")) == ""
    assert Floki.text(Floki.find(html, "[data-bubble-id=number]")) == "12.5"
    assert Floki.text(Floki.find(html, "[data-bubble-id=wrong-type]")) == ""
    assert Floki.text(Floki.find(html, "[data-bubble-id=missing-type]")) == ""
    assert result.model.source.payload == payload

    assert Enum.any?(
             result.bindings,
             &(&1["slot"] == "data_source" and &1["payload"] == parent())
           )
  end

  defp parent, do: %{"%x" => "ElementParent", "is_slidable" => false}

  @tag :tmp_dir
  test "each typed reusable receives its own supplied data", %{tmp_dir: tmp} do
    payload = %{
      "_id" => "reusable-data",
      "pages" => %{
        "index" => %{
          "%x" => "Page",
          "%nm" => "index",
          "%p" => %{"container_layout" => "column"},
          "%el" =>
            Map.new(["First", "Second"], fn value ->
              {value, %{"%x" => "CustomElement", "%p" => %{"%ci" => "card", "%ds" => value}}}
            end)
        }
      },
      "element_definitions" => %{
        "card" => %{
          "%x" => "CustomDefinition",
          "id" => "card",
          "%p" => %{"%gt" => "text", "container_layout" => "column"},
          "%el" => %{"label" => label("title")}
        }
      }
    }

    assert {:ok, _result} =
             Frontend.export_payload(payload, tmp,
               secret_scan_adapter: FrontendFixtures.clean_scanner()
             )

    html = File.read!(Path.join(tmp, "pages/index/index.html")) |> Floki.parse_document!()
    assert Floki.text(Floki.find(html, "[data-bubble-id=title]")) == "FirstSecond"
  end

  defp label(id),
    do: %{
      "%x" => "Text",
      "id" => id,
      "%p" => %{"text" => %{"%x" => "TextExpression", "%e" => %{"0" => parent()}}}
    }

  defp group(data, children) do
    props = %{"container_layout" => "column"}
    props = if is_nil(data), do: props, else: Map.merge(props, %{"%ds" => data, "%gt" => "text"})
    %{"%x" => "Group", "%p" => props, "%el" => children}
  end
end
