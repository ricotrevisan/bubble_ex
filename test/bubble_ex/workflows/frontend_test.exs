defmodule BubbleEx.Workflows.FrontendTest do
  # The stack-neutral lowering of page and reusable-element workflows
  # (WTF-372) over test/support/target/phoenix/frontend_workflows.json.
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, Plan}
  alias BubbleEx.Workflows.Frontend
  alias BubbleEx.Workflows.Frontend.Workflow

  @fixture "test/support/target/phoenix/frontend_workflows.json"

  defp app, do: @fixture |> File.read!() |> Jason.decode!()

  defp lower(app) do
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, lowered} = Frontend.build(app, model, index)
    lowered
  end

  defp workflow(lowered, id), do: Enum.find(lowered.workflows, &(&1.bubble_id == id))

  # `app` with `fun` applied to the workflow `id` of page `home`.
  defp edit(app, id, fun), do: update_in(app, ["pages", "home", "workflows", id], fun)

  setup_all do
    %{lowered: lower(app())}
  end

  test "every page and reusable-element workflow is lowered, in a stable order", %{
    lowered: lowered
  } do
    assert length(lowered.workflows) == 29

    assert Enum.map(lowered.workflows, &{&1.surface, &1.bubble_id}) ==
             Enum.sort(Enum.map(lowered.workflows, &{&1.surface, &1.bubble_id}))

    assert workflow(lowered, "wCardInc").surface == "reusable:bCard"
    assert workflow(lowered, "wState").surface == "page:bHome"
    assert lower(app()) == lowered
  end

  test "events: element, kind, condition, run-when, disabled", %{lowered: lowered} do
    assert %Workflow{kind: :click, element: "bBtnOpen", disabled?: false} =
             workflow(lowered, "wOpen")

    assert %Workflow{kind: :click, disabled?: true} = workflow(lowered, "wOpenOff")
    assert %Workflow{kind: :input_change, element: "bNum"} = workflow(lowered, "wChanged")
    assert %Workflow{kind: :page_load, element: nil} = workflow(lowered, "wLoad")

    assert %Workflow{kind: :condition_true, run_when: :every_time, condition: %{ir: %{op: :gt}}} =
             workflow(lowered, "wCond")

    evt = workflow(lowered, "wEvt")
    assert evt.kind == :custom_event
    assert [%{id: "pWord", key: "word", type: "text"}] = evt.parameters
    assert [%{id: "rWord", name: "Result"}] = evt.returns
  end

  test "steps lower to the shared vocabulary", %{lowered: lowered} do
    [set, show] = workflow(lowered, "wState").steps
    assert %{index: 1, op: :set_state, type: "SetCustomState", residue: []} = set
    assert [%{state: "custom.label_", value: %{ir: %{op: :input}}}] = set.args.states
    assert %{index: 2, op: :show, args: %{element: "bFocus"}, condition: %{ir: _}} = show

    [nav] = workflow(lowered, "wNav").steps
    assert %{op: :navigate, args: %{page: "bOther", params: [%{key: "q"}]}} = nav

    [url] = workflow(lowered, "wUrl").steps
    assert %{args: %{page: :current, keep_params?: true}} = url

    [call, _] = workflow(lowered, "wCall").steps
    assert %{op: :call, args: %{workflow: "wEvt", params: [%{param: "pWord"}]}} = call

    [reset] = workflow(lowered, "wReset").steps

    assert %{op: :call_reusable, args: %{element: "bInst1", workflow: "wCardZero"}} = reset

    [create, _] = workflow(lowered, "wData").steps

    assert %{op: :create, args: %{data_type: "note", changes: [%{field: "title_text", op: :set}]}} =
             create

    [terminate] = workflow(lowered, "wEvt").steps
    assert %{op: :terminate, args: %{returns: [%{return: "rWord"}]}} = terminate

    [_zero, reset_inputs] = workflow(lowered, "wCardZero").steps
    assert %{op: :reset_inputs, args: %{within: nil}} = reset_inputs
  end

  test "Go to page sends its data to a page with a type of content (WTF-378)" do
    send_user = fn app ->
      edit(
        app,
        "wNav",
        &put_in(&1, ["actions", "0", "properties", "data_to_send"], %{"type" => "CurrentUser"})
      )
    end

    typed = put_in(app(), ["pages", "other", "properties", "page_item_type"], "user")
    [nav] = typed |> send_user.() |> lower() |> workflow("wNav") |> Map.fetch!(:steps)
    assert %{residue: [], args: %{thing: %{ir: %{op: :current_user}}, untyped?: false}} = nav

    # No type of content: Bubble appends the data as a path segment all the
    # same (replay, WTF-466), so it is lowered, marked `untyped?`.
    [nav] = app() |> send_user.() |> lower() |> workflow("wNav") |> Map.fetch!(:steps)
    assert %{residue: [], args: %{thing: %{ir: %{op: :current_user}}, untyped?: true}} = nav

    # The index page takes it too, under /index (WTF-454).
    index =
      typed
      |> put_in(["pages", "other", "name"], "index")
      |> put_in(["pages", "home", "name"], "home")
      |> send_user.()
      |> lower()

    assert [%{residue: [], args: %{thing: %{ir: %{op: :current_user}}}}] =
             workflow(index, "wNav").steps
  end

  test "Go to page sends its data to the current page (WTF-454)" do
    send_user = fn app ->
      edit(
        app,
        "wUrl",
        &put_in(&1, ["actions", "0", "properties", "data_to_send"], %{"type" => "CurrentUser"})
      )
    end

    # A page's own workflow: that page's rules.
    [nav] = app() |> send_user.() |> lower() |> workflow("wUrl") |> Map.fetch!(:steps)

    assert %{residue: [], args: %{page: :current, untyped?: true}} = nav

    [nav] =
      app()
      |> put_in(["pages", "home", "properties", "page_item_type"], "user")
      |> send_user.()
      |> lower()
      |> workflow("wUrl")
      |> Map.fetch!(:steps)

    assert %{residue: [], args: %{page: :current, thing: %{ir: %{op: :current_user}}}} = nav

    # A reusable element's: whichever page renders it, checked at run time.
    card =
      app()
      |> put_in(["element_definitions", "card", "workflows", "wCardOpen", "actions", "0"], %{
        "id" => "aCardNav",
        "properties" => %{
          "element_id" => "Current page",
          "data_to_send" => %{"type" => "CurrentUser"}
        },
        "type" => "ChangePage"
      })
      |> lower()

    assert [%{residue: [], args: %{page: :current, thing: %{ir: %{op: :current_user}}}}] =
             workflow(card, "wCardOpen").steps
  end

  describe "Go to page's target (WTF-429)" do
    # wNav going to `target` instead of page bOther.
    defp nav_to(app, target) do
      app
      |> edit("wNav", &put_in(&1, ["actions", "0", "properties", "element_id"], target))
      |> lower()
      |> workflow("wNav")
    end

    defp unresolved?(lowered, w) do
      [step] = w.steps

      step.residue == [
        %{subject: step.id, reason: :unresolved_reference, detail: %{reference: "page"}}
      ] and step.args.page == nil and not Workflow.native?(w) and
        Enum.any?(
          lowered.diagnostics,
          &(&1.code == :frontend_workflow_residue and
              &1.details.reason == "unresolved_reference" and &1.details.subject == step.id)
        )
    end

    test "an unknown, empty, path-like or unicode ID is residue, never the current page" do
      hostile = [
        "bMissing",
        "",
        "   ",
        nil,
        42,
        %{"type" => "CurrentPage"},
        "/other",
        "../other",
        "other",
        "https://example.com/other",
        "bOther/../bHome",
        "ページ",
        "bOther​",
        "bÖther",
        "bGone page",
        "bOther\n",
        " bOther",
        "current page",
        "Current page ",
        "Current Page",
        "Current page"
      ]

      for target <- hostile do
        app =
          edit(app(), "wNav", &put_in(&1, ["actions", "0", "properties", "element_id"], target))

        lowered = lower(app)
        assert unresolved?(lowered, workflow(lowered, "wNav")), inspect(target)
      end
    end

    test "a deleted page's ID is residue" do
      app = update_in(app(), ["pages"], &Map.delete(&1, "other"))
      lowered = lower(app)
      assert unresolved?(lowered, workflow(lowered, "wNav"))
    end

    test "a page whose ID has a space is that page, not the current one" do
      id = "bOther page\n"

      w =
        app()
        |> put_in(["pages", "other", "id"], id)
        |> nav_to(id)

      assert [%{residue: [], args: %{page: ^id}}] = w.steps
    end

    test "Current page is the current page, unless a page has that ID" do
      assert [%{residue: [], args: %{page: :current}}] =
               app() |> nav_to("Current page") |> Map.fetch!(:steps)

      app = put_in(app(), ["pages", "other", "id"], "Current page")
      lowered = lower(app)
      assert unresolved?(lowered, workflow(lowered, "wUrl"))
    end

    test "the fixture's workflow to a page that is gone refuses to run", %{lowered: lowered} do
      w = workflow(lowered, "wNavGone")
      assert [%{residue: []}, %{op: :navigate, residue: [_]}] = w.steps
      refute Workflow.native?(w)
    end
  end

  test "Add a pause before next action lowers to a pause (WTF-451)", %{lowered: lowered} do
    [_, pause, _] = workflow(lowered, "wPause").steps

    assert %{op: :pause, type: "PauseWFClient", residue: [], args: %{length: %{ir: ir}}} = pause
    assert %{op: :literal, args: [30]} = ir
    assert Workflow.native?(workflow(lowered, "wEvtPause"))
  end

  test "an unsupported action is residue with a diagnostic, never dropped", %{
    lowered: lowered
  } do
    w = workflow(lowered, "wResidue")
    assert [%{residue: []}, %{op: nil, type: "SendEmail", residue: [residue]}] = w.steps

    assert residue == %{
             subject: "action:aRes2",
             reason: :unsupported_action,
             detail: %{type: "SendEmail"}
           }

    refute Workflow.native?(w)

    assert Enum.any?(
             lowered.diagnostics,
             &(&1.code == :frontend_workflow_residue and &1.details.subject == "action:aRes2")
           )

    assert Enum.any?(
             lowered.diagnostics,
             &(&1.code == :frontend_workflow_disabled and &1.subject.workflow == "wOpenOff")
           )
  end

  test "unresolved references, unknown options and plugin events are residue" do
    lowered =
      app()
      |> edit("wCall", &put_in(&1, ["actions", "0", "properties", "custom_event"], "wCardZero"))
      |> edit("wState", &put_in(&1, ["actions", "0", "properties", "surprise"], true))
      |> edit("wLoad", &Map.put(&1, "type", "1488796042609x768734193128308700-AAX"))
      |> edit("wCond", &put_in(&1, ["properties", "run_when"], "sometimes"))
      |> edit("wClose", &put_in(&1, ["properties", "element_id"], "bCardInc"))
      |> lower()

    reasons = fn id ->
      lowered |> workflow(id) |> Workflow.residue() |> Enum.map(&{&1.reason, &1.detail})
    end

    # A custom event of another page or reusable element.
    assert {:unresolved_reference, %{reference: "workflow"}} in reasons.("wCall")
    assert {:unsupported_option, %{options: ["surprise"]}} in reasons.("wState")

    assert {:plugin_event, %{plugin: "1488796042609x768734193128308700"}} in reasons.("wLoad")

    assert {:unsupported_option, %{options: ["run_when"]}} in reasons.("wCond")
    # An element of another surface.
    assert {:unresolved_reference, %{reference: "element"}} in reasons.("wClose")
  end

  test "a condition-true workflow without \"run this\" runs once (unverified default)" do
    lowered =
      app()
      |> edit("wCond", &update_in(&1, ["properties"], fn p -> Map.delete(p, "run_when") end))
      |> lower()

    assert workflow(lowered, "wCond").run_when == :once
  end

  test "elements and custom states with their defaults", %{lowered: lowered} do
    assert %{surface: "page:bHome", kind: :page} = lowered.elements["bHome"]
    assert %{surface: "page:bHome", instance_of: "bCard"} = lowered.elements["bInst1"]
    assert %{surface: "reusable:bCard", value: "text"} = lowered.elements["bCardNote"]
    refute Map.has_key?(lowered.elements, "bOtherMissing")

    label = Enum.find(lowered.states, &(&1.element == "bHome" and &1.state == "custom.label_"))
    assert %{type: "text", default: %{ir: %{op: :literal, args: ["start"]}}} = label
    assert Enum.any?(lowered.states, &(&1.element == "bCard" and &1.state == "custom.count_"))
  end

  test "coverage counts workflows and steps by residue", %{lowered: lowered} do
    coverage = Frontend.coverage(lowered)

    assert coverage["workflows"] == %{
             "total" => 29,
             "native" => 26,
             "residue" => 3,
             "disabled" => 1
           }

    assert coverage["steps"]["residue"] == 3
    assert coverage["by_surface"]["reusable"] == %{"total" => 3, "native" => 3}

    assert coverage["residue_reasons"] == %{
             "unsupported_action" => 1,
             "unsupported_option" => 1,
             "unresolved_reference" => 1
           }

    assert coverage["step_ops"]["set_state"] == 21
    assert coverage["step_ops"]["pause"] == 2
  end

  test "its residue feeds the plan", %{lowered: lowered} do
    app = app()
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, plan} = Plan.build(model, index, nil, [], residue: Frontend.residue(lowered))

    task = Enum.find(plan.tasks, &(&1.id == "workflow:wResidue"))
    assert [%{subject: "action:aRes2", reason: :unsupported_action}] = task.residue
    assert {:ok, decoded} = plan |> Plan.to_json() |> Plan.decode()
    assert Plan.to_json(decoded) == Plan.to_json(plan)
  end

  test "invalid input" do
    assert {:error, %BubbleEx.Error{kind: :invalid_input}} = Frontend.build(:app, nil, nil)
  end

  # WTF-478, replayed on Bubble (2026-10-01): a page's search drops a
  # constraint whose value is empty only when it states
  # `ignore_empty_constraints: true`; else the constraint matches nothing.
  # A page workflow's server-side action (here a delete) is not replayed:
  # its searches take the backend rule, so an empty value always matches
  # nothing and a delete never reaches every record the user can read.
  test "server actions in page workflows ignore the flag; client actions follow the page rule" do
    search = fn options, next ->
      %{
        "type" => "Search",
        "properties" =>
          Map.merge(options, %{
            "type_to_find" => "custom.note",
            "constraints" => %{
              "0" => %{
                "key" => "title_text",
                "constraint_type" => "equals",
                "value" => %{
                  "type" => "GetElement",
                  "properties" => %{"element_id" => "bIn"},
                  "next" => %{"type" => "Message", "name" => "get_data"}
                }
              }
            }
          }),
        "next" => next
      }
    end

    first = %{"type" => "Message", "name" => "first_element"}

    step = fn action ->
      app()
      |> edit("wLoad", &Map.put(&1, "actions", %{"0" => action}))
      |> lower()
      |> workflow("wLoad")
      |> Map.fetch!(:steps)
      |> hd()
    end

    guarded = fn pred, op ->
      assert %{op: ^op, args: [guard, %{op: :eq, args: [%{op: :field}, value]}]} = pred

      case op do
        :and -> assert %{op: :not, args: [%{op: :is_empty, args: [^value]}]} = guard
        :or -> assert %{op: :is_empty, args: [^value]} = guard
      end
    end

    for {options, page_op} <- [
          {%{}, :and},
          {%{"ignore_empty_constraints" => false}, :and},
          {%{"ignore_empty_constraints" => true}, :or}
        ] do
      # A delete (server-side): matches nothing, whatever the flag.
      delete =
        step.(%{
          "id" => "aLoad1",
          "type" => "DeleteThing",
          "properties" => %{"to_delete" => search.(options, first)}
        })

      assert delete.residue == []

      assert %{target: %{ir: %{op: :first, args: [%{op: :search, args: [_, pred]}]}}} =
               delete.args

      guarded.(pred, :and)

      # A client-side action's condition: the page rule.
      hide =
        step.(%{
          "id" => "aLoad1",
          "type" => "HideElement",
          "properties" => %{
            "element_id" => "bLabel",
            "condition" =>
              search.(
                options,
                Map.put(first, "next", %{"type" => "Message", "name" => "is_not_empty"})
              )
          }
        })

      assert %{ir: condition} = hide.condition
      assert [pred] = for(%{op: :search, args: [_, p]} <- walk(condition), do: p)
      guarded.(pred, page_op)
    end
  end

  defp walk(%BubbleEx.Expression.IR{args: args} = ir), do: [ir | Enum.flat_map(args, &walk/1)]
  defp walk(_), do: []
end
