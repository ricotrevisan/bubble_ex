defmodule BubbleEx.Frontend.GeometryStylesTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.FrontendFixtures

  @tag :tmp_dir
  test "a reusable style can refer to a unique page element's measured height", %{tmp_dir: tmp} do
    app = payload()

    assert {:ok, result} =
             Frontend.export_payload(app, tmp,
               secret_scan_adapter: FrontendFixtures.clean_scanner()
             )

    html = Path.join(tmp, "pages/index/index.html") |> File.read!() |> Floki.parse_document!()
    assert [style] = Floki.find(html, "style[data-bubbleex-geometry]")
    [config] = Floki.attribute(style, "data-bubbleex-geometry")

    assert [%{"element" => "header", "axis" => "height", "variable" => variable}] =
             Jason.decode!(config)

    assert Floki.text(style, style: true) =~ "min-height: var(#{variable}) !important"
    assert [script] = Floki.find(html, "script[src]")
    [src] = Floki.attribute(script, "src")
    assert src =~ "../../assets/"
    assert Path.join([tmp, "pages/index", src]) |> File.regular?()
    assert result.model.source.payload == app
    assert result.findings == []
  end

  @tag :tmp_dir
  test "literal numeric style parameters compile without a measurement runtime", %{tmp_dir: tmp} do
    app = put_in(payload(), ["pages", "index", "%el", "instance", "%p", "param_height"], 104)

    assert {:ok, _} =
             Frontend.export_payload(app, tmp,
               secret_scan_adapter: FrontendFixtures.clean_scanner()
             )

    html = Path.join(tmp, "pages/index/index.html") |> File.read!() |> Floki.parse_document!()
    assert [style] = Floki.find(html, "style")
    assert Floki.text(style, style: true) =~ "min-height: 104px !important"
    assert Floki.find(html, "script") == []
  end

  @tag :tmp_dir
  test "measured references survive forwarding through another reusable", %{tmp_dir: tmp} do
    outer = %{
      "%x" => "CustomDefinition",
      "id" => "outer",
      "%p" => %{"container_layout" => "column"},
      "%el" => %{
        "inner" => %{
          "%x" => "CustomElement",
          "id" => "inner",
          "%p" => %{
            "definition" => "bumper",
            "param_height" => get_element("outer", "param_height")
          }
        }
      }
    }

    app =
      payload()
      |> put_in(["element_definitions", "outer"], outer)
      |> put_in(["pages", "index", "%el", "instance", "%p", "definition"], "outer")

    assert {:ok, _} =
             Frontend.export_payload(app, tmp,
               secret_scan_adapter: FrontendFixtures.clean_scanner()
             )

    html = Path.join(tmp, "pages/index/index.html") |> File.read!() |> Floki.parse_document!()

    [config] =
      Floki.find(html, "style[data-bubbleex-geometry]")
      |> Floki.attribute("data-bubbleex-geometry")

    assert [%{"element" => "header", "axis" => "height"}] =
             Enum.map(Jason.decode!(config), &Map.take(&1, ["element", "axis"]))
  end

  @tag :tmp_dir
  test "a text parameter cannot escape a numeric style binding", %{tmp_dir: tmp} do
    app =
      put_in(
        payload(),
        ["pages", "index", "%el", "instance", "%p", "param_height"],
        "0px}</style><script>alert(1)</script><style>#spacer{height:99"
      )

    assert {:ok, _} =
             Frontend.export_payload(app, tmp,
               secret_scan_adapter: FrontendFixtures.clean_scanner()
             )

    html = Path.join(tmp, "pages/index/index.html") |> File.read!() |> Floki.parse_document!()
    assert Floki.find(html, "script, style") == []
  end

  test "style templates reject executable markup, resources and unsupported expression chains" do
    alias BubbleEx.Frontend.GeometryStyles

    for html <- [
          "<style>#spacer { background-image: url(https://example.invalid/image); }</style>",
          "<style>#spacer { height: 80px; }</style><script>alert(1)</script>",
          "<style media=\"print\">#spacer { height: 80px; }</style>",
          "<style>@media (width < 600px) { #spacer { height: 80px; } }</style>"
        ] do
      assert GeometryStyles.compile(html, %{}) == :unknown
    end

    chained =
      put_in(get_element("header", "get_height"), ["%n", "%n"], %{"%nm" => "plus", "%a" => 10})

    assert GeometryStyles.resolve(chained) == :unknown

    for ending <- ["em", "px + 1px)", "px\""] do
      expression = %{
        "%x" => "TextExpression",
        "%e" => %{
          "0" => "<style>#spacer { height: ",
          "1" => get_element("header", "get_height"),
          "2" => ending <> "; }</style>"
        }
      }

      assert GeometryStyles.compile(expression, %{}) == :unknown
    end

    assert GeometryStyles.compile("<style>#spacer { height: BUBBLEEXDIMENSION0px; }</style>", %{}) ==
             :unknown

    assert GeometryStyles.resolve(get_element("header", "get_width")) ==
             {:ok, %{element: "header", axis: "width"}}
  end

  @tag :fidelity
  @tag :tmp_dir
  test "exported geometry styles settle on load and resize and reject ambiguous or cyclic measurements",
       %{tmp_dir: tmp} do
    app =
      put_in(payload(), ["pages", "index", "%el", "header", "%s"], %{
        "0" => %{
          "%c" => %{
            "%x" => "PageData",
            "%p" => %{"%nm" => "Current Page Width"},
            "%n" => %{"%nm" => "greater_or_equal_than", "%a" => 600}
          },
          "%p" => %{"min_height_css" => "96px"}
        }
      })

    missing =
      put_in(
        app,
        ["pages", "index", "%el", "instance", "%p", "param_height"],
        get_element("missing", "get_height")
      )

    duplicate =
      put_in(
        app,
        ["pages", "index", "%el", "duplicate"],
        get_in(app, ["pages", "index", "%el", "header"])
      )

    feedback =
      app
      |> put_in(["pages", "index", "%el", "header", "%p", "unique_id"], "header-actual")
      |> put_in(
        [
          "element_definitions",
          "bumper",
          "%el",
          "spacer",
          "%el",
          "style",
          "%p",
          "%ht",
          "%e",
          "0"
        ],
        "<style>#header-actual {padding-top: "
      )
      |> put_in(
        [
          "element_definitions",
          "bumper",
          "%el",
          "spacer",
          "%el",
          "style",
          "%p",
          "%ht",
          "%e",
          "2"
        ],
        "px !important; padding-bottom: 10px !important;}</style>"
      )

    for {name, value} <- [
          {"normal", app},
          {"missing", missing},
          {"duplicate", duplicate},
          {"feedback", feedback}
        ] do
      assert {:ok, _} =
               Frontend.export_payload(value, Path.join(tmp, name),
                 secret_scan_adapter: FrontendFixtures.clean_scanner()
               )
    end

    {output, status} =
      System.cmd("node", ["test/support/fidelity/geometry-styles.mjs", Path.expand(tmp)],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp payload do
    %{
      "_id" => "geometry",
      "element_definitions" => %{
        "bumper" => %{
          "%x" => "CustomDefinition",
          "id" => "bumper",
          "%p" => %{"container_layout" => "column"},
          "%el" => %{
            "spacer" => %{
              "%x" => "Group",
              "id" => "spacer",
              "%p" => %{
                "container_layout" => "column",
                "single_height" => true,
                "min_height_css" => "96px",
                "unique_id" => "spacer"
              },
              "%el" => %{
                "style" => %{
                  "%x" => "HTML",
                  "id" => "style",
                  "%p" => %{
                    "min_height_css" => "0px",
                    "min_width_css" => "0px",
                    "%ht" => %{
                      "%x" => "TextExpression",
                      "%e" => %{
                        "0" => "<style>#spacer { min-height: ",
                        "1" => get_element("bumper", "param_height"),
                        "2" => "px !important; height: auto !important; }</style>"
                      }
                    }
                  }
                }
              }
            }
          }
        }
      },
      "pages" => %{
        "index" => %{
          "%x" => "Page",
          "%nm" => "index",
          "%p" => %{"container_layout" => "column"},
          "%el" => %{
            "header" => %{
              "%x" => "FloatingGroup",
              "id" => "header",
              "%p" => %{
                "container_layout" => "column",
                "floating_reference" => "top",
                "floating_reference_horizontal_resp" => "right",
                "single_width" => true,
                "min_width_css" => "200px",
                "single_height" => true,
                "min_height_css" => "80px"
              }
            },
            "instance" => %{
              "%x" => "CustomElement",
              "id" => "instance",
              "%p" => %{
                "definition" => "bumper",
                "param_height" => get_element("header", "get_height")
              }
            }
          }
        }
      }
    }
  end

  defp get_element(id, message),
    do: %{
      "%x" => "GetElement",
      "%p" => %{"%ei" => id},
      "%n" => %{"%x" => "Message", "%nm" => message, "is_slidable" => false}
    }
end
