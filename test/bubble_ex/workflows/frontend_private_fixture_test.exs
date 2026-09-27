defmodule BubbleEx.Workflows.FrontendPrivateFixtureTest do
  # WTF-372 against a real app, like the other private-fixture tests.
  # Excluded by default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
  #
  # The coverage of the page and reusable-element workflows, at IR level
  # (`BubbleEx.Workflows.Frontend.coverage/1`) and in generated code
  # (`BubbleEx.Target.Elixir.FrontendWorkflows.coverage/1`, the metric
  # defined in `docs/frontend-workflows.md`), is compared with a committed
  # count snapshot, by default mm-137's. The snapshot holds counts only.
  # Update it with a reason:
  #
  #     BUBBLE_EX_UPDATE_COUNTS=1 BUBBLE_EX_PRIVATE_EXPORT=… mix test --only private_fixture
  #
  # BUBBLE_EX_FRONTEND_WORKFLOW_COUNTS names another snapshot file.
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Index, Model, Plan}
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Test.SplitExport
  alias BubbleEx.Workflows.Frontend

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  @default_snapshot "test/support/target/phoenix/counts/mm-137.frontend_workflows.json"

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    app = SplitExport.load(path)
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    {:ok, lowered} = Frontend.build(app, model, index)
    {:ok, backend_lowered} = BubbleEx.Workflows.Backend.build(app, model, index)

    {:ok, backend} =
      BubbleEx.Target.Ash.Workflows.map(backend_lowered, project, namespace: "Private")

    {:ok, spec} =
      FrontendWorkflows.map(lowered, project,
        namespace: "Private",
        frontend: frontend,
        backend: backend
      )

    %{
      app: app,
      model: model,
      index: index,
      project: project,
      frontend: frontend,
      lowered: lowered,
      backend: backend,
      spec: spec
    }
  end

  test "matches the recorded count snapshot", %{lowered: lowered, spec: spec} do
    snapshot = System.get_env("BUBBLE_EX_FRONTEND_WORKFLOW_COUNTS") || @default_snapshot

    counts = %{
      "ir" => Frontend.coverage(lowered),
      "generated" => FrontendWorkflows.coverage(spec)
    }

    IO.puts(
      "\nfrontend workflows: " <>
        (counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true))
    )

    if System.get_env("BUBBLE_EX_UPDATE_COUNTS") do
      File.mkdir_p!(Path.dirname(snapshot))

      File.write!(
        snapshot,
        (%{"counts" => counts} |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"
      )
    end

    recorded = snapshot |> File.read!() |> Jason.decode!()
    assert counts == recorded["counts"], "counts changed; update #{snapshot} with a reason"
  end

  test "every frontend workflow of the plan is lowered and bound once", %{
    model: model,
    index: index,
    frontend: frontend,
    lowered: lowered,
    spec: spec
  } do
    {:ok, plan} = Plan.build(model, index, frontend, [], residue: Frontend.residue(lowered))

    planned =
      for t <- plan.tasks,
          t.kind == :workflow,
          not String.starts_with?(t.parent || "", "backend:"),
          not String.starts_with?(t.parent || "", "cycle:"),
          into: MapSet.new(),
          do: t.id

    bound = spec |> FrontendWorkflows.Spec.workflows() |> MapSet.new(& &1.symbol)
    assert MapSet.subset?(planned, bound)
    assert MapSet.size(bound) == length(lowered.workflows)
  end

  test "the rendered app wires only what its pages list; output is deterministic", %{
    project: project,
    frontend: frontend,
    backend: backend,
    spec: spec
  } do
    opts = [
      name: "Private",
      module: "Private",
      frontend: frontend,
      workflows: backend,
      frontend_workflows: spec
    ]

    {:ok, files} = Phoenix.render(project, opts)
    assert {:ok, ^files} = Phoenix.render(project, opts)

    for {path, content} <- files, String.ends_with?(path, "/workflows.ex") do
      assert {:ok, _} = Code.string_to_quoted(content), path
    end
  end
end
