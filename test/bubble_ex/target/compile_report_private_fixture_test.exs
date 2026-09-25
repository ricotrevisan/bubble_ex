defmodule BubbleEx.Target.CompileReportPrivateFixtureTest do
  # The expression compiler's compile rate on a real app (WTF-368), like
  # BubbleEx.Target.AshPrivateFixtureTest. Excluded by default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
  #
  # `BubbleEx.Target.CompileReport.build/4` counts (no names or IDs) are
  # compared with a committed snapshot, by default the mm-137 test
  # version's, for each setting of `ignore_empty_constraints` (Bubble's
  # default for searches that do not state it is not verified). A changed
  # count means updating the snapshot, with the reason in the PR:
  #
  #     BUBBLE_EX_UPDATE_COUNTS=1 BUBBLE_EX_PRIVATE_EXPORT=… mix test --only private_fixture
  #
  # BUBBLE_EX_COMPILE_COUNTS names another snapshot file. That the compiled
  # privacy filters compile and run against the pinned Ash is checked by
  # scripts/ash_compile_check.sh with the same BUBBLE_EX_PRIVATE_EXPORT.
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Model}
  alias BubbleEx.Target.{Ash, CompileReport}
  alias BubbleEx.Target.Ash.Expressions
  alias BubbleEx.Test.SplitExport

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  @default_snapshot "test/support/expression/counts/mm-137.json"
  @settings [{"unknown", nil}, {"ignored", true}, {"compared", false}]

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    app = SplitExport.load(path)
    {:ok, model} = Model.build(app)
    {:ok, project} = Ash.map(model)
    %{app: app, model: model, project: project}
  end

  test "matches the recorded count snapshot", %{app: app, model: model, project: project} do
    snapshot = System.get_env("BUBBLE_EX_COMPILE_COUNTS") || @default_snapshot

    counts =
      Map.new(@settings, fn {name, setting} ->
        {:ok, report} =
          CompileReport.build(app, model, project, ignore_empty_constraints: setting)

        {name, report}
      end)

    IO.puts("""

    expression compile report (by ignore_empty_constraints default):
    #{counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)}
    """)

    if System.get_env("BUBBLE_EX_UPDATE_COUNTS") do
      File.mkdir_p!(Path.dirname(snapshot))
      document = %{"ignore_empty_constraints" => counts}

      File.write!(
        snapshot,
        (document |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"
      )
    end

    recorded = snapshot |> File.read!() |> Jason.decode!()

    assert counts == recorded["ignore_empty_constraints"],
           "counts changed; update #{snapshot} with a reason"
  end

  test "every privacy condition compiles or is itemized, deterministically",
       %{model: model, project: project} do
    {:ok, results} = Expressions.privacy(model, project)
    assert results != []

    for result <- results do
      assert result.expr != nil or result.diagnostics != [], "#{result.type}/#{result.rule}"
    end

    assert Expressions.privacy(model, project) == {:ok, results}
  end
end
