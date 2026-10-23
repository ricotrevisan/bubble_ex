defmodule BubbleEx.Target.Phoenix.BlockedWorkflowsTest do
  # The owner's report of the workflows that cannot run (WTF-607), from the
  # synthetic test/support/target/phoenix/frontend_workflows.json. That a
  # blocked workflow runs no step at all, not even those before the one
  # that blocks it, is frontend_workflows_behavior.exs's ("a workflow with
  # a step that was not lowered runs no step at all").
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model}
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Target.Phoenix.BlockedWorkflows

  @fixture "test/support/target/phoenix/frontend_workflows.json"

  setup_all do
    app = @fixture |> File.read!() |> Jason.decode!()
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)

    {:ok, expressions} =
      BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
        runtime: "Shop.Bubble.Runtime",
        namespace: "Shop"
      )

    {:ok, lowered} = BubbleEx.Workflows.Frontend.build(app, model, index)
    {:ok, backend_lowered} = BubbleEx.Workflows.Backend.build(app, model, index)

    {:ok, backend} =
      BubbleEx.Target.Ash.Workflows.map(backend_lowered, project, namespace: "Shop")

    {:ok, spec} =
      FrontendWorkflows.map(lowered, project,
        namespace: "Shop",
        frontend: frontend,
        backend: backend
      )

    {:ok, files} =
      Phoenix.render(project,
        module: "Shop",
        frontend: frontend,
        expressions: expressions,
        workflows: backend,
        frontend_workflows: spec
      )

    notes = BlockedWorkflows.notes(spec, backend, frontend: frontend)
    %{files: files, spec: spec, notes: notes, by_id: Map.new(notes, &{&1.workflow, &1})}
  end

  test "one note per workflow the runtime refuses, none for a native or disabled one",
       %{spec: spec, notes: notes} do
    refused =
      for w <- Spec.workflows(spec), not w.disabled?, not Spec.native?(w), do: w.workflow

    assert refused != []

    assert notes |> Enum.map(& &1.workflow) |> Enum.filter(&(&1 in refused)) |> Enum.sort() ==
             Enum.sort(refused)

    for w <- Spec.workflows(spec),
        w.disabled? or Spec.native?(w),
        do: refute(Enum.any?(notes, &(&1.workflow == w.workflow)), w.workflow)

    assert length(Enum.uniq_by(notes, & &1.workflow)) == length(notes)
  end

  test "a step that was not converted: the workflow, its event, the step and why", %{by_id: by_id} do
    # wResidue: step 1 sets a state (converted), step 2 shows an alert (not).
    assert %{
             where: {:page, "index"},
             event: "when \"bBtnResidue\" is clicked",
             blocker: {:step, 2, "AlertShowMessage"},
             reason: :unsupported_action
           } = by_id["wResidue"]
  end

  test "a workflow refused through the custom event it triggers names that event (step 1 converted)",
       %{
         by_id: by_id
       } do
    assert %{blocker: {:calls, [callee]}, reason: :calls_blocked} = by_id["wCallee"]
    assert callee == ~s("broken")
  end

  test "the report groups the notes by reason, in plain words", %{files: files, notes: notes} do
    md = files[".wtf/blocked_workflows.md"]
    assert md == BlockedWorkflows.markdown(notes)
    assert md =~ "#{length(notes)} workflows of this app cannot run"
    assert md =~ "not even the steps before that part"
    assert md =~ "| A step uses an action that is not converted yet | "
    assert md =~ "## It runs another workflow that cannot run (1 workflow)"

    assert md =~
             ~s{- Page "index", when "bBtnResidue" is clicked: step 2, Show message in an alert [AlertShowMessage] (`workflow:wResidue`)}

    # What the owner can do: change it in Bubble, or drop it in the decisions file.
    assert md =~ "**change it in Bubble**"
    assert md =~ "record a drop decision for its ID"
    # One line per workflow.
    assert md |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "- Page ")) ==
             Enum.count(notes, &match?({:page, _}, &1.where))
  end

  test "the report is a generated file" do
    assert BlockedWorkflows.path() == ".wtf/blocked_workflows.md"
  end

  test "with nothing blocked the report says so" do
    assert BlockedWorkflows.markdown([]) =~ "none is refused"
  end

  test "an owner's name cannot break a line or a table" do
    note = %{
      workflow: "wX",
      symbol: "workflow:wX",
      where: {:page, "a|b\nc"},
      event: "when the page is loaded",
      name: "x`y",
      blocker: {:step, 1, "Nope"},
      reason: :unsupported_action,
      detail: ["Nope"],
      plugin: nil
    }

    md = BlockedWorkflows.markdown([note])

    assert md =~
             ~s{- Page "a b c", when the page is loaded ("x y"): step 1, "Nope" [Nope] (`workflow:wX`)}
  end
end
