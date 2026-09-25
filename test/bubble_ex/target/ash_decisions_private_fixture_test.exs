defmodule BubbleEx.Target.AshDecisionsPrivateFixtureTest do
  # Owner decisions applied to a real app (WTF-401), like
  # BubbleEx.Target.AshPrivateFixtureTest. Excluded by default, and skipped
  # unless a decision file is named too:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export \
  #     BUBBLE_EX_PRIVATE_DECISIONS=path/to/decisions.json \
  #       mix test --only private_fixture
  #
  # The decision file is a JSON array of `BubbleEx.Decision.to_map/1`
  # records made against that export (for mm-137: accept the
  # denormalized-field finding "40. Sort: Thing Title" on "00. Thing - Join",
  # and reject the search-index hints, which Target.Ash applies from cut 2).
  # It names private Bubble IDs, so it is never committed. The committed
  # snapshot holds only the Project's hash, the decision set's hash and
  # aggregate counts, never names or IDs. A changed hash or count means
  # updating the snapshot, with the reason in the PR:
  #
  #     BUBBLE_EX_UPDATE_COUNTS=1 BUBBLE_EX_PRIVATE_EXPORT=… BUBBLE_EX_PRIVATE_DECISIONS=… \
  #       mix test --only private_fixture
  #
  # BUBBLE_EX_ASH_DECIDED_COUNTS names another snapshot file.
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Decision, Findings, Index, Model}
  alias BubbleEx.Decision.Resolved
  alias BubbleEx.Target.Ash
  alias BubbleEx.Target.Ash.{Project, Source}
  alias BubbleEx.Test.SplitExport

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  if System.get_env("BUBBLE_EX_PRIVATE_DECISIONS") in [nil, ""] do
    @moduletag skip: "set BUBBLE_EX_PRIVATE_DECISIONS to a decision file for the export"
  end

  @default_snapshot "test/support/target/ash/counts/mm-137.decided.json"
  @now ~U[2026-09-26 00:00:00Z]

  setup_all do
    export =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    app = SplitExport.load(export)
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, %{findings: findings}} = Findings.analyze(app, model: model, index: index)

    records =
      "BUBBLE_EX_PRIVATE_DECISIONS"
      |> System.fetch_env!()
      |> File.read!()
      |> Jason.decode!()
      |> Enum.map(fn map ->
        {:ok, decision} = Decision.from_map(map)
        decision
      end)

    {:ok, resolved} = Decision.resolve(records, findings, index: index, now: @now)
    applied = Decision.applicable(resolved, findings)
    sha = Decision.decisions_sha256(records)
    opts = [index: index, privacy: :unverified, decisions_sha256: sha]
    {:ok, project} = Ash.map(model, applied, opts)
    {:ok, faithful} = Ash.map(model, [], index: index, privacy: :unverified)

    %{
      model: model,
      resolved: resolved,
      applied: applied,
      sha: sha,
      opts: opts,
      project: project,
      faithful: faithful
    }
  end

  test "the decisions are current and apply", %{resolved: resolved, applied: applied} do
    assert Resolved.blocking(resolved) == []
    assert Enum.any?(applied, &(&1.transform == :derive_from_related))
    refute Enum.any?(applied, & &1.automatic)
  end

  test "a derived field is a calculation with its locked name, not a column",
       %{applied: applied, project: project, faithful: faithful} do
    derived = for a <- applied, a.transform == :derive_from_related, do: a

    for a <- derived do
      %{type: t, field: f} = a.subject
      resource = Enum.find(project.resources, &(&1.source.type == t))
      locked = get_in(faithful.names, ["resources", t, "attributes", f])

      refute Enum.any?(resource.attributes, &(&1.source[:field] == f))
      calc = Enum.find(resource.calculations, &(&1.kind == :derived and &1.source.field == f))
      assert calc.name == locked
      assert calc.public?
      {:ref, path, _attribute} = calc.expr.expr
      assert length(path) == length(a.proposal.derivation.via)
    end

    assert Enum.map(project.applied, & &1.key) == Enum.map(applied, & &1.key)
    {:ok, _source} = Source.render(project)
  end

  test "matches the recorded hash and count snapshot",
       %{project: project, sha: sha, model: model, applied: applied, opts: opts} do
    snapshot = System.get_env("BUBBLE_EX_ASH_DECIDED_COUNTS") || @default_snapshot

    document = %{
      "schema_version" => Project.schema_version(),
      "project_sha256" => CanonicalJson.sha256(Project.to_map(project)),
      "decisions_sha256" => sha,
      "counts" => Project.summary(project)
    }

    IO.puts(
      "\ntarget ash (decided):\n" <>
        (document |> CanonicalJson.ordered() |> Jason.encode!(pretty: true))
    )

    if System.get_env("BUBBLE_EX_UPDATE_COUNTS") do
      File.mkdir_p!(Path.dirname(snapshot))

      File.write!(
        snapshot,
        (document |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"
      )
    end

    assert snapshot |> File.read!() |> Jason.decode!() == document,
           "the decided Project changed; update #{snapshot} with a reason"

    # deterministic, and stable under its own name map
    {:ok, again} = Ash.map(model, applied, opts)
    assert Project.to_json(again) == Project.to_json(project)
    names = project.names |> Jason.encode!() |> Jason.decode!()
    {:ok, locked} = Ash.map(model, applied, Keyword.put(opts, :names, names))
    assert Project.to_json(locked) == Project.to_json(project)
  end
end
