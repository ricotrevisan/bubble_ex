defmodule BubbleEx.PlanPrivateFixtureTest do
  # Coverage dry run of the migration plan on a real app (WTF-366), like
  # BubbleEx.Target.CompileReportPrivateFixtureTest. Excluded by default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
  #
  # `BubbleEx.Plan` coverage (aggregate counts only: no names or IDs) is
  # compared with a committed snapshot, by default the mm-137 test
  # version's, for two residue settings:
  #
  #   * `neutral` - expressions residue when they do not compile to the
  #     stack-neutral IR
  #   * `elixir` - also when their IR does not compile to Elixir
  #     (`BubbleEx.Target.Elixir` against the Ash project), the first
  #     target's bound
  #
  # With BUBBLE_EX_PRIVATE_DECISIONS (see
  # BubbleEx.Target.AshDecisionsPrivateFixtureTest) the `decided` counts
  # (neutral) are compared too. A changed count means updating the
  # snapshot, with the reason in the PR:
  #
  #     BUBBLE_EX_UPDATE_COUNTS=1 BUBBLE_EX_PRIVATE_EXPORT=… mix test --only private_fixture
  #
  # BUBBLE_EX_PLAN_COUNTS names another snapshot file.
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Decision, Diagnostic, Findings, Frontend, Index, Model, Plan}
  alias BubbleEx.Plan.Residue
  alias BubbleEx.Target.Ash
  alias BubbleEx.Target.Elixir, as: ElixirTarget
  alias BubbleEx.Test.SplitExport

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  @default_snapshot "test/support/plan/counts/mm-137.json"
  @now ~U[2026-09-26 00:00:00Z]

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    app = SplitExport.load(path)
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, frontend} = Frontend.normalize(app)
    {:ok, project} = Ash.map(model)

    {:ok, neutral} = Residue.expressions(app, model, index)
    {:ok, elixir} = Residue.expressions(app, model, index, check: &elixir_check(&1, &2, project))
    styles = Residue.styles(app)

    %{
      app: app,
      model: model,
      index: index,
      frontend: frontend,
      neutral: neutral ++ styles,
      elixir: elixir ++ styles
    }
  end

  defp elixir_check(ir, site, project) do
    {:ok, result} = ElixirTarget.compile(ir, project, path: Diagnostic.pointer(site.path))
    if result.source, do: [], else: Residue.constructs(result.diagnostics)
  end

  test "matches the recorded coverage snapshot", ctx do
    {:ok, neutral} = Plan.build(ctx.model, ctx.index, ctx.frontend, [], residue: ctx.neutral)
    {:ok, elixir} = Plan.build(ctx.model, ctx.index, ctx.frontend, [], residue: ctx.elixir)

    counts = %{"faithful" => %{"neutral" => neutral.coverage, "elixir" => elixir.coverage}}
    counts = with_decisions(counts, ctx)

    IO.puts("""

    plan coverage:
    #{counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)}
    """)

    snapshot = System.get_env("BUBBLE_EX_PLAN_COUNTS") || @default_snapshot

    if System.get_env("BUBBLE_EX_UPDATE_COUNTS") do
      File.mkdir_p!(Path.dirname(snapshot))

      File.write!(
        snapshot,
        (counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"
      )
    end

    recorded = snapshot |> File.read!() |> Jason.decode!()

    assert counts["faithful"] == recorded["faithful"],
           "counts changed; update #{snapshot} with a reason"

    if counts["decided"],
      do:
        assert(
          counts["decided"] == recorded["decided"],
          "decided counts changed; update #{snapshot}"
        )

    assert Plan.to_json(neutral) ==
             ctx.model
             |> Plan.build(ctx.index, ctx.frontend, [], residue: ctx.neutral)
             |> elem(1)
             |> Plan.to_json()
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

        {:ok, plan} =
          Plan.build(ctx.model, ctx.index, ctx.frontend, applied,
            residue: ctx.neutral,
            decisions_sha256: Decision.decisions_sha256(records)
          )

        Map.put(counts, "decided", %{"neutral" => plan.coverage})
    end
  end
end
