defmodule BubbleEx.Decision.DropPrivateFixtureTest do
  # Owner drops (WTF-422) on a real app, like the other private fixture
  # tests. Excluded by default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export \
  #     [BUBBLE_EX_PRIVATE_DECISIONS=path/to/decisions.json] \
  #       mix test --only private_fixture
  #
  # The dropped symbols are chosen deterministically from the export (the
  # first droppable one of each kind by symbol ID that no recorded decision
  # names), never named here: the test asserts invariants and prints
  # aggregate counts only (no names or IDs). With a decision file the
  # owner's recorded decisions are resolved together with the drops.
  use ExUnit.Case, async: true

  alias BubbleEx.{Decision, Findings, Index, Model, Plan}
  alias BubbleEx.Decision.{Drop, Resolved}
  alias BubbleEx.Index.Subject
  alias BubbleEx.Target.Ash
  alias BubbleEx.Target.Ash.Project
  alias BubbleEx.Target.Phoenix.Structural.Coverage
  alias BubbleEx.Test.SplitExport

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  @now ~U[2026-09-27 00:00:00Z]

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    app = SplitExport.load(path)
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, %{findings: findings}} = Findings.analyze(app, model: model, index: index)

    records =
      case System.get_env("BUBBLE_EX_PRIVATE_DECISIONS") do
        blank when blank in [nil, ""] ->
          []

        file ->
          file
          |> File.read!()
          |> Jason.decode!()
          |> Enum.map(fn map ->
            {:ok, decision} = Decision.from_map(map)
            decision
          end)
      end

    %{app: app, model: model, index: index, findings: findings, records: records}
  end

  # The first droppable symbol of each kind no recorded decision names, and
  # for a data type the fields referencing it (accepted as dangling).
  defp choose(index, records) do
    named = records |> Enum.flat_map(&Subject.symbol_ids(&1.subject)) |> MapSet.new()

    pick = fn kind, extra ->
      index
      |> Index.symbols(kind)
      |> Enum.find(fn s ->
        {:ok, impact} = Drop.impact(index, s.id)

        impact.refusal == nil and not MapSet.member?(named, s.id) and
          Enum.all?(impact.removed, &(not MapSet.member?(named, &1))) and extra.(s, impact)
      end)
    end

    backend_called = fn s, impact -> s.attrs[:backend] == true and impact.callers != [] end

    [
      pick.(:data_type, fn _, impact -> impact.dangling != [] end) ||
        pick.(:data_type, fn _, _ -> true end),
      pick.(:field, fn s, _ -> not String.starts_with?(s.parent, "data_type:user") end),
      pick.(:option_set, fn _, _ -> true end),
      pick.(:page, fn _, _ -> true end),
      pick.(:workflow, backend_called) || pick.(:workflow, fn _, _ -> true end)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  defp drops(index, symbols, accept?) do
    # a field inside a dropped type goes with it
    types = for s <- symbols, s.kind == :data_type, into: MapSet.new(), do: s.id

    symbols
    |> Enum.reject(&(&1.kind == :field and MapSet.member?(types, &1.parent)))
    |> Enum.map(fn s ->
      {:ok, impact} = Drop.impact(index, s.id)
      opts = [author: %{kind: :owner, id: "user:fixture", via: :form}]
      opts = if accept?, do: [{:dangling, impact.dangling} | opts], else: opts
      {:ok, d} = Decision.drop(index, s.id, "Private fixture drop.", opts)
      d
    end)
  end

  test "drops resolve, map, plan and account; access is never widened", ctx do
    %{model: model, index: index, findings: findings, records: records} = ctx
    symbols = choose(index, records)
    assert symbols != []
    drops = drops(index, symbols, true)
    all = records ++ drops

    # a recorded decision may no longer resolve against a newer export (it
    # blocks on its own); the drops add no blocking entry
    {:ok, recorded} = Decision.resolve(records, findings, index: index, now: @now)
    recorded_blocking = MapSet.new(Resolved.blocking(recorded), & &1.decision.id)

    {:ok, resolved} = Decision.resolve(all, findings, index: index, now: @now)

    assert Enum.reject(
             Resolved.blocking(resolved),
             &MapSet.member?(recorded_blocking, &1.decision.id)
           ) ==
             []

    for %{decision: %{kind: :drop}} = e <- resolved.entries, do: assert(e.state == :active)

    applied = Decision.applicable(resolved, findings)
    sha = Decision.decisions_sha256(all)
    opts = [index: index, privacy: :unverified, decisions_sha256: sha]
    {:ok, project} = Ash.map(model, applied, opts)
    {:ok, again} = Ash.map(model, Enum.reverse(applied), opts)
    assert Project.to_json(project) == Project.to_json(again)

    refute Enum.any?(project.diagnostics, &(&1.code == :ash_drop_dangling_reference))
    dropped = Project.dropped(project)
    refute Enum.any?(project.resources, &MapSet.member?(dropped.types, &1.source.type))

    # never wider: no resource has more authorizing checks than without
    # the drops
    {:ok, baseline} =
      Ash.map(
        model,
        Decision.applicable(
          elem(Decision.resolve(records, findings, index: index, now: @now), 1),
          findings
        ),
        Keyword.put(opts, :decisions_sha256, Decision.decisions_sha256(records))
      )

    for r <- project.resources do
      before = Enum.find(baseline.resources, &(&1.source == r.source))
      assert checks(r) <= checks(before)
    end

    {:ok, frontend} = BubbleEx.Frontend.normalize(ctx.app)
    {:ok, plan} = Plan.build(model, index, frontend, applied)
    tasks = for t <- plan.tasks, t.kind == :drop, do: t
    assert length(tasks) == length(drops)
    assert Enum.all?(tasks, &(&1.status == :closed and &1.closed_by != nil))
    schema = MapSet.new(Plan.task(plan, "generate:schema").subjects)
    for t <- tasks, id <- t.subjects, do: refute(MapSet.member?(schema, id))

    counts =
      Coverage.account(%{model: model, index: index, plan: plan, project: project})
      |> Coverage.counts()

    decision = Map.new(counts, fn {k, c} -> {k, c["reasons"]["decision:owner_drop"] || 0} end)
    assert Enum.sum(Map.values(decision)) >= length(drops)

    uses =
      plan.tasks
      |> Enum.flat_map(& &1.residue)
      |> Enum.count(&(&1.reason == :uses_dropped))

    IO.puts(
      "\n[drop private fixture] drops: #{length(drops)} " <>
        "(#{symbols |> Enum.frequencies_by(& &1.kind) |> inspect()}), " <>
        "removed symbols: #{tasks |> Enum.map(&length(&1.subjects)) |> Enum.sum()}, " <>
        "uses_dropped residue: #{uses}, decision bucket: #{inspect(decision)}"
    )
  end

  test "an unaccepted dangling reference blocks", %{index: index, findings: findings} do
    case index |> choose([]) |> Enum.filter(&(&1.kind == :data_type)) do
      [type] ->
        {:ok, %{dangling: dangling}} = Drop.impact(index, type.id)
        [drop] = drops(index, [type], false)
        {:ok, resolved} = Decision.resolve([drop], findings, index: index, now: @now)

        if dangling == [],
          do: assert(Resolved.blocking(resolved) == []),
          else: assert([_] = Resolved.blocking(resolved))

      [] ->
        :ok
    end
  end

  defp checks(%{policies: policies}),
    do: Enum.count(for p <- policies, c <- p.checks, c.kind == :authorize_if, do: c)
end
