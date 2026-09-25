defmodule BubbleEx.Target.AshPrivateFixtureTest do
  # Regression anchor for BubbleEx.Target.Ash against a real app (WTF-342),
  # like BubbleEx.ModelPrivateFixtureTest. Excluded by default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
  #
  # The Project's aggregate counts (`BubbleEx.Target.Ash.Project.summary/1`)
  # are compared with a committed count snapshot, by default the mm-137 test
  # version's. The snapshot holds counts only, never names or IDs. A changed
  # count means updating the snapshot, with the reason in the PR:
  #
  #     BUBBLE_EX_UPDATE_COUNTS=1 BUBBLE_EX_PRIVATE_EXPORT=… mix test --only private_fixture
  #
  # BUBBLE_EX_ASH_COUNTS names another snapshot file. That the generated
  # source compiles is checked by scripts/ash_compile_check.sh with the same
  # BUBBLE_EX_PRIVATE_EXPORT.
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Model}
  alias BubbleEx.Target.Ash
  alias BubbleEx.Target.Ash.{Project, Source}
  alias BubbleEx.Test.{PermutedJson, SplitExport}

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  @default_snapshot "test/support/target/ash/counts/mm-137.json"
  @budget_ms 10_000

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    app = SplitExport.load(path)
    {:ok, model} = Model.build(app)
    {:ok, index} = BubbleEx.Index.build(app)
    {micros, {:ok, project}} = :timer.tc(fn -> Ash.map(model, [], index: index) end)
    %{app: app, model: model, index: index, project: project, map_ms: div(micros, 1000)}
  end

  test "matches the recorded count snapshot", %{project: project, map_ms: ms} do
    snapshot = System.get_env("BUBBLE_EX_ASH_COUNTS") || @default_snapshot
    counts = Project.summary(project)

    IO.puts("""

    target ash: mapped in #{ms} ms (budget #{@budget_ms} ms)
    #{counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)}
    """)

    if System.get_env("BUBBLE_EX_UPDATE_COUNTS") do
      document = %{"schema_version" => Project.schema_version(), "counts" => counts}
      File.mkdir_p!(Path.dirname(snapshot))

      File.write!(
        snapshot,
        (document |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"
      )
    end

    recorded = snapshot |> File.read!() |> Jason.decode!()
    assert recorded["schema_version"] == Project.schema_version()
    assert counts == recorded["counts"], "counts changed; update #{snapshot} with a reason"
    assert ms <= @budget_ms
  end

  test "is deterministic across runs, permuted input and the name map",
       %{app: app, model: model, index: index, project: project} do
    {:ok, source} = Source.render(project)
    {:ok, again} = Ash.map(model, [], index: index)
    assert Project.to_json(again) == Project.to_json(project)
    assert Source.render(again) == {:ok, source}

    :rand.seed(:exsss, {1, 2, 3})
    {:ok, permuted_model} = app |> PermutedJson.encode() |> Jason.decode!() |> Model.build()
    {:ok, permuted} = Ash.map(permuted_model, [], index: index)
    assert Project.to_json(permuted) == Project.to_json(project)

    names = project.names |> Jason.encode!() |> Jason.decode!()
    {:ok, locked} = Ash.map(model, [], names: names, index: index)
    assert Project.to_json(locked) == Project.to_json(project)
  end

  test "every privacy rule of a mapped type compiles to a calculation or is itemized",
       %{model: model, project: project} do
    diagnosed =
      for d <- project.diagnostics,
          d.subject[:rule],
          into: MapSet.new(),
          do: {d.subject.type, d.subject.rule}

    for resource <- project.resources,
        type = Enum.find(model.data_types, &(&1.id == resource.source.type)),
        rule <- type.rules,
        not rule.default? do
      assert rule.id in resource.privacy.compiled_rules or
               {type.id, rule.id} in diagnosed,
             "#{type.id}/#{rule.id}"
    end

    assert project.policies_verified == false
  end

  test "every live data type is a resource with a unique module and table",
       %{model: model, project: project} do
    live = Enum.count(model.data_types, &(not &1.deleted and is_nil(&1.raw)))
    assert length(project.resources) == live
    assert project.resources |> Enum.map(& &1.module) |> Enum.uniq() |> length() == live
    assert project.resources |> Enum.map(& &1.table) |> Enum.uniq() |> length() == live
  end
end
