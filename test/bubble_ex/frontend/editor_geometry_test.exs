defmodule BubbleEx.Frontend.EditorGeometryTest do
  # WTF-446: Bubble's editor JSON (a Buildprint v5 workspace, a `.bubble`
  # export) writes every element's canvas box as `left`/`top`/`width`/
  # `height`, also inside Column, Row and Align-to-parent containers where
  # Bubble ignores it, and leaves out the sizing flags that are off. The
  # same page in the shape the fidelity cases are calibrated on (no canvas
  # offsets, explicit flags, sizes only on fixed axes) must lay out alike:
  # same normalized layout, same CSS, same Tailwind classes.
  use ExUnit.Case, async: true

  alias BubbleEx.Buildprint.V5
  alias BubbleEx.Frontend
  alias BubbleEx.Frontend.EditorGeometry
  alias BubbleEx.Frontend.Export.Css
  alias BubbleEx.Target.Phoenix.Tailwind

  defp flags(fit_width, single_width, fit_height, single_height) do
    %{
      "fit_width" => fit_width,
      "single_width" => single_width,
      "fit_height" => fit_height,
      "single_height" => single_height
    }
  end

  defp el(id, type, order, props, elements \\ nil) do
    base = %{"id" => id, "type" => type, "properties" => Map.put(props, "order", order)}
    if elements, do: Map.put(base, "elements", elements), else: base
  end

  # The page as the Bubble editor writes it (what V5.merge/2 returns).
  defp editor_page do
    %{
      "id" => "pgblog",
      "type" => "Page",
      "name" => "blog",
      "properties" => %{
        "container_layout" => "column",
        "new_responsive" => true,
        "left" => 0,
        "top" => 0,
        "width" => 1440,
        "height" => 767,
        "default_width" => 1440,
        "min_height_px" => 800
      },
      "elements" => %{
        "hero" =>
          el(
            "hero",
            "Group",
            1,
            %{
              "container_layout" => "column",
              "left" => 32,
              "top" => 96,
              "width" => 0,
              "height" => 0,
              "fit_height" => true,
              "max_width_css" => "1280px",
              "row_gap" => 16
            },
            %{
              "title" =>
                el("title", "Text", 1, %{
                  "text" => "Title",
                  "left" => -32,
                  "top" => -95,
                  "width" => 200,
                  "height" => 45,
                  "fit_width" => true,
                  "fit_height" => true
                }),
              "body" =>
                el("body", "Text", 2, %{
                  "text" => "Body",
                  "left" => 0,
                  "top" => 0,
                  "width" => 0,
                  "height" => 45,
                  "fit_height" => true,
                  "min_height_css" => "17px"
                }),
              "cta" =>
                el("cta", "Button", 3, %{
                  "text" => "Go",
                  "left" => 10,
                  "top" => 10,
                  "width" => 150,
                  "height" => 40,
                  "single_width" => true,
                  "single_height" => true,
                  "min_width_css" => "150px",
                  "min_height_css" => "40px"
                })
            }
          ),
        "cards" =>
          el(
            "cards",
            "Group",
            2,
            %{
              "container_layout" => "row",
              "left" => 0,
              "top" => 300,
              "width" => 0,
              "height" => 0,
              "fit_height" => true,
              "column_gap" => 24
            },
            %{
              "card" =>
                el("card", "Group", 1, %{
                  "container_layout" => "column",
                  "left" => -80,
                  "top" => -80,
                  "width" => 280,
                  "height" => 280,
                  "fit_height" => true,
                  "min_width_css" => "280px"
                }),
              "badge" =>
                el("badge", "Group", 2, %{
                  "container_layout" => "row",
                  "left" => 0,
                  "top" => 0,
                  "width" => 0,
                  "height" => 0,
                  "fit_width" => true,
                  "fit_height" => true
                })
            }
          ),
        "canvas" =>
          el(
            "canvas",
            "Group",
            3,
            %{
              "container_layout" => "fixed",
              "left" => 0,
              "top" => 600,
              "width" => 400,
              "height" => 200,
              "single_width" => true,
              "single_height" => true,
              "min_width_css" => "400px",
              "min_height_css" => "200px"
            },
            %{
              "dot" =>
                el("dot", "Shape", 1, %{
                  "left" => 12,
                  "top" => 12,
                  "width" => 72,
                  "height" => 54,
                  "single_width" => true,
                  "single_height" => true
                })
            }
          )
      }
    }
  end

  # The same page in the calibrated shape of the fidelity cases.
  defp calibrated_page do
    %{
      "id" => "pgblog",
      "type" => "Page",
      "name" => "blog",
      "properties" =>
        Map.merge(flags(false, false, false, false), %{
          "container_layout" => "column",
          "new_responsive" => true,
          "width" => 1440,
          "default_width" => 1440,
          "min_height_px" => 800
        }),
      "elements" => %{
        "hero" =>
          el(
            "hero",
            "Group",
            1,
            Map.merge(flags(false, false, true, false), %{
              "container_layout" => "column",
              "max_width_css" => "1280px",
              "row_gap" => 16
            }),
            %{
              "title" =>
                el("title", "Text", 1, Map.put(flags(true, false, true, false), "text", "Title")),
              "body" =>
                el(
                  "body",
                  "Text",
                  2,
                  Map.merge(flags(false, false, true, false), %{
                    "text" => "Body",
                    "min_height_css" => "17px"
                  })
                ),
              "cta" =>
                el(
                  "cta",
                  "Button",
                  3,
                  Map.merge(flags(false, true, false, true), %{
                    "text" => "Go",
                    "min_width_css" => "150px",
                    "min_height_css" => "40px"
                  })
                )
            }
          ),
        "cards" =>
          el(
            "cards",
            "Group",
            2,
            Map.merge(flags(false, false, true, false), %{
              "container_layout" => "row",
              "column_gap" => 24
            }),
            %{
              "card" =>
                el(
                  "card",
                  "Group",
                  1,
                  Map.merge(flags(false, false, true, false), %{
                    "container_layout" => "column",
                    "min_width_css" => "280px"
                  })
                ),
              "badge" =>
                el(
                  "badge",
                  "Group",
                  2,
                  Map.put(flags(true, false, true, false), "container_layout", "row")
                )
            }
          ),
        "canvas" =>
          el(
            "canvas",
            "Group",
            3,
            Map.merge(flags(false, true, false, true), %{
              "container_layout" => "fixed",
              "min_width_css" => "400px",
              "min_height_css" => "200px"
            }),
            %{
              "dot" =>
                el("dot", "Shape", 1, %{
                  "x" => 12,
                  "y" => 12,
                  "width" => 72,
                  "height" => 54,
                  "single_width" => true,
                  "single_height" => true
                })
            }
          )
      }
    }
  end

  defp app(page), do: %{"_id" => "wtf446", "pages" => %{"blog" => page}}

  # What a Buildprint v5 workspace yields: a stub page in the preamble,
  # completed by the page's fragment.
  defp v5_app do
    preamble = %{
      "_id" => "wtf446",
      "pages" => %{"blog" => %{"id" => "pgblog", "name" => "blog", "type" => "Page"}}
    }

    {app, []} = V5.merge(preamble, [{"pages/blog.ts", %{"pages" => %{"blog" => editor_page()}}}])
    app
  end

  # Per element: its CSS declarations and rules, and the Tailwind classes
  # the HEEx emitter prints for them.
  defp layout(app) do
    {:ok, %{pages: [page]}} = Frontend.normalize(app)

    Map.new(Css.lower(page), fn %{node: node, declarations: declarations, rules: rules} ->
      {utilities, residue} = Tailwind.utilities(declarations)

      {node.source.bubble_id,
       %{css: declarations, rules: rules, classes: utilities, residue: residue}}
    end)
  end

  defp classes(layout, id), do: layout[id].classes

  test "a v5 editor page lays out like its calibrated equivalent" do
    editor = layout(v5_app())
    calibrated = layout(app(calibrated_page()))

    assert Map.keys(editor) == Map.keys(calibrated)

    for id <- Map.keys(calibrated) do
      assert {id, editor[id]} == {id, calibrated[id]}
    end
  end

  test "elements in flow are not positioned and have no zero sizes" do
    layout = layout(v5_app())

    for id <- ~w(hero title body cta cards card badge canvas) do
      refute "absolute" in classes(layout, id), id
      refute Enum.any?(classes(layout, id), &(&1 in ["w-[0px]", "h-[0px]"])), id
      refute Enum.any?(classes(layout, id), &String.match?(&1, ~r/^-?(left|top)-/)), id
    end

    # Neither fixed nor fit: fills between min and max (a column's width,
    # a row's free space).
    assert "w-[100%]" in classes(layout, "hero")
    assert "w-[100%]" in classes(layout, "body")
    assert "grow-[1]" in classes(layout, "card")
    # Fit to content: no width at all; fixed: the editor's min width.
    refute Enum.any?(classes(layout, "title"), &String.starts_with?(&1, "w-"))
    assert "w-[150px]" in classes(layout, "cta")
    # A Fixed container still places its children at their offsets.
    assert "absolute" in classes(layout, "dot")
    assert "left-[12px]" in classes(layout, "dot")
    # The page grows with its content from its min height.
    refute Enum.any?(classes(layout, "pgblog"), &(&1 in ["absolute", "h-[767px]"]))
  end

  defp editor_app(page), do: EditorGeometry.mark(app(page))

  defp column_page(elements, props \\ %{}) do
    %{
      "id" => "pg",
      "type" => "Page",
      "name" => "p",
      "properties" =>
        Map.merge(
          %{
            "container_layout" => "column",
            "width" => 1440,
            "height" => 767,
            "min_height_px" => 800
          },
          props
        ),
      "elements" => elements
    }
  end

  defp only_child(app) do
    {:ok, %{pages: [page]}} = Frontend.normalize(app)
    [child] = page.children
    child
  end

  test "editor pages grow with their content, with or without canvas offsets" do
    for offsets <- [%{}, %{"left" => 0, "top" => 0}], fixed <- [true, false] do
      props = Map.put(offsets, "fixed_width", fixed)
      layout = layout(editor_app(column_page(%{}, props)))
      page = classes(layout, "pg")

      refute Enum.any?(page, &(&1 in ["absolute", "h-[767px]"])), inspect(props)
      assert "min-h-[800px]" in page
      assert "w-[1440px]" in page == fixed, inspect(props)
      assert "w-[100%]" in page == not fixed, inspect(props)
    end
  end

  test "flow children lose their canvas size with or without offsets" do
    text =
      el("t", "Text", 1, %{
        "text" => "x",
        "width" => 200,
        "height" => 45,
        "fit_width" => true,
        "fit_height" => true
      })

    child = only_child(editor_app(column_page(%{"t" => text})))

    refute Map.has_key?(child.box, :width)
    refute Map.has_key?(child.box, :height)
  end

  test "plugin elements keep their canvas size and lose only their offsets" do
    plugin =
      el("pl", "1488796042609x768734193128308700-AAg", 1, %{
        "left" => 24,
        "top" => 40,
        "width" => 300,
        "height" => 120
      })

    child = only_child(editor_app(column_page(%{"pl" => plugin})))

    assert child.kind == :placeholder
    assert %{width: 300, height: 120} = child.box
    refute Map.has_key?(child.box, :x)
    refute Map.has_key?(child.box, :y)
  end

  # Assumption until a Bubble capture calibrates it (WTF-358 replay list):
  # an element neither fixed nor fit on its height, without a min height,
  # keeps its canvas height as a min height (never as a height).
  test "neither fixed nor fit: the canvas height is a min height" do
    group = fn props ->
      el(
        "g",
        "Group",
        1,
        Map.merge(
          %{"container_layout" => "column", "left" => 0, "top" => 0, "height" => 280},
          props
        )
      )
    end

    layout = fn props -> layout(editor_app(column_page(%{"g" => group.(props)}))) end

    assert "min-h-[280px]" in classes(layout.(%{}), "g")
    refute Enum.any?(classes(layout.(%{}), "g"), &String.starts_with?(&1, "h-"))
    assert "min-h-[40px]" in classes(layout.(%{"min_height_css" => "40px"}), "g")

    refute Enum.any?(
             classes(layout.(%{"fit_height" => true}), "g"),
             &String.starts_with?(&1, "min-h-")
           )

    assert "h-[280px]" in classes(
             layout.(%{"single_height" => true, "min_height_css" => "280px"}),
             "g"
           )

    refute Enum.any?(classes(layout.(%{"height" => 0}), "g"), &String.starts_with?(&1, "min-h-"))
  end

  test "a reusable definition's canvas size does not size its instances" do
    definition = %{
      "id" => "hdr",
      "type" => "CustomDefinition",
      "name" => "header",
      "properties" => %{"container_layout" => "column", "width" => 1280, "height" => 80}
    }

    {:ok, %{reusables: [editor]}} =
      Frontend.normalize(
        EditorGeometry.mark(%{"_id" => "wtf446", "element_definitions" => %{"hdr" => definition}})
      )

    {:ok, %{reusables: [calibrated]}} =
      Frontend.normalize(%{
        "_id" => "wtf446",
        "element_definitions" => %{
          "hdr" =>
            put_in(definition, ["properties"], %{
              "container_layout" => "column",
              "%w" => 1280,
              "%h" => 80
            })
        }
      })

    assert editor.box == calibrated.box
    refute Map.has_key?(editor.box, :width)
  end

  test "children of legacy containers keep their canvas box" do
    page = %{
      "id" => "pglegacy",
      "type" => "Page",
      "name" => "legacy",
      "properties" => %{"left" => 0, "top" => 0, "width" => 1080},
      "elements" => %{
        "t" => el("t", "Text", 1, %{"text" => "x", "left" => 40, "top" => 60, "width" => 200})
      }
    }

    assert %{x: 40, y: 60, width: 200} = only_child(editor_app(page)).box
  end

  test "an unmarked app is read as before, and the option overrides the mark" do
    text = el("t", "Text", 1, %{"text" => "x", "left" => 40, "top" => 60, "width" => 200})
    raw = app(column_page(%{"t" => text}))

    assert %{x: 40, y: 60, width: 200} = only_child(raw).box

    {:ok, %{pages: [page]}} = Frontend.normalize(raw, geometry: :editor)
    refute Map.has_key?(hd(page.children).box, :x)

    {:ok, %{pages: [page]}} = Frontend.normalize(EditorGeometry.mark(raw), geometry: :runtime)
    assert %{x: 40} = hd(page.children).box
    assert {:ok, _} = Frontend.normalize(EditorGeometry.mark(raw))
  end
end
