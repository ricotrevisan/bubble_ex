defmodule BubbleEx.Target.Phoenix.CellClicksTest do
  # WTF-520: clicks and input changes of the page's own elements in
  # repeating group cells (depth 1 and 2), run in the cell the browser's
  # event names. The behavior of the generated app is
  # test/support/target/phoenix/cell_clicks_behavior.exs
  # (scripts/phoenix_compile_check.sh).
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, PageData}
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Workflows.Frontend

  @fixture "test/support/target/phoenix/cell_clicks.json"

  @products ["pages", "products", "elements", "bProducts", "elements"]
  @inner [
    "pages",
    "categories",
    "elements",
    "bCats",
    "elements",
    "bCatBox",
    "elements",
    "bCatProducts",
    "elements"
  ]

  defp app, do: @fixture |> File.read!() |> Jason.decode!()

  defp built(app, privacy \\ :omit) do
    {:ok, model} = Model.build(app)
    {:ok, page_data} = PageData.build(app, model)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: privacy)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    {:ok, lowered} = Frontend.build(app, model, index)

    {:ok, spec} =
      FrontendWorkflows.map(lowered, project,
        namespace: "Shop",
        frontend: frontend,
        page_data: page_data
      )

    %{spec: spec, project: project, frontend: frontend, model: model, index: index}
  end

  defp spec(app, privacy \\ :omit), do: built(app, privacy).spec

  defp files(app) do
    %{spec: spec, project: project, frontend: frontend, model: model, index: index} = built(app)

    {:ok, compiled} =
      BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
        runtime: "Shop.Bubble.Runtime",
        namespace: "Shop"
      )

    {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
    {:ok, workflows} = BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "Shop")

    {:ok, files} =
      Phoenix.render(project,
        module: "Shop",
        frontend: frontend,
        expressions: compiled,
        workflows: workflows,
        frontend_workflows: spec
      )

    files
  end

  defp data(spec, element) do
    spec.surfaces
    |> Enum.flat_map(fn {_id, s} -> s.data end)
    |> Enum.find(&(&1.element == element))
  end

  defp binds(step),
    do: step |> Spec.step_values() |> Enum.flat_map(& &1.bindings) |> Enum.map(& &1.bind)

  defp button(id), do: %{"id" => id, "type" => "Button", "properties" => %{"width" => 30}}

  defp clicked(id, element, actions),
    do: %{
      "id" => id,
      "type" => "ButtonClicked",
      "properties" => %{"element_id" => element},
      "actions" =>
        actions |> Enum.with_index() |> Map.new(fn {a, i} -> {Integer.to_string(i), a} end)
    }

  describe "binding" do
    test "a row's click runs in its cell: the detail group outside the list is page data" do
      spec = spec(app())
      w = Spec.workflow(spec, "bProductsPage", "wShow")

      assert %{cell: "bProducts", residue: [], data?: true} = w
      assert Spec.wired?(w) and Spec.native?(w)
      assert [%{op: :display_data, residue: [], args: %{cell?: false}} = step] = w.steps
      assert binds(step) == [{:cell, "bProducts"}]

      # Event-driven: empty until the click, read from what it showed.
      assert %{read: :displayed, residue: []} = data(spec, "bDetail")
    end

    test "an input in a row is tracked per cell; its change reads that cell's value and thing" do
      spec = spec(app())

      assert spec.surfaces["bProductsPage"].cell_inputs == %{
               "bQty" => %{type: :number, cell: "bProducts"}
             }

      # Not one of the page's own inputs: those are kept once.
      assert spec.surfaces["bProductsPage"].inputs == %{}

      w = Spec.workflow(spec, "bProductsPage", "wQty")
      assert %{cell: "bProducts", residue: [], kind: :input_change} = w
      assert [%{op: :update, residue: []} = step] = w.steps

      assert Enum.sort(binds(step)) == [
               {:cell, "bProducts"},
               {:cell_input, %{cell: "bProducts", element: "bQty"}}
             ]
    end

    test "a nested cell's click reads the inner cell's thing and the outer cell's group" do
      spec = spec(app())
      w = Spec.workflow(spec, "bCategoriesPage", "wNestPick")

      assert %{cell: "bCatProducts", residue: []} = w
      assert [show, set] = w.steps
      assert binds(show) == [{:cell, "bCatProducts"}]
      assert binds(set) == [{:outer_cell_data, "bCatBox"}]
      assert %{read: :displayed, residue: []} = data(spec, "bNestDetail")
    end

    test "a refused workflow in a row is still wired: the runtime refuses it, loudly" do
      w = Spec.workflow(spec(app()), "bProductsPage", "wRefuse")

      assert Spec.wired?(w)
      refute Spec.native?(w)
      assert w.cell == "bProducts"
    end

    test "with enforced privacy, the same events are wired" do
      spec = spec(app(), :enforced)

      for {surface, id} <- [
            {"bProductsPage", "wShow"},
            {"bProductsPage", "wQty"},
            {"bCategoriesPage", "wNestPick"}
          ] do
        assert %{residue: [], cell: cell} = Spec.workflow(spec, surface, id)
        assert is_binary(cell)
      end

      assert %{read: :displayed, residue: []} = data(spec, "bDetail")
    end

    test "a third level, or a runtime container in the cell, stays a trigger in a runtime template" do
      deep = %{
        "id" => "bDeep",
        "type" => "RepeatingGroup",
        "properties" => %{
          "group_type" => "custom.product",
          "rows" => 5,
          "width" => 300,
          "height" => 100,
          "data_source" => %{
            "type" => "Search",
            "properties" => %{
              "type_to_find" => "custom.product",
              "sort_field" => "name_text",
              "descending" => false,
              "ignore_empty_constraints" => false
            }
          }
        },
        "elements" => %{"bDeepBtn" => button("bDeepBtn")}
      }

      app =
        app()
        |> put_in(@inner ++ ["bDeep"], deep)
        |> put_in(
          ["pages", "categories", "workflows", "wDeep"],
          clicked("wDeep", "bDeepBtn", [
            %{
              "id" => "aDeep1",
              "type" => "DisplayGroupData",
              "properties" => %{
                "element_id" => "bNestDetail",
                "data_source" => %{"type" => "CurrentDataItem"}
              }
            }
          ])
        )

      spec = spec(app)

      assert %{cell: nil, residue: [%{reason: :trigger_in_runtime_template} | _]} =
               Spec.workflow(spec, "bCategoriesPage", "wDeep")

      # bNestDetail may now be set by an event the page never triggers:
      # not read as empty.
      refute data(spec, "bNestDetail")

      # The nested click is still wired.
      assert %{cell: "bCatProducts", residue: []} =
               Spec.workflow(spec, "bCategoriesPage", "wNestPick")
    end

    test "a cell's input whose first value is dynamic is not tracked: its change is residue" do
      app =
        put_in(app(), @products ++ ["bQty", "properties", "value"], %{
          "type" => "CurrentDataItem",
          "next" => %{"type" => "Message", "name" => "qty_number"}
        })

      spec = spec(app)
      assert spec.surfaces["bProductsPage"].cell_inputs == %{}

      assert %{residue: [%{reason: :unavailable_input, detail: %{inputs: ["input_value"]}}]} =
               Spec.workflow(spec, "bProductsPage", "wQty")
    end

    test "a row's click that only shows a page element runs in the browser" do
      app =
        app()
        |> put_in(@products ++ ["bPeek"], button("bPeek"))
        |> put_in(
          ["pages", "products", "workflows", "wPeek"],
          clicked("wPeek", "bPeek", [
            %{
              "id" => "aPeek1",
              "type" => "ShowElement",
              "properties" => %{"element_id" => "bDetail"}
            }
          ])
        )

      w = Spec.workflow(spec(app), "bProductsPage", "wPeek")
      assert %{client?: true, cell: "bProducts", residue: []} = w

      files = files(app)
      module = files["lib/shop_web/live/products_live/workflows.ex"]
      refute module =~ ~s("bPeek" =>)

      heex = files["lib/shop_web/live/products_live.html.heex"]
      assert squash(heex) =~ ~s|phx-click={Workflows.wf_w_peek("")}|
    end

    test "master-detail without page data: the cell's thing is unavailable, nothing is wired" do
      app = app()
      %{project: project, frontend: frontend, model: model, index: index} = built(app)
      {:ok, lowered} = Frontend.build(app, model, index)

      {:ok, spec} =
        FrontendWorkflows.map(lowered, project, namespace: "Shop", frontend: frontend)

      assert %{cell: nil, residue: [%{reason: :trigger_in_runtime_template} | _]} =
               Spec.workflow(spec, "bProductsPage", "wShow")
    end
  end

  describe "printed" do
    test "the surface lists cell events apart, with their repeating group" do
      files = files(app())
      module = files["lib/shop_web/live/products_live/workflows.ex"]

      assert module =~ "clicks: %{},"
      assert module =~ ~s("bShow" => {"bProducts", ["wShow"]})
      assert module =~ ~s(cell_changes: %{"bQty" => {"bProducts", ["wQty"]}})
      assert module =~ ~s(cell_inputs: %{"bQty" => {"bProducts", {:number, nil}}})
      assert module =~ ~s(cell_lists: [{"bProducts", nil}])
      assert module =~ ~s|BubbleWorkflows.cell_input(ctx, "bQty")|

      nested = files["lib/shop_web/live/categories_live/workflows.ex"]
      assert nested =~ ~s(cell_clicks: %{"bNestPick" => {"bCatProducts", ["wNestPick"]}})
      assert nested =~ ~s(cell_lists: [{"bCatProducts", "bCats"}])
      assert nested =~ ~s|BubbleWorkflows.outer_cell_data(ctx, "bCatBox")|
    end

    test "a row's button and input carry the cell's scope; the detail group is outside" do
      files = files(app())
      heex = squash(files["lib/shop_web/live/products_live.html.heex"])
      cell = ~s|Bubble.cell_scope("","bProducts",cell_bproducts,cell_bproducts_i)|

      assert heex =~ ~s|phx-click={Bubble.push("click",#{cell},"bShow")}|
      assert heex =~ ~s|phx-value-scope={#{cell}}|
      assert heex =~ ~s|value={Bubble.input(@bubble_inputs,#{cell},"bQty")}|
      assert heex =~ ~s|id={"bubble-input-\#{#{cell}}-"<>"bQty"}|

      nested = squash(files["lib/shop_web/live/categories_live.html.heex"])

      assert nested =~
               ~s|Bubble.push("click",Bubble.cell_scope(Bubble.cell_scope("","bCats",cell_bcats,cell_bcats_i),"bCatProducts",cell_bcatproducts,cell_bcatproducts_i),"bNestPick")|

      runtime = files["lib/shop_web/bubble_workflows.ex"]
      assert runtime =~ "def put_page_cells(socket, page)"
      assert runtime =~ "defp page_cell(socket, key)"

      data = files["lib/shop_web/bubble_data.ex"]
      assert data =~ "BubbleWorkflows.put_page_cells(page)"
    end

    test "a text in the row reads the row's input value, in the cell's scope" do
      shows =
        %{
          "id" => "bQtyEcho",
          "type" => "Text",
          "properties" => %{
            "width" => 300,
            "height" => 40,
            "text" => %{
              "type" => "TextExpression",
              "entries" => %{
                "0" => "Typed: ",
                "1" => %{
                  "type" => "GetElement",
                  "properties" => %{"element_id" => "bQty"},
                  "next" => %{"type" => "Message", "name" => "get_data"}
                }
              }
            }
          }
        }

      heex =
        app()
        |> put_in(@products ++ ["bQtyEcho"], shows)
        |> files()
        |> Map.fetch!("lib/shop_web/live/products_live.html.heex")
        |> squash()

      assert heex =~
               ~s|Bubble.input(@bubble_inputs,Bubble.cell_scope("","bProducts",cell_bproducts,cell_bproducts_i),"bQty")|

      refute heex =~ "TODO(bubble:bQtyEcho)"
    end
  end

  defp squash(text), do: String.replace(text, ~r/\s+/, "")
end
