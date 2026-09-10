defmodule BubbleEx.Frontend.ResponsiveTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.Frontend.Export.Css
  alias BubbleEx.Frontend.Responsive

  test "breakpoint paint uses the declared breakpoint and preserves authored order" do
    states = %{"10" => state("greater_than", 30), "2" => state("less_than", 24)}
    raw = %{"%x" => "Text", "%s" => states}
    breakpoints = %{"mobile" => %{"size" => 768}}

    assert [
             %{media: %{"operator" => "<", "width" => 768}, overrides: %{"%fs" => 24}},
             %{media: %{"operator" => ">", "width" => 768}, overrides: %{"%fs" => 30}}
           ] = Responsive.breakpoint_states(raw, breakpoints)

    assert Responsive.breakpoint_states(raw, %{}) == []
    chained = put_in(raw, ["%s", "2", "%c", "%n", "%n"], %{"%nm" => "and_"})
    assert length(Responsive.breakpoint_states(chained, breakpoints)) == 1
  end

  test "normalization and CSS preserve strict breakpoints, local paint and partial padding" do
    conditional = state("less_than", 24)

    conditional =
      update_in(conditional, ["%p"], &Map.merge(&1, %{"row_gap" => 16, "padding_left" => 20}))

    payload = %{
      "_id" => "responsive-app",
      "settings" => %{
        "client_safe" => %{"responsive_breakpoints" => %{"mobile" => %{"size" => 768}}}
      },
      "pages" => %{
        "index" => %{
          "type" => "Page",
          "properties" => %{"container_layout" => "column"},
          "elements" => %{
            "heading" => %{
              "id" => "heading",
              "%x" => "Text",
              "%p" => %{"%3" => "Heading", "%fs" => 40},
              "%s" => %{"0" => conditional}
            }
          }
        }
      }
    }

    assert {:ok, model} = Frontend.normalize(payload)
    [page] = model.pages
    [heading] = page.children
    assert heading.unmapped["%s"]["0"] == conditional
    css = Css.page(page)
    assert css =~ "font-size: 40px"
    assert css =~ "@media (width < 768px)"
    assert css =~ "font-size: 24px"
    assert css =~ "row-gap: 16px"
    assert css =~ "padding-left: 20px"
    refute css =~ "padding-right: 0"
  end

  test "breakpoint hiding respects whether the hidden element collapses" do
    rule = put_in(state("less_than", 14), ["%p"], %{"%iv" => false})

    for {collapse, declaration} <- [{true, "display: none"}, {false, "visibility: hidden"}] do
      payload = %{
        "_id" => "visibility",
        "settings" => %{
          "client_safe" => %{
            "responsive_breakpoints" => %{"mobile" => %{"size" => 500}}
          }
        },
        "pages" => %{
          "index" => %{
            "type" => "Page",
            "elements" => %{
              "label" => %{
                "%x" => "Text",
                "%p" => %{"%3" => "Label", "collapse_when_hidden" => collapse},
                "%s" => %{"0" => rule}
              }
            }
          }
        }
      }

      assert {:ok, model} = Frontend.normalize(payload)
      css = Css.page(hd(model.pages))
      assert css =~ "@media (width < 500px)"
      assert css =~ declaration
    end
  end

  test "shared styles retain configured and literal page-width conditions" do
    literal = put_in(state("less_or_equal_than", 18), ["%c", "%n", "%a"], 500)

    payload = %{
      "_id" => "shared-responsive",
      "settings" => %{
        "client_safe" => %{"responsive_breakpoints" => %{"mobile" => %{"size" => 768}}}
      },
      "pages" => %{"index" => %{"type" => "Page"}},
      "styles" => %{
        "heading" => %{
          "%x" => "Text",
          "%p" => %{"%fs" => 40},
          "%s" => %{"0" => state("less_than", 24), "1" => literal}
        }
      }
    }

    assert {:ok, model} = Frontend.normalize(payload)
    css = Css.shared(model)
    assert css =~ "font-size: 40px"
    assert css =~ "@media (width < 768px)"
    assert css =~ "font-size: 24px"
    assert css =~ "@media (width <= 500px)"
    assert css =~ "font-size: 18px"
  end

  defp state(operator, font_size) do
    %{
      "%x" => "State",
      "%p" => %{"%fs" => font_size},
      "%c" => %{
        "%x" => "PageData",
        "%p" => %{"%nm" => "Current Page Width"},
        "%n" => %{
          "%x" => "Message",
          "%nm" => operator,
          "%a" => %{"%x" => "Breakpoint", "%p" => %{"breakpoint_id" => "mobile"}}
        }
      }
    }
  end

  test "a breakpoint can show an initially hidden native element with its normal display mode" do
    for {type, display} <- [{"Button", "inline-flex"}, {"Group", "flex"}] do
      show = state("less_or_equal_than", 14) |> put_in(["%p"], %{"%iv" => true})

      payload = %{
        "_id" => "show-at-mobile",
        "settings" => %{
          "client_safe" => %{"responsive_breakpoints" => %{"mobile" => %{"size" => 768}}}
        },
        "pages" => %{
          "index" => %{
            "%x" => "Page",
            "%p" => %{"container_layout" => "column"},
            "%el" => %{
              "target" => %{
                "%x" => type,
                "%p" => %{
                  "container_layout" => "column",
                  "%iv" => false,
                  "collapse_when_hidden" => true,
                  "button_type" => "label_icon",
                  "icon" => "material outlined arrow_forward",
                  "text" => "Go"
                },
                "%s" => %{"0" => show}
              }
            }
          }
        }
      }

      assert {:ok, model} = Frontend.normalize(payload)
      css = Css.page(hd(model.pages))
      [base, media] = String.split(css, "@media", parts: 2)
      assert base =~ "display: none;"
      assert media =~ "display: #{display};"
      assert media =~ "visibility: visible;"
    end
  end
end
