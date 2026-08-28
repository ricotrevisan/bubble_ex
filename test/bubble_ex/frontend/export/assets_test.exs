defmodule BubbleEx.Frontend.Export.AssetsTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.Frontend.Auth
  alias BubbleEx.Frontend.Export.Assets
  alias BubbleEx.Frontend.Fetch.Context

  @tag :tmp_dir
  test "bundles the controlled Font Awesome sprite as a content-addressed local asset", %{
    tmp_dir: tmp
  } do
    payload = %{
      "_id" => "icons",
      "element_definitions" => %{
        "badge" => %{
          "id" => "badge",
          "type" => "CustomDefinition",
          "properties" => %{"container_layout" => "row"},
          "elements" => %{
            "star" => %{
              "id" => "star",
              "type" => "Icon",
              "properties" => %{"icon" => "fa fa-star"}
            }
          }
        }
      }
    }

    assert {:ok, model} = Frontend.normalize(payload)
    assert {:ok, _url, auth} = Auth.prepare("https://example.test/app", [])
    context = %Context{page_url: "https://example.test/app", auth: auth}

    sprite =
      ~s(<svg xmlns="http://www.w3.org/2000/svg"><symbol id="fa-star" viewBox="0 0 32 32"><path fill="currentColor" d="M1 2L3 4Z"/></symbol></svg>)

    url = "https://example.test/static/icon_libraries/fontawesome-4.7.0.svg"
    sprite_path = Path.join(tmp, "fontawesome.svg")
    File.write!(sprite_path, sprite)

    assert {assets, []} =
             Assets.collect(model.reusables,
               fetch_context: context,
               asset_files: %{url => sprite_path}
             )

    assert [asset] = Map.values(assets)
    assert asset.bytes =~ ~s(<symbol id="fa-star" viewBox="0 0 32 32">)
    assert asset.bytes =~ ~s(<path fill="currentColor" d="M1 2L3 4Z"/>)
    refute asset.bytes =~ "<image"
    assert asset.path =~ ~r|^assets/[0-9a-f]{64}\.svg$|
  end

  @tag :tmp_dir
  test "rejects active subresources in a downloaded icon sprite", %{tmp_dir: tmp} do
    payload = %{
      "_id" => "icons",
      "element_definitions" => %{
        "badge" => %{
          "id" => "badge",
          "type" => "CustomDefinition",
          "properties" => %{"container_layout" => "row"},
          "elements" => %{
            "star" => %{
              "id" => "star",
              "type" => "Icon",
              "properties" => %{"icon" => "fa fa-star"}
            }
          }
        }
      }
    }

    assert {:ok, model} = Frontend.normalize(payload)
    assert {:ok, _url, auth} = Auth.prepare("https://example.test/app", [])
    context = %Context{page_url: "https://example.test/app", auth: auth}
    url = "https://example.test/static/icon_libraries/fontawesome-4.7.0.svg"
    sprite_path = Path.join(tmp, "active.svg")

    File.write!(
      sprite_path,
      ~s(<svg><symbol id="fa-star" viewBox="0 0 32 32"><path d="M1 2L3 4Z"/><image href="/network-leak"/></symbol></svg>)
    )

    assert {%{}, [finding]} =
             Assets.collect(model.reusables,
               fetch_context: context,
               asset_files: %{url => sprite_path}
             )

    assert finding["type"] == "asset_failure"
    assert finding["message"] =~ "safe Font Awesome symbol"
    assert [_exporter_id] = finding["refs"]
  end
end
