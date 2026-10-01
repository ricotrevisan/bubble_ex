defmodule BubbleEx.Verify.CalibrationTest do
  # Calibrating the interpreter against Bubble recordings (WTF-426): the
  # fair comparison through the Data API is the default, the ID-only
  # answer is counted, and per flag the dependent ops and flip effects.
  use ExUnit.Case, async: true

  alias BubbleEx.Model
  alias BubbleEx.Verify.{Calibration, DataApi, Difference, Matrix, Recording}

  @policy_app "test/support/target/ash/policies.json" |> File.read!() |> Jason.decode!()

  setup_all do
    {:ok, model} = Model.build(@policy_app)
    {:ok, matrix} = Matrix.synthesize(model, app: "fixture-app")
    %{model: model, matrix: matrix, held: DataApi.held_map(matrix.seed)}
  end

  # Bubble recordings: what the Data API answers for `observations_of`.
  defp bubble(matrix, held, observations_of) do
    for r <- matrix.recordings do
      {:ok, rec} =
        %{
          r
          | oracle: :bubble,
            source: %{app: "fixture-app", branch: "wtfreplay"},
            observations: DataApi.project(observations_of.(r), held)
        }
        |> Map.from_struct()
        |> Recording.new()

      rec
    end
  end

  test "a Bubble that answers as the interpreter predicts agrees everywhere", ctx do
    recordings = bubble(ctx.matrix, ctx.held, & &1.observations)
    {:ok, report} = Calibration.compare(ctx.model, ctx.matrix, recordings)

    assert report.held_only
    assert report.ops == ctx.matrix.report.checks
    assert report.disagree == 0 and report.disagreements == []
    assert report.skipped == 0

    for {_flag, f} <- report.flags,
        do: assert(f.flip_fixes == 0 and f.disagree == 0)

    assert report.flags.dangling_ref_is_empty.verdict == :not_exercised
  end

  test "empty fields are left out by default: raw comparison disagrees", ctx do
    recordings = bubble(ctx.matrix, ctx.held, & &1.observations)
    {:ok, raw} = Calibration.compare(ctx.model, ctx.matrix, recordings, held_only: false)
    refute raw.held_only
    assert raw.disagree > 0
  end

  test "a Bubble reading like the target policy refutes nothing but shows the flag", ctx do
    # Bubble answering like the fail-safe reading (empty user-side values deny)
    recordings =
      bubble(ctx.matrix, ctx.held, fn r ->
        Difference.to_target(
          r.observations,
          Difference.for_scenario(ctx.matrix.differences, r.scenario.id)
        )
      end)

    {:ok, report} = Calibration.compare(ctx.model, ctx.matrix, recordings)
    assert report.disagree > 0
    f = report.flags.actor_empty_denies
    assert f.flip_fixes == f.disagree and f.flip_fixes > 0
    assert f.flip_breaks == 0

    # each disagreement is a scenario with an intended difference
    scenarios = ctx.matrix.differences |> Enum.map(& &1.scenario) |> MapSet.new()
    assert Enum.all?(report.disagreements, &MapSet.member?(scenarios, &1.scenario))

    # under the target's reading the same recordings agree
    {:ok, target} =
      Calibration.compare(ctx.model, ctx.matrix, recordings,
        assumptions:
          for(
            flag <- Difference.flags(:rule_conditions),
            do: {flag, Difference.policy()[flag].target}
          )
      )

    assert target.disagree == 0
  end

  test "incomplete or model recordings are skipped; bad input is refused", ctx do
    [first | rest] = bubble(ctx.matrix, ctx.held, & &1.observations)

    {:ok, report} =
      Calibration.compare(
        ctx.model,
        ctx.matrix,
        [%{first | complete: false} | rest] ++ ctx.matrix.recordings
      )

    assert report.skipped == 1 + length(ctx.matrix.recordings)
    assert %{ambiguous: _, found_by_search: _} = report.id_only
    assert {:error, %{kind: :invalid_input}} = Calibration.compare(:nope, ctx.matrix, [])
  end

  describe "the Data API's view" do
    test "an ID-only answer: hidden, or readable with no held field" do
      held = ["Created Date", "title_text"]
      assert DataApi.answer(false, ["title_text"], held) == :id_only
      assert DataApi.answer(true, ["body_text"], held) == :id_only
      assert DataApi.answer(true, ["body_text", "title_text"], held) == {:fields, ["title_text"]}
      assert DataApi.ambiguous?(true, ["body_text"], held)
      refute DataApi.ambiguous?(false, ["body_text"], held)
    end

    test "held fields are the seed's non-empty values and the built-ins Bubble sets", ctx do
      held = DataApi.held(ctx.matrix.seed, "u.admin")
      assert "email" in held and "admin_boolean" in held
      assert Enum.all?(DataApi.always_held(), &(&1 in held))
      assert DataApi.held(ctx.matrix.seed, "no.such.key") == Enum.sort(DataApi.always_held())
    end
  end
end
