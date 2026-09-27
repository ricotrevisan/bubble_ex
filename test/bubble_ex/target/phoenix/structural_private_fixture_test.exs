defmodule BubbleEx.Target.Phoenix.StructuralPrivateFixtureTest do
  # The structural verification pack (WTF-386) on a real app: the whole
  # generation (Model, Index, frontend, Plan, Ash project, backend
  # workflows, API clients, the Phoenix rendering, twice) and
  # `Structural.run/2` over it. Excluded by default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
  #
  # The summary's counts and statuses (no names or Bubble IDs) are compared
  # with a committed snapshot, by default the mm-137 test version's. With
  # BUBBLE_EX_PRIVATE_DECISIONS the `decided` summary (the owner's decisions
  # applied) is compared too. A changed count means updating the snapshot,
  # with the reason in the PR:
  #
  #     BUBBLE_EX_UPDATE_COUNTS=1 BUBBLE_EX_PRIVATE_EXPORT=… mix test --only private_fixture
  #
  # BUBBLE_EX_STRUCTURAL_COUNTS names another snapshot file. Uncovered
  # symbols and failing diffs are printed to the console only.
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Decision, Findings, Frontend, Index, Model, Plan}
  alias BubbleEx.Plan.Residue
  alias BubbleEx.Target.{ApiClients, Ash, Phoenix}
  alias BubbleEx.Target.Ash.Workflows
  alias BubbleEx.Target.Phoenix.Structural
  alias BubbleEx.Test.SplitExport
  alias BubbleEx.Workflows.Backend

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  @default_snapshot "test/support/verify/counts/structural.mm-137.json"
  @now ~U[2026-09-27 00:00:00Z]

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    app = SplitExport.load(path)
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, frontend} = Frontend.normalize(app)
    {:ok, expressions} = Residue.expressions(app, model, index)

    %{
      app: app,
      model: model,
      index: index,
      frontend: frontend,
      residue: expressions ++ Residue.styles(app)
    }
  end

  test "the structural summary matches the recorded snapshot", ctx do
    faithful = summary(ctx, [], nil)
    counts = with_decisions(%{"faithful" => faithful}, ctx)

    IO.puts("""

    structural summary:
    #{counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)}
    """)

    snapshot = System.get_env("BUBBLE_EX_STRUCTURAL_COUNTS") || @default_snapshot

    if System.get_env("BUBBLE_EX_UPDATE_COUNTS") do
      File.mkdir_p!(Path.dirname(snapshot))

      File.write!(
        snapshot,
        (counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"
      )
    end

    recorded = snapshot |> File.read!() |> Jason.decode!()
    assert counts["faithful"] == recorded["faithful"], "counts changed; update #{snapshot}"

    if counts["decided"],
      do:
        assert(
          counts["decided"] == recorded["decided"],
          "decided counts changed; update #{snapshot}"
        )
  end

  # Everything the pack reports, with the policy coverage of the
  # `:unverified` mapping of the same decisions alongside.
  defp summary(ctx, applied, sha) do
    opts = [index: ctx.index, decisions_sha256: sha]

    {:ok, plan} =
      Plan.build(ctx.model, ctx.index, ctx.frontend, applied,
        residue: ctx.residue,
        decisions_sha256: sha
      )

    {:ok, project} = Ash.map(ctx.model, applied, opts)
    {:ok, unverified} = Ash.map(ctx.model, applied, Keyword.put(opts, :privacy, :unverified))
    {:ok, backend} = Backend.build(ctx.app, ctx.model, ctx.index)
    {:ok, workflows} = Workflows.map(backend, project, namespace: "Private")
    {:ok, api_clients} = ApiClients.map(ctx.model)

    render = [
      name: "Private",
      module: "Private",
      frontend: ctx.frontend,
      workflows: workflows,
      api_clients: api_clients
    ]

    {:ok, files} = Phoenix.render(project, render)
    {:ok, rerender} = Phoenix.render(project, render)

    inputs = %{
      model: ctx.model,
      index: ctx.index,
      plan: plan,
      project: project,
      files: files,
      rerender: rerender,
      workflows: workflows,
      api_clients: api_clients
    }

    {:ok, report} = Structural.run(inputs, app: "private-app", now: @now)

    {:ok, policies} =
      Structural.run(%{inputs | project: unverified}, app: "private-app", now: @now)

    for r <- report.results ++ policies.results, r.status == :fail do
      IO.puts("#{r.id}: #{length(r.diff)} differences")
      Enum.each(Enum.take(r.diff, 20), &IO.puts("  #{inspect(&1)}"))
    end

    policy = Enum.find(policies.results, &(&1.check == "policy_coverage"))

    report
    |> Structural.summary()
    |> Map.drop(["statement", "not_run"])
    |> Map.put("policy_coverage_unverified", %{
      "status" => Atom.to_string(policy.status),
      "counts" => policies.counts["privacy_rules"]
    })
  end

  defp with_decisions(counts, ctx) do
    case System.get_env("BUBBLE_EX_PRIVATE_DECISIONS") do
      path when path in [nil, ""] ->
        counts

      path ->
        {:ok, %{findings: findings}} =
          Findings.analyze(ctx.app, model: ctx.model, index: ctx.index)

        records =
          path
          |> File.read!()
          |> Jason.decode!()
          |> Enum.map(fn map ->
            {:ok, decision} = Decision.from_map(map)
            decision
          end)

        {:ok, resolved} = Decision.resolve(records, findings, index: ctx.index, now: @now)
        applied = Decision.applicable(resolved, findings)
        Map.put(counts, "decided", summary(ctx, applied, Decision.decisions_sha256(records)))
    end
  end
end
