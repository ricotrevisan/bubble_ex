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
  alias BubbleEx.Plan.{Content, Residue}
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

  # WTF-367: per-task semantic hashes on the real app. Counts only.
  describe "re-verification" do
    setup ctx do
      {:ok, content} = Content.digests(ctx.app, ctx.model, ctx.index)
      {:ok, plan} = build_with(ctx, ctx.app, content)
      %{content: content, plan: plan}
    end

    test "a plan against itself, and against its captions renamed, is all unchanged", ctx do
      {:ok, diff} = Plan.diff(ctx.plan, ctx.plan)
      assert diff.counts.unchanged == length(ctx.plan.tasks)
      assert diff.counts.needs_reverify == 0

      renamed = rename_captions(ctx.app)
      {:ok, model} = Model.build(renamed)
      {:ok, index} = Index.build(renamed, model: model)
      {:ok, content} = Content.digests(renamed, model, index)
      {:ok, plan} = build_with(%{ctx | model: model, index: index}, renamed, content)
      {:ok, diff} = Plan.diff(ctx.plan, plan)

      IO.puts(
        "\nplan re-verification: #{length(ctx.plan.tasks)} tasks, " <>
          "#{map_size(ctx.plan.symbols)} symbols, plan.json #{byte_size(Plan.to_json(ctx.plan))} bytes"
      )

      assert diff.counts.changed == 0 and diff.counts.needs_reverify == 0
    end

    test "editing one dynamic text changes exactly the tasks covering it", ctx do
      element =
        Enum.find(Index.symbols(ctx.index, :element), fn s ->
          match?(%{"properties" => %{"text" => %{}}}, pointer(ctx.app, s.path)) and
            Enum.any?(ctx.plan.tasks, &(s.id in &1.subjects or covers?(ctx, &1, s.id)))
        end) || flunk("no element with a dynamic text")

      path = segments(element.path) ++ ["properties", "text"]

      edited =
        update_in(ctx.app, Enum.map(path, &Access.key(&1)), fn text ->
          entries = Map.get(text, "entries", %{})
          Map.put(text, "entries", Map.put(entries, "#{map_size(entries)}", " (edited)"))
        end)

      {:ok, content} = Content.digests(edited, ctx.model, ctx.index)
      {:ok, plan} = build_with(ctx, edited, content)
      {:ok, diff} = Plan.diff(ctx.plan, plan)

      expected = for t <- ctx.plan.tasks, covers?(ctx, t, element.id), do: t.id
      changed = for %{status: :changed} = e <- diff.tasks, do: e.task

      IO.puts(
        "\none dynamic text edited: #{length(changed)} changed, " <>
          "#{diff.counts.needs_reverify} need re-verifying"
      )

      assert Enum.sort(changed) == Enum.sort(expected)

      for %{status: :changed} = e <- diff.tasks,
          do: assert(e.changes == %{added: [], removed: [], changed: [element.id]})

      assert diff.counts.needs_reverify >= length(changed)
    end
  end

  defp build_with(ctx, _app, content),
    do: Plan.build(ctx.model, ctx.index, ctx.frontend, [], residue: ctx.neutral, content: content)

  defp covers?(ctx, task, id) do
    Enum.any?(task.subjects, &(&1 == id or ancestor?(ctx.index, id, &1)))
  end

  defp ancestor?(index, id, ancestor) do
    case Index.symbol(index, id) do
      %{parent: nil} -> false
      %{parent: ^ancestor} -> true
      %{parent: parent} -> ancestor?(index, parent, ancestor)
      nil -> false
    end
  end

  defp pointer(app, path), do: BubbleEx.Workflows.ExplanationContext.at_pointer(app, path)
  defp segments(pointer), do: BubbleEx.Index.Workflows.segments(pointer)

  defp rename_captions(%{} = map) do
    Map.new(map, fn
      {k, v} when k in ["default_name", "comment"] and is_binary(v) -> {k, v <> " (renamed)"}
      {k, v} -> {k, rename_captions(v)}
    end)
  end

  defp rename_captions(list) when is_list(list), do: Enum.map(list, &rename_captions/1)
  defp rename_captions(other), do: other

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
