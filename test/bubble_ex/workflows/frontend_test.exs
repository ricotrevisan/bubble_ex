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
    assert length(lowered.workflows) == 21

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
      |> edit("wNav", &put_in(&1, ["actions", "0", "properties", "data_to_send"], "x"))
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
    assert {:unsupported_option, %{options: ["data_to_send"]}} in reasons.("wNav")
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
             "total" => 21,
             "native" => 19,
             "residue" => 2,
             "disabled" => 1
           }

    assert coverage["steps"]["residue"] == 2
    assert coverage["by_surface"]["reusable"] == %{"total" => 3, "native" => 3}
    assert coverage["residue_reasons"] == %{"unsupported_action" => 2}
    assert coverage["step_ops"]["set_state"] == 11
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
end
