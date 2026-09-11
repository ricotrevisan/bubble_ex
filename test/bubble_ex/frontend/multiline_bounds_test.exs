defmodule BubbleEx.Frontend.MultilineBoundsTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.FrontendFixtures

  @tag :fidelity
  @tag :tmp_dir
  test "fit-height textarea preserves authored minimum, breakpoint minimum and maximum", %{
    tmp_dir: tmp
  } do
    payload = %{
      "_id" => "multiline-bounds",
      "pages" => %{
        "index" => %{
          "%x" => "Page",
          "%nm" => "index",
          "%p" => %{"container_layout" => "column"},
          "%el" => %{
            "field" => %{
              "id" => "field",
              "%x" => "MultiLineInput",
              "%p" => %{
                "fit_height" => true,
                "single_height" => false,
                "single_width" => false,
                "min_height_css" => "70px",
                "max_height_css" => "400px",
                "min_width_css" => "0px",
                "font_size" => 14,
                "line_height" => 1.5,
                "padding" => "12px",
                "border_style" => "none"
              },
              "%s" => %{
                "0" => %{
                  "%c" => %{
                    "%x" => "PageData",
                    "%p" => %{"%nm" => "Current Page Width"},
                    "%n" => %{"%nm" => "less_or_equal_than", "%a" => 600}
                  },
                  "%p" => %{"min_height_css" => "140px"}
                }
              }
            }
          }
        }
      }
    }

    assert {:ok, result} =
             Frontend.export_payload(payload, tmp,
               secret_scan_adapter: FrontendFixtures.clean_scanner()
             )

    assert result.findings == []

    {output, status} =
      System.cmd("node", ["test/support/fidelity/multiline-bounds.mjs", Path.expand(tmp)],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
