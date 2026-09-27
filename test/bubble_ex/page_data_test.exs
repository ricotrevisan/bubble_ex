defmodule BubbleEx.PageDataTest do
  # WTF-420: the data a page shows, lowered stack-neutrally, bound to Ash
  # reads for LiveView and printed with the pages. The behavior of the
  # generated app is test/support/target/phoenix/page_data_behavior.exs
  # (scripts/phoenix_compile_check.sh).
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, PageData}
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

      assert PageData.coverage(pd)["sources"] == %{"total" => 7, "native" => 7, "residue" => 0}
      assert {:ok, ^pd} = PageData.build(app(), elem(build(app()), 0))
    end

    test "a search that does not state ignore_empty_constraints is residue, loudly" do
      app =
        update_in(
          app(),
          ["pages", "index", "elements", "bList", "properties", "data_source", "properties"],
          &Map.delete(&1, "ignore_empty_constraints")
        )

      {_model, pd} = build(app)

      assert [%{reason: :uncompiled_expression, detail: %{constructs: constructs}}] =
               source(pd, "bList").residue

      assert "expr_uncompiled:ignore_empty_constraints" in constructs
      assert [%{code: :page_data_residue}] = pd.diagnostics
      assert PageData.residue(pd) == source(pd, "bList").residue

      # The caller may supply Bubble's default (not verified).
      {_model, pd} = build(app, ignore_empty_constraints: true)
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

      assert FrontendWorkflows.data_coverage(spec)["sources"] == %{
               "total" => 7,
               "wired" => 7,
               "residue" => 0
             }
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

      # The list is not generated (its search does not say whether it
      # ignores empty constraints): the group reading it is not either.
      app =
        update_in(
          app,
          ["pages", "index", "elements", "bList", "properties", "data_source", "properties"],
          &Map.delete(&1, "ignore_empty_constraints")
        )

      {spec, _project, _frontend, _app, _model} = spec(app)

      assert %{
               read: nil,
               residue: [
                 %{reason: :unavailable_input, detail: %{inputs: ["element_state:get_list_data"]}}
               ]
             } = data(spec, "bFromList")

      assert FrontendWorkflows.data_coverage(spec)["sources"]["wired"] == 5
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
    refute files["lib/shop_web/bubble_routes.ex"] =~ ":bubble_thing"
  end
end
