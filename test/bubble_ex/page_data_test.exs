defmodule BubbleEx.PageDataTest do
  # WTF-420: the data a page shows, lowered stack-neutrally, bound to Ash
  # reads for LiveView and printed with the pages. The behavior of the
  # generated app is test/support/target/phoenix/page_data_behavior.exs
  # (scripts/phoenix_compile_check.sh).
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, PageData}
  alias BubbleEx.Expression.IR
  alias BubbleEx.PageData.Source
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Workflows.Frontend

  @fixture "test/support/target/phoenix/page_data.json"

  defp app, do: @fixture |> File.read!() |> Jason.decode!()

  defp build(app, opts \\ []) do
    {:ok, model} = Model.build(app)
    {:ok, page_data} = PageData.build(app, model, opts)
    {model, page_data}
  end

  defp spec(app, opts \\ []) do
    {model, page_data} = build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    {:ok, lowered} = Frontend.build(app, model, index)

    {:ok, spec} =
      FrontendWorkflows.map(
        lowered,
        project,
        [namespace: "Shop", frontend: frontend] ++
          if(Keyword.get(opts, :page_data, true), do: [page_data: page_data], else: [])
      )

    {spec, project, frontend, app, model}
  end

  defp source(page_data, element), do: Enum.find(page_data.sources, &(&1.element == element))

  defp search_pred(%Source{
         value: %{ir: %IR{op: :sort, args: [%IR{op: :search, args: [_, p]} | _]}}
       }),
       do: p

  defp data(spec, element) do
    spec.surfaces
    |> Enum.flat_map(fn {_id, s} -> s.data end)
    |> Enum.find(&(&1.element == element))
  end

  describe "the stack-neutral sources" do
    test "a page's thing, groups and a repeating group, with page sizes" do
      {_model, pd} = build(app())

      assert %Source{kind: :page_thing, type: "custom.task", value: nil, residue: []} =
               source(pd, "bTaskPage")

      assert %Source{kind: :list, type: "list.custom.task", page_size: 3, cell: nil} =
               list = source(pd, "bList")

      assert %{op: :sort} = list.value.ir
      assert %Source{kind: :group, type: "custom.task"} = source(pd, "bFirstOpen")
      assert %Source{kind: :group, type: "custom.project"} = source(pd, "bProjGroup")

      assert PageData.inputs(source(pd, "bProjGroup")) == [
               {:page_thing, %{"page" => "bTaskPage"}}
             ]

      # The shown page's four (WTF-492) included.
      assert PageData.coverage(pd)["sources"] == %{"total" => 13, "native" => 13, "residue" => 0}
      assert {:ok, ^pd} = PageData.build(app(), elem(build(app()), 0))
    end

    # WTF-478, replayed on Bubble (2026-10-01): on a page, an empty
    # constraint value matches nothing unless the search states
    # `ignore_empty_constraints: true`, which drops the constraint.
    test "an empty constraint value: dropped when the search ignores it, else matches nothing" do
      dropped = fn pd -> search_pred(source(pd, "bList")) end

      {_model, pd} = build(app())
      assert %IR{op: :or, args: [%IR{op: :is_empty}, %IR{op: :text_contains}]} = dropped.(pd)

      assert %IR{op: :and, args: [%IR{op: :not, args: [%IR{op: :is_empty}]}, _]} =
               search_pred(source(pd, "bStrict"))

      for options <- [
            &Map.delete(&1, "ignore_empty_constraints"),
            &Map.put(&1, "ignore_empty_constraints", false)
          ] do
        app =
          update_in(
            app(),
            ["pages", "index", "elements", "bList", "properties", "data_source", "properties"],
            options
          )

        # Compiled, not residue; the caller's default does not change it.
        for default <- [nil, true, false] do
          {_model, pd} = build(app, ignore_empty_constraints: default)
          assert source(pd, "bList").residue == []
          assert pd.diagnostics == []

          assert %IR{
                   op: :and,
                   args: [%IR{op: :not, args: [%IR{op: :is_empty}]}, %IR{op: :text_contains}]
                 } =
                   dropped.(pd)
        end
      end
    end

    test "a search constrained or sorted on a field a privacy rule keeps out of searches is residue" do
      rules = fn non_filterable ->
        %{
          "everyone" => %{
            "permissions" => %{
              "search_for" => true,
              "view_all" => true,
              "non_filterable_fields" => non_filterable
            }
          }
        }
      end

      restricted =
        put_in(app(), ["user_types", "task", "privacy_role"], rules.(%{"0" => "title_text"}))

      {_model, pd} = build(restricted)

      assert [%{reason: :search_field_restricted, detail: %{fields: ["title_text"]}}] =
               source(pd, "bList").residue

      assert :page_data_residue in Enum.map(pd.diagnostics, & &1.code)

      # another field restricted: the search loads
      other =
        put_in(app(), ["user_types", "task", "privacy_role"], rules.(%{"0" => "done_boolean"}))

      {_model, pd} = build(other)
      assert source(pd, "bList").residue == []
    end

    test "a type of content that is not a data type is residue" do
      app = put_in(app(), ["pages", "task", "properties", "page_item_type"], "text")
      {_model, pd} = build(app)

      assert [%{reason: :unsupported_option, detail: %{options: ["page_item_type"]}}] =
               source(pd, "bTaskPage").residue
    end
  end

  describe "bound to Ash and LiveView" do
    test "a normalized list page source loads through its decided join relationship" do
      app = BubbleEx.Test.DecidedFixture.app(:join)

      app =
        put_in(app, ["pages", "pgHome", "elements", "rgJoinedTasks"], %{
          "id" => "rgJoinedTasks",
          "type" => "RepeatingGroup",
          "properties" => %{
            "group_type" => "custom.task",
            "data_source" => %{
              "type" => "CurrentPageItem",
              "next" => %{"type" => "Message", "name" => "tasks_list_custom_task"}
            }
          }
        })

      app = put_in(app, ["pages", "pgHome", "properties", "page_item_type"], "custom.project")
      %{applied: applied, decisions_sha256: sha} = BubbleEx.Test.DecidedFixture.build(:join)
      {:ok, model} = Model.build(app)

      {:ok, project} =
        BubbleEx.Target.Ash.map(model, applied, privacy: :omit, decisions_sha256: sha)

      {:ok, page_data} = PageData.build(app, model)
      {:ok, index} = Index.build(app, model: model)
      {:ok, frontend} = BubbleEx.Frontend.normalize(app)
      {:ok, lowered} = Frontend.build(app, model, index)

      {:ok, spec} =
        FrontendWorkflows.map(lowered, project,
          namespace: "Shop",
          frontend: frontend,
          page_data: page_data
        )

      assert %{read: {:value, compiled}, residue: [], resource: "Task"} =
               data(spec, "rgJoinedTasks")

      assert compiled.source =~ "Enum.map(get_in(page_thing_phome, [Access.key(:tasks)])"
      assert [%{bind: {:data, %{element: "pHome"}}, loads: [["tasks"]]}] = compiled.bindings
      assert %{read: :url_thing, resource: "Project", residue: []} = data(spec, "pHome")

      {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
      {:ok, workflows} = BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "Shop")

      {:ok, files} =
        Phoenix.render(project,
          module: "Shop",
          frontend: frontend,
          workflows: workflows,
          frontend_workflows: spec
        )

      page =
        Enum.find_value(files, fn {path, source} ->
          if String.ends_with?(path, "/workflows.ex") and source =~ "rgJoinedTasks", do: source
        end)

      assert is_binary(page)

      assert page =~
               ~s|BubbleData.load_value(BubbleWorkflows.data(ctx, [], "pHome"), [["tasks"]], ctx)|

      assert files["lib/shop_web/bubble_data.ex"] =~
               "Runtime.load_page(value, loads, Runtime.root(nil, ctx.actor), related_cap())"

      assert page =~ "BubbleData.records("
      assert page =~ "Shop.Task"
    end

    test "value-backed repeating groups pass their page size to the generated loader" do
      {spec, project, frontend, app, model} = spec(app())

      surfaces =
        Map.new(spec.surfaces, fn {id, surface} ->
          {id,
           %{
             surface
             | data:
                 Enum.map(surface.data, fn
                   %{element: "bList"} = d -> %{d | read: {:value, %{source: "[]", bindings: []}}}
                   d -> d
                 end)
           }}
        end)

      {:ok, index} = Index.build(app, model: model)
      {:ok, lowered} = BubbleEx.Workflows.Backend.build(app, model, index)
      {:ok, backend} = BubbleEx.Target.Ash.Workflows.map(lowered, project, namespace: "Shop")

      {:ok, files} =
        Phoenix.render(project,
          module: "Shop",
          frontend: frontend,
          workflows: backend,
          frontend_workflows: %{spec | surfaces: surfaces}
        )

      assert files["lib/shop_web/live/index_live/workflows.ex"] =~
               "BubbleData.records(ctx, Shop.Task, [], true, 3)"
    end

    test "a search is a query with pinned inputs; a thing comes from the URL" do
      {spec, _project, _frontend, _app, _model} = spec(app())

      assert %{read: :url_thing, resource: "Task", residue: []} = data(spec, "bTaskPage")

      assert %{read: {:query, q}, page_size: 3, residue: []} = data(spec, "bList")
      assert q.resource == "Task" and q.take == :all and q.sort == [{"title", :asc}]
      # The input's value and whether it is empty are computed before the query.
      assert [%{var: "pin_1"}, %{var: "pin_2"}] = q.pins
      refute inspect(q.filter.expr) =~ ":arg"

      assert %{read: {:query, %{take: :first}}} = data(spec, "bFirstOpen")
      assert %{kind: :instance, holder: "bCard", residue: []} = data(spec, "bCard1")
      assert %{kind: :instance, holder: "bCard", residue: []} = data(spec, "bCard2")

      assert %{read: {:value, %{bindings: [%{bind: {:data, %{element: "bTaskPage"}}}]}}} =
               data(spec, "bProjGroup")

      # The group after the page's thing it reads.
      assert Enum.map(Spec.data(spec, "bTaskPage"), & &1.element) == ["bTaskPage", "bProjGroup"]

      # With the shown page's (WTF-492): its four sources and the six
      # elements its "Display data" steps set.
      assert FrontendWorkflows.data_coverage(spec)["sources"] == %{
               "total" => 19,
               "wired" => 19,
               "residue" => 0
             }

      # An empty constraint value: dropped in bList, matches nothing in
      # bStrict (WTF-478). Both read the input and its emptiness as pins.
      assert %{read: {:query, strict}, residue: []} = data(spec, "bStrict")
      assert {:or, [{:op, "==", {:pin, "pin_2"}, {:value, true}}, _]} = q.filter.expr

      assert {:and, [{:call, "is_distinct_from", [pin: "pin_2", value: true]}, _]} =
               strict.filter.expr

      assert [%{var: "pin_1"}, %{var: "pin_2", value: %{source: empty}}] = strict.pins
      assert empty =~ "Runtime.empty?("
    end

    test "Bubble's random sort is a random order, limited by the page size (WTF-452)" do
      {spec, project, frontend, app, model} = spec(app())

      assert %{read: {:query, q}, page_size: 2, residue: []} = data(spec, "bRandom")
      assert q.resource == "Task" and q.take == :all and q.sort == [:random]

      {:ok, index} = Index.build(app, model: model)
      {:ok, lowered} = BubbleEx.Workflows.Backend.build(app, model, index)
      {:ok, backend} = BubbleEx.Target.Ash.Workflows.map(lowered, project, namespace: "Shop")

      {:ok, files} =
        Phoenix.render(project,
          module: "Shop",
          frontend: frontend,
          workflows: backend,
          frontend_workflows: spec
        )

      page = files["lib/shop_web/live/index_live/workflows.ex"]
      assert page =~ ~r/\|> BubbleData\.random_sort\(\)\n\s*\|> BubbleData\.read\(ctx, :all, 2\)/
      assert files["lib/shop_web/bubble_data.ex"] =~ "def random_sort(query) do"
      assert files["config/test.exs"] =~ "config :shop, ShopWeb.BubbleData, random_seed: "

      # Another unknown sort field stays uncompiled.
      unknown =
        put_in(
          app(),
          [
            "pages",
            "index",
            "elements",
            "bRandom",
            "properties",
            "data_source",
            "properties",
            "sort_field"
          ],
          "no_such_field_text"
        )

      {spec, _project, _frontend, _app, _model} = spec(unknown)
      assert %{read: nil, residue: [%{reason: :uncompiled_expression}]} = data(spec, "bRandom")
    end

    test "a source reading one that is not loaded is not loaded either" do
      from_list = %{
        "id" => "bFromList",
        "type" => "Group",
        "properties" => %{
          "group_type" => "custom.task",
          "data_source" => %{
            "type" => "GetElement",
            "properties" => %{"element_id" => "bList"},
            "next" => %{
              "type" => "Message",
              "name" => "get_list_data",
              "next" => %{"type" => "Message", "name" => "first_element"}
            }
          }
        }
      }

      app = put_in(app(), ["pages", "index", "elements", "bFromList"], from_list)
      {spec, _project, _frontend, _app, _model} = spec(app)
      assert %{read: {:value, _}, residue: []} = data(spec, "bFromList")

      # The list is not generated (its search has an unmodeled option):
      # the group reading it is not either.
      app =
        update_in(
          app,
          ["pages", "index", "elements", "bList", "properties", "data_source", "properties"],
          &Map.put(&1, "dynamic_sort_field", "x")
        )

      {spec, _project, _frontend, _app, _model} = spec(app)

      assert %{
               read: nil,
               residue: [
                 %{reason: :unavailable_input, detail: %{inputs: ["element_state:get_list_data"]}}
               ]
             } = data(spec, "bFromList")

      assert FrontendWorkflows.data_coverage(spec)["sources"]["wired"] == 17
    end

    test "a repeating group in a repeating group's cell is residue" do
      app =
        update_in(app(), ["pages", "index", "elements", "bList", "elements"], fn els ->
          Map.put(els, "bInner", %{
            "id" => "bInner",
            "type" => "RepeatingGroup",
            "properties" => %{
              "group_type" => "custom.task",
              "data_source" =>
                app()["pages"]["index"]["elements"]["bList"]["properties"]["data_source"]
            }
          })
        end)

      {spec, _project, _frontend, _app, _model} = spec(app)

      assert %{residue: [%{reason: :page_data_in_cell, detail: %{kind: "list"}}]} =
               data(spec, "bInner")
    end

    test "a workflow reading the page's thing is bound to it, and reads stored data" do
      app =
        put_in(app(), ["pages", "task", "workflows"], %{
          "wThing" => %{
            "id" => "wThing",
            "type" => "PageLoaded",
            "actions" => %{
              "0" => %{
                "id" => "aThing1",
                "type" => "OpenURL",
                "properties" => %{
                  "url" => %{
                    "type" => "TextExpression",
                    "entries" => %{
                      "0" => "/task/",
                      "1" => %{
                        "type" => "CurrentPageItem",
                        "next" => %{"type" => "Message", "name" => "title_text"}
                      }
                    }
                  }
                }
              }
            }
          }
        })

      {with_data, _, _, _, _} = spec(app)
      w = Spec.workflow(with_data, "bTaskPage", "wThing")
      assert Spec.native?(w) and w.data?

      {without, _, _, _, _} = spec(app, page_data: false)
      w = Spec.workflow(without, "bTaskPage", "wThing")
      assert [%{reason: :unavailable_input}] = hd(w.steps).residue
    end
  end

  describe "printed" do
    setup do
      {spec, project, frontend, app, model} = spec(app())

      {:ok, compiled} =
        BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
          runtime: "Shop.Bubble.Runtime",
          namespace: "Shop"
        )

      {:ok, index} = Index.build(app, model: model)
      {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
      {:ok, workflows} = BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "Shop")

      {:ok, files} =
        Phoenix.render(project,
          name: "Shop",
          frontend: frontend,
          expressions: compiled,
          workflows: workflows,
          frontend_workflows: spec
        )

      %{files: files}
    end

    test "two reusable instances store data under their own nested scope", %{files: files} do
      index = files["lib/shop_web/live/index_live/workflows.ex"]
      template = files["lib/shop_web/components/reusables/task_card.html.heex"]
      loader = files["lib/shop_web/bubble_data.ex"]

      assert index =~ ~s(instance: "bCard1")
      assert index =~ ~s(instance: "bCard2")
      assert index =~ ~s(element: "bCard")
      assert template =~ ~s|Bubble.data(@bubble_data, @scope, "bCard")|
      assert loader =~ "BubbleWorkflows.scope(ctx, [source.instance])"
    end

    test "routes, data functions, templates and change notifications", %{files: files} do
      assert files["lib/shop_web/bubble_routes.ex"] =~
               ~s(live "/task/:bubble_thing", ShopWeb.TaskLive)

      refute files["lib/shop_web/bubble_routes.ex"] =~ ~s(live "/:bubble_thing")

      index = files["lib/shop_web/live/index_live/workflows.ex"]
      assert index =~ "def __bubble__(:data), do: @data"
      assert index =~ "|> Ash.Query.filter("
      assert index =~ "|> BubbleData.read(ctx, :all, 3)"
      assert index =~ "require Ash.Query"
      assert index =~ ~s(element: "bCellGroup")
      assert index =~ ~s(cell_loads: [["project"]])

      # What each source reads of the page (WTF-475): typing in bQuery reads
      # again bList and its cells' group, nothing else.
      assert index =~ ~r/element: "bList",.*?inputs: \["bQuery"\],\s+reads: \[\]/s
      assert index =~ ~r/element: "bCellGroup",.*?inputs: \[\],\s+reads: \["bList"\]/s
      assert index =~ ~r/element: "bFirstOpen",.*?inputs: \[\],\s+reads: \[\]/s
      assert files["lib/shop_web/bubble_data.ex"] =~ "defp load_inputs(socket, page, changed)"
      assert index =~ "= ctx.cell"

      template = files["lib/shop_web/live/index_live.html.heex"]
      assert template =~ ~s|<- Bubble.cells(@bubble_data, "", "bList")}|
      assert template =~ ~s|Bubble.data(@bubble_data, "", "bFirstOpen")|
      refute template =~ "@items_"

      live = files["lib/shop_web/live/task_live.ex"]
      assert live =~ "BubbleWorkflows.handle_params(socket, Workflows, params, uri)"

      assert files["lib/shop/task.ex"] =~ "notifiers: [Ash.Notifier.PubSub]"
      assert files["lib/shop/task.ex"] =~ "publish_all :update, [\"Task\", :_pkey]"
      assert files["lib/shop_web/bubble_data.ex"] =~ "data_access: true"
      assert files["lib/shop/bubble/changes.ex"] =~ "def broadcast(topic, _event, _notification)"

      for {path, content} <- files,
          String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs") do
        assert {:ok, _} = Code.string_to_quoted(content), path
      end
    end
  end

  test "a binding reading page data the page does not load is a marker, never silently empty" do
    app = put_in(app(), ["pages", "task", "properties", "page_item_type"], "text")
    {spec, project, frontend, app, model} = spec(app)

    {:ok, compiled} =
      BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
        runtime: "Shop.Bubble.Runtime",
        namespace: "Shop"
      )

    {:ok, index} = Index.build(app, model: model)
    {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
    {:ok, workflows} = BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "Shop")

    {:ok, files} =
      Phoenix.render(project,
        name: "Shop",
        frontend: frontend,
        expressions: compiled,
        workflows: workflows,
        frontend_workflows: spec
      )

    template = files["lib/shop_web/live/task_live.html.heex"]
    assert template =~ "TODO(bubble:bProjGroup) its data source is not loaded"
    assert template =~ "TODO(bubble:bProjName) text: reads page data that is not loaded"
    # Every page takes a path segment (WTF-466); this one reads nothing there.
    assert files["lib/shop_web/bubble_routes.ex"] =~ ~s(live "/task/:bubble_thing")
  end

  # WTF-492: "Display data in a group / popup" and "Display list in a
  # repeating group". The generated app's behavior is
  # page_data_behavior.exs (and enforced_behavior.exs for privacy).
  describe "Display data" do
    defp shown_workflow(app, id, actions),
      do: put_in(app, ["pages", "shown", "workflows", id, "actions"], actions)

    defp steps(spec, surface) do
      for w <- spec.surfaces[surface].workflows,
          step <- w.steps,
          into: %{},
          do: {step.bubble_id, step}
    end

    test "lowers to a step setting the element's data, stack-neutrally" do
      {:ok, model} = Model.build(app())
      {:ok, index} = Index.build(app(), model: model)
      {:ok, lowered} = Frontend.build(app(), model, index)
      steps = for w <- lowered.workflows, s <- w.steps, into: %{}, do: {s.bubble_id, s}

      assert %{op: :display_data, residue: [], args: %{element: "bShown", cell: nil, value: v}} =
               steps["aShowA1"]

      assert %IR{op: :input, args: [:element_state, %{"element" => "bSrcA"}]} = v.ir

      assert %{op: :display_list, residue: [], args: %{element: "bShownList"}} =
               steps["aShowList1"]

      assert %{op: :display_data, residue: [], args: %{element: "bPanel1"}} = steps["aShowCard1"]
      assert %{op: :reset_group, residue: []} = steps["aResetShown1"]

      # A list into a group, or data into a text: the element holds no such data.
      app =
        app()
        |> shown_workflow("wShowA", %{
          "0" => %{
            "id" => "aBad1",
            "type" => "DisplayListData",
            "properties" => %{"element_id" => "bShown"}
          },
          "1" => %{
            "id" => "aBad2",
            "type" => "DisplayGroupData",
            "properties" => %{"element_id" => "bShowA"}
          }
        })

      {:ok, model} = Model.build(app)
      {:ok, index} = Index.build(app, model: model)
      {:ok, lowered} = Frontend.build(app, model, index)
      steps = for w <- lowered.workflows, s <- w.steps, into: %{}, do: {s.bubble_id, s}

      for id <- ["aBad1", "aBad2"],
          do:
            assert(
              [%{reason: :unsupported_option, detail: %{options: ["element_id"]}}] =
                steps[id].residue
            )
    end

    test "an element with no data source holds what the step shows; one with a source is overridden" do
      {spec, _project, _frontend, _app, _model} = spec(app())

      for {element, kind} <- [
            {"bShown", :group},
            {"bPop", :group},
            {"bShownList", :list},
            {"bPanelGroup", :group}
          ],
          do:
            assert(
              %{read: :displayed, kind: ^kind, displayed?: true, resource: "Task", residue: []} =
                data(spec, element)
            )

      assert %{read: :displayed, kind: :instance, holder: "bPanel", key: %{path: ["bPanel1"]}} =
               data(spec, "bPanel1")

      assert %{read: {:query, _}, displayed?: true} = data(spec, "bSrcA")
      assert %{read: {:query, _}, displayed?: false} = data(spec, "bSrcB")

      # What reads it is page data: the group inside, and the page's
      # bindings (Spec.read/4).
      assert %{read: {:value, %{bindings: [%{bind: {:data, %{element: "bShown"}}}]}}, residue: []} =
               data(spec, "bShownProj")

      assert Spec.read(
               spec,
               "bShownPage",
               {:element_state, %{"element" => "bShown", "state" => "get_group_data"}}
             ) == {:data, %{path: [], element: "bShown"}}

      steps = steps(spec, "bShownPage")

      assert %{
               residue: [],
               args: %{
                 key: %{path: [], element: "bShown"},
                 cell?: false,
                 list?: false,
                 resource: "Task",
                 value: %{bindings: [%{bind: {:data, %{element: "bSrcA"}}}]}
               }
             } = steps["aShowA1"]

      assert %{args: %{key: %{path: ["bPanel1"], element: "bPanel"}}} = steps["aShowCard1"]
      assert %{args: %{list?: true, page_size: 1}} = steps["aShowList1"]
      assert %{page_size: 1} = data(spec, "bShownList")
      # An outer group's reset clears the displayed group inside it.
      assert %{args: %{clears: ["bInner"]}} = steps["aResetOuter1"]
      # A later step reads what the first just set.
      assert %{args: %{value: %{bindings: [%{bind: {:data, %{element: "bShown"}}}]}}} =
               steps["aChain2"]

      assert %{args: %{clears: ["bShown"]}} = steps["aResetShown1"]
      assert %{args: %{clears: :all}} = steps["aResetPanel1"]

      # The reusable element's own custom event shows its parameter.
      assert %{args: %{value: %{bindings: [%{bind: {:param, "pTask"}}]}}} =
               steps(spec, "bPanel")["aPanelShow1"]
    end

    test "an element only a step that never runs would show stays unloaded, loudly" do
      residue = %{"id" => "aMail", "type" => "SendEmail", "properties" => %{}}

      app =
        app()
        |> update_in(
          ["pages", "shown", "workflows", "wShowA", "actions"],
          &Map.put(&1, "1", residue)
        )
        |> update_in(
          ["pages", "shown", "workflows", "wShowB", "actions"],
          &Map.put(&1, "1", residue)
        )
        |> update_in(
          ["pages", "shown", "workflows", "wChain", "actions"],
          &Map.put(&1, "2", residue)
        )

      {spec, _project, _frontend, _app, _model} = spec(app)

      # bShown has no source and no running step: it is not page data, and
      # what reads it is not loaded either.
      refute data(spec, "bShown")

      assert %{read: nil, residue: [%{reason: :unavailable_input}]} = data(spec, "bShownProj")
      # The popup's step still runs.
      assert %{read: :displayed} = data(spec, "bPop")
    end

    test "in a repeating group's cell, only a group, from a workflow of that cell" do
      group = %{
        "id" => "bCellShown",
        "type" => "Group",
        "properties" => %{"group_type" => "custom.task", "width" => 300, "height" => 40}
      }

      app =
        app()
        |> put_in(["pages", "shown", "elements", "bSrcList", "elements", "bCellShown"], group)
        |> shown_workflow("wShowA", %{
          "0" => %{
            "id" => "aCell1",
            "type" => "DisplayGroupData",
            "properties" => %{
              "element_id" => "bCellShown",
              "data_source" => %{
                "type" => "GetElement",
                "properties" => %{"element_id" => "bSrcA"},
                "next" => %{"type" => "Message", "name" => "get_group_data"}
              }
            }
          }
        })

      {spec, _project, _frontend, _app, _model} = spec(app)

      assert %{residue: [%{reason: :page_data_in_cell, detail: %{kind: "display"}}]} =
               steps(spec, "bShownPage")["aCell1"]

      refute data(spec, "bCellShown")

      # From a button of the same cell, the step keeps it per cell; the
      # workflow does not run yet (a trigger in a cell's template), so the
      # group is not loaded either.
      button = %{"id" => "bCellBtn", "type" => "Button", "properties" => %{"width" => 30}}

      app =
        app
        |> put_in(["pages", "shown", "elements", "bSrcList", "elements", "bCellBtn"], button)
        |> put_in(
          ["pages", "shown", "workflows", "wShowA", "properties", "element_id"],
          "bCellBtn"
        )

      {spec, _project, _frontend, _app, _model} = spec(app)

      assert %{residue: [], args: %{cell?: true, key: %{element: "bCellShown"}}} =
               steps(spec, "bShownPage")["aCell1"]

      assert %{residue: [%{reason: :trigger_in_runtime_template}]} =
               Enum.find(spec.surfaces["bShownPage"].workflows, &(&1.workflow == "wShowA"))

      refute data(spec, "bCellShown")
    end
  end

  describe "Display data, printed" do
    test "the step keeps the element's data per instance; the loader reads it as the user" do
      {spec, project, frontend, app, model} = spec(app())

      {:ok, compiled} =
        BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
          runtime: "Shop.Bubble.Runtime",
          namespace: "Shop"
        )

      {:ok, index} = Index.build(app, model: model)
      {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
      {:ok, workflows} = BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "Shop")

      {:ok, files} =
        Phoenix.render(project,
          name: "Shop",
          frontend: frontend,
          expressions: compiled,
          workflows: workflows,
          frontend_workflows: spec
        )

      shown = files["lib/shop_web/live/shown_live/workflows.ex"]

      assert shown =~
               ~r/BubbleWorkflows.display\(\s*ctx,\s*"aShowA1",\s*\[\],\s*"bShown",\s*false,\s*Shop.Task,\s*false,/

      assert shown =~
               ~r/BubbleWorkflows.display\(\s*ctx,\s*"aShowCard1",\s*\["bPanel1"\],\s*"bPanel",/

      assert shown =~ ~s|BubbleWorkflows.reset(ctx, [], "bShown", [], ["bShown"])|
      assert shown =~ ~s|BubbleWorkflows.reset(ctx, ["bPanel1"], nil, [], :all)|
      assert shown =~ ~r/element: "bShown",\s+fun: nil,\s+read: :displayed,/
      assert shown =~ ~r/element: "bSrcA",.*?display: %\{page_size: nil\}/s

      template = files["lib/shop_web/live/shown_live.html.heex"]
      assert template =~ ~s|Bubble.data(@bubble_data, "", "bShown")|
      refute template =~ "TODO(bubble:bShown"

      runtime = files["lib/shop_web/bubble_workflows.ex"]

      assert runtime =~
               "def display(ctx, step, path, element, cell?, resource, list?, value, page_size \\\\ nil)"

      # A list keeps its repeating group's page size (one row here).
      assert shown =~
               ~r/"aShowList1",.*?"bShownList",\s*false,\s*Shop.Task,\s*true,.*?,\s*1\s*\)/s

      assert files["lib/shop_web/bubble_data.ex"] =~
               "def show(ctx, {resource, list?, value}, page_size)"
    end
  end
end
