defmodule BubbleEx.Frontend.PositionedOrderTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.FrontendFixtures

  @tag :tmp_dir
  test "positioned children follow layer order even with stale flow order", %{tmp_dir: tmp} do
    for mode <- ["relative", "fixed"], layer_key <- ["%z", "zindex", "z_index", "z-index"] do
      directory = Path.join(tmp, mode <> layer_key)

      assert {:ok, _} =
               Frontend.export_payload(payload(mode, layer_key), directory,
                 secret_scan_adapter: FrontendFixtures.clean_scanner()
               )

      document =
        Path.join(directory, "pages/index/index.html")
        |> File.read!()
        |> Floki.parse_document!()

      assert Floki.find(document, "p") |> Enum.map(&Floki.text/1) == [
               "Example App",
               "Marketplace"
             ]
    end
  end

  @tag :tmp_dir
  test "flow children keep their authored order independent of layers", %{tmp_dir: tmp} do
    for mode <- ["row", "column"] do
      assert {:ok, _} =
               Frontend.export_payload(payload(mode), Path.join(tmp, mode),
                 secret_scan_adapter: FrontendFixtures.clean_scanner()
               )

      document =
        Path.join([tmp, mode, "pages/index/index.html"])
        |> File.read!()
        |> Floki.parse_document!()

      assert Floki.find(document, "p") |> Enum.map(&Floki.text/1) == [
               "Marketplace",
               "Example App"
             ]
    end
  end

  defp payload(mode, layer_key \\ "%z") do
    %{
      "_id" => "positioned",
      "pages" => %{
        "index" => %{
          "%x" => "Page",
          "%nm" => "index",
          "%p" => %{"container_layout" => "column"},
          "%el" => %{
            "card" => %{
              "%x" => "Group",
              "%p" => %{"container_layout" => mode},
              "%el" => %{
                "name" => %{
                  "%x" => "Text",
                  "%p" => %{"%3" => "Example App", "order" => 3, layer_key => 3}
                },
                "tag" => %{"%x" => "Text", "%p" => %{"%3" => "Marketplace", layer_key => 4}}
              }
            }
          }
        }
      }
    }
  end
end
