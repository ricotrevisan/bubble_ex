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

    test "a group only a refused row workflow sets stays unloaded, loudly" do
      group = %{
        "id" => "bDetail2",
        "type" => "Group",
        "properties" => %{"width" => 300, "height" => 40, "group_type" => "custom.product"},
        "elements" => %{
          "bDetail2Name" => %{
            "id" => "bDetail2Name",
            "type" => "Text",
            "properties" => %{
              "width" => 300,
              "height" => 40,
              "text" => %{
                "type" => "TextExpression",
                "entries" => %{
                  "0" => %{
                    "type" => "ElementParent",
                    "next" => %{"type" => "Message", "name" => "name_text"}
                  }
                }
              }
            }
          }
        }
      }

      show = %{
        "id" => "aBoth1",
        "type" => "DisplayGroupData",
        "properties" => %{
          "element_id" => "bDetail2",
          "data_source" => %{"type" => "CurrentDataItem"}
        }
      }

      animate = %{
        "id" => "aBoth2",
        "type" => "AnimateElement",
        "properties" => %{"element_id" => "bDetail2"}
      }

      app =
        app()
        |> put_in(["pages", "products", "elements", "bDetail2"], group)
        |> put_in(@products ++ ["bBoth"], button("bBoth"))
        |> put_in(
          ["pages", "products", "workflows", "wBoth"],
          clicked("wBoth", "bBoth", [show, animate])
        )

      spec = spec(app)
      w = Spec.workflow(spec, "bProductsPage", "wBoth")

      # Wired (the runtime refuses it with the notice), but it never sets
      # bDetail2: not read as empty where Bubble would fill it.
      assert Spec.wired?(w) and not Spec.native?(w)
      refute data(spec, "bDetail2")

      # Without the action it does not lower, it runs, and bDetail2 loads.
      app =
        put_in(
          app,
          ["pages", "products", "workflows", "wBoth"],
          clicked("wBoth", "bBoth", [show])
        )

      assert %{read: :displayed, residue: []} = data(spec(app), "bDetail2")
    end

    test "a list of options is keyed by its option: its click and input are wired per cell" do
      for privacy <- [:omit, :enforced] do
        spec = spec(app(), privacy)

        assert Spec.option_list?(spec, "bStatuses")
        assert Spec.option_lists(spec) == ["bStatuses"]
        refute Spec.option_list?(spec, "bProducts")

        w = Spec.workflow(spec, "bStatusesPage", "wPickStatus")
        assert %{cell: "bStatuses", residue: []} = w
        assert Spec.wired?(w) and Spec.native?(w)
        assert [%{op: :display_data, residue: []} = step] = w.steps
        assert binds(step) == [{:cell, "bStatuses"}]

        assert spec.surfaces["bStatusesPage"].cell_inputs == %{
                 "bStatusNote" => %{type: :text, cell: "bStatuses"}
               }

        assert %{cell: "bStatuses", residue: [], kind: :input_change} =
                 Spec.workflow(spec, "bStatusesPage", "wStatusNote")

        # Event-driven: empty until a row's click.
        assert %{read: :displayed, residue: []} = data(spec, "bStatusDetail")
      end
    end

    test "an option-typed list whose source computes texts stays keyed by position: unwired" do
      app =
        app()
        |> put_in(["user_types", "board", "fields", "labels_list_text"], %{
          "display" => "Labels",
          "value" => "list.text"
        })
        |> put_in(
          [
            "pages",
            "statuses",
            "elements",
            "bStatuses",
            "properties",
            "data_source",
            "next",
            "next",
            "name"
          ],
          "labels_list_text"
        )

      spec = spec(app)

      # Typed as statuses, but holding the board's texts: never value-keyed,
      # so no user text reaches a scope or a DOM attribute.
      refute Spec.option_list?(spec, "bStatuses")
      assert Spec.option_lists(spec) == []

      for id <- ["wPickStatus", "wStatusNote", "wMark"] do
        assert %{cell: nil, residue: [%{reason: :trigger_in_runtime_template} | _]} =
                 Spec.workflow(spec, "bStatusesPage", id)
      end

      refute Map.has_key?(spec.surfaces["bStatusesPage"].cell_inputs, "bStatusNote")

      files = files(app)
      heex = squash(files["lib/shop_web/live/statuses_live.html.heex"])
      assert heex =~ ~s|<-Bubble.cells(@bubble_data,"","bStatuses")}|
      refute heex =~ "keyed_cells"
      assert files["lib/shop_web/components/bubble.ex"] =~ "@option_lists MapSet.new([])"
    end

    test "a list of options in another list's cell is keyed by its option in the outer cell" do
      statuses = get_in(app(), ["pages", "statuses", "elements", "bStatuses"])

      inner =
        statuses
        |> Map.put("id", "bCatStatuses")
        |> Map.put("elements", %{"bCatStatusBtn" => button("bCatStatusBtn")})

      app =
        app()
        |> put_in(["pages", "categories", "elements", "bCats", "elements", "bCatStatuses"], inner)
        |> put_in(
          ["pages", "categories", "workflows", "wCatStatus"],
          clicked("wCatStatus", "bCatStatusBtn", [
            %{
              "id" => "aCatStatus1",
              "type" => "SetCustomState",
              "properties" => %{
                "element_id" => "bCategoriesPage",
                "custom_state" => "custom.t_",
                "value" => 1
              }
            }
          ])
        )

      spec = spec(app)
      assert Spec.option_list?(spec, "bCatStatuses")
      assert %{cell: "bCatStatuses"} = Spec.workflow(spec, "bCategoriesPage", "wCatStatus")

      heex = squash(files(app)["lib/shop_web/live/categories_live.html.heex"])

      assert heex =~
               ~s|{cell_bcatstatuses,cell_bcatstatuses_i,cell_bcatstatuses_n}<-Bubble.keyed_cells(@bubble_data,"","bCatStatuses",cell_bcats_i)|

      assert heex =~
               ~s|Bubble.cell_scope(Bubble.cell_scope("","bCats",cell_bcats,cell_bcats_i),"bCatStatuses",cell_bcatstatuses,cell_bcatstatuses_i,cell_bcatstatuses_n)|
    end

    test "a list of texts has cells by position only: its events stay unwired" do
      # Unlike options (unique within their set), texts have no key that
      # names the same item once the list changes: only a position.
      texts = %{
        "id" => "bTags",
        "type" => "RepeatingGroup",
        "properties" => %{
          "group_type" => "text",
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
            },
            "next" => %{"type" => "Message", "name" => "name_text"}
          }
        },
        "elements" => %{
          "bTagBtn" => button("bTagBtn"),
          "bTagIn" => %{"id" => "bTagIn", "type" => "Input", "properties" => %{"width" => 100}}
        }
      }

      app =
        app()
        |> put_in(["pages", "products", "elements", "bTags"], texts)
        |> put_in(
          ["pages", "products", "workflows", "wTag"],
          clicked("wTag", "bTagBtn", [
            %{
              "id" => "aTag1",
              "type" => "SetCustomState",
              "properties" => %{
                "element_id" => "bProductsPage",
                "custom_state" => "custom.t_",
                "value" => 1
              }
            }
          ])
        )

      spec = spec(app)

      # The list loads; its cells are keyed by position.
      assert %{residue: []} = data(spec, "bTags")

      assert %{cell: nil, residue: [%{reason: :trigger_in_runtime_template} | _]} =
               Spec.workflow(spec, "bProductsPage", "wTag")

      refute Map.has_key?(spec.surfaces["bProductsPage"].cell_inputs, "bTagIn")
    end

    test "a reusable element's own list: its row's click runs in its surface's cell" do
      spec = spec(app())

      assert %{cell: "bPickList", residue: []} = w = Spec.workflow(spec, "bPickerDef", "wPickBtn")
      assert Spec.wired?(w) and Spec.native?(w)
      assert %{read: :displayed, residue: []} = data(spec, "bPicked")

      module = files(app())["lib/shop_web/components/reusables/product_picker/workflows.ex"]
      assert module =~ ~s(cell_lists: [{"bPickList", nil}])
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

  describe "printed, a list of options" do
    test "its cells are read with each option's occurrence and keyed by it" do
      files = files(app())
      heex = squash(files["lib/shop_web/live/statuses_live.html.heex"])
      key = "cell_bstatuses,cell_bstatuses_i,cell_bstatuses_n"
      cell = ~s|Bubble.cell_scope("","bStatuses",#{key})|

      assert heex =~ ~s|:for={{#{key}}<-Bubble.keyed_cells(@bubble_data,"","bStatuses")}|
      assert heex =~ ~s|id={Bubble.cell_id("","bStatuses",#{key})}|
      assert heex =~ ~s|phx-click={Bubble.push("click",#{cell},"bPickStatus")}|
      assert heex =~ ~s|value={Bubble.input(@bubble_inputs,#{cell},"bStatusNote")}|

      # A list of things keeps its cells as before.
      products = squash(files["lib/shop_web/live/products_live.html.heex"])
      assert products =~ ~s|<-Bubble.cells(@bubble_data,"","bProducts")}|

      module = files["lib/shop_web/live/statuses_live/workflows.ex"]
      assert module =~ ~s("bPickStatus" => {"bStatuses", ["wPickStatus"]})
      assert module =~ ~s("bMark" => {"bStatuses", ["wMark"]})

      assert module =~
               ~s(@cells [{"bStatuses", [{"bStatusChip", ShopWeb.Reusables.StatusChip.Workflows}]}])

      assert module =~ ~s(cell_lists: [{"bStatuses", nil}])

      assert files["lib/shop_web/components/bubble.ex"] =~
               ~s|@option_lists MapSet.new(["bStatuses"])|

      # The list is read from the first board's field (a query of boards,
      # no source of type board): boards publish their changes, so a
      # reordered list reaches the page.
      assert module =~ ~s(query_topics: ["Board"])
      board = files["lib/shop/board.ex"]
      assert board =~ "notifiers: [Ash.Notifier.PubSub]"
      assert board =~ ~s(publish_all :update, ["Board"])
    end
  end

  # The generated `<Web>.Bubble` cell keys (WTF-520), compiled on its own.
  describe "cell keys" do
    setup do
      module = OptionCellKeysWeb.Bubble

      # Under a name of its own: only this module is compiled (it calls
      # the others at runtime only; Ash's one struct is a stand-in here).
      unless Code.ensure_loaded?(module) do
        Code.compile_string("defmodule OptionCellKeysWeb.NotLoaded, do: defstruct([])")

        source =
          app()
          |> files()
          |> Map.fetch!("lib/shop_web/components/bubble.ex")
          |> String.replace("defmodule ShopWeb.Bubble do", "defmodule #{inspect(module)} do")
          |> String.replace("%Ash.NotLoaded{}", "%OptionCellKeysWeb.NotLoaded{}")

        # The runtime modules it calls are not compiled here: no warnings.
        ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(source) end)
      end

      %{bubble: module}
    end

    defp list(values), do: %{{"", "bStatuses"} => values, {"", "bTags"} => values}

    # The scopes of a statuses list's cells, with their option.
    defp scopes(b, values) do
      for {v, i, n} <- b.keyed_cells(list(values), "", "bStatuses"),
          into: %{},
          do: {b.cell_scope("", "bStatuses", v, i, n), v}
    end

    test "an option's cell is its value, escaped, and, when listed more than once, its occurrence and count",
         %{bubble: b} do
      cells = b.keyed_cells(list(~w(todo doing todo done)), "", "bStatuses")

      assert cells == [
               {"todo", 1, {1, 2}},
               {"doing", 2, {1, 1}},
               {"todo", 3, {2, 2}},
               {"done", 4, {1, 1}}
             ]

      assert Enum.map(cells, fn {v, i, n} -> b.cell_scope("", "bStatuses", v, i, n) end) == [
               "bStatuses~2~4todo~51~62",
               "bStatuses~2~4doing",
               "bStatuses~2~4todo~52~62",
               "bStatuses~2~4done"
             ]

      assert Enum.all?(cells, fn {v, _i, n} -> b.keyed_cell?(v, n) end)
      assert b.cell_id("", "bStatuses", "todo", 3, {2, 2}) == "bubble-cell--bStatuses-o-todo-2-2"
      assert b.cell_id("", "bStatuses", "done", 4, {1, 1}) == "bubble-cell--bStatuses-o-done"

      # Escaped as an ID is: never an instance's scope or another cell's.
      assert b.cell_scope("p", "bStatuses", "a-b~5", 1, {1, 1}) == "p-bStatuses~2~4a~1b~05"
    end

    test "a reordered list keeps each option's scope", %{bubble: b} do
      assert scopes(b, ~w(todo doing todo done)) == scopes(b, ~w(done todo doing todo))
    end

    test "a change in an option's count gives every cell of that value a new scope", %{bubble: b} do
      before = scopes(b, ~w(todo doing todo done))

      # One "todo" removed: the one left is not either old "todo" cell,
      # so nothing kept for them (inputs, states) is carried over.
      shrunk = scopes(b, ~w(doing todo done))
      assert shrunk["bStatuses~2~4todo"] == "todo"
      refute Map.has_key?(before, "bStatuses~2~4todo")
      refute Map.has_key?(shrunk, "bStatuses~2~4todo~51~62")
      refute Map.has_key?(shrunk, "bStatuses~2~4todo~52~62")

      # A second "todo" added: the first one's scope changes too.
      grown = scopes(b, ~w(todo doing done todo))
      refute Map.has_key?(grown, "bStatuses~2~4todo")

      # Other options keep theirs.
      for scope <- ["bStatuses~2~4doing", "bStatuses~2~4done"],
          do: assert(before[scope] == shrunk[scope] and shrunk[scope] == grown[scope])

      # Whatever scope survives names the same option.
      for {scope, v} <- shrunk, Map.has_key?(before, scope), do: assert(before[scope] == v)
    end

    test "a list of texts, or an empty option, is keyed by position: no event per cell", %{
      bubble: b
    } do
      assert [{"todo", 1, nil}, {"doing", 2, nil}] =
               cells = b.keyed_cells(list(~w(todo doing)), "", "bTags")

      assert b.cell_scope("", "bTags", "todo", 1, nil) == "bTags~2~31"
      refute Enum.any?(cells, fn {v, _i, n} -> b.keyed_cell?(v, n) end)

      assert [{"todo", 1, {1, 1}}, {nil, 2, nil}, {"", 3, nil}] =
               b.keyed_cells(list(["todo", nil, ""]), "", "bStatuses")

      refute b.keyed_cell?(nil, nil)
      refute b.keyed_cell?("", nil)
      refute b.keyed_cell?("", {1, 1})
      # A bare occurrence (the shape before counts) is not a key.
      refute b.keyed_cell?("todo", 1)
      assert b.cell_scope("", "bStatuses", nil, 2, nil) == "bStatuses~2~32"

      # A thing is keyed by its ID, as before.
      assert b.keyed_cell?(%{id: "1x2"}, nil)
      assert b.cell_scope("", "bProducts", %{id: "1x2"}, 4) == "bProducts~21x2"
    end
  end

  defp squash(text), do: String.replace(text, ~r/\s+/, "")
end
