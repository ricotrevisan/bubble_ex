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

      # Inside a repeating group's cell: its cell's (WTF-494), only what
      # the instance sets.
      assert %{cell: "bList"} = param(pd, "bCardC", "param_pTask")
      refute param(pd, "bCardC", "param_pFlag")

      assert %{cell: "bList", holder: "bRowDef", type: "boolean"} =
               param(pd, "bRowC", "param_pFlag")

      # A nested instance's, in the reusable element.
      assert %{surface: "bCard", holder: "bBadgeDef"} = param(pd, "bBadge", "param_pLabel")
    end

    test "a default is a source of the reusable element", %{page_data: pd} do
      assert %{surface: "bCard", holder: "bCard", id: "reusable:bCard", residue: []} =
               param(pd, "bCard", "param_pNote")

      assert %{residue: []} = param(pd, "bCard", "param_pHeading")
      # No default, no source.
      refute param(pd, "bCard", "param_pTitle")

      assert %{"by_kind" => %{"param" => %{"total" => 25, "native" => 25}}} =
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
               {:data, %{path: [], element: "param_pTitle/bCard"}}

      # Set by no instance, with no default: still read (empty).
      assert read.("bCard", "bCard", "param_pDue") ==
               {:data, %{path: [], element: "param_pDue/bCard"}}

      # An instance's value, from where the instance is.
      assert read.("bTaskPage", "bCardA", "param_pTitle") ==
               {:data, %{path: ["bCardA"], element: "param_pTitle/bCard"}}

      # Not set by that instance (its default is computed inside it).
      assert read.("bTaskPage", "bCardB", "param_pTask") == nil
      # In a cell: kept per cell, not read from the page.
      assert read.("bTaskPage", "bCardC", "param_pTitle") == nil
      assert read.("bTaskPage", "bRowC", "param_pLabel") == nil
    end

    test "values load in order: a default after what it reads, a source after a property",
         %{spec: spec} do
      assert %{key: %{path: ["bCardA"], element: "param_pTask/bCard"}, residue: []} =
               bound(spec, "bTaskPage", "bCardA", "param_pTask")

      assert %{key: %{path: [], element: "param_pHeading/bCard"}, residue: []} =
               bound(spec, "bCard", "bCard", "param_pHeading")

      assert %{reads: [{:data, %{path: [], element: "param_pTask/bCard"}}], residue: []} =
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

  describe "with Display data (WTF-492)" do
    test "a step sets the instance's own thing; its properties stay sources of the page",
         %{spec: spec, files: files} do
      assert %{read: :displayed, kind: :instance, displayed?: true} =
               Enum.find(
                 Spec.data(spec, "bTaskPage"),
                 &(&1.element == "bCardB" and &1.param == nil)
               )

      for p <- ~w(param_pTitle param_pCount param_pFlag param_pNote) do
        assert %{displayed?: false, residue: []} = bound(spec, "bTaskPage", "bCardB", p)
      end

      page = files["lib/shop_web/live/task_live/workflows.ex"]
      refute page =~ ~r/element: "param_pTitle\/bCard",[^}]*display:/s
    end
  end

  describe "property IDs" do
    test "are keyed with their reusable element: two may share an ID", %{spec: spec, files: files} do
      # Card's Task (a thing) and Badge's (text) share the ID pTask.
      assert %{key: %{element: "param_pTask/bCard"}} =
               bound(spec, "bTaskPage", "bCardA", "param_pTask")

      assert %{key: %{element: "param_pTask/bBadgeDef"}} =
               bound(spec, "bBadgeDef", "bBadgeDef", "param_pTask")

      # The project, read through Card's Task, is loaded with Card's value
      # only, never with Badge's text.
      page = files["lib/shop_web/live/task_live/workflows.ex"]
      assert page =~ ~r/element: "param_pTask\/bCard",[^}]*loads: \[\["project"\]\]/s

      badge = files["lib/shop_web/components/reusables/badge/workflows.ex"]
      assert badge =~ ~r/element: "param_pTask\/bBadgeDef",[^}]*loads: \[\],/s
    end

    test "a default reading its own property is a cycle" do
      app =
        put_in_app(
          app(),
          ~w(element_definitions card properties parameters 6 default_value),
          %{
            "type" => "TextExpression",
            "entries" => %{
              "0" => %{
                "type" => "GetElement",
                "properties" => %{"element_id" => "bCard"},
                "next" => %{"type" => "Message", "name" => "param_pNote"}
              }
            }
          }
        )

      %{spec: spec} = build(app)

      assert %{residue: [%{reason: :unresolved_reference, detail: %{reference: "data_source"}}]} =
               bound(spec, "bCard", "bCard", "param_pNote")
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

      assert template =~ ~s|Bubble.data(@bubble_data, @scope, "param_pTitle/bCard")|

      assert template =~
               ~s|hidden={!visible_bflagt(Bubble.data(@bubble_data, @scope, "param_pFlag/bCard"))}|

      assert template =~ ~s|bubble_data={@bubble_data}|

      badge = files["lib/shop_web/components/reusables/badge.html.heex"]
      assert badge =~ ~s|Bubble.data(@bubble_data, @scope, "param_pLabel/bBadgeDef")|

      page = files["lib/shop_web/live/task_live.html.heex"]
      assert page =~ ~s|Bubble.data(@bubble_data, "bCardA", "param_pTitle/bCard")|

      # In a cell where the instance is not rendered per cell, what it sets
      # is marked (WTF-494).
      for p <- ~w(pTitle pTask) do
        assert page =~
                 "TODO(bubble:bCardC) its property param_#{p} is not passed (page_data_in_cell)"
      end

      refute page =~ "TODO(bubble:bCardC) its property param_pFlag"

      assert page =~
               "TODO(bubble:bCardC) rendered once for every cell, not per cell (page_data_in_cell)"
    end

    test "values and defaults are data sources of their surfaces", %{files: files} do
      page = files["lib/shop_web/live/task_live/workflows.ex"]
      assert page =~ ~s|element: "param_pTitle/bCard",|
      assert page =~ ~s|instance: "bCardA",|
      assert page =~ "# bubble:data bCardA param_pTitle\n"
      assert page =~ ~s|BubbleData.records(ctx, nil, true, false, nil)|

      card = files["lib/shop_web/components/reusables/card/workflows.ex"]
      assert card =~ "# bubble:data bCard param_pNote\n"
      assert card =~ ~r/element: "param_pNote\/bCard",.*?default: true/s
      assert card =~ ~s|BubbleWorkflows.data(ctx, [], "param_pCount/bCard")|

      loader = files["lib/shop_web/bubble_data.ex"]
      assert loader =~ "Map.get(source, :default, false)"
    end

    test "the data coverage counts the properties", %{spec: spec} do
      assert %{"by_kind" => %{"param" => %{"total" => 25, "wired" => 23}}} =
               FrontendWorkflows.data_coverage(spec)
    end
  end

  describe "an instance in a repeating group's cell (WTF-494)" do
    test "is rendered per cell unless its reusable element searches with its instance",
         %{spec: spec} do
      assert Spec.per_cell?(spec, "bRowC")
      assert %{surface: "bTaskPage", cell: "bList", holder: "bRowDef"} = spec.cells["bRowC"]

      # Card's bFound searches with This Card's Query: once per cell.
      refute Spec.per_cell?(spec, "bCardC")

      assert [%{reason: :page_data_in_cell, detail: %{kind: "query"}}] =
               spec.cells["bCardC"].residue

      assert %{residue: [%{reason: :page_data_in_cell, detail: %{kind: "query"}}]} =
               bound(spec, "bTaskPage", "bCardC", "param_pTask")

      # Not per element: an instance outside a cell.
      refute Spec.per_cell?(spec, "bCardA")
    end

    test "its thing and properties are computed per cell, after the list", %{spec: spec} do
      assert %{
               cell: "bList",
               key: %{path: ["bRowC"], element: "param_pLabel/bRowDef"},
               reads: [{:cell, "bList"}],
               residue: []
             } = bound(spec, "bTaskPage", "bRowC", "param_pLabel")

      # A static-free value reads the list all the same: it is per cell.
      assert %{reads: reads, residue: []} = bound(spec, "bTaskPage", "bRowC", "param_pQuery")
      assert {:cell, "bList"} in reads

      assert %{kind: :instance, key: %{path: ["bRowC"], element: "bRowDef"}, residue: []} =
               Enum.find(
                 Spec.data(spec, "bTaskPage"),
                 &(&1.element == "bRowC" and &1.kind == :instance)
               )

      # Read in the cell's scope inside the reusable element.
      assert Spec.read(
               spec,
               "bRowDef",
               {:element_state, %{"element" => "bRowDef", "state" => "param_pLabel"}}
             ) == {:data, %{path: [], element: "param_pLabel/bRowDef"}}

      # Its workflows run (in the cell's scope, at run time).
      assert %{blocked_by: [], residue: []} = Spec.workflow(spec, "bRowDef", "wRowPick")
      assert %{blocked_by: [], residue: []} = Spec.workflow(spec, "bRowDef", "wRowShow")
    end

    test "the page lists its cells; the component gets the cell's scope", %{files: files} do
      page = files["lib/shop_web/live/task_live/workflows.ex"]

      assert page =~
               ~r/@cells \[\s*\{"bList",\s*\[\s*\{"bRowC", ShopWeb\.Reusables\.Row\.Workflows\},\s*\{"bRowC-bRowChip", ShopWeb\.Reusables\.Chip\.Workflows\}\s*\]\}\s*\]/

      assert page =~ "def __bubble__(:cells), do: @cells"
      # Card is not rendered per cell: not listed.
      refute page =~ ~s|{"bCardC", ShopWeb.Reusables.Card.Workflows}|

      template = files["lib/shop_web/live/task_live.html.heex"]

      assert template =~
               ~s|scope={Bubble.nest(Bubble.cell_scope("", "bList", cell_blist, cell_blist_i), "bRowC")}|

      assert template =~ ~s|scope="bCardC"|

      # A search reading nothing of the instance is read once for every
      # cell; the relationships a value loads through what it reads are
      # loaded for every cell first.
      row = files["lib/shop_web/components/reusables/row/workflows.ex"]
      assert row =~ ~r/element: "bRowAny",[^}]*shared: true/s
      refute row =~ ~r/element: "bRowShown",[^}]*shared: true/s
    end

    test "a reusable element nesting one that searches with its instance is not per cell" do
      # Row nests Card (whose bFound searches with This Card's Query).
      app =
        put_in_app(
          app(),
          ~w(element_definitions row elements bRowCard),
          %{
            "id" => "bRowCard",
            "type" => "CustomElement",
            "properties" => %{
              "custom_id" => "bCard",
              "order" => 13,
              "width" => 300,
              "height" => 40
            }
          }
        )

      %{spec: spec, files: files} = build(app)
      refute Spec.per_cell?(spec, "bRowC")

      assert %{residue: [%{reason: :page_data_in_cell}]} =
               bound(spec, "bTaskPage", "bRowC", "param_pLabel")

      refute files["lib/shop_web/live/task_live/workflows.ex"] =~ ~s|{"bRowC", |
    end
  end
end
