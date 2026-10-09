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

      # The shown page's four (WTF-492) included, the initial page's three
      # (WTF-520: a group, an input's initial content, a list) and the
      # loaded page's eight (WTF-520: a group's and three lists' searches,
      # two conditional sources; WTF-521: two lists' own searches with
      # conditional ones), the keywords page's two lists (WTF-520) and the
      # group reading the group a popup's "is opened" workflow sets
      # (WTF-520); the pair page's two instances of one reusable element,
      # one of whose data source does not compile (WTF-522).
      assert PageData.coverage(pd)["sources"] == %{"total" => 31, "native" => 30, "residue" => 1}
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
          # Only the pair page's instance whose source does not compile (WTF-522).
          assert [%{details: %{subject: "element:bPairB"}}] = pd.diagnostics

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

      assert compiled.source =~ "Runtime.as_list(get_in(page_thing_phome, [Access.key(:tasks)]))"
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

      data = files["lib/shop_web/bubble_data.ex"]
      assert data =~ "true -> load_page(value, loads, ctx.actor)"

      assert data =~
               "Runtime.load_page(value, loads, Runtime.root(nil, actor), related_cap(), opts)"

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
      assert q.resource == "Task" and q.take == :all and q.sort == [{"title", :asc_nils_last}]
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

      # With the shown page's (WTF-492): its six sources and the six
      # elements with no source its "Display data" steps set; the initial
      # page's three (WTF-520); the loaded page's eight (WTF-521: two
      # lists' own searches with conditional ones included) and its two
      # groups with no source (WTF-520); the keywords page's two lists
      # (WTF-520: keyword searches); the popup a click opens, the group
      # its "is opened" workflow sets and the group reading that one
      # (WTF-520: popup events); the pair page's two instances, one of
      # which does not load (WTF-522).
      assert FrontendWorkflows.data_coverage(spec)["sources"] == %{
               "total" => 41,
               "wired" => 40,
               "residue" => 1
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

      assert FrontendWorkflows.data_coverage(spec)["sources"]["wired"] == 38
    end

    test "a repeating group in a repeating group's cell is read per outer cell; a third level is residue" do
      source = app()["pages"]["index"]["elements"]["bList"]["properties"]["data_source"]

      rg = fn id, elements ->
        %{
          "id" => id,
          "type" => "RepeatingGroup",
          "properties" => %{"group_type" => "custom.task", "data_source" => source},
          "elements" => elements
        }
      end

      app =
        update_in(app(), ["pages", "index", "elements", "bList", "elements"], fn els ->
          Map.put(els, "bInner", rg.("bInner", %{"bDeeper" => rg.("bDeeper", %{})}))
        end)

      {spec, _project, _frontend, _app, _model} = spec(app)

      # Two levels (WTF-520): a value per outer cell.
      assert %{residue: [], cell: "bList", read: {:query, _}} = data(spec, "bInner")

      assert %{residue: [%{reason: :page_data_in_cell, detail: %{kind: "list"}}]} =
               data(spec, "bDeeper")
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

    test "a popup's opened and closed workflows are listed and reported by its hook (WTF-520)",
         %{files: files} do
      module = files["lib/shop_web/live/shown_live/workflows.ex"]
      page = files["lib/shop_web/live/shown_live.html.heex"]
      runtime = files["lib/shop_web/bubble_workflows.ex"]
      hook = files["lib/shop_web/components/bubble.ex"]

      assert module =~ ~s|"bPopOpen" => %{opened: ["wPopOpened"], closed: ["wPopClosed"]}|
      assert module =~ ~s|"bLoopA" => %{opened: ["wLoopA"], closed: []}|

      panel = files["lib/shop_web/components/reusables/panel/workflows.ex"]
      assert panel =~ ~s|popups: %{"bPanelPop" => %{opened: ["wPanelPopOpened"], closed: []}}|

      # The popup carries the events its hook reports; one with none, none.
      assert page =~
               ~r/data-bubble-events="closed opened"[^>]*data-bubble-id="bPopOpen"|data-bubble-id="bPopOpen"[^>]*data-bubble-events="closed opened"/

      refute page =~ ~r/data-bubble-id="bPop"[^>]*data-bubble-events/

      assert hook =~
               ~s|this.pushEvent("bubble:popup", { scope, element, event })|

      assert runtime =~ ~r/def handle_event\(\s*socket,\s*page,\s*"bubble:popup"/
      assert runtime =~ "expect_popups(socket, popups, budget)"
    end

    test "two reusable instances store data under their own nested scope", %{files: files} do
      index = files["lib/shop_web/live/index_live/workflows.ex"]
      template = files["lib/shop_web/components/reusables/task_card.html.heex"]
      loader = files["lib/shop_web/bubble_data.ex"]

      assert index =~ ~s(instance: "bCard1")
      assert index =~ ~s(instance: "bCard2")
      assert index =~ ~s(element: "bCard")
      assert template =~ ~s|Bubble.data(@bubble_data, @scope, "bCard")|
      assert loader =~ "Bubble.nest(scope, source.instance)"
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
      assert %{args: %{clears: ["bInner", "bInnerSrc"]}} = steps["aResetOuter1"]
      # A later step reads what the first just set.
      assert %{args: %{value: %{bindings: [%{bind: {:data, %{element: "bShown"}}}]}}} =
               steps["aChain2"]

      assert %{args: %{clears: ["bShown"]}} = steps["aResetShown1"]
      assert %{args: %{clears: :all}} = steps["aResetPanel1"]

      # The reusable element's own custom event shows its parameter.
      assert %{args: %{value: %{bindings: [%{bind: {:param, "pTask"}}]}}} =
               steps(spec, "bPanel")["aPanelShow1"]
    end

    # Adds a step the lowering leaves as residue: its workflow never runs.
    defp refused(app, workflow, key) do
      residue = %{"id" => "aMail" <> key, "type" => "SendEmail", "properties" => %{}}

      update_in(
        app,
        ["pages", "shown", "workflows", workflow, "actions"],
        &Map.put(&1, key, residue)
      )
    end

    test "an element only refused events would set shows nothing until one runs (WTF-520)" do
      app =
        app()
        |> refused("wShowA", "1")
        |> refused("wShowB", "1")
        |> refused("wChain", "2")

      {spec, _project, _frontend, _app, _model} = spec(app)

      # bShown has no source and only clicks set it: as in Bubble, it shows
      # nothing before a click, and the page loads what reads it.
      assert %{read: :displayed, residue: []} = data(spec, "bShown")
      assert %{residue: []} = data(spec, "bShownProj")
      assert %{read: :displayed} = data(spec, "bPop")
    end

    test "an element a refused page-load workflow would set stays unloaded, loudly (WTF-520)" do
      app =
        app()
        |> refused("wShowA", "1")
        |> update_in(["pages", "shown", "workflows", "wShowA"], fn w ->
          w |> Map.put("type", "PageLoaded") |> Map.put("properties", %{})
        end)

      {spec, _project, _frontend, _app, _model} = spec(app)

      # Bubble sets bShown as the page loads; the page cannot: it is not
      # page data, and what reads it is not loaded either (the clicks
      # setting it too do not change that).
      refute data(spec, "bShown")
      assert %{read: nil, residue: [%{reason: :unavailable_input}]} = data(spec, "bShownProj")

      # Run whole, it sets bShown as the page loads: page data again.
      app =
        update_in(app(), ["pages", "shown", "workflows", "wShowA"], fn w ->
          w |> Map.put("type", "PageLoaded") |> Map.put("properties", %{})
        end)

      {spec, _project, _frontend, _app, _model} = spec(app)
      assert %{read: :displayed, residue: []} = data(spec, "bShown")
      assert %{residue: []} = data(spec, "bShownProj")
    end

    test "a custom event a page-load workflow calls sets its element as the page loads" do
      event = %{
        "id" => "wShowEvent",
        "type" => "CustomEvent",
        "properties" => %{},
        "actions" => %{
          "0" =>
            app()
            |> get_in(["pages", "shown", "workflows", "wShowA", "actions", "0"])
            |> Map.put("id", "aShowEvent1")
        }
      }

      call = %{
        "id" => "wLoadCall",
        "type" => "PageLoaded",
        "properties" => %{},
        "actions" => %{
          "0" => %{
            "id" => "aLoadCall1",
            "type" => "TriggerCustomEvent",
            "properties" => %{"custom_event" => "wShowEvent"}
          }
        }
      }

      app =
        app()
        |> put_in(["pages", "shown", "workflows", "wShowEvent"], event)
        |> put_in(["pages", "shown", "workflows", "wLoadCall"], call)

      {spec, _project, _frontend, _app, _model} = spec(app)
      assert %{read: :displayed} = data(spec, "bShown")

      # The page-load caller refused, the custom event never runs as the
      # page loads: bShown is not page data.
      {spec, _project, _frontend, _app, _model} = spec(refused(app, "wLoadCall", "1"))
      refute data(spec, "bShown")
    end

    test "a page-load step, a refused click and a conditional source (WTF-520)" do
      {spec, _project, _frontend, _app, _model} = spec(app())

      # A page-load workflow that runs sets bLoaded: page data, read by a
      # text and a list's search, ordered after it.
      assert %{read: :displayed, residue: []} = data(spec, "bLoaded")
      assert %{residue: [], reads: reads} = data(spec, "bLoadedList")
      assert {:data, %{path: [], element: "bLoaded"}} in reads

      # Only a refused click sets bClicked: empty until then, read anyway.
      assert %{read: :displayed, residue: []} = data(spec, "bClicked")
      assert %{residue: []} = data(spec, "bClickedList")

      assert %{blocked_by: [_ | _]} =
               Enum.find(spec.surfaces["bLoadedPage"].workflows, &(&1.workflow == "wClicked"))

      # bCond's only source is its condition's, reading bLoaded (WTF-521:
      # the condition tested, then only its branch read).
      assert %{read: {:switch, _}, residue: [], reads: cond_reads} = data(spec, "bCond")
      assert {:data, %{path: [], element: "bLoaded"}} in cond_reads
    end

    # WTF-520: a group with no source (bDetail) and a group reading it
    # (bDetailProj), set only by the given workflows.
    @detail %{
      "id" => "bDetail",
      "type" => "Group",
      "properties" => %{"group_type" => "custom.task", "width" => 300, "height" => 40},
      "elements" => %{
        "bDetailProj" => %{
          "id" => "bDetailProj",
          "type" => "Group",
          "properties" => %{
            "group_type" => "custom.project",
            "width" => 300,
            "height" => 40,
            "data_source" => %{
              "type" => "ElementParent",
              "next" => %{"type" => "Message", "name" => "project_custom_project"}
            }
          }
        }
      }
    }

    defp detail_app(workflows, app, at \\ ["pages", "shown", "elements"]) do
      app = put_in(app, at ++ ["bDetail"], @detail)

      Enum.reduce(workflows, app, fn w, acc ->
        put_in(acc, ["pages", "shown", "workflows", w["id"]], w)
      end)
    end

    defp wf(id, type, props, actions),
      do: %{
        "id" => id,
        "type" => type,
        "properties" => props,
        "actions" =>
          actions |> Enum.with_index() |> Map.new(fn {a, i} -> {Integer.to_string(i), a} end)
      }

    defp show_detail(id),
      do: %{
        "id" => id,
        "type" => "DisplayGroupData",
        "properties" => %{
          "element_id" => "bDetail",
          "data_source" => %{
            "type" => "GetElement",
            "properties" => %{"element_id" => "bSrcA"},
            "next" => %{"type" => "Message", "name" => "get_group_data"}
          }
        }
      }

    defp call(id, event, type \\ "TriggerCustomEvent"),
      do: %{"id" => id, "type" => type, "properties" => %{"custom_event" => event}}

    defp mail(id), do: %{"id" => id, "type" => "SendEmail", "properties" => %{}}

    defp event(id, actions), do: wf(id, "CustomEvent", %{}, actions)
    defp clicked(id, actions), do: wf(id, "ButtonClicked", %{"element_id" => "bShowA"}, actions)

    defp kept?(workflows, app \\ app(), at \\ ["pages", "shown", "elements"]) do
      {spec, _project, _frontend, _app, _model} = spec(detail_app(workflows, app, at))

      case data(spec, "bDetail") do
        %{read: :displayed, residue: []} ->
          assert %{residue: []} = data(spec, "bDetailProj")
          true

        nil ->
          assert %{residue: [%{reason: :unavailable_input}]} = data(spec, "bDetailProj")
          false
      end
    end

    @user_logged_in %{
      "type" => "CurrentUser",
      "next" => %{"type" => "Message", "name" => "logged_in"}
    }

    test "which workflows may start a display step decide whether its element loads (WTF-520)" do
      # Events: a click, an input change, a "do every" tick; empty before.
      assert kept?([clicked("wD", [show_detail("aD")])])
      assert kept?([clicked("wD", [show_detail("aD"), mail("aDm")])])
      assert kept?([wf("wD", "InputChanged", %{"element_id" => "bPick"}, [show_detail("aD")])])
      assert kept?([wf("wD", "DoInterval", %{"interval" => 5}, [show_detail("aD")])])

      # As the page loads: kept only when the workflow runs whole.
      assert kept?([wf("wD", "PageLoaded", %{}, [show_detail("aD")])])
      refute kept?([wf("wD", "PageLoaded", %{}, [show_detail("aD"), mail("aDm")])])

      cond = %{"condition" => @user_logged_in, "run_when" => "every_time"}
      assert kept?([wf("wD", "ConditionTrue", cond, [show_detail("aD")])])
      refute kept?([wf("wD", "ConditionTrue", cond, [show_detail("aD"), mail("aDm")])])

      # Events this target does not wire may fire as the page loads.
      refute kept?([wf("wD", "LoggedIn", %{}, [show_detail("aD")])])
      refute kept?([wf("wD", "1700000000000x100000000000000000-AAA", %{}, [show_detail("aD")])])

      # A popup opened or closed: by what opens or closes it (below). The
      # fixture's bPop only a click opens.
      assert kept?([wf("wD", "PopupOpened", %{"element_id" => "bPop"}, [show_detail("aD")])])

      # A disabled workflow never runs: the element shows nothing.
      assert kept?([
               wf("wD", "PageLoaded", %{"workflow_disabled" => true}, [
                 show_detail("aD"),
                 mail("aDm")
               ])
             ])
    end

    test "a custom event's callers decide for its display steps (WTF-520)" do
      # Nothing calls it: it never runs.
      assert kept?([event("wE", [show_detail("aD")])])

      # A wired click calls it; or schedules it.
      assert kept?([event("wE", [show_detail("aD")]), clicked("wC", [call("aC", "wE")])])

      assert kept?([
               event("wE", [show_detail("aD")]),
               clicked("wC", [call("aC", "wE", "ScheduleCustom")])
             ])

      # A refused page-load workflow schedules it: not kept.
      refute kept?([
               event("wE", [show_detail("aD")]),
               wf("wL", "PageLoaded", %{}, [call("aC", "wE", "ScheduleCustom"), mail("aLm")])
             ])

      # A plugin's event calls it, through another custom event.
      refute kept?([
               event("wE", [show_detail("aD")]),
               event("wF", [call("aF", "wE")]),
               wf("wP", "1700000000000x100000000000000000-AAA", %{}, [call("aP", "wF")])
             ])

      # A cycle of custom events with no other caller never runs; with a
      # page-load caller that runs whole, it is kept.
      cycle = [
        event("wE", [show_detail("aD"), call("aE", "wF")]),
        event("wF", [call("aF", "wE")])
      ]

      assert kept?(cycle)
      assert kept?(cycle ++ [wf("wL", "PageLoaded", %{}, [call("aL", "wF")])])
      refute kept?(cycle ++ [wf("wL", "PageLoaded", %{}, [call("aL", "wF"), mail("aLm")])])
    end

    # WTF-520: a popup nothing else opens or closes, for its workflows.
    @pop2 %{
      "id" => "bPop2",
      "type" => "Popup",
      "properties" => %{"group_type" => "custom.task", "width" => 300, "height" => 200}
    }

    defp popup_app(extra \\ %{}),
      do: put_in(app(), ["pages", "shown", "elements", "bPop2"], Map.merge(@pop2, extra))

    defp opened(id, actions), do: wf(id, "PopupOpened", %{"element_id" => "bPop2"}, actions)
    defp closed(id, actions), do: wf(id, "PopupClosed", %{"element_id" => "bPop2"}, actions)

    defp toggle(id, type),
      do: %{"id" => id, "type" => type, "properties" => %{"element_id" => "bPop2"}}

    defp loaded(id, actions), do: wf(id, "PageLoaded", %{}, actions)

    test "what opens or closes a popup decides for its workflows' display steps (WTF-520)" do
      app = popup_app()

      # Popups are closed as the page loads: nothing opens it, its "is
      # opened" workflow never runs; only the user closes it (Escape),
      # which the page reports.
      assert kept?([opened("wD", [show_detail("aD")])], app)
      assert kept?([closed("wD", [show_detail("aD")])], app)

      # A click opens it (or a custom event a click calls): empty until then.
      for step <- ["ShowElement", "ToggleElement"] do
        assert kept?(
                 [opened("wD", [show_detail("aD")]), clicked("wC", [toggle("aC", step)])],
                 app
               )
      end

      assert kept?(
               [
                 opened("wD", [show_detail("aD")]),
                 event("wE", [toggle("aE", "ShowElement")]),
                 clicked("wC", [call("aC", "wE")])
               ],
               app
             )

      # A click hides it: its "is closed" workflow is event-driven too.
      assert kept?(
               [closed("wD", [show_detail("aD")]), clicked("wC", [toggle("aC", "HideElement")])],
               app
             )

      # A page-load workflow opens it: kept only when both run whole.
      assert kept?(
               [opened("wD", [show_detail("aD")]), loaded("wL", [toggle("aL", "ShowElement")])],
               app
             )

      refute kept?(
               [
                 opened("wD", [show_detail("aD"), mail("aDm")]),
                 loaded("wL", [toggle("aL", "ShowElement")])
               ],
               app
             )

      refute kept?(
               [
                 opened("wD", [show_detail("aD")]),
                 loaded("wL", [toggle("aL", "ShowElement"), mail("aLm")])
               ],
               app
             )

      # A toggle as the page loads may close it as well.
      refute kept?(
               [
                 closed("wD", [show_detail("aD")]),
                 loaded("wL", [toggle("aL", "ToggleElement"), mail("aLm")])
               ],
               app
             )

      # A plugin's event opens it, through a custom event: it may fire as
      # the page loads.
      refute kept?(
               [
                 opened("wD", [show_detail("aD")]),
                 event("wE", [toggle("aE", "ShowElement")]),
                 wf("wP", "1700000000000x100000000000000000-AAA", %{}, [call("aP", "wE")])
               ],
               app
             )

      # A disabled opener never runs.
      assert kept?(
               [
                 opened("wD", [show_detail("aD")]),
                 loaded("wL", [toggle("aL", "ShowElement"), mail("aLm")])
                 |> put_in(["properties", "workflow_disabled"], true)
               ],
               app
             )
    end

    test "a popup the page cannot follow keeps what its workflows set unloaded (WTF-520)" do
      # Its conditions set its visibility: they may open it as the page
      # loads, and the page does not follow an overlay's conditions.
      visible = %{
        "states" => %{
          "0" => %{"condition" => @user_logged_in, "properties" => %{"is_visible" => true}}
        }
      }

      refute kept?(
               [opened("wD", [show_detail("aD")]), clicked("wC", [toggle("aC", "ShowElement")])],
               popup_app(visible)
             )

      # Not a popup: Bubble lists only popups for these events, so the
      # workflow is not wired (the page never triggers it).
      group = %{@pop2 | "type" => "Group"}
      app = put_in(app(), ["pages", "shown", "elements", "bPop2"], group)

      refute kept?(
               [opened("wD", [show_detail("aD")]), clicked("wC", [toggle("aC", "ShowElement")])],
               app
             )

      # A click in a repeating group's cell opens it: an event the page
      # wires per cell (WTF-520), so its "is opened" workflow is too.
      button = %{"id" => "bRowBtn", "type" => "Button", "properties" => %{"width" => 30}}

      app =
        put_in(
          popup_app(),
          ["pages", "shown", "elements", "bSrcList", "elements", "bRowBtn"],
          button
        )

      row_opens = [
        opened("wD", [show_detail("aD")]),
        wf("wR", "ButtonClicked", %{"element_id" => "bRowBtn"}, [toggle("aR", "ShowElement")])
      ]

      assert kept?(row_opens, app)

      # In the cells of a list the page does not load, nothing triggers it.
      unloaded =
        put_in(app, ["pages", "shown", "elements", "bSrcList", "properties", "data_source"], %{
          "type" => "GetElement",
          "properties" => %{"element_id" => "bShowA"},
          "next" => %{"type" => "Message", "name" => "is_visible"}
        })

      refute kept?(row_opens, unloaded)
    end

    test "a popup's opened and closed workflows are wired; what they set loads (WTF-520)" do
      {spec, _project, _frontend, _app, _model} = spec(app())

      for id <- ["wPopOpened", "wPopClosed"] do
        w = Spec.workflow(spec, "bShownPage", id)
        assert Spec.wired?(w) and Spec.native?(w), id
      end

      # Only the popup's "is opened" workflow sets bPopInner, and only a
      # click opens the popup: empty until then; what reads it loads.
      assert %{read: :displayed, residue: []} = data(spec, "bPopInner")
      assert %{residue: [], reads: reads} = data(spec, "bPopInnerProj")
      assert {:data, %{path: [], element: "bPopInner"}} in reads

      # Not a Popup, or a reusable element that is itself one: residue.
      app =
        update_in(app(), ["pages", "shown", "workflows", "wPopOpened"], fn w ->
          put_in(w, ["properties", "element_id"], "bShown")
        end)

      {spec, _project, _frontend, _app, _model} = spec(app)

      assert %{residue: [%{reason: :unsupported_event, detail: %{type: "PopupOpened"}}]} =
               Spec.workflow(spec, "bShownPage", "wPopOpened")

      refute data(spec, "bPopInner")
    end

    test "an action this target does not lower on a popup keeps its workflows' data unloaded (WTF-520)" do
      animate = %{
        "id" => "aAnim",
        "type" => "AnimateElement",
        "properties" => %{"element_id" => "bPop2", "animation" => "fadeIn"}
      }

      # It may open the popup as the page loads, or any time: never kept.
      refute kept?([opened("wD", [show_detail("aD")]), loaded("wL", [animate])], popup_app())
      refute kept?([opened("wD", [show_detail("aD")]), clicked("wC", [animate])], popup_app())
      refute kept?([closed("wD", [show_detail("aD")]), clicked("wC", [animate])], popup_app())

      # In a disabled workflow it never runs.
      assert kept?(
               [
                 opened("wD", [show_detail("aD")]),
                 loaded("wL", [animate]) |> put_in(["properties", "workflow_disabled"], true)
               ],
               popup_app()
             )
    end

    test "what the opener shows and the popup's own workflow resets or shows is unloaded (WTF-520)" do
      opener = clicked("wC", [show_detail("aC"), toggle("aCs", "ShowElement")])

      reset = fn id, element ->
        %{"id" => id, "type" => "ResetGroup", "properties" => %{"element_id" => element}}
      end

      # Alone, the click's step is kept.
      assert kept?([opener], popup_app())

      # The popup's "is opened" resets the element, or shows data in it
      # too: which wins is not replayed.
      refute kept?([opener, opened("wO", [reset.("aO", "bDetail")])], popup_app())
      refute kept?([opener, opened("wO", [show_detail("aO")])], popup_app())

      # bDetail inside the popup, which its "is opened" resets.
      refute kept?(
               [opener, opened("wO", [reset.("aO", "bPop2")])],
               popup_app(%{"elements" => %{}}),
               ["pages", "shown", "elements", "bPop2", "elements"]
             )

      # Through a custom event the click calls; and for "is closed".
      refute kept?(
               [
                 clicked("wC", [show_detail("aC"), call("aCc", "wE")]),
                 event("wE", [toggle("aE", "ShowElement")]),
                 opened("wO", [reset.("aO", "bDetail")])
               ],
               popup_app()
             )

      refute kept?(
               [
                 clicked("wC", [show_detail("aC"), toggle("aCh", "HideElement")]),
                 closed("wO", [reset.("aO", "bDetail")])
               ],
               popup_app()
             )

      # Resetting something else, or a popup the click does not open: kept.
      assert kept?([opener, opened("wO", [reset.("aO", "bShown")])], popup_app())

      assert kept?(
               [clicked("wC", [show_detail("aC")]), opened("wO", [reset.("aO", "bDetail")])],
               popup_app()
             )
    end

    test "a reusable element's custom event the page calls as it loads (WTF-520)" do
      # bPanelGroup (inside bPanel) is set by the reusable element's
      # custom event, which a click on the page calls: kept.
      {spec, _project, _frontend, _app, _model} = spec(app())
      assert %{read: :displayed} = data(spec, "bPanelGroup")

      # A refused page-load workflow calls it instead: not kept.
      app =
        update_in(app(), ["pages", "shown", "workflows", "wShowPanel"], fn w ->
          w
          |> Map.put("type", "PageLoaded")
          |> Map.put("properties", %{})
          |> put_in(["actions", "1"], mail("aPanelMail"))
        end)

      {spec, _project, _frontend, _app, _model} = spec(app)
      refute data(spec, "bPanelGroup")
    end

    test "a click in a repeating group's cell is an event: master-detail is kept (WTF-520)" do
      button = %{"id" => "bRowBtn", "type" => "Button", "properties" => %{"width" => 30}}

      app =
        put_in(app(), ["pages", "shown", "elements", "bSrcList", "elements", "bRowBtn"], button)

      row = %{
        show_detail("aD")
        | "properties" => %{
            "element_id" => "bDetail",
            "data_source" => %{"type" => "CurrentDataItem"}
          }
      }

      # Master-detail: the row's click runs in its cell (the page wires it
      # per cell), so bDetail is page data, empty until the click.
      workflow = wf("wD", "ButtonClicked", %{"element_id" => "bRowBtn"}, [row])
      assert kept?([workflow], app)

      {spec, _project, _frontend, _app, _model} = spec(detail_app([workflow], app))

      assert %{residue: [], cell: "bSrcList", steps: [step]} =
               Enum.find(spec.surfaces["bShownPage"].workflows, &(&1.workflow == "wD"))

      # "Current cell's" thing is the cell's, kept as an ID by the page.
      assert %{
               residue: [],
               args: %{cell?: false, value: %{bindings: [%{bind: {:cell, "bSrcList"}}]}}
             } =
               step

      # A list the page does not load has no cells: the click stays a
      # trigger in a runtime template, and bDetail is not read as empty.
      unloaded =
        put_in(app, ["pages", "shown", "elements", "bSrcList", "properties", "data_source"], %{
          "type" => "GetElement",
          "properties" => %{"element_id" => "bShowA"},
          "next" => %{"type" => "Message", "name" => "is_visible"}
        })

      refute kept?([workflow], unloaded)

      {spec, _project, _frontend, _app, _model} = spec(detail_app([workflow], unloaded))

      assert %{cell: nil, residue: [%{reason: :trigger_in_runtime_template} | _]} =
               Enum.find(spec.surfaces["bShownPage"].workflows, &(&1.workflow == "wD"))
    end

    defp state(condition, element),
      do: %{
        "condition" => condition,
        "properties" => %{
          "data_source" => %{
            "type" => "GetElement",
            "properties" => %{"element_id" => element},
            "next" => %{"type" => "Message", "name" => "get_group_data"}
          }
        }
      }

    test "conditional data sources with no source of their own: the last true state wins" do
      states = %{"0" => state(@user_logged_in, "bSrcA"), "1" => state(@user_logged_in, "bSrcB")}

      app =
        put_in(
          app(),
          ["pages", "shown", "elements", "bDetail"],
          Map.put(@detail, "states", states)
        )

      {_model, page_data} = build(app)

      # if(state 1, B, if(state 0, A, empty)): the last state outermost.
      assert %Source{value: %{ir: %IR{op: :if, args: [_, b, %IR{op: :if, args: [_, a, none]}]}}} =
               source(page_data, "bDetail")

      assert [{:element_state, %{"element" => "bSrcB"}}] = ir_inputs(b)
      assert [{:element_state, %{"element" => "bSrcA"}}] = ir_inputs(a)
      assert %IR{op: :empty} = none
    end

    defp ir_inputs(%IR{op: :input, args: [kind, ref]}), do: [{kind, ref}]
    defp ir_inputs(%IR{args: args}), do: Enum.flat_map(args, &ir_inputs/1)
    defp ir_inputs(_), do: []

    test "instances no step or source fills show nothing, when all of a reusable's do (WTF-520)" do
      # bPanel1, the panel's only instance, has no data source; without the
      # step that sets it, nothing does: the panel's own thing is nothing.
      app = update_in(app(), ["pages", "shown", "workflows"], &Map.delete(&1, "wShowCard"))
      {spec, _project, _frontend, _app, _model} = spec(app)

      assert %{kind: :instance, read: :displayed, residue: [], key: key} = data(spec, "bPanel1")
      assert key == %{path: ["bPanel1"], element: "bPanel"}
      assert MapSet.member?(spec.data_index.roots, "bPanel")

      # Another instance of it with a source of its own: left as it was.
      other = %{
        "id" => "bPanel2",
        "type" => "CustomElement",
        "properties" => %{
          "custom_id" => "bPanel",
          "group_type" => "custom.task",
          "width" => 300,
          "height" => 40,
          "data_source" => %{
            "type" => "GetElement",
            "properties" => %{"element_id" => "bSrcA"},
            "next" => %{"type" => "Message", "name" => "get_group_data"}
          }
        }
      }

      {spec, _project, _frontend, _app, _model} =
        spec(put_in(app, ["pages", "shown", "elements", "bPanel2"], other))

      refute data(spec, "bPanel1")
      assert %{kind: :instance, residue: []} = data(spec, "bPanel2")
    end

    test "a group no step sets and with no data source shows nothing (WTF-520)" do
      never = %{
        "id" => "bNever",
        "type" => "Group",
        "properties" => %{"group_type" => "custom.task", "width" => 300, "height" => 40},
        "elements" => %{
          "bNeverProj" => %{
            "id" => "bNeverProj",
            "type" => "Group",
            "properties" => %{
              "group_type" => "custom.project",
              "width" => 300,
              "height" => 40,
              "data_source" => %{
                "type" => "ElementParent",
                "next" => %{"type" => "Message", "name" => "project_custom_project"}
              }
            }
          }
        }
      }

      app = put_in(app(), ["pages", "shown", "elements", "bNever"], never)
      {spec, _project, _frontend, _app, _model} = spec(app)

      assert %{read: :displayed, residue: []} = data(spec, "bNever")
      assert %{residue: []} = data(spec, "bNeverProj")

      # A condition giving it a data source: the group shows that source
      # while the condition is yes, else nothing (WTF-520).
      conditional = %{
        "0" => %{
          "condition" => %{
            "type" => "CurrentUser",
            "next" => %{"type" => "Message", "name" => "logged_in"}
          },
          "properties" => %{
            "data_source" => %{
              "type" => "GetElement",
              "properties" => %{"element_id" => "bSrcA"},
              "next" => %{"type" => "Message", "name" => "get_group_data"}
            }
          }
        }
      }

      app = put_in(app, ["pages", "shown", "elements", "bNever", "states"], conditional)
      {_model, page_data} = build(app)

      assert %Source{kind: :group, residue: [], value: %{ir: %IR{op: :if, args: [_, _, none]}}} =
               source(page_data, "bNever")

      assert %IR{op: :empty} = none

      {spec, _project, _frontend, _app, _model} = spec(app)
      assert %{read: {:switch, _}, residue: [], displayed?: false} = data(spec, "bNever")
      assert %{residue: []} = data(spec, "bNeverProj")

      # A state with no condition is residue: the group is not read as
      # empty, and what reads it is not loaded.
      app =
        update_in(
          app,
          ["pages", "shown", "elements", "bNever", "states", "0"],
          &Map.delete(&1, "condition")
        )

      {spec, _project, _frontend, _app, _model} = spec(app)
      assert %{residue: [%{reason: :uncompiled_expression}]} = data(spec, "bNever")
      assert %{residue: [%{reason: :unavailable_input}]} = data(spec, "bNeverProj")

      # Without page data, nothing is read as empty.
      {spec, _project, _frontend, _app, _model} =
        spec(put_in(app(), ["pages", "shown", "elements", "bNever"], never), page_data: false)

      refute data(spec, "bNever")
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

      # From a button of the same cell, the step keeps it per cell, and
      # the click runs in that cell (WTF-520): the group is page data per
      # cell, empty until the click.
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

      assert %{residue: [], cell: "bSrcList"} =
               Enum.find(spec.surfaces["bShownPage"].workflows, &(&1.workflow == "wShowA"))

      assert %{read: :displayed, cell: "bSrcList", residue: []} = data(spec, "bCellShown")
    end
  end

  # WTF-521: an element with a data source of its own whose conditional
  # states set another: the states fold over its own source (the base),
  # the last true one winning; outside a cell the page tests the
  # conditions and reads only the winning branch.
  describe "conditional data sources over an element's own" do
    defp with_states(app, page, element, states),
      do: put_in(app, ["pages", page, "elements", element, "states"], states)

    defp render_files(app) do
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

      files
    end

    @search_done %{
      "type" => "Search",
      "properties" => %{
        "type_to_find" => "custom.task",
        "sort_field" => "title_text",
        "descending" => true,
        "constraints" => %{
          "0" => %{"constraint_type" => "equals", "key" => "done_boolean", "value" => true}
        }
      }
    }

    test "the base plus one condition: the state over its own source" do
      app = with_states(app(), "shown", "bSrcA", %{"0" => state(@user_logged_in, "bSrcB")})
      {_model, page_data} = build(app)

      # if(state 0, B, own source): its own source is the base.
      assert %Source{
               kind: :group,
               residue: [],
               value: %{ir: %IR{op: :if, args: [%IR{op: :logged_in}, b, %IR{op: :first}]}}
             } = source(page_data, "bSrcA")

      assert [{:element_state, %{"element" => "bSrcB"}}] = ir_inputs(b)

      # Bound: the condition, then the branch, else the base's own search
      # (a whole query, its first item). It reads what all of them read.
      {spec, _project, _frontend, _app, _model} = spec(app)

      assert %{
               residue: [],
               read:
                 {:switch,
                  %{
                    cases: [%{when: {:value, _}, then: {:value, _}}],
                    else: {:query, %{take: :first, resource: "Task"}}
                  }},
               reads: reads
             } = data(spec, "bSrcA")

      assert {:data, %{path: [], element: "bSrcB"}} in reads
    end

    test "several conditions: the last state is tested first, then the others, then the base" do
      states = %{
        "0" => state(@user_logged_in, "bSrcB"),
        "1" => state(@user_logged_in, "bSrcIn")
      }

      app = with_states(app(), "shown", "bSrcA", states)
      {_model, page_data} = build(app)

      assert %Source{
               residue: [],
               value: %{ir: %IR{op: :if, args: [_, last, %IR{op: :if, args: [_, first, base]}]}}
             } = source(page_data, "bSrcA")

      assert [{:element_state, %{"element" => "bSrcIn"}}] = ir_inputs(last)
      assert [{:element_state, %{"element" => "bSrcB"}}] = ir_inputs(first)
      assert %IR{op: :first} = base

      {spec, _project, _frontend, _app, _model} = spec(app)

      assert %{read: {:switch, %{cases: [one, two], else: {:query, _}}}, reads: reads} =
               data(spec, "bSrcA")

      assert {:value, %{bindings: [%{bind: {:data, %{element: "bSrcIn"}}}]}} = one.then
      assert {:value, %{bindings: [%{bind: {:data, %{element: "bSrcB"}}}]}} = two.then
      assert {:data, %{path: [], element: "bSrcB"}} in reads
      assert {:data, %{path: [], element: "bSrcIn"}} in reads

      # Printed: the conditions in order, each branch and the base a
      # function of its own, so only the winning one runs.
      shown = render_files(app)["lib/shop_web/live/shown_live/workflows.ex"]

      [fun] =
        Regex.run(~r/def (data_bsrca_\w+)\(ctx\) do\n\s+cond do/, shown, capture: :all_but_first)

      assert shown =~
               ~r/cond do\s+#{fun}_when_1\(ctx\) == true -> #{fun}_then_1\(ctx\)\s+#{fun}_when_2\(ctx\) == true -> #{fun}_then_2\(ctx\)\s+true -> #{fun}_else\(ctx\)\s+end/

      assert shown =~ "defp #{fun}_else(ctx) do"
      assert shown =~ ~r/element: "bSrcA",.*?reads: \["bSrcB", "bSrcIn"\]/s
      assert {:ok, _} = Code.string_to_quoted(shown)
    end

    test "a condition or an override that does not compile keeps the residue" do
      no_condition = Map.delete(state(@user_logged_in, "bSrcB"), "condition")

      bad_override =
        put_in(state(@user_logged_in, "bSrcB"), ["properties", "data_source"], %{
          "type" => "NoSuchExpression"
        })

      for bad <- [no_condition, bad_override] do
        app =
          app()
          |> with_states("shown", "bSrcA", %{"0" => state(@user_logged_in, "bSrcB"), "1" => bad})

        {_model, page_data} = build(app)
        %Source{residue: residue, value: value} = source(page_data, "bSrcA")

        # Never its own source alone, nor a partial fold.
        assert Enum.any?(residue, &(&1.reason == :uncompiled_expression))

        assert %{reason: :unsupported_option, detail: %{options: ["states.data_source"]}} =
                 List.last(residue)

        assert %IR{op: :first} = value.ir

        {spec, _project, _frontend, _app, _model} = spec(app)
        assert %{residue: [_ | _], read: nil} = data(spec, "bSrcA")
      end
    end

    test "a reusable instance: its own thing is the base; with none, empty" do
      app =
        app()
        |> with_states("index", "bCard1", %{"0" => state(@user_logged_in, "bFirstOpen")})
        |> with_states("shown", "bPanel1", %{"0" => state(@user_logged_in, "bSrcA")})

      {_model, page_data} = build(app)

      assert %Source{
               kind: :instance,
               holder: "bCard",
               residue: [],
               value: %{ir: %IR{op: :if, args: [_, _, %IR{op: :first}]}}
             } = source(page_data, "bCard1")

      assert %Source{
               kind: :instance,
               holder: "bPanel",
               residue: [],
               value: %{ir: %IR{op: :if, args: [_, _, %IR{op: :empty}]}}
             } = source(page_data, "bPanel1")

      {spec, _project, _frontend, _app, _model} = spec(app)

      assert %{residue: [], read: {:switch, %{else: {:query, _}}}, reads: reads} =
               data(spec, "bCard1")

      assert {:data, %{path: [], element: "bFirstOpen"}} in reads

      assert %{residue: [], read: {:switch, %{else: {:value, _}}}, key: %{path: ["bPanel1"]}} =
               data(spec, "bPanel1")
    end

    test "a repeating group's search: the state is a whole other search, never merged" do
      condition = %{
        "type" => "GetElement",
        "properties" => %{"element_id" => "bQuery"},
        "next" => %{
          "type" => "Message",
          "name" => "get_data",
          "next" => %{
            "type" => "Message",
            "name" => "equals",
            "args" => %{"type" => "TextExpression", "entries" => %{"0" => "done"}}
          }
        }
      }

      states = %{
        "0" => %{"condition" => condition, "properties" => %{"data_source" => @search_done}}
      }

      app = with_states(app(), "index", "bList", states)
      {_model, page_data} = build(app)
      assert %Source{kind: :list, page_size: 3, residue: []} = source(page_data, "bList")

      {spec, _project, _frontend, _app, _model} = spec(app)

      assert %{
               residue: [],
               page_size: 3,
               read:
                 {:switch,
                  %{cases: [%{when: {:value, _}, then: {:query, then}}], else: {:query, base}}}
             } = data(spec, "bList")

      # Each branch is its own query: its constraints and sort, no other's.
      assert %{take: :all, sort: [{"title", :desc_nils_last}], pins: []} = then
      assert then.filter.expr == {:op, "==", {:ref, [], "done"}, {:value, true}}
      assert %{take: :all, sort: [{"title", :asc_nils_last}], pins: [_, _]} = base
      assert {:or, [_, {:call, "contains", [{:ref, [], "title"}, {:pin, _}]}]} = base.filter.expr
      refute Map.has_key?(then, :queries) or Map.has_key?(base, :queries)

      index = render_files(app)["lib/shop_web/live/index_live/workflows.ex"]

      [fun] =
        Regex.run(~r/def (data_blist_\w+)\(ctx\) do\n\s+cond do/, index, capture: :all_but_first)

      # The base and the branch each read a page of their own query.
      for part <- ["then_1", "else"] do
        assert index =~ ~r/defp #{fun}_#{part}\(ctx\) do.*?\|> BubbleData.read\(ctx, :all, 3\)/s
      end

      # Typing in bQuery reads it again: both the condition and the base read it.
      assert index =~ ~r/element: "bList",.*?read: :query,.*?inputs: \["bQuery"\]/s
    end

    test "a condition reading the element's own value is a cycle, not an always-empty read" do
      own_empty = %{
        "type" => "GetElement",
        "properties" => %{"element_id" => "bSrcA"},
        "next" => %{
          "type" => "Message",
          "name" => "get_group_data",
          "next" => %{"type" => "Message", "name" => "is_empty"}
        }
      }

      app = with_states(app(), "shown", "bSrcA", %{"0" => state(own_empty, "bSrcB")})
      {_model, page_data} = build(app)
      assert %Source{residue: [], value: %{ir: %IR{op: :if}}} = source(page_data, "bSrcA")

      # Read as the page loads, This Group's Task is always empty there:
      # the override would always win. Fail closed, and so does what
      # reads it.
      {spec, _project, _frontend, _app, _model} = spec(app)

      assert %{
               read: nil,
               residue: [%{reason: :unresolved_reference, detail: %{reference: "data_source"}}]
             } = data(spec, "bSrcA")
    end

    test "a state whose source is another kind of value than the element's is residue" do
      task_list = %{
        "type" => "Search",
        "properties" => %{"type_to_find" => "custom.task", "sort_field" => "title_text"}
      }

      cases = [
        # A Task group, a list of tasks.
        {"bSrcA",
         %{"condition" => @user_logged_in, "properties" => %{"data_source" => task_list}}},
        # A Task group, a Project.
        {"bSrcA", state(@user_logged_in, "bShownProj")},
        # A Task list, one task.
        {"bSrcList", state(@user_logged_in, "bSrcA")}
      ]

      for {element, bad} <- cases do
        app = with_states(app(), "shown", element, %{"0" => bad})
        {_model, page_data} = build(app)
        %Source{residue: residue} = source(page_data, element)

        assert %{
                 reason: :uncompiled_expression,
                 detail: %{constructs: ["conditional_source_type"]}
               } =
                 Enum.find(residue, &(&1.reason == :uncompiled_expression)),
               element

        assert %{reason: :unsupported_option} = List.last(residue)

        {spec, _project, _frontend, _app, _model} = spec(app)
        assert %{residue: [_ | _], read: nil} = data(spec, element)
      end
    end

    test "a state's search on a field privacy keeps out of searches is residue" do
      rules = %{
        "everyone" => %{
          "permissions" => %{
            "search_for" => true,
            "view_all" => true,
            "non_filterable_fields" => %{"0" => "done_boolean"}
          }
        }
      }

      states = %{
        "0" => %{"condition" => @user_logged_in, "properties" => %{"data_source" => @search_done}}
      }

      app =
        app()
        |> put_in(["user_types", "task", "privacy_role"], rules)
        |> with_states("index", "bStrict", states)

      {_model, page_data} = build(app)

      assert [%{reason: :search_field_restricted, detail: %{fields: ["done_boolean"]}}] =
               source(page_data, "bStrict").residue

      {spec, _project, _frontend, _app, _model} = spec(app)
      assert %{read: nil, residue: [_ | _]} = data(spec, "bStrict")
    end

    test "in a repeating group's cell, the fold stays one value computed per cell" do
      state = %{
        "condition" => @user_logged_in,
        "properties" => %{
          "data_source" => %{
            "type" => "CurrentDataItem",
            "next" => %{"type" => "Message", "name" => "project_custom_project"}
          }
        }
      }

      app =
        update_in(
          app(),
          ["pages", "index", "elements", "bList", "elements", "bCellGroup"],
          &Map.put(&1, "states", %{"0" => state})
        )

      {_model, page_data} = build(app)

      assert %Source{cell: "bList", residue: [], value: %{ir: %IR{op: :if}}} =
               source(page_data, "bCellGroup")

      {spec, _project, _frontend, _app, _model} = spec(app)
      assert %{residue: [], cell: "bList", read: {:value, _}} = data(spec, "bCellGroup")
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

  # WTF-520: an input whose initial content reads data starts with that
  # value, its conditional states applied, and what reads the input waits
  # for it.
  describe "an input's initial content" do
    defp initial_path(rest), do: ["pages", "initial", "elements", "bInitBox", "elements" | rest]

    test "is a source of the input, its content states folded in Bubble's order" do
      {_model, pd} = build(app())

      assert %Source{kind: :input, type: "text", cell: nil, residue: []} =
               init = source(pd, "bInitQuery")

      # Its group's project's name, or "Dr" while that is empty.
      assert %IR{
               op: :if,
               args: [
                 %IR{op: :is_empty},
                 %IR{op: :literal, args: ["Dr"]},
                 %IR{op: :field, args: [_, "project", "name_text"]}
               ]
             } = init.value.ir

      assert PageData.inputs(init) == [
               {:element_state, %{"element" => "bInitBox", "state" => "get_group_data"}}
             ]

      # A static initial content is the page's, not a source.
      assert source(pd, "bQuery") == nil

      # The last state that is true wins: a later state is outermost.
      later = %{
        "condition" => %{
          "type" => "ElementParent",
          "next" => %{
            "type" => "Message",
            "name" => "name_text",
            "next" => %{"type" => "Message", "name" => "is_not_empty"}
          }
        },
        "properties" => %{"content" => "Ea"}
      }

      {_model, pd} = build(put_in(app(), initial_path(["bInitQuery", "states", "1"]), later))

      assert %IR{
               op: :if,
               args: [_, %IR{args: ["Ea"]}, %IR{op: :if, args: [_, %IR{args: ["Dr"]}, _]}]
             } =
               source(pd, "bInitQuery").value.ir
    end

    test "that does not compile is residue; in a repeating group's cell it is no source" do
      no_condition =
        put_in(app(), initial_path(["bInitQuery", "states", "0", "condition"]), nil)

      {_model, pd} = build(no_condition)

      assert %Source{kind: :input, residue: [%{reason: :uncompiled_expression}]} =
               source(pd, "bInitQuery")

      in_cell =
        put_in(
          app(),
          ["pages", "initial", "elements", "bInitList", "elements", "bInCell"],
          %{
            "id" => "bInCell",
            "type" => "Input",
            "properties" => %{
              "content_format" => "text",
              "content" => %{
                "type" => "CurrentDataItem",
                "next" => %{"type" => "Message", "name" => "title_text"}
              }
            }
          }
        )

      {_model, pd} = build(in_cell)
      assert source(pd, "bInCell") == nil
    end

    test "makes the input tracked, read after its group and before what reads it" do
      {spec, _project, _frontend, _app, _model} = spec(app())
      page = spec.surfaces["bInitPage"]

      assert page.inputs == %{"bInitQuery" => :text}
      assert page.initial == ["bInitQuery"]

      assert %{
               kind: :input,
               read: {:value, _},
               residue: [],
               reads: [{:data, %{element: "bInitBox"}}]
             } =
               data(spec, "bInitQuery")

      assert %{read: {:query, q}, residue: []} = list = data(spec, "bInitList")
      assert {:data, %{path: [], element: "bInitQuery"}} in list.reads

      assert Enum.any?(
               q.pins,
               &match?(
                 %{value: %{bindings: [%{bind: {:input, %{element: "bInitQuery"}}} | _]}},
                 &1
               )
             )

      assert Enum.map(Spec.data(spec, "bInitPage"), & &1.element) ==
               ["bInitBox", "bInitQuery", "bInitList"]

      # Other inputs keep a static first value.
      assert spec.surfaces["bHome"].initial == []
    end

    test "that does not load leaves the input untracked, and what reads it unloaded" do
      unloaded =
        update_in(
          app(),
          ["pages", "initial", "elements", "bInitBox", "properties", "data_source", "properties"],
          &Map.put(&1, "dynamic_sort_field", "x")
        )

      {spec, _project, _frontend, _app, _model} = spec(unloaded)
      page = spec.surfaces["bInitPage"]

      assert page.inputs == %{}
      assert page.initial == []
      assert data(spec, "bInitQuery") == nil

      assert %{
               read: nil,
               residue: [
                 %{reason: :unavailable_input, detail: %{inputs: ["element_state:get_data"]}}
               ]
             } = data(spec, "bInitList")
    end

    test "reading the input itself is a cycle: the input is not tracked" do
      own = %{
        "type" => "GetElement",
        "properties" => %{"element_id" => "bInitQuery"},
        "next" => %{"type" => "Message", "name" => "get_data"}
      }

      {spec, _project, _frontend, _app, _model} =
        spec(put_in(app(), initial_path(["bInitQuery", "properties", "content"]), own))

      assert spec.surfaces["bInitPage"].initial == []
      assert data(spec, "bInitQuery") == nil
      assert %{read: nil} = data(spec, "bInitList")
    end

    test "is printed: the page keeps :data as the first value and shows the loaded one" do
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

      flows = files["lib/shop_web/live/initial_live/workflows.ex"]
      assert flows =~ ~s|inputs: %{"bInitQuery" => {:text, :data}}|
      assert flows =~ ~s|BubbleWorkflows.reset(ctx, [], "bInitBox", [{"bInitQuery", :data}])|

      assert flows =~
               ~r/element: "bInitList",.*?inputs: \["bInitQuery"\],\s*reads: \["bInitQuery"\]/s

      assert flows =~ ~r/if\(\s*Shop.Bubble.Runtime.empty\?\(/

      template = files["lib/shop_web/live/initial_live.html.heex"]
      assert template =~ ~s|Bubble.input(@bubble_inputs, @bubble_data, "", "bInitQuery"|
      refute template =~ "TODO(bubble:bInitQuery"
      refute template =~ "TODO(bubble:bInitList"

      component = files["lib/shop_web/components/bubble.ex"]
      assert component =~ "def input(inputs, data, scope, element, initial \\\\ nil)"
      assert files["lib/shop_web/bubble_workflows.ex"] =~ ":data -> Map.get(ctx.data, key)"
    end
  end
end

defmodule BubbleEx.PageDataUnloadedInstanceTest do
  # WTF-522: a reusable element's reads of its own thing load when any
  # instance's source loads; an instance whose own source does not load
  # is not rendered (residue), never rendered reading nothing. The
  # generated app's behavior is in page_data_behavior.exs.
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, PageData}
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Workflows.Frontend

  @fixture "test/support/target/phoenix/page_data.json"

  defp app, do: @fixture |> File.read!() |> Jason.decode!()

  defp spec(app) do
    {:ok, model} = Model.build(app)
    {:ok, page_data} = PageData.build(app, model)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    {:ok, lowered} = Frontend.build(app, model, index)

    {:ok, spec} =
      FrontendWorkflows.map(lowered, project,
        namespace: "Shop",
        frontend: frontend,
        page_data: page_data
      )

    {spec, %{app: app, model: model, index: index, project: project, frontend: frontend}}
  end

  defp files(app) do
    {spec, %{model: model, index: index, project: project, frontend: frontend}} = spec(app)

    {:ok, compiled} =
      BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
        runtime: "Shop.Bubble.Runtime",
        namespace: "Shop"
      )

    {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
    {:ok, workflows} = BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "Shop")

    opts = [
      name: "Shop",
      frontend: frontend,
      expressions: compiled,
      workflows: workflows,
      frontend_workflows: spec
    ]

    {:ok, files} = Phoenix.render(project, opts)
    {:ok, report} = Phoenix.frontend_report(project, opts)
    {files, report}
  end

  defp data(spec, element) do
    spec.surfaces
    |> Enum.flat_map(fn {_id, s} -> s.data end)
    |> Enum.find(&(&1.element == element))
  end

  defp put_pair(app, id, props),
    do: update_in(app, ["pages", "pair", "elements", id, "properties"], &Map.merge(&1, props))

  @uncompiled %{"type" => "NoSuchExpression"}

  @user_logged_in %{
    "type" => "CurrentUser",
    "next" => %{"type" => "Message", "name" => "logged_in"}
  }

  test "only the instance whose own source does not load is unloaded" do
    {spec, _} = spec(app())

    # The card's reads of its own thing load (other instances give it one).
    assert MapSet.member?(spec.data_index.roots, "bCard")
    assert %{kind: :instance, residue: []} = data(spec, "bPairA")
    assert %{kind: :instance, residue: [_ | _]} = data(spec, "bPairB")

    assert Spec.unloaded(spec, "bPairB") == [:uncompiled_expression]
    assert Spec.unloaded(spec, "bPairA") == nil
    assert Spec.unloaded(spec, "bCard1") == nil

    # The card's workflow reading its own thing stays native: it runs in
    # the instances the page renders, never in bPairB's scope.
    w = Spec.workflow(spec, "bCard", "wCardSelf")
    assert Spec.native?(w) and Spec.wired?(w)
  end

  test "a source reading data the page does not load, or a conditional one that does not compile" do
    # bPairB reads a group whose own source does not compile: the target
    # does not bind it (unavailable_input).
    bad = %{
      "id" => "bPairBad",
      "type" => "Group",
      "properties" => %{
        "group_type" => "custom.task",
        "width" => 300,
        "height" => 40,
        "data_source" => @uncompiled
      }
    }

    app =
      app()
      |> put_in(["pages", "pair", "elements", "bPairBad"], bad)
      |> put_pair("bPairB", %{
        "data_source" => %{
          "type" => "GetElement",
          "properties" => %{"element_id" => "bPairBad"},
          "next" => %{"type" => "Message", "name" => "get_group_data"}
        }
      })

    {spec, _} = spec(app)
    assert Spec.unloaded(spec, "bPairB") == [:unavailable_input]
    assert Spec.unloaded(spec, "bPairA") == nil

    # No source of its own, a conditional state whose source does not
    # compile: never shown from its base (empty) alone.
    state = %{
      "condition" => @user_logged_in,
      "properties" => %{"data_source" => @uncompiled}
    }

    app =
      app()
      |> update_in(
        ["pages", "pair", "elements", "bPairB", "properties"],
        &Map.delete(&1, "data_source")
      )
      |> put_in(["pages", "pair", "elements", "bPairB", "states"], %{"0" => state})

    {spec, _} = spec(app)
    assert [_ | _] = Spec.unloaded(spec, "bPairB")

    # A conditional source that loads: rendered, as before.
    ok = put_in(state, ["properties", "data_source"], %{"type" => "CurrentPageItem"})
    task_page = %{"type" => "Search", "properties" => %{"type_to_find" => "custom.task"}}
    ok = put_in(ok, ["properties", "data_source"], Map.put(task_page, "next", first()))
    app = put_in(app, ["pages", "pair", "elements", "bPairB", "states"], %{"0" => ok})
    {spec, _} = spec(app)
    assert Spec.unloaded(spec, "bPairB") == nil
    assert %{residue: [], read: {:switch, _}} = data(spec, "bPairB")
  end

  defp first, do: %{"type" => "Message", "name" => "first_element"}

  test "when no instance's source loads, the reads are marked and every instance renders" do
    app =
      app()
      |> put_pair("bPairA", %{"data_source" => @uncompiled})
      |> update_in(["pages", "index", "elements"], &Map.drop(&1, ["bCard1", "bCard2"]))

    {spec, _} = spec(app)
    refute MapSet.member?(spec.data_index.roots, "bCard")
    assert spec.data_index.unloaded == %{}

    {files, _report} = files(app)
    page = files["lib/shop_web/live/pair_live.html.heex"]
    card = files["lib/shop_web/components/reusables/task_card.html.heex"]

    assert page =~ ~s(<.task_card\n    data-bubble-id="bPairB")
    assert card =~ "TODO(bubble:bCardTitle) text: reads page data that is not loaded"
  end

  test "printed: the instance is residue, its scope is not rendered; its sibling is" do
    {files, report} = files(app())
    page = files["lib/shop_web/live/pair_live.html.heex"]
    flows = files["lib/shop_web/live/pair_live/workflows.ex"]

    assert page =~ ~s(<.task_card\n    data-bubble-id="bPairA")
    refute page =~ ~s(data-bubble-id="bPairB"\n    class="[color:#000000] h-[40px] relative)

    assert page =~
             ~r/<div data-bubble-id="bPairB"[^>]*>\s*<%!-- TODO\(bubble:bPairB\) not rendered: its data source does not load, and its reusable element reads the thing it gives \(Parent group\) --%>/

    assert page =~ "TODO(bubble:bPairB) its data source is not loaded (uncompiled_expression)"

    # No data, event or workflow runs in its scope.
    assert flows =~ ~s|@instances [{"bPairA", ShopWeb.Reusables.TaskCard.Workflows}]|

    assert report["counts"]["placeholder"] >= 1
  end

  test "an instance in a repeating group's cell whose own source does not load" do
    card = fn id, source ->
      %{
        "id" => id,
        "type" => "CustomElement",
        "properties" => %{
          "custom_id" => "bCard",
          "group_type" => "custom.task",
          "order" => 9,
          "width" => 300,
          "height" => 40,
          "data_source" => source
        }
      }
    end

    app =
      app()
      |> put_in(
        ["pages", "index", "elements", "bList", "elements", "bCellCardOk"],
        card.("bCellCardOk", %{"type" => "CurrentDataItem"})
      )
      |> put_in(
        ["pages", "index", "elements", "bList", "elements", "bCellCardBad"],
        card.("bCellCardBad", @uncompiled)
      )

    {spec, _} = spec(app)
    assert Spec.per_cell?(spec, "bCellCardOk")
    refute Spec.per_cell?(spec, "bCellCardBad")
    assert Spec.unloaded(spec, "bCellCardBad") == [:uncompiled_expression]

    {files, _report} = files(app)
    page = files["lib/shop_web/live/index_live.html.heex"]
    flows = files["lib/shop_web/live/index_live/workflows.ex"]

    assert flows =~ ~s|{"bList", [{"bCellCardOk", ShopWeb.Reusables.TaskCard.Workflows}]}|
    refute flows =~ ~s|"bCellCardBad", ShopWeb|
    assert page =~ "TODO(bubble:bCellCardBad) not rendered"
    refute page =~ "TODO(bubble:bCellCardBad) rendered once for every cell"
  end

  test "an instance of a reusable element that never reads its own thing is rendered" do
    # The card's title is static and its click sends no data: nothing in
    # it reads the thing an instance gives it, so bPairB renders as is.
    app =
      app()
      |> put_in(
        ["element_definitions", "card", "elements", "bCardTitle", "properties", "text"],
        %{"type" => "TextExpression", "entries" => %{"0" => "Card"}}
      )
      |> update_in(
        ["element_definitions", "card", "workflows", "wCardSelf", "actions", "0", "properties"],
        &Map.delete(&1, "data_to_send")
      )

    {spec, %{model: model}} = spec(app)
    {:ok, page_data} = PageData.build(app, model)
    refute MapSet.member?(page_data.self_reads, "bCard")
    assert spec.data_index.unloaded == %{}

    {files, _report} = files(app)
    page = files["lib/shop_web/live/pair_live.html.heex"]
    assert page =~ ~s(<.task_card\n    data-bubble-id="bPairB")
    refute page =~ "TODO(bubble:bPairB) not rendered"

    # The fixture's card reads it (its title, its click's data).
    {:ok, page_data} = PageData.build(app(), model)
    assert MapSet.member?(page_data.self_reads, "bCard")
  end

  test "a Display data step into the instance is not kept" do
    button = fn id ->
      %{"id" => id, "type" => "Button", "properties" => %{"width" => 300, "height" => 40}}
    end

    show = fn id, button, instance ->
      %{
        "id" => id,
        "type" => "ButtonClicked",
        "properties" => %{"element_id" => button},
        "actions" => %{
          "0" => %{
            "id" => id <> "1",
            "type" => "DisplayGroupData",
            "properties" => %{
              "element_id" => instance,
              "data_source" => %{
                "type" => "GetElement",
                "properties" => %{"element_id" => "bPairA"},
                "next" => %{"type" => "Message", "name" => "get_group_data"}
              }
            }
          }
        }
      }
    end

    app =
      app()
      |> update_in(["pages", "pair", "elements"], fn els ->
        els |> Map.put("bShowA", button.("bShowA")) |> Map.put("bShowB", button.("bShowB"))
      end)
      |> put_in(["pages", "pair", "workflows"], %{
        "wShowA" => show.("wShowA", "bShowA", "bPairA"),
        "wShowB" => show.("wShowB", "bShowB", "bPairB")
      })

    {spec, _} = spec(app)
    assert Spec.unloaded(spec, "bPairB") == [:uncompiled_expression]
    assert %{steps: [%{residue: []}]} = Spec.workflow(spec, "bPairPage", "wShowA")

    assert %{steps: [%{residue: [%{reason: :target_not_rendered, detail: detail}]}]} =
             Spec.workflow(spec, "bPairPage", "wShowB")

    assert detail == %{element: "element:bPairB"}
  end

  test "a nested instance below the unloaded one has no scope either" do
    # The card nests a panel whose source is the card's own thing.
    nested = %{
      "id" => "bCardPanel",
      "type" => "CustomElement",
      "properties" => %{
        "custom_id" => "bPanel",
        "group_type" => "custom.task",
        "order" => 3,
        "width" => 300,
        "height" => 40,
        "data_source" => %{"type" => "ElementParent"}
      }
    }

    app = put_in(app(), ["element_definitions", "card", "elements", "bCardPanel"], nested)
    {spec, _} = spec(app)
    assert Spec.unloaded(spec, "bPairB") == [:uncompiled_expression]
    assert Spec.unloaded(spec, "bCardPanel") == nil

    {files, _report} = files(app)
    flows = files["lib/shop_web/live/pair_live/workflows.ex"]
    [instances] = Regex.run(~r/@instances \[.*?\]\n/s, flows)
    assert instances =~ ~s("bPairA")
    assert instances =~ "bCardPanel"
    refute instances =~ "bPairB"
  end

  test "an unloaded instance in a popup is residue there too" do
    popup = %{
      "id" => "bPairPop",
      "type" => "Popup",
      "properties" => %{"order" => 3, "width" => 300, "height" => 200},
      "elements" => %{"bPairB" => app()["pages"]["pair"]["elements"]["bPairB"]}
    }

    app =
      app()
      |> update_in(["pages", "pair", "elements"], &Map.delete(&1, "bPairB"))
      |> put_in(["pages", "pair", "elements", "bPairPop"], popup)

    {spec, _} = spec(app)
    assert Spec.unloaded(spec, "bPairB") == [:uncompiled_expression]

    {files, _report} = files(app)
    page = files["lib/shop_web/live/pair_live.html.heex"]
    flows = files["lib/shop_web/live/pair_live/workflows.ex"]
    assert page =~ "TODO(bubble:bPairB) not rendered"
    refute page =~ ~s(<.task_card\n      data-bubble-id="bPairB")
    refute flows =~ ~s({"bPairB", ShopWeb)
  end

  test "a page condition reading the instance's custom state is not decided" do
    cond_on = fn instance ->
      %{
        "0" => %{
          "condition" => %{
            "type" => "GetElement",
            "properties" => %{"element_id" => instance},
            "next" => %{
              "type" => "Message",
              "name" => "custom.seen_",
              "next" => %{
                "type" => "Message",
                "name" => "equals",
                "args" => %{"type" => "TextExpression", "entries" => %{"0" => "yes"}}
              }
            }
          },
          "properties" => %{"is_visible" => false}
        }
      }
    end

    text = fn id, instance ->
      %{
        "id" => id,
        "type" => "Text",
        "properties" => %{
          "width" => 300,
          "height" => 40,
          "text" => %{"type" => "TextExpression", "entries" => %{"0" => "Seen"}}
        },
        "states" => cond_on.(instance)
      }
    end

    app =
      app()
      |> put_in(["element_definitions", "card", "custom_states"], %{
        "seen_" => %{"default_val" => "no", "display" => "Seen", "value" => "text"}
      })
      |> update_in(["pages", "pair", "elements"], fn els ->
        els
        |> Map.put("bSeenA", text.("bSeenA", "bPairA"))
        |> Map.put("bSeenB", text.("bSeenB", "bPairB"))
      end)

    {files, _report} = files(app)
    page = files["lib/shop_web/live/pair_live.html.heex"]
    refute page =~ "TODO(bubble:bSeenA) visibility"

    assert page =~
             ~r/TODO\(bubble:bSeenB\) visibility: 1 conditional not lowered \(it reads a value the page does not keep: element_state:custom.seen_\)/
  end

  test "a page's workflow calling into the instance's custom event is not run there" do
    # The card's custom event reads its own thing; the pair page calls it
    # in each instance.
    event = %{
      "id" => "wCardEvt",
      "type" => "CustomEvent",
      "properties" => %{"event_name" => "go"},
      "actions" => %{
        "0" => %{
          "id" => "aCardEvt1",
          "type" => "ChangePage",
          "properties" => %{
            "element_id" => "Current page",
            "data_to_send" => %{"type" => "ElementParent"}
          }
        }
      }
    }

    button = fn id ->
      %{"id" => id, "type" => "Button", "properties" => %{"width" => 300, "height" => 40}}
    end

    call = fn id, button, instance ->
      %{
        "id" => id,
        "type" => "ButtonClicked",
        "properties" => %{"element_id" => button},
        "actions" => %{
          "0" => %{
            "id" => id <> "1",
            "type" => "TriggerCustomEventFromReusable",
            "properties" => %{"custom_event" => "wCardEvt", "element_id" => instance}
          }
        }
      }
    end

    app =
      app()
      |> put_in(["element_definitions", "card", "workflows", "wCardEvt"], event)
      |> update_in(["pages", "pair", "elements"], fn els ->
        els |> Map.put("bCallA", button.("bCallA")) |> Map.put("bCallB", button.("bCallB"))
      end)
      |> put_in(["pages", "pair", "workflows"], %{
        "wCallA" => call.("wCallA", "bCallA", "bPairA"),
        "wCallB" => call.("wCallB", "bCallB", "bPairB")
      })

    {spec, _} = spec(app)
    assert %{steps: [%{residue: []}]} = Spec.workflow(spec, "bPairPage", "wCallA")

    assert %{steps: [%{residue: [%{reason: :target_not_rendered, detail: detail}]}]} =
             Spec.workflow(spec, "bPairPage", "wCallB")

    assert detail == %{element: "element:bPairB"}
  end

  test "a default read from outside the instance, and its custom states, fail closed" do
    # The card gets a property whose default reads its own thing, and a
    # custom state; the pair page reads both from each instance.
    label = %{
      "btype_id" => "text",
      "editor_type" => "DynamicValue",
      "is_list" => false,
      "optional" => true,
      "param_id" => "pLabel",
      "param_name" => "Label",
      "default_value" => %{
        "type" => "TextExpression",
        "entries" => %{
          "0" => "Card ",
          "1" => %{
            "type" => "GetElement",
            "properties" => %{"element_id" => "bCard"},
            "next" => %{
              "type" => "Message",
              "name" => "get_group_data",
              "next" => %{"type" => "Message", "name" => "title_text"}
            }
          }
        }
      }
    }

    reads = fn instance, name ->
      %{
        "type" => "GetElement",
        "properties" => %{"element_id" => instance},
        "next" => %{"type" => "Message", "name" => name}
      }
    end

    list = fn id, instance ->
      %{
        "id" => id,
        "type" => "RepeatingGroup",
        "properties" => %{
          "group_type" => "custom.task",
          "rows" => 2,
          "columns" => 1,
          "width" => 300,
          "height" => 40,
          "data_source" => %{
            "type" => "Search",
            "properties" => %{
              "type_to_find" => "custom.task",
              "constraints" => %{
                "0" => %{
                  "key" => "title_text",
                  "constraint_type" => "equals",
                  "value" => reads.(instance, "param_pLabel")
                }
              }
            }
          }
        }
      }
    end

    text = fn id, instance, name ->
      %{
        "id" => id,
        "type" => "Text",
        "properties" => %{
          "width" => 300,
          "height" => 40,
          "text" => %{"type" => "TextExpression", "entries" => %{"0" => reads.(instance, name)}}
        }
      }
    end

    app =
      app()
      |> put_in(["element_definitions", "card", "properties", "parameters"], %{"0" => label})
      |> put_in(["element_definitions", "card", "custom_states"], %{
        "seen_" => %{"default_val" => "no", "display" => "Seen", "value" => "text"}
      })
      |> update_in(["pages", "pair", "elements"], fn els ->
        els
        |> Map.put("bPairListA", list.("bPairListA", "bPairA"))
        |> Map.put("bPairListB", list.("bPairListB", "bPairB"))
        |> Map.put("bPairLabelA", text.("bPairLabelA", "bPairA", "param_pLabel"))
        |> Map.put("bPairLabelB", text.("bPairLabelB", "bPairB", "param_pLabel"))
        |> Map.put("bPairSeenA", text.("bPairSeenA", "bPairA", "custom.seen_"))
        |> Map.put("bPairSeenB", text.("bPairSeenB", "bPairB", "custom.seen_"))
      end)

    {spec, _} = spec(app)

    # A's default is read from outside; B's scope is not read, so neither
    # is its default.
    assert %{residue: []} = data(spec, "bPairListA")

    assert %{residue: [%{reason: :unavailable_input, detail: %{inputs: ["element_state:param"]}}]} =
             data(spec, "bPairListB")

    assert Spec.instance_property(spec, "bPairPage", "bPairA", "param_pLabel")
    refute Spec.instance_property(spec, "bPairPage", "bPairB", "param_pLabel")

    state = fn e -> {:element_state, %{"element" => e, "state" => "custom.seen_"}} end
    assert {:state, %{path: ["bPairA"]}} = Spec.read(spec, "bPairPage", state.("bPairA"))
    assert Spec.read(spec, "bPairPage", state.("bPairB")) == nil

    {files, _report} = files(app)
    page = files["lib/shop_web/live/pair_live.html.heex"]
    refute page =~ "TODO(bubble:bPairLabelA)"
    assert page =~ "TODO(bubble:bPairLabelB) text: reads page data that is not loaded"
    assert page =~ "TODO(bubble:bPairSeenB)"
    refute page =~ "TODO(bubble:bPairSeenA)"
  end
end
