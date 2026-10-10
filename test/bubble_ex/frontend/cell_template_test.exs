defmodule BubbleEx.Frontend.CellTemplateTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.Frontend.Export.Css
  alias BubbleEx.Frontend.Normalized.{Node, Source}

  # Captured from the rubble-rg-example test app (served payload): one dynamic
  # Repeating Group over custom.task, a Text and a Done Button per cell, one
  # explicit column (`%c5`) and a 56px cell minimum height.
  defp app, do: "test/support/fixtures/served_tasks.json" |> File.read!() |> Jason.decode!()

  defp rg(payload, bubble_id \\ "bTGLx") do
    assert {:ok, model} = Frontend.normalize(payload)
    [page] = model.pages
    Enum.find(all_nodes(page.children), &(&1.source.bubble_id == bubble_id))
  end

  defp all_nodes(nodes), do: Enum.flat_map(nodes, &[&1 | all_nodes(&1.children)])

  test "a dynamic repeating group normalizes its cell minima and columns onto the placeholder layout" do
    list = rg(app())

    assert list.kind == :placeholder

    assert list.runtime == %{
             "boundary" => "container",
             "type" => "RepeatingGroup",
             "repeats" => true
           }

    assert list.layout[:mode] == :row
    assert list.layout[:columns] == 1
    assert list.layout[:cell_min_width] == "0px"
    assert list.layout[:cell_min_height] == "56px"
    assert list.layout[:fill_width?] == true
  end

  test "the cell template is a group cell with the per-cell layout split" do
    list = rg(app())
    assert {:ok, cell} = Frontend.cell_template(list)

    assert cell.kind == :group
    assert cell.variant == :repeating_cell
    refute cell.placeholder?
    assert cell.exporter_id == list.exporter_id <> "/cells/template"
    assert cell.exporter_id != list.exporter_id
    assert cell.map_key == "cell-template"
    assert cell.source.path == list.source.path

    # The cell content's layout only: no outer fill flags, cell minima or
    # columns, and the authored cell minimum on the cell's box.
    assert cell.layout == %{mode: :row, wrap: :wrap}
    assert cell.box == %{min_width: "0px", min_height: "56px"}
    assert cell.children == list.children
  end

  test "lowering the cell styles the wrapper and its children in the cell's parent mode" do
    {:ok, cell} = Frontend.cell_template(rg(app()))

    assert [cell_entry, text_entry, button_entry] = Css.lower(cell)
    assert cell_entry.node == cell

    assert Map.new(cell_entry.declarations) == %{
             "align-items" => "flex-start",
             "display" => "flex",
             "flex-direction" => "row",
             "flex-wrap" => "wrap",
             "min-height" => "56px",
             "min-width" => "0px",
             "position" => "relative"
           }

    # Fill width in a row parent grows the text next to the button instead of
    # stacking both at full width.
    assert text_entry.node.source.bubble_id == "bTGLz"

    assert Map.new(text_entry.declarations) == %{
             "flex-basis" => "0",
             "flex-grow" => "1",
             "flex-shrink" => "1",
             "min-height" => "0px",
             "min-width" => "0px",
             "position" => "relative",
             "white-space" => "pre-wrap",
             "z-index" => 2
           }

    # The button stays in the same cell at its own size.
    assert button_entry.node.source.bubble_id == "bTGMB"

    assert Map.new(button_entry.declarations) == %{
             "min-height" => "44px",
             "min-width" => "0px",
             "position" => "relative",
             "z-index" => 3
           }
  end

  test "the group's own lowering still stops at the runtime boundary" do
    list = rg(app())
    assert [entry] = Css.lower(list)
    assert entry.node == list
    assert Map.new(entry.declarations)["display"] == "grid"
  end

  test "nodes without a dynamic repeating group template are unsupported" do
    # An unwired template has nothing to render per cell.
    empty = put_in(app(), ["%p3", "bTGLm", "%el", "bTGLy", "%el"], %{})
    assert Frontend.cell_template(rg(empty)) == :unsupported

    # Static lists expand their own cells.
    assert Frontend.cell_template(static_list()) == :unsupported

    # Other runtime containers and native nodes have no per-item template.
    table = %Node{
      exporter_id: "tbl",
      kind: :placeholder,
      map_key: "tbl",
      source: %Source{},
      runtime: %{"boundary" => "container", "type" => "Table", "repeats" => true},
      children: [text()]
    }

    assert Frontend.cell_template(table) == :unsupported

    group = %Node{exporter_id: "g", kind: :group, map_key: "g", source: %Source{}}
    assert Frontend.cell_template(group) == :unsupported
  end

  # Captured from the mixxy rebuild (editor-shaped `.bubble` export, loaded
  # marked like `BubbleEx.AppDefinition` does): the same task list with a
  # fixed-width Done button and an 87.5px cell minimum, no authored columns.
  defp rebuilt_app do
    assert {:ok, app} =
             "test/support/fixtures/rebuilt_tasks.json"
             |> File.read!()
             |> Frontend.decode_bubble_export()

    app
  end

  test "the rebuilt capture's fixed-width Done keeps its row beside a filling title" do
    list = rg(rebuilt_app(), "bTIrm")

    assert list.layout[:mode] == :row
    assert list.layout[:cell_min_height] == "87.5px"
    # `fixed_columns` without an authored count stays absent.
    refute Map.has_key?(list.layout, :columns)

    {:ok, cell} = Frontend.cell_template(list)
    assert cell.box == %{min_width: "0px", min_height: "87.5px"}

    assert [cell_entry, title_entry, done_entry] = Css.lower(cell)

    assert Map.new(cell_entry.declarations) == %{
             "align-items" => "flex-start",
             "display" => "flex",
             "flex-direction" => "row",
             "flex-wrap" => "wrap",
             "min-height" => "87.5px",
             "min-width" => "0px",
             "position" => "relative"
           }

    assert title_entry.node.source.bubble_id == "bTIro"

    assert Map.new(title_entry.declarations) == %{
             "flex-basis" => "0",
             "flex-grow" => "1",
             "flex-shrink" => "1",
             "min-height" => "36px",
             "min-width" => "0px",
             "position" => "relative",
             "white-space" => "pre-wrap",
             "z-index" => 2
           }

    assert done_entry.node.source.bubble_id == "bTIrq"
    done = Map.new(done_entry.declarations)

    assert done == %{
             "height" => "44px",
             "max-width" => "150px",
             "min-height" => "44px",
             "min-width" => "150px",
             "position" => "relative",
             "width" => "150px",
             "z-index" => 3
           }

    # The group's own lowering still stops at the runtime boundary.
    assert [entry] = Css.lower(list)
    assert Map.new(entry.declarations)["display"] == "grid"
  end

  defp text do
    %Node{exporter_id: "t", kind: :text, map_key: "t", source: %Source{}}
  end

  defp static_list do
    parent_expression = %{"%x" => "TextExpression", "%e" => %{"0" => %{"%x" => "ElementParent"}}}

    payload = %{
      "_id" => "lists",
      "pages" => %{
        "index" => %{
          "type" => "Page",
          "name" => "index",
          "properties" => %{"container_layout" => "column"},
          "elements" => %{
            "logos" => %{
              "id" => "logos",
              "%x" => "RepeatingGroup",
              "%p" => %{
                "%rs" => 1,
                "fixed_rows" => true,
                "fixed_columns" => false,
                "show_all_items" => true,
                "container_layout" => "column",
                "cell_min_width_css" => "0px",
                "cell_min_height_css" => "10px",
                "%ds" => %{
                  "%x" => "ArbitraryText",
                  "%p" => %{
                    "arbitrary_text" => %{
                      "%x" => "TextExpression",
                      "%e" => %{
                        "0" => "https://example.test/one.svg\nhttps://example.test/two.svg"
                      }
                    }
                  },
                  "%n" => %{
                    "%nm" => "split_by",
                    "%x" => "Message",
                    "is_slidable" => true,
                    "%p" => %{
                      "separator" => %{"%x" => "TextExpression", "%e" => %{"0" => "\n"}}
                    }
                  }
                }
              },
              "%el" => %{
                "logo" => %{
                  "id" => "logo",
                  "%x" => "Image",
                  "%p" => %{"src" => parent_expression}
                }
              }
            }
          }
        }
      }
    }

    {:ok, model} = Frontend.normalize(payload)
    hd(hd(model.pages).children)
  end
end
