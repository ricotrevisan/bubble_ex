defmodule BubbleEx.Frontend.AspectShapesTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.FrontendFixtures

  test "aspect shapes derive height from width despite retained vertical bounds" do
    for mode <- ["relative", "row", "column", "fixed"] do
      assert {:ok, model} = Frontend.normalize(payload(mode))
      shape = shape(model)
      assert shape.box[:height] == "max-content"
      refute shape.box[:min_height]
      refute shape.box[:max_height]
      assert shape.style.resolved["aspect-ratio"] == "1000 / 600"
    end
  end

  test "disabled and invalid ratios preserve ordinary fixed-height shapes" do
    for overrides <- [
          %{"use_aspect_ratio" => false},
          %{"aspect_ratio_width" => 0},
          %{"aspect_ratio_height" => -1},
          %{"aspect_ratio_width" => "1000"}
        ] do
      app = update_in(payload("column"), shape_path(), &Map.merge(&1, overrides))
      assert {:ok, model} = Frontend.normalize(app)
      assert shape(model).box[:height] == "150px"
      assert shape(model).box[:min_height] == "150px"
      assert shape(model).box[:max_height] == "200px"
    end
  end

  @tag :fidelity
  @tag :tmp_dir
  test "exported aspect shapes retain their ratio when resized in native containers", %{
    tmp_dir: tmp
  } do
    for mode <- ["relative", "row", "column", "fixed"] do
      assert {:ok, result} =
               Frontend.export_payload(payload(mode), Path.join(tmp, mode),
                 secret_scan_adapter: FrontendFixtures.clean_scanner()
               )

      assert result.findings == []
    end

    {output, status} =
      System.cmd("node", ["test/support/fidelity/aspect-shapes.mjs", Path.expand(tmp)],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp shape(model),
    do: model.pages |> hd() |> Map.fetch!(:children) |> hd() |> Map.fetch!(:children) |> hd()

  defp shape_path, do: ["pages", "index", "%el", "parent", "%el", "shape", "%p"]

  defp payload(mode) do
    %{
      "_id" => "aspect-shapes",
      "pages" => %{
        "index" => %{
          "%x" => "Page",
          "%nm" => "index",
          "%p" => %{"container_layout" => "column"},
          "%el" => %{
            "parent" => %{
              "%x" => "Group",
              "%p" => %{
                "container_layout" => mode,
                "single_width" => false,
                "min_width_css" => "0px",
                "single_height" => true,
                "min_height_css" => "700px"
              },
              "%el" => %{
                "shape" => %{
                  "id" => "shape",
                  "%x" => "Shape",
                  "%p" => %{
                    "%w" => 900,
                    "%h" => 150,
                    "single_width" => false,
                    "min_width_css" => "0px",
                    "single_height" => true,
                    "min_height_css" => "150px",
                    "max_height_css" => "200px",
                    "fit_height" => false,
                    "use_aspect_ratio" => true,
                    "aspect_ratio_width" => 1000,
                    "aspect_ratio_height" => 600,
                    "nonant_alignment" => "ba"
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
