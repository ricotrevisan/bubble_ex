defmodule BubbleEx.ServedTasksTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{Expression, Index, Model, PageData}
  alias BubbleEx.Expression.IR
  alias BubbleEx.Frontend.Payload
  alias BubbleEx.Workflows.{Frontend, Source}

  # Captured from the rubble-rg-example test app, 2026-10-10. Only the
  # page, reusable and data schema are retained, with their original keys.
  defp app, do: "test/support/fixtures/served_tasks.json" |> File.read!() |> Jason.decode!()

  test "served Add and Done workflows lower with typed cell and input reads" do
    app = app()
    assert {:ok, model} = Model.build(app)
    assert {:ok, index} = Index.build(app, model: model)
    assert {:ok, frontend} = Frontend.build(app, model, index)
    assert length(frontend.workflows) == 2
    assert Enum.all?(frontend.workflows, &(&1.residue == []))

    add = Enum.find(frontend.workflows, &(&1.bubble_id == "bTGMD"))
    assert add.element == "bTGLv"
    assert [create, reset] = add.steps
    assert %{op: :create, residue: [], args: %{data_type: "task", changes: changes}} = create

    assert [
             %{field: "title_text", value: %{ir: %IR{op: :input}}},
             %{field: "done_boolean", value: %{ir: %IR{op: :literal, args: [false]}}}
           ] = changes

    assert reset.op == :reset_inputs

    done = Enum.find(frontend.workflows, &(&1.bubble_id == "bTGMF"))
    assert done.element == "bTGMB"
    assert [%{op: :update, residue: [], args: args}] = done.steps
    assert args.data_type == "task"
    assert %IR{op: :input, args: [:cell_thing, _]} = args.target.ir

    assert [%{field: "done_boolean", value: %{ir: %IR{op: :eq, args: [_, %IR{args: [false]}]}}}] =
             args.changes

    writes = Index.references_from(index, "action:bTGMJ", [:writes_field])
    assert [%{to: "field:task/done_boolean"}] = writes
  end

  test "served search keeps descending Created Date sort and unbounded RG rows" do
    app = app()
    assert {:ok, model} = Model.build(app)
    assert {:ok, data} = PageData.build(app, model)
    assert [%{element: "bTGLx", page_size: nil, residue: [], value: value}] = data.sources
    assert %IR{op: :sort, args: [%IR{op: :search}, "Created Date", true]} = value.ir

    # %c5 is the observed columns alias; no row count is present in the capture.
    app = put_in(app, ["%p3", "bTGLm", "%el", "bTGLy", "%p", "rows"], 3)
    app = put_in(app, ["%p3", "bTGLm", "%el", "bTGLy", "%p", "%c5"], 2)
    assert {:ok, %{sources: [%{page_size: 6}]}} = PageData.build(app, model)
  end

  test "compact search and element refs re-emit exact source, including collisions" do
    search = get_in(app(), ["%p3", "bTGLm", "%el", "bTGLy", "%p", "%ds"])
    ref = %{"%x" => "GetElement", "%p" => %{"%ei" => "bTGLt"}}

    for raw <- [
          search,
          ref,
          put_in(search, ["%p", "sort_field"], "title_text"),
          put_in(ref, ["%p", "element_id"], "other")
        ] do
      assert {:ok, parsed} = Expression.parse(raw)
      assert {:ok, ^raw} = Expression.to_bubble(parsed.ast)
    end

    assert {:ok, %{ast: %{options: %{"sort_field" => "Created Date", "descending" => true}}}} =
             Expression.parse(search)

    assert {:ok, %{ast: %{ref: %{"element_id" => "bTGLt"}}}} = Expression.parse(ref)
  end

  test "workflow member normalization leaves nested expressions and lists untouched" do
    expression = %{"%x" => "GetElement", "%p" => %{"%ei" => "input"}}
    entries = [%{"%k" => "title_text", "%v" => expression}]

    assert %{"initial_values" => ^entries, "element_id" => "readable"} =
             Source.member_props(%{
               "%i2" => entries,
               "%ei" => "compact",
               "element_id" => "readable"
             })
  end

  defp all_nodes(nodes), do: Enum.flat_map(nodes, &[&1 | all_nodes(&1.children)])

  test "served conditions expose readable state keys and unambiguous property diffs" do
    assert {:ok, normalized} = BubbleEx.Frontend.normalize(app())
    text = normalized.pages |> all_nodes() |> Enum.find(&(&1.source.bubble_id == "bTGLz"))
    binding = text.bindings["condition"]
    assert %{"0" => state} = binding.payload
    assert Map.keys(state) |> Enum.sort() == ["condition", "properties", "type"]
    assert state["type"] == "State"
    assert state["properties"] == %{"background_style" => "bgcolor", "bgcolor" => "#d1f0d1"}
    assert state["condition"]["%x"] == "ElementParent"

    assert %{"%3" => "label", "bgcolor" => "readable"} =
             Payload.expand_properties(%{
               "%3" => "label",
               "%bgc" => "compact",
               "bgcolor" => "readable"
             })
  end
end
