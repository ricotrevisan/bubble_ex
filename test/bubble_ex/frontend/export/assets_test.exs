defmodule BubbleEx.Frontend.Export.AssetsTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.Frontend.Auth
  alias BubbleEx.Frontend.Export.Assets
  alias BubbleEx.Frontend.Fetch.Context
  alias BubbleEx.Frontend.SafeUrl
  alias BubbleEx.HTTP
  alias Plug.Conn

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> HTTP.delete_process_options() end)
    :ok
  end

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

  test "pins a validated public hostname without a second DNS lookup" do
    public_resolver = fn "cdn.example.test", 250 -> {:ok, [{93, 184, 216, 34}]} end
    private_resolver = fn "cdn.example.test", 250 -> {:ok, [{127, 0, 0, 1}]} end

    assert {:ok, {"https://93.184.216.34/image.png", "cdn.example.test"}} =
             SafeUrl.pin_public_http_destination(
               "https://cdn.example.test/image.png",
               250,
               public_resolver
             )

    assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
             SafeUrl.pin_public_http_destination(
               "https://cdn.example.test/image.png",
               250,
               private_resolver
             )
  end

  test "rejects cross-origin private-network asset destinations before requesting them" do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("private destination was requested") end)

    for url <- [
          "http://127.0.0.1/private.png",
          "http://169.254.169.254/metadata.png",
          "http://[::1]/private.png",
          "http://[::ffff:127.0.0.1]/private.png"
        ] do
      {model, context} = image_model(url)
      assert {assets, [finding]} = Assets.collect(model.pages, fetch_context: context)
      assert [%{failed?: true}] = Map.values(assets)
      assert finding["message"] =~ "did not resolve to a public address"
    end
  end

  test "does not follow a public asset redirect into a private network" do
    {model, context} = image_model("http://93.184.216.34/asset.png")
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:requested, conn.host})

      conn
      |> Conn.put_resp_header("location", "http://127.0.0.1/metadata")
      |> Conn.resp(302, "")
    end)

    assert {assets, [finding]} = Assets.collect(model.pages, fetch_context: context)
    assert [%{failed?: true}] = Map.values(assets)
    assert finding["message"] =~ "did not resolve to a public address"
    assert_received {:requested, "93.184.216.34"}
    refute_received {:requested, "127.0.0.1"}
  end

  test "a missing configured local asset never falls back to the network" do
    url = "https://cdn.example.test/image.png"
    {model, context} = image_model(url)

    Req.Test.stub(__MODULE__, fn _conn ->
      flunk("configured local asset fell back to the network")
    end)

    assert {assets, [finding]} =
             Assets.collect(model.pages,
               fetch_context: context,
               asset_files: %{url => "/definitely/missing/bubble-ex-asset.png"}
             )

    assert [%{failed?: true}] = Map.values(assets)
    assert finding["message"] =~ "configured local asset could not be read"
  end

  defp image_model(url) do
    payload = %{
      "_id" => "assets",
      "pages" => %{
        "home" => %{
          "id" => "home",
          "type" => "Page",
          "name" => "index",
          "properties" => %{"container_layout" => "column"},
          "elements" => %{
            "image" => %{
              "id" => "image",
              "type" => "Image",
              "properties" => %{"image" => url}
            }
          }
        }
      }
    }

    assert {:ok, model} = Frontend.normalize(payload)
    assert {:ok, _url, auth} = Auth.prepare("https://app.example.test", [])
    {model, %Context{page_url: "https://app.example.test", auth: auth}}
  end
end
