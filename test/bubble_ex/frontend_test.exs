defmodule BubbleEx.FrontendTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Error
  alias BubbleEx.Frontend
  alias BubbleEx.Frontend.Normalized

  describe "normalize/2" do
    test "rejects a non-map payload as :invalid_input" do
      assert {:error, %Error{kind: :invalid_input}} = Frontend.normalize("not a map")
      assert {:error, %Error{kind: :invalid_input}} = Frontend.normalize(42)
      assert {:error, %Error{kind: :invalid_input}} = Frontend.normalize([%{"_id" => "x"}])
    end

    test "rejects invalid JSON as :parse_failed" do
      assert {:error, %Error{kind: :parse_failed}} = Frontend.normalize("{not json")
    end

    test "rejects a decoded JSON array as :invalid_input" do
      assert {:error, %Error{kind: :invalid_input}} = Frontend.normalize("[1, 2]")
    end

    test "rejects a legacy renderer as :unsupported_renderer" do
      payload = %{
        "_id" => "legacyapp",
        "pages" => %{
          "home" => %{
            "id" => "pg1",
            "type" => "Page",
            "name" => "index",
            "new_responsive" => false
          }
        }
      }

      assert {:error, %Error{kind: :unsupported_renderer}} = Frontend.normalize(payload)
    end

    test "normalizes a modern page into the versioned model with diagnostics" do
      payload = modern_page()

      assert {:ok, %Normalized{} = model} = Frontend.normalize(payload)
      assert model.normalized_schema_version == 2
      assert model.identity.bubble_id == "s1app"
      assert model.identity.app_version == "live"
      assert is_list(model.diagnostics)
      assert [page] = model.pages
      assert page.kind == :page
      assert page.variant == :column
      assert is_binary(page.exporter_id)
      assert page.source.map_key == "home"
      assert page.source.bubble_id == "pghome"
      assert is_list(page.source.path)
    end

    test "accepts the raw aliased payload shape used by parse_app_json" do
      payload = %{
        "_id" => "rawapp",
        "%p3" => %{
          "opaque" => %{
            "id" => "pgopaque",
            "%x" => "Page",
            "%nm" => "tanstack-chart-demo",
            "%p" => %{"container_layout" => "column"},
            "%el" => %{
              "text" => %{
                "id" => "text",
                "%x" => "Text",
                "%nm" => "Greeting",
                "%p" => %{
                  "%3" => %{"%x" => "TextExpression", "%e" => %{"0" => "Hello"}},
                  "%fc" => "#123456",
                  "%fs" => 18,
                  "%w" => 120,
                  "collapse_when_hidden" => true,
                  "single_width" => true,
                  "tag_type" => "normal"
                }
              }
            }
          }
        }
      }

      assert {:ok, %Normalized{pages: [page]}} = Frontend.normalize(payload)
      assert page.kind == :page
      assert page.name == "tanstack-chart-demo"
      assert page.variant == :column
      refute Map.has_key?(page.unmapped, "%nm")

      assert [text] = page.children
      assert text.kind == :text
      assert text.name == "Greeting"
      assert text.content["text"].resolved == "Hello"
      assert text.style.resolved["font_color"] == "#123456"
      assert text.style.resolved["font_size"] == 18
      assert text.box.width == 120
      refute text.box[:collapsed?]
      refute Map.has_key?(text.unmapped, "%nm")
    end

    test "canonicalizes live compact paint aliases and control slots" do
      payload = %{
        "_id" => "raw-paint-app",
        "%s" => %{
          "primary" => %{
            "id" => "style-primary",
            "%x" => "Group",
            "%nm" => "Primary surface",
            "%p" => %{
              "%bas" => "bgcolor",
              "%bgc" => "#FFFFFF",
              "%bos" => "solid",
              "%bw" => 1,
              "%bc" => "#D8E0EC",
              "%br" => 18,
              "boxshadow_enable" => true,
              "%bs" => "outset",
              "%bh" => 0,
              "%bv" => 8,
              "%bsb" => 24,
              "%bsp" => 0,
              "%bsc" => "rgba(23,32,51,0.08)",
              "opacity" => 100,
              "%fc" => "#172033",
              "%fs" => 15,
              "%lh" => 1.4,
              "%ls" => 0,
              "%fa" => "center",
              "font_family" => "Inter",
              "font_weight" => "600",
              "padding_top" => 12,
              "padding_right" => 24,
              "padding_bottom" => 12,
              "padding_left" => 24
            }
          }
        },
        "%p3" => %{
          "home" => %{
            "id" => "page-home",
            "%x" => "Page",
            "%nm" => "index",
            "%p" => %{"container_layout" => "column"},
            "%el" => %{
              "canonical" => %{
                "id" => "canonical",
                "%x" => "Group",
                "%p" => %{"background" => "#010203", "opacity" => 1}
              },
              "disabled_shadow" => %{
                "id" => "disabled-shadow",
                "%x" => "Group",
                "%p" => %{
                  "%bas" => "none",
                  "%bos" => "none",
                  "%br" => 0,
                  "boxshadow_enable" => false,
                  "%bs" => "outset",
                  "opacity" => 25
                }
              },
              "email" => %{
                "id" => "email",
                "%x" => "Input",
                "%p" => %{"%cf" => "email", "%ps" => "you@example.com"}
              },
              "gradient" => %{
                "id" => "gradient",
                "%x" => "Group",
                "%p" => %{
                  "%bas" => "gradient",
                  "%b4" => "bottom",
                  "%bgf" => "#D8E7FF",
                  "background_gradient_mid" => "#EFE5FF",
                  "%bgt" => "#FFF0D8",
                  "background_gradient_style" => "linear",
                  "%bos" => "solid",
                  "%bw" => 1,
                  "%bc" => "#C9D6E8",
                  "%br" => 28,
                  "boxshadow_enable" => false,
                  "%bs" => "none",
                  "opacity" => 100
                }
              },
              "header" => %{
                "id" => "header",
                "%x" => "Group",
                "%p" => %{
                  "%bas" => "bgcolor",
                  "%bgc" => "#FFFFFF",
                  "%bos" => "solid",
                  "%bw" => 1,
                  "%bc" => "#D8E0EC",
                  "%br" => 18,
                  "boxshadow_enable" => true,
                  "%bs" => "outset",
                  "%bh" => 0,
                  "%bv" => 8,
                  "%bsb" => 24,
                  "%bsp" => 0,
                  "%bsc" => "rgba(23,32,51,0.08)",
                  "opacity" => 100
                }
              },
              "multiline" => %{
                "id" => "multiline",
                "%x" => "MultiLineInput",
                "%p" => %{
                  "%c1" => "I32 multiline literal",
                  "%ps" => "I32 multiline placeholder",
                  "character_limit" => 120
                }
              },
              "password" => %{
                "id" => "password",
                "%x" => "Input",
                "%p" => %{
                  "%cf" => "password",
                  "%c1" => "BubbleEx mask demo",
                  "%ps" => "I37 password placeholder"
                }
              },
              "radios" => %{
                "id" => "radios",
                "%x" => "RadioButtons",
                "%p" => %{"%ch" => "Narrow\nWide", "%d1" => "Wide"}
              },
              "select" => %{
                "id" => "select",
                "%x" => "Dropdown",
                "%p" => %{
                  "%ch" => "Alpha\nBeta\nGamma",
                  "%d1" => "Beta",
                  "%ps" => "Choose"
                }
              }
            }
          }
        }
      }

      assert {:ok, %Normalized{pages: [page], styles: [shared]}} = Frontend.normalize(payload)

      assert shared.properties["background"] == "#FFFFFF"
      assert shared.properties["border"] == "1px solid #D8E0EC"
      assert shared.properties["border-radius"] == "18px"
      assert shared.properties["box-shadow"] == "0 8px 24px rgba(23,32,51,0.08)"
      assert shared.properties["opacity"] == 1.0
      assert shared.properties["font_face"] == "Inter"
      assert shared.properties["font_size"] == 15
      assert shared.properties["font_color"] == "#172033"
      assert shared.properties["line_height"] == 1.4
      assert shared.properties["letter_spacing"] == 0
      assert shared.properties["text_align"] == "center"
      assert shared.properties["padding_top"] == "12px"
      assert shared.properties["padding_right"] == "24px"
      refute Enum.any?(Map.keys(shared.properties), &String.starts_with?(&1, "%"))
      refute Map.has_key?(shared.properties, "%bos")
      refute Map.has_key?(shared.properties, "%bs")

      nodes = Map.new(page.children, &{&1.source.bubble_id, &1})
      canonical = nodes["canonical"]
      disabled_shadow = nodes["disabled-shadow"]
      email = nodes["email"]
      gradient = nodes["gradient"]
      header = nodes["header"]
      multiline = nodes["multiline"]
      password = nodes["password"]
      radios = nodes["radios"]
      select = nodes["select"]

      assert canonical.style.resolved["opacity"] == 1

      assert disabled_shadow.style.resolved == %{
               "background" => "none",
               "border" => "none",
               "border-radius" => "0",
               "box-shadow" => "none",
               "opacity" => 0.25
             }

      assert gradient.style.resolved["background"] ==
               "linear-gradient(to top, #D8E7FF, #EFE5FF, #FFF0D8)"

      assert gradient.style.resolved["border"] == "1px solid #C9D6E8"
      assert gradient.style.resolved["border-radius"] == "28px"
      assert gradient.style.resolved["box-shadow"] == "none"

      assert header.style.resolved == %{
               "background" => "#FFFFFF",
               "border" => "1px solid #D8E0EC",
               "border-radius" => "18px",
               "box-shadow" => "0 8px 24px rgba(23,32,51,0.08)",
               "opacity" => 1.0
             }

      assert header.unmapped == %{}
      assert email.variant == :email
      assert email.attributes["type"] == "email"
      assert email.content["placeholder"].resolved == "you@example.com"
      assert password.variant == :password
      assert password.content["value"].resolved == "BubbleEx mask demo"
      assert password.content["placeholder"].resolved == "I37 password placeholder"
      assert multiline.content["value"].resolved == "I32 multiline literal"
      assert multiline.content["placeholder"].resolved == "I32 multiline placeholder"
      assert multiline.attributes["maxlength"] == 120

      assert Enum.map(select.content["choices"].resolved, & &1["value"]) == [
               "Alpha",
               "Beta",
               "Gamma"
             ]

      assert select.content["value"].resolved == "Beta"
      assert select.content["placeholder"].resolved == "Choose"
      assert Enum.map(radios.content["choices"].resolved, & &1["value"]) == ["Narrow", "Wide"]
      assert radios.content["value"].resolved == "Wide"
    end

    test "normalizes inset shadow components" do
      payload =
        page_with_elements(%{
          "inset" => %{
            "id" => "inset",
            "type" => "Group",
            "properties" => %{
              "boxshadow_enable" => true,
              "boxshadow_style" => "inset",
              "boxshadow_horizontal" => 1,
              "boxshadow_vertical" => 2,
              "boxshadow_blur" => 3,
              "boxshadow_spread" => -4,
              "boxshadow_color" => "#000000",
              "opacity" => 100,
              "background_style" => "none"
            }
          }
        })

      assert {:ok, %Normalized{pages: [%{children: [inset]}]}} = Frontend.normalize(payload)
      assert inset.style.resolved["box-shadow"] == "inset 1px 2px 3px -4px #000000"
      assert inset.style.resolved["opacity"] == 1.0
    end

    test "lowers a compact page-width visibility state into a collapsed responsive rule" do
      states = compact_page_width_states()
      payload = page_with_elements(%{"nav" => compact_responsive_group(states)})

      assert {:ok, %Normalized{pages: [%{children: [nav]}]}} = Frontend.normalize(payload)

      assert nav.responsive == [
               %{
                 "when" => %{"max_viewport_width" => 768},
                 "visibility" => "collapsed"
               }
             ]

      refute nav.box[:hidden?]
      assert nav.unmapped["%s"] == states
    end

    test "does not lower unsupported compact state expressions and preserves them losslessly" do
      states = compact_page_width_states()

      unsupported = [
        put_in(states, ["0", "%c", "%p", "%nm"], "Current User"),
        put_in(states, ["0", "%c", "%n", "%nm"], "greater_than"),
        put_in(states, ["0", "%c", "%n", "%a"], "768"),
        put_in(states, ["0", "%p", "%iv"], true),
        update_in(states, ["0", "%p"], &Map.put(&1, "%bgc", "#ffffff")),
        Map.put(states, "1", %{"%x" => "State"})
      ]

      Enum.each(unsupported, fn raw_states ->
        payload = page_with_elements(%{"nav" => compact_responsive_group(raw_states)})

        assert {:ok, %Normalized{pages: [%{children: [nav]}]}} = Frontend.normalize(payload)
        assert nav.responsive == []
        assert nav.unmapped["%s"] == raw_states
      end)

      payload =
        page_with_elements(%{
          "nav" => compact_responsive_group(states, %{"collapse_when_hidden" => false})
        })

      assert {:ok, %Normalized{pages: [%{children: [nav]}]}} = Frontend.normalize(payload)
      assert nav.responsive == []
      assert nav.unmapped["%s"] == states
    end

    test "maps raw Bubble responsive layout fields into the normalized contract" do
      payload = %{
        "_id" => "layout-app",
        "%p3" => %{
          "demo" => %{
            "id" => "page-demo",
            "%x" => "Page",
            "%nm" => "demo",
            "%p" => %{
              "container_layout" => "column",
              "container_horiz_alignment" => "center",
              "container_vert_alignment" => "space_between",
              "backdrop_background_style" => "bgcolor",
              "backdrop_bgcolor" => "#F4F7FB",
              "font_family" => "Inter",
              "min_width_px" => 0,
              "max_width_px" => 1440,
              "min_height_px" => 900,
              "max_height_px" => 2_000,
              "padding_top" => 20,
              "padding_right" => 16,
              "padding_bottom" => 56,
              "padding_left" => 16,
              "single_width" => false,
              "fit_width" => false,
              "single_height" => false,
              "fit_height" => false
            },
            "%el" => %{
              "row" => %{
                "id" => "row",
                "%x" => "Group",
                "%nm" => "Natural row",
                "%p" => %{
                  "order" => 1,
                  "container_layout" => "row",
                  "container_horiz_alignment" => "space_between",
                  "container_vert_alignment" => "center",
                  "horiz_alignment" => "center",
                  "%l" => 999,
                  "%t" => 888,
                  "%z" => 6,
                  "single_width" => false,
                  "fit_width" => false,
                  "single_height" => false,
                  "fit_height" => true,
                  "max_width_css" => "1120px",
                  "min_height_css" => "72px",
                  "padding_top" => 12,
                  "padding_right" => 16,
                  "padding_bottom" => 12,
                  "padding_left" => 16,
                  "margin_top" => "1",
                  "margin_right" => "2.5",
                  "margin_bottom" => 3,
                  "margin_left" => 4
                },
                "%el" => %{
                  "stretch" => image_fixture(1, "%2f", "stretch"),
                  "rescale" => image_fixture(2, "2f", "rescale"),
                  "zoom" => image_fixture(3, "run_mode", "zoom")
                }
              },
              "fixed" => %{
                "id" => "fixed",
                "%x" => "Group",
                "%nm" => "Fixed canvas",
                "%p" => %{
                  "order" => 2,
                  "container_layout" => "fixed",
                  "single_width" => false,
                  "fit_width" => true,
                  "single_height" => false,
                  "fit_height" => true
                },
                "%el" => %{
                  "shape" => %{
                    "id" => "fixed-shape",
                    "%x" => "Shape",
                    "%p" => %{
                      "%l" => 24,
                      "%t" => 32,
                      "%z" => 7,
                      "%w" => 196,
                      "%h" => 92,
                      "single_width" => true,
                      "single_height" => true,
                      "rotation_angle" => 12
                    }
                  }
                }
              }
            }
          }
        }
      }

      assert {:ok, %Normalized{pages: [page]}} = Frontend.normalize(payload)
      assert page.style.resolved["font_face"] == "Inter"
      assert page.style.resolved["background"] == "#F4F7FB"
      assert page.box.min_width == 0
      assert page.box.max_width == 1440
      assert page.box.min_height == 900
      assert page.box.max_height == 2_000
      assert page.box.padding == "20px 16px 56px 16px"
      assert page.layout.fill_width?
      assert page.layout.fill_height?
      assert page.layout.justify == "space-between"
      assert page.layout.align == "center"
      assert page.unmapped == %{}

      assert [row, fixed] = page.children
      assert row.layout.mode == :row
      assert row.layout.wrap == :wrap
      assert row.layout.justify == "space-between"
      assert row.layout.align == "center"
      assert row.layout.fill_width?
      refute row.layout.fill_height?
      assert row.box.align_self == "center"
      refute Map.has_key?(row.box, :x)
      refute Map.has_key?(row.box, :y)
      refute Map.has_key?(row.box, :z_index)
      assert row.box.max_width == "1120px"
      assert row.box.min_height == "72px"
      assert row.box.padding == "12px 16px 12px 16px"
      assert row.box.margin == "1px 2.5px 3px 4px"
      assert row.unmapped == %{}

      assert [stretch, rescale, zoom] = row.children
      assert Enum.map([stretch, rescale, zoom], & &1.variant) == [:stretch, :rescale, :zoom]

      for image <- [stretch, rescale, zoom] do
        assert image.box.min_width == "320px"
        assert image.box.max_width == "320px"
        assert image.box.min_height == "180px"
        assert image.box.max_height == "180px"
        assert image.box.align_self == "center"
        assert image.layout.fill_width?
        assert image.layout.fill_height?
        assert image.unmapped == %{}
      end

      refute fixed.layout.fill_width?
      refute fixed.layout.fill_height?
      assert [shape] = fixed.children
      assert shape.box.x == 24
      assert shape.box.y == 32
      assert shape.box.z_index == 7
      assert shape.box.rotation == 12
      assert shape.box.width == 196
      assert shape.box.height == 92
      refute shape.layout.fill_width?
      refute shape.layout.fill_height?
    end

    test "uses Bubble's default Fixed Group width when a fixed canvas omits %w" do
      payload =
        page_with_elements(%{
          "fixed" => %{
            "id" => "default-fixed",
            "type" => "Group",
            "properties" => %{
              "container_layout" => "fixed",
              "%h" => 420,
              "min_width_css" => "336px",
              "fit_width" => false,
              "single_width" => false,
              "fit_height" => false,
              "single_height" => true
            }
          }
        })

      assert {:ok, %Normalized{pages: [%{children: [fixed]}]}} = Frontend.normalize(payload)
      assert fixed.layout.mode == :fixed
      assert fixed.layout.fill_width?
      assert fixed.box.width == 400
      assert fixed.box.min_width == 400
      assert fixed.box.max_width == 400
      assert fixed.box.height == 420
      assert fixed.box.min_height == 420
      assert fixed.box.max_height == 420
    end

    test "preserves Bubble runtime dimensions for legacy Fixed groups and shapes" do
      payload = %{
        "_id" => "fixed-default-app",
        "%p3" => %{
          "demo" => %{
            "id" => "page-fixed",
            "%x" => "Page",
            "%nm" => "demo",
            "%p" => %{"container_layout" => "column"},
            "%el" => %{
              "fixed" => %{
                "id" => "legacy-fixed",
                "%x" => "Group",
                "%p" => %{"container_layout" => "fixed", "%w" => 196},
                "%el" => %{
                  "shape" => %{
                    "id" => "legacy-shape",
                    "%x" => "Shape",
                    "%p" => %{"%l" => 12, "%t" => 30, "%w" => 72, "%z" => 1}
                  }
                }
              }
            }
          }
        }
      }

      assert {:ok, %Normalized{pages: [%{children: [fixed]}]}} = Frontend.normalize(payload)
      assert fixed.layout.mode == :fixed
      assert fixed.layout.fill_height?
      assert fixed.box.width == 196
      assert fixed.box.min_width == 196
      assert fixed.box.max_width == 196
      assert fixed.box.height == 250
      assert fixed.box.min_height == 250
      assert fixed.box.max_height == 250

      assert [shape] = fixed.children
      assert shape.box.x == 12
      assert shape.box.y == 30
      assert shape.box.z_index == 1
      assert shape.box.width == 72
      assert shape.box.height == 150
    end

    test "maps Bubble nonants to all direction-aware placement cells" do
      nonants = [
        {"aa", "top_start"},
        {"ba", "top_center"},
        {"ca", "top_end"},
        {"ab", "center_start"},
        {"bb", "center"},
        {"cb", "center_end"},
        {"ac", "bottom_start"},
        {"bc", "bottom_center"},
        {"cc", "bottom_end"}
      ]

      elements =
        nonants
        |> Enum.with_index()
        |> Map.new(fn {{nonant, _cell}, order} ->
          {nonant,
           %{
             "id" => "shape-#{nonant}",
             "type" => "Shape",
             "properties" => %{"nonant_alignment" => nonant, "order" => order}
           }}
        end)

      payload = %{
        "_id" => "nonant-app",
        "pages" => %{
          "demo" => %{
            "id" => "page",
            "type" => "Page",
            "name" => "demo",
            "properties" => %{"container_layout" => "relative"},
            "elements" => elements
          }
        }
      }

      assert {:ok, %Normalized{pages: [page]}} = Frontend.normalize(payload)

      assert Enum.map(page.children, fn node ->
               {node.map_key, node.box.placement["cell"]}
             end) == nonants
    end

    test "lowers raw aliased checkbox properties instead of a placeholder" do
      payload = %{
        "_id" => "raw-checkbox-app",
        "%p3" => %{
          "checkboxes" => %{
            "id" => "page-checkboxes",
            "%x" => "Page",
            "%nm" => "checkboxes",
            "%p" => %{"container_layout" => "column"},
            "%el" => %{
              "checked" => %{
                "id" => "checkbox-checked",
                "%x" => "Checkbox",
                "%nm" => "Checked checkbox",
                "%p" => %{
                  "%ct" => "checked",
                  "%lab" => "Include static assets",
                  "%1m" => true,
                  "%fc" => "#172033",
                  "%fs" => 16,
                  "%lh" => 1.25,
                  "%ls" => 0
                }
              },
              "unchecked" => %{
                "id" => "checkbox-unchecked",
                "%x" => "Checkbox",
                "%nm" => "Unchecked checkbox",
                "%p" => %{
                  "%ct" => "unchecked",
                  "%lab" => "Optional assets",
                  "%1m" => false
                }
              }
            }
          }
        }
      }

      assert {:ok, %Normalized{pages: [page], diagnostics: diagnostics}} =
               Frontend.normalize(payload)

      assert [checked, unchecked] = page.children
      assert checked.kind == :checkbox
      assert checked.variant == :static
      refute checked.placeholder?
      assert checked.content["label"].resolved == "Include static assets"
      assert checked.content["checked"].resolved == true
      assert checked.attributes["required"] == true
      assert checked.style.resolved["font_color"] == "#172033"
      assert checked.style.resolved["font_size"] == 16
      assert checked.style.resolved["line_height"] == 1.25
      assert checked.unmapped == %{}

      assert unchecked.kind == :checkbox
      assert unchecked.content["label"].resolved == "Optional assets"
      assert unchecked.content["checked"].resolved == false
      refute Map.has_key?(unchecked.attributes, "required")

      refute Enum.any?(diagnostics, fn diagnostic ->
               diagnostic.code == :unsupported_element
             end)
    end

    test "lowers S1 kinds and keeps unresolved expressions on the node" do
      payload = s1_payload()

      assert {:ok, %Normalized{pages: [page], diagnostics: diags}} = Frontend.normalize(payload)
      kinds = Enum.map(page.children, & &1.kind)
      assert kinds == [:group, :text, :text, :image, :shape, :button, :link, :input, :placeholder]

      [row, heading, dynamic, image, shape, button, link, input, plugin] = page.children

      assert row.kind == :group
      assert row.variant == :row
      assert row.layout.mode == :row
      assert row.layout.row_gap == 8
      assert row.layout.column_gap == 16

      assert heading.kind == :text
      assert heading.variant == :h1
      assert heading.content["text"].resolved == "Hello"

      assert dynamic.kind == :text
      assert dynamic.variant == :normal
      assert dynamic.content["text"].binding_id
      assert dynamic.bindings["text"].kind == :value
      assert dynamic.bindings["text"].id == dynamic.exporter_id <> " :: text"

      assert image.kind == :image
      assert image.variant == :zoom
      assert image.content["src"].resolved == "https://cdn.example/hero.png"

      assert shape.kind == :shape
      assert shape.attributes["aria-hidden"] == "true"

      assert button.kind == :button
      assert button.variant == :label
      assert button.content["label"].resolved == "Go"

      assert link.kind == :link
      assert link.content["destination"].resolved == "https://example.com"

      assert input.kind == :input
      assert input.variant == :email
      assert input.attributes["type"] == "email"

      assert plugin.kind == :placeholder
      assert plugin.placeholder?
      assert plugin.bindings["plugin"].kind == :plugin

      assert Enum.any?(diags, fn d ->
               d.code == :unsupported_element and plugin.exporter_id in d.refs
             end)
    end

    test "converts a single unconditioned Go to page button into a navigation button" do
      payload = %{
        "_id" => "s1app",
        "app_version" => "live",
        "pages" => %{
          "home" => %{
            "id" => "pghome",
            "type" => "Page",
            "name" => "index",
            "properties" => %{"container_layout" => "column"},
            "elements" => %{
              "go" => %{
                "id" => "elGo",
                "type" => "Button",
                "properties" => %{"text" => "About", "order" => 1}
              }
            },
            "workflows" => %{
              "wfGo" => %{
                "id" => "wfGo",
                "type" => "ButtonClicked",
                "properties" => %{"element_id" => "elGo"},
                "actions" => %{
                  "0" => %{
                    "id" => "actGo",
                    "type" => "ChangePage",
                    "properties" => %{"page" => "about"}
                  }
                }
              }
            }
          }
        }
      }

      assert {:ok, %Normalized{pages: [page]}} = Frontend.normalize(payload)
      assert [button] = page.children
      assert button.kind == :button
      assert button.variant == :navigation
      assert button.content["destination"].resolved == "about"
      assert button.bindings["workflow"].kind == :workflow
      assert button.bindings["workflow"].payload["type"] == "ButtonClicked"
    end

    test "keeps buttons as buttons when the click workflow is not a pure navigation" do
      payload =
        page_with_elements(%{
          "multi" => %{
            "id" => "elMulti",
            "type" => "Button",
            "properties" => %{"text" => "Do stuff", "order" => 1}
          },
          "dynamic" => %{
            "id" => "elDyn",
            "type" => "Button",
            "properties" => %{"text" => "Maybe", "order" => 2}
          }
        })
        |> put_in(["pages", "home", "workflows"], %{
          "wfMulti" => %{
            "type" => "ButtonClicked",
            "properties" => %{"element_id" => "elMulti"},
            "actions" => %{
              "0" => %{"type" => "ChangePage", "properties" => %{"page" => "about"}},
              "1" => %{"type" => "TerminateWorkflow", "properties" => %{}}
            }
          },
          "wfDyn" => %{
            "type" => "ButtonClicked",
            "properties" => %{"element_id" => "elDyn"},
            "condition" => %{"type" => "IsLoggedIn"},
            "actions" => %{
              "0" => %{"type" => "OpenURL", "properties" => %{"url" => "https://example.com"}}
            }
          }
        })

      assert {:ok, %Normalized{pages: [page]}} = Frontend.normalize(payload)
      assert [dynamic, multi] = Enum.sort_by(page.children, & &1.source.bubble_id)
      assert dynamic.source.bubble_id == "elDyn"
      assert multi.source.bubble_id == "elMulti"
      assert dynamic.variant == :label
      refute Map.has_key?(dynamic.content, "destination")
      assert multi.variant == :label
      refute Map.has_key?(multi.content, "destination")
    end

    test "converts an aliased ButtonClicked OpenURL workflow" do
      payload = %{
        "_id" => "rawapp",
        "%p3" => %{
          "home" => %{
            "id" => "pghome",
            "%x" => "Page",
            "%nm" => "index",
            "%el" => %{
              "go" => %{
                "id" => "elGo",
                "%x" => "Button",
                "%nm" => "Docs",
                "%p" => %{"%3" => "Docs"}
              }
            },
            "%wf" => %{
              "wf" => %{
                "id" => "wf",
                "%x" => "ButtonClicked",
                "%p" => %{"%ei" => "elGo"},
                "actions" => %{
                  "0" => %{
                    "%x" => "OpenURL",
                    "%p" => %{"url" => "https://example.com", "open_in_new_tab" => true}
                  }
                }
              }
            }
          }
        }
      }

      assert {:ok, %Normalized{pages: [page]}} = Frontend.normalize(payload)
      assert [button] = page.children
      assert button.variant == :navigation
      assert button.content["destination"].resolved == "https://example.com"
      assert button.attributes["target"] == "_blank"
    end

    test "icon buttons and rich text become placeholders" do
      payload =
        page_with_elements(%{
          "iconBtn" => %{
            "id" => "b1",
            "type" => "Button",
            "properties" => %{"button_type" => "icon", "text" => "X"}
          },
          "rich" => %{
            "id" => "t1",
            "type" => "Text",
            "properties" => %{"tag_type" => "bbcode", "text" => "[b]nope[/b]"}
          }
        })

      assert {:ok, %Normalized{pages: [page]}} = Frontend.normalize(payload)
      assert Enum.all?(page.children, & &1.placeholder?)
    end

    test "classifies explicit normal and h4 Text semantics" do
      payload =
        page_with_elements(%{
          "normal" => %{
            "id" => "t-normal",
            "type" => "Text",
            "properties" => %{"tag_type" => "normal", "text" => "Body", "order" => 1}
          },
          "h4" => %{
            "id" => "t-h4",
            "type" => "Text",
            "properties" => %{"tag_type" => "h4", "text" => "Heading four", "order" => 2}
          }
        })

      assert {:ok, %Normalized{pages: [page]}} = Frontend.normalize(payload)
      assert [normal, h4] = page.children
      assert normal.variant == :normal
      assert h4.variant == :h4
    end

    test "classifies Image stretch_or_rescale including adjust_height" do
      payload =
        page_with_elements(%{
          "a" => %{
            "id" => "i1",
            "type" => "Image",
            "properties" => %{
              "stretch_or_rescale" => "adjust_height",
              "src" => "https://cdn.example/a.png",
              "alt_tag" => "A"
            }
          }
        })

      assert {:ok, %Normalized{pages: [page]}} = Frontend.normalize(payload)
      [image] = page.children
      assert image.kind == :image
      assert image.variant == :adjust_height
      assert image.content["src"].resolved == "https://cdn.example/a.png"
      assert image.content["alt"].resolved == "A"
    end

    test "keeps a page-width image expression bound and exposes its public asset prefix" do
      url = "https://cdn.example/hero.png?ignore_imgix=1&n="

      width_expression = %{
        "%x" => "TextExpression",
        "%e" => %{
          "0" => url,
          "1" => %{
            "%x" => "PageData",
            "%p" => %{"%nm" => "Current Page Width"}
          }
        }
      }

      path_expression =
        put_in(width_expression, ["%e", "0"], "https://cdn.example/images/")

      user_expression =
        put_in(width_expression, ["%e", "1", "%p", "%nm"], "Current User")

      payload =
        page_with_elements(%{
          "a_width" => %{
            "id" => "i-width",
            "type" => "Image",
            "properties" => %{"src" => width_expression}
          },
          "m_path" => %{
            "id" => "i-path",
            "type" => "Image",
            "properties" => %{"src" => path_expression}
          },
          "z_user" => %{
            "id" => "i-user",
            "type" => "Image",
            "properties" => %{"src" => user_expression}
          }
        })

      assert {:ok, %Normalized{pages: [page]}} = Frontend.normalize(payload)
      [width_image, path_image, user_image] = page.children

      assert width_image.content["src"].binding_id == width_image.exporter_id <> " :: src"
      assert width_image.bindings["src"].payload == width_expression
      assert width_image.attributes["asset_src"] == url

      assert path_image.content["src"].binding_id == path_image.exporter_id <> " :: src"
      refute Map.has_key?(path_image.attributes, "asset_src")

      assert user_image.content["src"].binding_id == user_image.exporter_id <> " :: src"
      refute Map.has_key?(user_image.attributes, "asset_src")
    end

    test "normalizes Bubble Link page and link_disabled properties" do
      payload =
        page_with_elements(%{
          "internal" => %{
            "id" => "l1",
            "type" => "Link",
            "properties" => %{
              "text" => "Target",
              "linktype" => "pagelink",
              "page" => "target-page",
              "open_in_new_tab" => true,
              "nofollow" => true
            }
          },
          "disabled" => %{
            "id" => "l2",
            "type" => "Link",
            "properties" => %{
              "text" => "Disabled",
              "linktype" => "externallink",
              "url" => "https://example.com/disabled",
              "link_disabled" => true
            }
          }
        })

      assert {:ok, %Normalized{pages: [page]}} = Frontend.normalize(payload)
      [disabled, internal] = page.children

      assert disabled.kind == :link
      assert disabled.content["destination"].resolved == "https://example.com/disabled"
      assert disabled.attributes["disabled"] == true

      assert internal.kind == :link
      assert internal.content["destination"].resolved == "target-page"
      assert internal.attributes["target"] == "_blank"
      assert internal.attributes["rel"] == "nofollow noopener"
    end

    test "normalizes Bubble Text and Password Input content" do
      payload =
        page_with_elements(%{
          "password" => %{
            "id" => "password1",
            "type" => "Input",
            "properties" => %{
              "content_format" => "password",
              "content" => "BubbleEx mask demo",
              "placeholder" => "Password placeholder"
            }
          },
          "text" => %{
            "id" => "text1",
            "type" => "Input",
            "properties" => %{
              "content_format" => "text",
              "placeholder" => "Text placeholder"
            }
          }
        })

      assert {:ok, %Normalized{pages: [page]}} = Frontend.normalize(payload)
      [password, text] = page.children

      assert password.kind == :input
      assert password.variant == :password
      assert password.attributes["type"] == "password"
      assert password.content["value"].resolved == "BubbleEx mask demo"
      assert password.content["placeholder"].resolved == "Password placeholder"

      assert text.kind == :input
      assert text.variant == :text
      assert text.attributes["type"] == "text"
      assert text.content["placeholder"].resolved == "Text placeholder"
    end

    test "normalizes the characterized S2 static-control slice" do
      assert {:ok, %Normalized{pages: [page], diagnostics: diagnostics} = model} =
               Frontend.normalize(BubbleEx.FrontendFixtures.s2_controls_app())

      assert model.normalized_schema_version == 2

      [multiline, checkbox, unchecked_checkbox, dropdown, radios, dynamic_dropdown] =
        page.children

      assert multiline.kind == :multiline_input
      assert multiline.variant == :fixed
      assert multiline.content["value"].resolved == "Line one\nLine two"
      assert multiline.content["placeholder"].resolved == "Describe the export"
      assert multiline.attributes["maxlength"] == 240

      assert checkbox.kind == :checkbox
      assert checkbox.variant == :static
      assert checkbox.content["label"].resolved == "Include static assets"
      assert checkbox.content["checked"].resolved == true
      assert checkbox.attributes["required"] == true

      assert unchecked_checkbox.kind == :checkbox
      assert unchecked_checkbox.variant == :static
      assert unchecked_checkbox.content["checked"].resolved == false
      refute Map.has_key?(unchecked_checkbox.attributes, "required")

      assert dropdown.kind == :dropdown
      assert dropdown.variant == :static

      assert dropdown.content["choices"].resolved == [
               %{"label" => "HTML", "value" => "HTML"},
               %{"label" => "React", "value" => "React"},
               %{"label" => "Vue", "value" => "Vue"}
             ]

      assert dropdown.content["value"].resolved == "React"
      assert dropdown.content["placeholder"].resolved == "Choose a target"

      assert dynamic_dropdown.kind == :placeholder
      assert dynamic_dropdown.variant == :unsupported_dropdown_variant
      assert dynamic_dropdown.bindings["plugin"].kind == :plugin

      assert radios.kind == :radio_buttons
      assert radios.variant == :static
      refute Map.has_key?(radios.content, "label")
      assert radios.content["value"].resolved == "Wide"
      assert length(radios.content["choices"].resolved) == 2

      assert Enum.any?(diagnostics, fn diagnostic ->
               diagnostic.code == :unsupported_element and
                 dynamic_dropdown.exporter_id in diagnostic.refs
             end)
    end

    test "keeps auto-height multiline and dynamic choice controls as placeholders" do
      payload =
        page_with_elements(%{
          "auto" => %{
            "id" => "m1",
            "type" => "MultiLineInput",
            "properties" => %{"fit_height" => true}
          },
          "dynamic_checkbox" => %{
            "id" => "c1",
            "type" => "Checkbox",
            "properties" => %{"contents" => "dynamic_state", "dynamic" => %{"type" => "PageData"}}
          },
          "dynamic_dropdown" => %{
            "id" => "d1",
            "type" => "Dropdown",
            "properties" => %{"choices_style" => "dynamic"}
          },
          "dynamic_radios" => %{
            "id" => "r1",
            "type" => "RadioButtons",
            "properties" => %{"choices_style" => "dynamic"}
          }
        })

      assert {:ok, %Normalized{pages: [page]}} = Frontend.normalize(payload)
      assert Enum.all?(page.children, & &1.placeholder?)
    end

    test "normalizes reusable definitions once and instances as references" do
      payload = %{
        "_id" => "s1app",
        "pages" => %{
          "home" => %{
            "id" => "pghome",
            "type" => "Page",
            "name" => "index",
            "properties" => %{"container_layout" => "column"},
            "elements" => %{
              "nav" => %{
                "id" => "inst1",
                "type" => "CustomElement",
                "properties" => %{"definition" => "cmpNav", "original_name" => "Nav"}
              }
            }
          }
        },
        "element_definitions" => %{
          "cmpNav" => %{
            "id" => "cmpNavInner",
            "name" => "Left Nav",
            "type" => "CustomDefinition",
            "properties" => %{"container_layout" => "column"},
            "elements" => %{
              "label" => %{
                "id" => "elNav",
                "type" => "Text",
                "properties" => %{"text" => "Nav", "tag_type" => "normal"}
              }
            }
          }
        }
      }

      assert {:ok, model} = Frontend.normalize(payload)
      assert [defn] = model.reusables
      assert defn.kind == :reusable_definition
      assert [text] = defn.children
      assert text.kind == :text
      assert text.content["text"].resolved == "Nav"

      assert [page] = model.pages
      assert [inst] = page.children
      assert inst.kind == :reusable_instance
      assert inst.definition_ref == "cmpNav"
      assert inst.children == []
    end
  end

  test "supports two-stop gradients and preserves unsupported gradient metadata" do
    payload =
      page_with_elements(%{
        "two-stop" => %{
          "id" => "two-stop",
          "type" => "Group",
          "properties" => %{
            "background_style" => "gradient",
            "background_gradient_from" => "#112233",
            "background_gradient_to" => "#AABBCC",
            "background_gradient_direction" => "top"
          }
        },
        "unsupported" => %{
          "id" => "unsupported",
          "type" => "Group",
          "properties" => %{
            "background_style" => "gradient",
            "background_gradient_style" => "radial",
            "background_gradient_from" => "#112233",
            "background_gradient_to" => %{"type" => "ColorExpression"}
          }
        },
        "fractional-opacity" => %{
          "id" => "fractional-opacity",
          "type" => "Group",
          "properties" => %{"background_style" => "none", "opacity" => 0.25}
        }
      })

    assert {:ok, %Normalized{pages: [page]}} = Frontend.normalize(payload)
    nodes = Map.new(page.children, &{&1.source.bubble_id, &1})

    assert nodes["two-stop"].style.resolved["background"] ==
             "linear-gradient(to bottom, #112233, #AABBCC)"

    assert nodes["two-stop"].unmapped == %{}
    refute Map.has_key?(nodes["unsupported"].style.resolved, "background")

    assert nodes["unsupported"].unmapped["properties"]["background_gradient_style"] ==
             "radial"

    assert nodes["unsupported"].unmapped["properties"]["background_gradient_to"] ==
             %{"type" => "ColorExpression"}

    assert nodes["fractional-opacity"].style.resolved["opacity"] == 0.25
  end

  test "does not classify a dynamic compact choices expression as static" do
    payload =
      page_with_elements(%{
        "dynamic-choices" => %{
          "id" => "dynamic-choices",
          "type" => "Dropdown",
          "properties" => %{
            "%ch" => %{
              "type" => "ListExpression",
              "entries" => [%{"type" => "PageData", "name" => "Things"}]
            }
          }
        }
      })

    assert {:ok, %Normalized{pages: [%{children: [dropdown]}]}} = Frontend.normalize(payload)
    assert dropdown.kind == :placeholder
    assert dropdown.variant == :unsupported_dropdown_variant
  end

  defp compact_page_width_states do
    %{
      "0" => %{
        "%x" => "State",
        "%c" => %{
          "%x" => "PageData",
          "%p" => %{"%ei" => "pghome", "%nm" => "Current Page Width"},
          "%n" => %{
            "%x" => "Message",
            "%nm" => "less_or_equal_than",
            "%a" => 768
          }
        },
        "%p" => %{"%iv" => false}
      }
    }
  end

  defp compact_responsive_group(states, property_overrides \\ %{}) do
    %{
      "id" => "nav",
      "%x" => "Group",
      "%p" =>
        Map.merge(
          %{
            "%iv" => true,
            "collapse_when_hidden" => true,
            "container_layout" => "row"
          },
          property_overrides
        ),
      "%s" => states
    }
  end

  defp image_fixture(order, mode_key, mode) do
    %{
      "id" => "image-#{mode}",
      "%x" => "Image",
      "%p" => %{
        "order" => order,
        mode_key => mode,
        "min_width_css" => "320px",
        "max_width_css" => "320px",
        "min_height_css" => "180px",
        "max_height_css" => "180px",
        "single_width" => false,
        "fit_width" => false,
        "single_height" => false,
        "fit_height" => false,
        "horiz_alignment" => "flex-start",
        "vert_alignment" => "center"
      }
    }
  end

  defp modern_page do
    %{
      "_id" => "s1app",
      "app_version" => "live",
      "pages" => %{
        "home" => %{
          "id" => "pghome",
          "type" => "Page",
          "name" => "index",
          "properties" => %{
            "container_layout" => "column",
            "title" => "Home"
          },
          "elements" => %{}
        }
      }
    }
  end

  defp page_with_elements(elements) do
    %{
      "_id" => "s1app",
      "app_version" => "live",
      "pages" => %{
        "home" => %{
          "id" => "pghome",
          "type" => "Page",
          "name" => "index",
          "properties" => %{"container_layout" => "column", "title" => "Home"},
          "elements" => elements
        }
      }
    }
  end

  defp s1_payload do
    page_with_elements(%{
      "row" => %{
        "id" => "elRow",
        "type" => "Group",
        "properties" => %{
          "container_layout" => "row",
          "row_gap" => 8,
          "column_gap" => 16,
          "order" => 1
        }
      },
      "heading" => %{
        "id" => "elH1",
        "type" => "Text",
        "properties" => %{"tag_type" => "h1", "text" => "Hello", "order" => 2}
      },
      "dynamic" => %{
        "id" => "elDyn",
        "type" => "Text",
        "properties" => %{
          "tag_type" => "normal",
          "order" => 3,
          "text" => %{
            "type" => "TextExpression",
            "entries" => %{
              "0" => "Hi ",
              "1" => %{"type" => "PageData", "properties" => %{"name" => "Current User"}}
            }
          }
        }
      },
      "hero" => %{
        "id" => "elImg",
        "type" => "Image",
        "properties" => %{
          "run_mode" => "zoom",
          "src" => "https://cdn.example/hero.png",
          "alt" => "Hero",
          "order" => 4
        }
      },
      "dot" => %{
        "id" => "elShape",
        "type" => "Shape",
        "properties" => %{"bgcolor" => "#fff", "order" => 5}
      },
      "cta" => %{
        "id" => "elBtn",
        "type" => "Button",
        "properties" => %{"text" => "Go", "order" => 6}
      },
      "docs" => %{
        "id" => "elLink",
        "type" => "Link",
        "properties" => %{"text" => "Docs", "destination" => "https://example.com", "order" => 7}
      },
      "email" => %{
        "id" => "elInput",
        "type" => "Input",
        "properties" => %{
          "format" => "email",
          "placeholder" => "you@example.com",
          "order" => 8
        }
      },
      "plug" => %{
        "id" => "elPlug",
        "type" => "materialicons-Materialicon",
        "properties" => %{"order" => 9}
      }
    })
  end
end
