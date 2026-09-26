defmodule BubbleEx.Verify.MatrixPrivateFixtureTest do
  # Privacy-matrix coverage on a real app (WTF-382; the WTF-358 exit
  # criterion: at least 90% of mm-137's 125 privacy rules solved). Real-app
  # captures stay private, so this reads a local export and is excluded by
  # default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
  #
  # Both measures are reported: rules solved (each condition exercised both
  # ways) and rules observable (mutation coverage), with per-flag counts of
  # the checks that depend on each assumption.
  #
  # The report's counts (no names or Bubble IDs; `Matrix.counts/1`) are
  # compared with a committed snapshot, by default the mm-137 test
  # version's. A changed count means updating the snapshot, with the reason
  # in the PR:
  #
  #     BUBBLE_EX_UPDATE_COUNTS=1 BUBBLE_EX_PRIVATE_EXPORT=… mix test --only private_fixture
  #
  # BUBBLE_EX_MATRIX_COUNTS names another snapshot file. Unsolved and
  # unobservable rules are
  # printed with their reasons (and IDs) to the console only.
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Model}
  alias BubbleEx.Test.SplitExport
  alias BubbleEx.Verify.{Matrix, Recording, Scenario}

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  @default_snapshot "test/support/verify/counts/mm-137.json"

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    {:ok, model} = path |> SplitExport.load() |> Model.build()
    {:ok, matrix} = Matrix.synthesize(model, app: "private-app")
    %{model: model, matrix: matrix}
  end

  test "coverage matches the recorded count snapshot and the 90% target", %{matrix: matrix} do
    snapshot = System.get_env("BUBBLE_EX_MATRIX_COUNTS") || @default_snapshot
    counts = Matrix.counts(matrix.report)

    IO.puts("""

    privacy matrix coverage:
    #{counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)}
    unsolved rules:
    #{Enum.map_join(matrix.report.unsolved, "\n", &"  #{&1.type}/#{&1.rule}: #{&1.reason} (#{&1.detail})")}
    unobservable rules:
    #{Enum.map_join(matrix.report.unobservable, "\n", &"  #{&1.type}/#{&1.rule}: #{&1.reason}")}
    """)

    if System.get_env("BUBBLE_EX_UPDATE_COUNTS") do
      File.mkdir_p!(Path.dirname(snapshot))

      File.write!(
        snapshot,
        (counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"
      )
    end

    assert counts == snapshot |> File.read!() |> Jason.decode!(),
           "counts changed; update #{snapshot} with a reason"

    assert matrix.report.rules.solved_percent >= 90.0
  end

  test "every document validates, deterministically", %{model: model, matrix: matrix} do
    for {scenario, recording} <- Enum.zip(matrix.scenarios, matrix.recordings) do
      assert :ok = Scenario.check_seed(scenario, matrix.seed)
      assert :ok = Recording.check_scenario(recording, scenario)
    end

    {:ok, again} = Matrix.synthesize(model, app: "private-app")
    assert Matrix.files(again) == Matrix.files(matrix)
  end
end
