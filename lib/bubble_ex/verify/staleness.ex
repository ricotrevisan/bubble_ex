defmodule BubbleEx.Verify.Staleness do
  @moduledoc """
  When recordings and results stop being evidence (WTF-358 §1.1, §3.8).
  Pure functions of the pinned hashes and the current ones: nothing here
  reads files or calls Bubble.

  **Recordings** pin `scenario.sha256` (`BubbleEx.Verify.Scenario.sha256/1`:
  the scenario without masks, covers and subjects), the scenario's
  `source_sha256` (the index subgraph it touches) and `seed_sha256`. When
  any differs from the current files, the recording must be re-recorded
  before it is an oracle again; an incomplete recording never is one.

  **Results** pin `basis.source_sha256`, `basis.decisions_sha256`
  (`BubbleEx.Decision.decisions_sha256/1`: changing any decision's
  generation inputs makes every result re-run), the scenario hashes and
  the oracle's `sha256` (the recording's `BubbleEx.Verify.Recording.sha256/1`).
  A pinned hash that is `nil` on either side is not compared. Decision
  validity itself is `BubbleEx.Verify.Result.link_decision/2`.

  Reasons are `BubbleEx.Verify.Result.stale_reasons/0`;
  `BubbleEx.Verify.Result.mark_stale/2` applies them.
  """

  alias BubbleEx.Verify.{Recording, Result, Scenario, Seed}

  @type current :: %{
          optional(:source_sha256) => String.t() | nil,
          optional(:decisions_sha256) => String.t() | nil,
          optional(:scenario) => Scenario.t() | nil,
          optional(:seed) => Seed.t() | nil,
          optional(:recording) => Recording.t() | nil
        }

  @doc """
  Why `recording` is no longer an oracle for `scenario` and `seed`:
  `:scenario_changed`, `:source_changed`, `:seed_changed`,
  `:recording_incomplete` (sorted; `[]` when it is current).
  """
  @spec recording(Recording.t(), Scenario.t(), Seed.t()) :: [atom()]
  def recording(%Recording{} = r, %Scenario{} = scenario, %Seed{} = seed) do
    [
      {:scenario_changed, r.scenario.sha256 != Scenario.sha256(scenario)},
      {:source_changed, r.scenario.source_sha256 != scenario.source_sha256},
      {:seed_changed, r.seed_sha256 != Seed.sha256(seed)},
      {:recording_incomplete, not r.complete}
    ]
    |> reasons()
  end

  @doc """
  Why `result` is no longer current, given what is current now: any of
  `:source_changed`, `:decisions_changed`, `:scenario_changed`,
  `:seed_changed`, `:recording_changed` and (when the current recording is
  given) the recording's own reasons.
  """
  @spec result(Result.t(), current()) :: [atom()]
  def result(%Result{} = r, current) when is_map(current) do
    scenario = current[:scenario]
    seed = current[:seed]
    recording = current[:recording]
    pinned = r.scenario || %{}

    [
      {:source_changed, differs?(r.basis.source_sha256, current[:source_sha256])},
      {:decisions_changed, differs?(r.basis.decisions_sha256, current[:decisions_sha256])},
      {:scenario_changed, differs?(pinned[:sha256], scenario && Scenario.sha256(scenario))},
      {:source_changed, differs?(pinned[:source_sha256], scenario && scenario.source_sha256)},
      {:seed_changed, differs?(pinned[:seed_sha256], seed && Seed.sha256(seed))},
      {:recording_changed,
       differs?(r.oracle && r.oracle.sha256, recording && Recording.sha256(recording))}
    ]
    |> reasons()
    |> Kernel.++(recording_reasons(recording, scenario, seed))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "`result/2` applied: the result marked stale when any reason holds."
  @spec refresh(Result.t(), current()) :: Result.t()
  def refresh(%Result{} = r, current), do: Result.mark_stale(r, result(r, current))

  defp recording_reasons(%Recording{} = rec, %Scenario{} = s, %Seed{} = seed),
    do: recording(rec, s, seed)

  defp recording_reasons(%Recording{complete: false}, _, _), do: [:recording_incomplete]
  defp recording_reasons(_, _, _), do: []

  defp differs?(nil, _), do: false
  defp differs?(_, nil), do: false
  defp differs?(a, b), do: a != b

  defp reasons(checks),
    do: for({reason, true} <- checks, do: reason) |> Enum.uniq() |> Enum.sort()
end
