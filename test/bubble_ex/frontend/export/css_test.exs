defmodule BubbleEx.Frontend.Export.CssTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend.Export.Css
  alias BubbleEx.Frontend.Normalized
  alias BubbleEx.Frontend.Normalized.{Node, Style}
  alias BubbleEx.Frontend.Normalized.Source

  test "emits canonical shared typography values" do
    style = %Style{
      exporter_id: "style",
      map_key: "style",
      slug: "body",
      class_name: "s-body",
      properties: %{
        "font_face" => "Inter",
        "font_size" => 15,
        "letter_spacing" => 0,
        "line_height" => 1.4,
        "padding_top" => "12px"
      }
    }

    css = Css.shared(%Normalized{styles: [style]})
    assert css =~ ~s(font-family: "Inter", Helvetica, Arial, sans-serif;)
    assert css =~ "font-size: 15px;"
    assert css =~ "letter-spacing: 0px;"
    assert css =~ "line-height: 1.4;"
    assert css =~ "padding-top: 12px;"
  end

  test "emits page paint and box dimensions and centers a max-width fill child" do
    header =
      node("header",
        layout: %{fill_width?: true, mode: :row},
        box: %{max_width: "1120px", min_height: "72px", align_self: "center"}
      )

    page =
      node("page",
        kind: :page,
        layout: %{mode: :column},
        box: %{padding: "20px 16px 56px", min_height: "900px"},
        style: %{resolved: %{"font_face" => "Inter", "bgcolor" => "#F4F7FB"}},
        children: [header]
      )

    css = Css.page(page)

    assert rule(css, "page") =~ "background: #F4F7FB;"
    assert rule(css, "page") =~ ~s(font-family: "Inter", Helvetica, Arial, sans-serif;)
    assert rule(css, "page") =~ "min-height: 900px;"
    assert rule(css, "page") =~ "padding: 20px 16px 56px;"

    header_rule = rule(css, "header")
    assert header_rule =~ "width: 100%;"
    assert header_rule =~ "max-width: 1120px;"
    assert header_rule =~ "min-height: 72px;"
    assert header_rule =~ "align-self: center;"
    refute header_rule =~ "flex-basis:"
  end

  test "uses the parent axis for fill sizing, row wrapping, and alignment" do
    row_fill =
      node("row-fill",
        kind: :text,
        layout: %{fill_width?: true, fill_height?: true},
        box: %{min_width: "336px"}
      )

    aligned = node("aligned", kind: :text, box: %{align_self: "end"})

    row =
      node("row",
        layout: %{mode: :row, wrap: :wrap, align: "center"},
        children: [row_fill, aligned]
      )

    column_fill =
      node("column-fill",
        kind: :text,
        layout: %{fill_width?: true, fill_height?: true}
      )

    column = node("column", layout: %{mode: :column}, children: [column_fill])
    page = node("page", kind: :page, layout: %{mode: :column}, children: [row, column])
    css = Css.page(page)

    assert rule(css, "row") =~ "flex-wrap: wrap;"
    assert rule(css, "row") =~ "align-items: center;"

    row_fill_rule = rule(css, "row-fill")
    assert row_fill_rule =~ "flex-basis: 0;"
    assert row_fill_rule =~ "flex-grow: 1;"
    assert row_fill_rule =~ "flex-shrink: 1;"
    assert row_fill_rule =~ "min-width: 336px;"
    assert row_fill_rule =~ "align-self: stretch;"
    refute row_fill_rule =~ "width: 100%;"

    assert rule(css, "aligned") =~ "align-self: flex-end;"

    assert rule(css, "column") =~ "align-items: flex-start;"

    column_fill_rule = rule(css, "column-fill")
    assert column_fill_rule =~ "width: 100%;"
    assert column_fill_rule =~ "flex-basis: 0;"
    assert column_fill_rule =~ "flex-grow: 1;"
    assert column_fill_rule =~ "flex-shrink: 1;"
  end

  test "places every align-to-parent nonant without replacing box dimensions" do
    cells = [
      {"top-start", "top_start", "start", "start"},
      {"top-center", "top_center", "center", "start"},
      {"top-end", "top_end", "end", "start"},
      {"center-start", "center_start", "start", "center"},
      {"center", "center", "center", "center"},
      {"center-end", "center_end", "end", "center"},
      {"bottom-start", "bottom_start", "start", "end"},
      {"bottom-center", "bottom_center", "center", "end"},
      {"bottom-end", "bottom_end", "end", "end"}
    ]

    children =
      Enum.map(cells, fn {id, cell, _justify, _align} ->
        node(id,
          kind: :shape,
          box: %{
            width: "320px",
            height: "180px",
            placement: %{
              "cell" => cell,
              "width" => "999px",
              "height" => "999px",
              "offset-x" => "2px",
              "offset-y" => "-3px"
            }
          }
        )
      end)

    parent = node("relative", layout: %{mode: :align_to_parent}, children: children)
    css = Css.page(parent)

    assert rule(css, "relative") =~ "position: relative;"
    assert rule(css, "relative") =~ "grid-template-columns: repeat(3, 1fr);"

    for {id, _cell, justify, align} <- cells do
      child_rule = rule(css, id)
      assert child_rule =~ "grid-area: 1 / 1 / 4 / 4;"
      assert child_rule =~ "justify-self: #{justify};"
      assert child_rule =~ "align-self: #{align};"
      assert child_rule =~ "translate: 2px -3px;"
      assert child_rule =~ "width: 320px;"
      assert child_rule =~ "height: 180px;"
      refute child_rule =~ "999px"
    end
  end

  test "positions fixed children with absolute offsets and z-index" do
    child =
      node("fixed-child",
        kind: :shape,
        box: %{x: "12px", y: "12px", width: "72px", height: "54px", z_index: 1}
      )

    origin_child =
      node("fixed-origin-child",
        kind: :shape,
        box: %{
          width: "132px",
          height: "132px",
          margin: "18px 18px 0 0",
          placement: %{"cell" => "top_end"}
        }
      )

    fixed = node("fixed", layout: %{mode: :fixed}, children: [child, origin_child])
    css = Css.page(fixed)

    assert rule(css, "fixed") =~ "position: relative;"

    child_rule = rule(css, "fixed-child")
    assert child_rule =~ "position: absolute;"
    assert child_rule =~ "left: 12px;"
    assert child_rule =~ "top: 12px;"
    assert child_rule =~ "z-index: 1;"

    origin_rule = rule(css, "fixed-origin-child")
    assert origin_rule =~ "position: absolute;"
    assert origin_rule =~ "left: 0px;"
    assert origin_rule =~ "top: 0px;"
    assert origin_rule =~ "margin: 0px;"
    refute origin_rule =~ "grid-area:"
  end

  test "matches Bubble's static radio group line box and inset" do
    radio =
      node("radio",
        kind: :radio_buttons,
        style: %{resolved: %{"font_face" => "Inter", "font_size" => 16}}
      )

    css = Css.page(radio)
    radio_rule = rule(css, "radio")

    assert radio_rule =~ "display: grid;"
    assert radio_rule =~ "gap: 10px 20px;"
    assert radio_rule =~ "line-height: 1;"
    assert radio_rule =~ "padding: 3px 0 3px 20px;"
  end

  test "keeps 320 by 180 image boxes and maps object-fit variants" do
    images = [
      node("stretch", kind: :image, variant: :stretch, box: %{width: 320, height: 180}),
      node("rescale", kind: :image, variant: :rescale, box: %{width: 320, height: 180}),
      node("zoom", kind: :image, variant: :zoom, box: %{width: 320, height: 180})
    ]

    css = Css.page(node("gallery", layout: %{mode: :column}, children: images))

    for {id, fit} <- [{"stretch", "fill"}, {"rescale", "contain"}, {"zoom", "cover"}] do
      image_rule = rule(css, id)
      assert image_rule =~ "width: 320px;"
      assert image_rule =~ "height: 180px;"
      assert image_rule =~ "object-fit: #{fit};"
      assert image_rule =~ "display: block;"
    end
  end

  defp node(id, opts) do
    %Node{
      exporter_id: id,
      map_key: id,
      source: %Source{},
      kind: Keyword.get(opts, :kind, :group),
      variant: opts[:variant],
      layout: opts[:layout],
      box: Keyword.get(opts, :box, %{}),
      style: Keyword.get(opts, :style, %{resolved: %{}}),
      children: Keyword.get(opts, :children, [])
    }
  end

  defp rule(css, id) do
    marker = ~s([data-exporter-id="#{id}"] {
)
    [_before, rest] = String.split(css, marker, parts: 2)
    [declarations | _rest] = String.split(rest, "}
", parts: 2)
    declarations
  end
end
