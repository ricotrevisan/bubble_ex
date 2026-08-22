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
