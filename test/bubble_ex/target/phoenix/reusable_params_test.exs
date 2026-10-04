defmodule BubbleEx.Target.Phoenix.ReusableParamsTest do
  # Reusable element properties (WTF-493), from the synthetic
  # test/support/target/phoenix/reusable_params.json: lowered as page data
  # (BubbleEx.PageData), bound (FrontendWorkflows.Data / Spec) and printed.
  # scripts/phoenix_compile_check.sh compiles the output and runs
  # test/support/target/phoenix/reusable_params_behavior.exs against it.
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model}
  alias BubbleEx.Expression.IR
  alias BubbleEx.PageData
  alias BubbleEx.Target.Elixir.{Frontend, FrontendWorkflows}
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Target.Phoenix

  @fixture "test/support/target/phoenix/reusable_params.json"

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

    %{files: files, page_data: page_data, spec: spec}
  end

  setup_all do
    build(app())
  end

  defp param(page_data, element, param),
    do:
      Enum.find(
        page_data.sources,
        &(&1.kind == :param and &1.element == element and &1.param == param)
      )

  defp bound(spec, surface, element, param),
    do: Enum.find(Spec.data(spec, surface), &(&1.element == element and &1.param == param))

  defp put_in_app(app, path, value), do: put_in(app, Enum.map(path, &Access.key(&1, %{})), value)

  describe "lowering (BubbleEx.PageData)" do
    test "an instance's values are sources where the instance is", %{page_data: pd} do
      title = param(pd, "bCardA", "param_pTitle")

      assert %{surface: "bTaskPage", holder: "bCard", type: "text", cell: nil, residue: []} =
               title

      assert title.id == "element:bCardA"

      # The editor keeps yes/no and numbers as text: they are the
      # property's type.
      assert %IR{op: :literal, args: [true], type: "boolean"} =
               param(pd, "bCardA", "param_pFlag").value.ir

      assert %IR{op: :literal, args: [3]} = param(pd, "bCardA", "param_pCount").value.ir

      # A thing, a list of things, a date: expressions in the page's scope.
      assert %{type: "custom.task", residue: []} = param(pd, "bCardA", "param_pTask")
      assert %{type: "list.custom.task", residue: []} = param(pd, "bCardA", "param_pTasks")
      assert %{type: "date", residue: []} = param(pd, "bCardA", "param_pDue")

      # Only what the instance sets.
      refute param(pd, "bCardA", "param_pNote")
      refute param(pd, "bCardB", "param_pTask")

      # Inside a repeating group's cell: its cell's.
      assert %{cell: "bList"} = param(pd, "bCardC", "param_pTask")

      # A nested instance's, in the reusable element.
      assert %{surface: "bCard", holder: "bBadgeDef"} = param(pd, "bBadge", "param_pLabel")
    end

    test "a default is a source of the reusable element", %{page_data: pd} do
      assert %{surface: "bCard", holder: "bCard", id: "reusable:bCard", residue: []} =
               param(pd, "bCard", "param_pNote")

      assert %{residue: []} = param(pd, "bCard", "param_pHeading")
      # No default, no source.
      refute param(pd, "bCard", "param_pTitle")

      assert %{"by_kind" => %{"param" => %{"total" => 16, "native" => 16}}} =
               PageData.coverage(pd)
    end

    test "a static value that is not the property's type is residue" do
      app = put_in_app(app(), ~w(pages task elements bCardB properties param_pCount), "many")
      {:ok, model} = Model.build(app)
      {:ok, pd} = PageData.build(app, model)

      assert [%{reason: :uncompiled_expression, detail: %{constructs: ["static_value"]}}] =
               param(pd, "bCardB", "param_pCount").residue
    end
  end

  describe "binding" do
    test "This Reusable's property is page data kept under the instance's scope", %{spec: spec} do
      read = fn surface, element, state ->
        Spec.read(spec, surface, {:element_state, %{"element" => element, "state" => state}})
      end

      assert read.("bCard", "bCard", "param_pTitle") ==
               {:data, %{path: [], element: "param_pTitle"}}

      # Set by no instance, with no default: still read (empty).
      assert read.("bCard", "bCard", "param_pDue") == {:data, %{path: [], element: "param_pDue"}}

      # An instance's value, from where the instance is.
      assert read.("bTaskPage", "bCardA", "param_pTitle") ==
               {:data, %{path: ["bCardA"], element: "param_pTitle"}}

      # Not set by that instance (its default is computed inside it).
      assert read.("bTaskPage", "bCardB", "param_pTask") == nil
      # In a cell: not passed.
      assert read.("bTaskPage", "bCardC", "param_pTitle") == nil
    end

    test "values load in order: a default after what it reads, a source after a property",
         %{spec: spec} do
      assert %{key: %{path: ["bCardA"], element: "param_pTask"}, residue: []} =
               bound(spec, "bTaskPage", "bCardA", "param_pTask")

      assert %{key: %{path: [], element: "param_pHeading"}, residue: []} =
               bound(spec, "bCard", "bCard", "param_pHeading")

      assert %{reads: [{:data, %{path: [], element: "param_pTask"}}], residue: []} =
               Enum.find(Spec.data(spec, "bCard"), &(&1.element == "bGroup"))

      assert %{residue: [%{reason: :page_data_in_cell}]} =
               bound(spec, "bTaskPage", "bCardC", "param_pTask")

      # The workflow reading a property runs.
      assert %{blocked_by: [], residue: []} = Spec.workflow(spec, "bCard", "wBump")
    end

    test "a property read only when every instance's value of it loads" do
      app =
        put_in_app(app(), ~w(pages task elements bCardB properties param_pTitle), %{
          "type" => "NoSuchExpression"
        })

      %{spec: spec, files: files} = build(app)

      assert Spec.read(
               spec,
               "bCard",
               {:element_state, %{"element" => "bCard", "state" => "param_pTitle"}}
             ) == nil

      # The default reading it is not loaded either, loudly.
      assert %{
               residue: [
                 %{reason: :unavailable_input, detail: %{inputs: ["element_state:param"]}}
               ]
             } =
               bound(spec, "bCard", "bCard", "param_pHeading")

      template = files["lib/shop_web/components/reusables/card.html.heex"]

      assert template =~
               "TODO(bubble:bTitle) text: reads page data that is not loaded (element_state:param_pTitle)"

      assert files["lib/shop_web/live/task_live.html.heex"] =~
               "TODO(bubble:bCardB) its property param_pTitle is not passed (uncompiled_expression)"
    end
  end

  describe "binding, across surfaces" do
    test "a value that lowers but does not load blocks what reads the property" do
      # bCardB's Task: bCardC's, which a cell keeps (not passed).
      app =
        put_in_app(app(), ~w(pages task elements bCardB properties param_pTask), %{
          "type" => "GetElement",
          "properties" => %{"element_id" => "bCardC"},
          "next" => %{"type" => "Message", "name" => "param_pTask"}
        })

      %{spec: spec} = build(app)

      assert %{residue: [%{reason: :unavailable_input}]} =
               bound(spec, "bTaskPage", "bCardB", "param_pTask")

      # The group reading This Reusable's Task, and the nested instance's
      # value reading it.
      assert %{residue: [%{reason: :unavailable_input, detail: %{inputs: ["data_source"]}}]} =
               Enum.find(Spec.data(spec, "bCard"), &(&1.element == "bGroup"))

      assert %{residue: [%{reason: :unavailable_input, detail: %{inputs: ["data_source"]}}]} =
               bound(spec, "bCard", "bBadge", "param_pLabel")

      assert Spec.read(
               spec,
               "bCard",
               {:element_state, %{"element" => "bCard", "state" => "param_pTask"}}
             ) == nil
    end
  end

  describe "the generated app" do
    test "the component reads its properties from the page's data, by scope", %{files: files} do
      template = files["lib/shop_web/components/reusables/card.html.heex"]

      assert template =~ ~s|Bubble.data(@bubble_data, @scope, "param_pTitle")|

      assert template =~
               ~s|hidden={!visible_bflagt(Bubble.data(@bubble_data, @scope, "param_pFlag"))}|

      assert template =~ ~s|bubble_data={@bubble_data}|

      badge = files["lib/shop_web/components/reusables/badge.html.heex"]
      assert badge =~ ~s|Bubble.data(@bubble_data, @scope, "param_pLabel")|

      page = files["lib/shop_web/live/task_live.html.heex"]
      assert page =~ ~s|Bubble.data(@bubble_data, "bCardA", "param_pTitle")|

      assert page =~
               "TODO(bubble:bCardC) its property param_pTask is not passed (page_data_in_cell)"
    end

    test "values and defaults are data sources of their surfaces", %{files: files} do
      page = files["lib/shop_web/live/task_live/workflows.ex"]
      assert page =~ ~s|element: "param_pTitle",|
      assert page =~ ~s|instance: "bCardA",|
      assert page =~ "# bubble:data bCardA param_pTitle\n"
      assert page =~ ~s|BubbleData.records(ctx, nil, true, false, nil)|

      card = files["lib/shop_web/components/reusables/card/workflows.ex"]
      assert card =~ "# bubble:data bCard param_pNote\n"
      assert card =~ ~r/element: "param_pNote",.*?default: true/s
      assert card =~ ~s|BubbleWorkflows.data(ctx, [], "param_pCount")|

      loader = files["lib/shop_web/bubble_data.ex"]
      assert loader =~ "Map.get(source, :default, false)"
    end

    test "the data coverage counts the properties", %{spec: spec} do
      assert %{"by_kind" => %{"param" => %{"total" => 16, "wired" => 14}}} =
               FrontendWorkflows.data_coverage(spec)
    end
  end
end
