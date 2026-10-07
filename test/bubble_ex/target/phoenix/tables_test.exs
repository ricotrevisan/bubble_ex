defmodule BubbleEx.Target.Phoenix.TablesTest do
  # Bubble's Table element, from the synthetic
  # test/support/target/phoenix/tables.json: its parts in the element
  # tree, its list as page data, "Current row's thing" bound as a
  # repeating group's cell, and the HTML table the page renders.
  # scripts/phoenix_compile_check.sh compiles the output and runs
  # test/support/target/phoenix/tables_behavior.exs against it.
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model}
  alias BubbleEx.Expression.Tree
  alias BubbleEx.PageData
  alias BubbleEx.Target.Elixir.{Frontend, FrontendWorkflows}
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Target.Phoenix

  @fixture "test/support/target/phoenix/tables.json"
  @page "lib/shop_web/live/index_live.html.heex"

  defp app, do: @fixture |> File.read!() |> Jason.decode!()

  defp build(app) do
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)

    {:ok, expressions} =
      Frontend.compile(app, model, project, frontend,
        runtime: "Shop.Bubble.Runtime",
        namespace: "Shop"
      )

    {:ok, lowered} = BubbleEx.Workflows.Frontend.build(app, model, index)
    {:ok, backend_lowered} = BubbleEx.Workflows.Backend.build(app, model, index)

    {:ok, backend} =
      BubbleEx.Target.Ash.Workflows.map(backend_lowered, project, namespace: "Shop")

    {:ok, page_data} = PageData.build(app, model)

    {:ok, spec} =
      FrontendWorkflows.map(lowered, project,
        namespace: "Shop",
        frontend: frontend,
        backend: backend,
        page_data: page_data
      )

    opts = [
      module: "Shop",
      frontend: frontend,
      expressions: expressions,
      workflows: backend,
      frontend_workflows: spec
    ]

    {:ok, files} = Phoenix.render(project, opts)
    {:ok, ^files} = Phoenix.render(project, opts)
    %{files: files, page_data: page_data, spec: spec, lowered: lowered}
  end

  setup_all do
    build(app())
  end

  defp put_in_app(app, path, value), do: put_in(app, Enum.map(path, &Access.key(&1, %{})), value)

  defp source(page_data, element, kind),
    do: Enum.find(page_data.sources, &(&1.element == element and &1.kind == kind))

  describe "the element tree" do
    test "a table's repeated row holds its thing; its header does not" do
      tree = Tree.build(app())

      assert %{repeats: true, content: "custom.task"} = Tree.node(tree, "bRow")
      assert %{repeats: false, content: nil} = Tree.node(tree, "bHead")
      assert %{repeats: false, content: "custom.task", page_size: nil} = Tree.node(tree, "bTable")
      # A fixed number of rows is the table's page.
      assert %{page_size: 2} = Tree.node(tree, "bFixed")

      assert Tree.cell(tree, "bRowTitle") == "bTable"
      assert Tree.cell(tree, "bRankText") == "bTable"
      assert Tree.cell(tree, "bHeadTitleText") == nil
      assert Tree.cell(tree, "bTable") == nil
      assert Tree.cell(tree, "bRow", true) == "bTable"
    end
  end

  describe "page data" do
    test "a table's data source is a list; its row's elements are per row", %{page_data: pd} do
      assert %{kind: :list, cell: nil, type: "list.custom.task", residue: []} =
               source(pd, "bTable", :list)

      assert %{page_size: 2} = source(pd, "bFixed", :list)
      assert %{cell: "bTable", residue: []} = source(pd, "bRankGroup", :group)
      assert %{cell: "bTable", holder: "bTagDef"} = source(pd, "bRowTag", :instance)
      assert %{cell: "bTable", residue: []} = source(pd, "bRowTag", :param)
      # A table with no data source has none.
      refute source(pd, "bStatic", :list)
      assert [_ | _] = source(pd, "bUnloaded", :list).residue
    end

    test "Current row's thing is the table's cell; in its header it is unresolved",
         %{spec: spec} do
      read = fn input, cell -> Spec.read(spec, "bHome", input, cell) end
      assert read.({:cell_thing, %{"element" => "bTable"}}, "bTable") == {:cell, "bTable"}

      assert [%{element: "bRowTag", cell: "bTable", residue: []}] =
               spec
               |> Spec.data("bHome")
               |> Enum.filter(&(&1.element == "bRowTag" and &1.kind == :instance))

      assert %{"bRowTag" => %{cell: "bTable", holder: "bTagDef", residue: []}} = spec.cells
    end

    test "a workflow in a table's row is residue; one in its header runs", %{spec: spec} do
      workflow = fn id -> Enum.find(spec.surfaces["bHome"].workflows, &(&1.workflow == id)) end
      assert %{residue: [%{reason: :trigger_in_runtime_template} | _]} = workflow.("wPick")
      # A click in the header, hiding an element of a static table.
      assert %{residue: [], blocked_by: []} = workflow.("wHead")
    end

    test "only a table's repeated row is a runtime template; its parts are not residue" do
      app = app()
      {:ok, frontend} = BubbleEx.Frontend.normalize(app)
      templates = BubbleEx.Plan.Residue.runtime_template_ids(frontend)

      for id <- ~w(bRow bCellTitle bRowTitle bRowTag bPick), do: assert(templates[id] == "bTable")

      for id <- ~w(bTable bHead bHeadBtn bHeadTag bColNote bStaticC1Text bStaticTag bFixedA),
          do: refute(Map.has_key?(templates, id))

      {:ok, model} = Model.build(app)
      {:ok, index} = Index.build(app, model: model)

      parts =
        for %{reason: :runtime_container, subject: "element:" <> id} <-
              BubbleEx.Plan.Residue.frontend(frontend, index),
            do: id

      assert parts == []
    end
  end

  describe "rendering" do
    test "an HTML table: columns, a header row, a row per item", %{files: files} do
      page = files[@page]

      assert page =~ ~r/<div data-bubble-id="bTable" class="[^"]*overflow-auto[^"]*">\s*<table/
      assert page =~ ~r/<colgroup>\s*<col data-bubble-id="bColTitle" class="[^"]*min-w-\[160px\]/
      assert page =~ ~r/<col data-bubble-id="bColNote" [^>]*hidden/
      assert page =~ ~r/<thead>\s*<tr data-bubble-id="bHead"/

      assert page =~
               ~s|:for={{cell_btable, cell_btable_i} <- Bubble.cells(@bubble_data, "", "bTable")}|

      assert page =~ ~s|id={Bubble.cell_id("", "bTable", cell_btable, cell_btable_i)}|
      assert page =~ "{text_browtitle(cell_btable)}"
      assert page =~ ~s|Bubble.data(@bubble_data, "", "bRankGroup", cell_btable_i)|
      # The hidden column's cells, in every row; a cell's own visibility
      # conditionals win over it, loudly.
      assert page =~ ~r/<th data-bubble-id="bHeadNote" [^>]*hidden/

      assert page =~
               ~r/data-bubble-id="bCellNote"\s+class="relative"\s+hidden=\{\s*!visible_bcellnote/

      assert page =~
               "TODO(bubble:bCellNote) its column is hidden on page load; its own visibility conditionals decide"

      # A column's minimum width is its cells' content's.
      assert page =~
               ~r/<th data-bubble-id="bHeadTitle" class="relative" scope="col">\s*<div class="[^"]*min-w-\[160px\]/

      # Header and static rows render once: their instances are the page's.
      assert page =~ ~s(scope="bHeadTag")
      assert page =~ ~s(scope="bStaticTag")
      assert page =~ ~s|phx-click={Bubble.push("click", "", "bHeadBtn")}|

      assert files["lib/shop_web/live/index_live/workflows.ex"] =~
               ~r/@instances \[\s*\{"bHeadTag", ShopWeb.Reusables.Tag.Workflows\},\s*\{"bStaticTag", ShopWeb.Reusables.Tag.Workflows\}\s*\]/

      # A reusable instance in a row: the row's scope.
      assert page =~ ~s|Bubble.cell_scope("", "bTable", cell_btable, cell_btable_i)|
      # The page accepts events in a row's instance only in the scopes of
      # the rows it read (WTF-494).
      assert files["lib/shop_web/live/index_live/workflows.ex"] =~
               ~s|@cells [{"bTable", [{"bRowTag", ShopWeb.Reusables.Tag.Workflows}]}]|

      # A row reference in the header: marked, never empty silently.
      assert page =~ "TODO(bubble:bHeadRowRef) text: dynamic value not compiled"
    end

    test "a static table renders its rows; one whose list does not load is marked",
         %{files: files} do
      page = files[@page]
      [static] = Regex.run(~r/<div data-bubble-id="bStatic".*?<\/table>/s, page)
      refute static =~ "<thead>"
      refute static =~ ":for"
      assert static =~ ~r/<tbody>\s*<tr data-bubble-id="bStaticHead"/
      assert static =~ "K: Colour"

      # Its columns render, its repeated row does not, loudly.
      [unloaded] = Regex.run(~r/<div data-bubble-id="bUnloaded".*?<\/table>/s, page)
      assert unloaded =~ "TODO(bubble:bUnloaded) its data source is not loaded"

      assert unloaded =~
               "TODO(bubble:bUnloaded) its repeated row is not rendered: the page does not load its list"

      assert unloaded =~ ~s(<col data-bubble-id="bUnloadedA")
      refute unloaded =~ "bUnloadedRow"
    end

    test "settings, parts and cells it does not lower are marked" do
      app =
        app()
        |> put_in_app(~w(pages index elements bTable properties resizable_columns), true)
        |> put_in_app(~w(pages index elements bTable elements bRow properties sticky), true)
        |> put_in_app(
          ~w(pages index elements bTable elements bRow elements bCellStray),
          %{
            "id" => "bCellStray",
            "type" => "TableCell",
            "properties" => %{"cell_main_axis_id" => "bNoColumn", "order" => 9}
          }
        )
        |> put_in_app(
          ~w(pages index elements bTable elements bColNote properties states_hint),
          1
        )

      page = build(app).files[@page]
      assert page =~ "TODO(bubble:bTable) table setting resizable_columns is not lowered"
      assert page =~ "TODO(bubble:bRow) table setting sticky is not lowered"
      assert page =~ "TODO(bubble:bColNote) table setting states_hint is not lowered"
      assert page =~ "TODO(bubble:bCellStray) its column is not in the table"
      assert page =~ ~s(data-bubble-id="bCellStray")
    end
  end
end
