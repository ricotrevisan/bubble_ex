defmodule BubbleEx.Verify do
  @moduledoc """
  Stack-neutral verification formats (WTF-381, V1 of the WTF-358
  verification proposal): what a migration is checked against and how the
  outcome is recorded. Formats and validation only; the replay driver, the
  model interpreter and the target-side runners build on them.

  | Format (`format` member) | Module | Stored |
  |--------------------------|--------|--------|
  | `bubble_ex.verify.seed` | `BubbleEx.Verify.Seed` | `.wtf/verification/seeds/<id>.json` |
  | `bubble_ex.verify.scenario` | `BubbleEx.Verify.Scenario` | `.wtf/verification/scenarios/<kind>/<id>.json` |
  | `bubble_ex.verify.recording` | `BubbleEx.Verify.Recording` | `.wtf/verification/recordings/<scenario id>.json` |
  | `bubble_ex.verify.result` | `BubbleEx.Verify.Result` | CI artifact (not committed) |

  Shared parts: `BubbleEx.Verify.Value` (canonical Bubble values, WTF-338),
  `BubbleEx.Verify.Observation`, `BubbleEx.Verify.Mask`,
  `BubbleEx.Verify.Check` (the check registry and who may accept a
  difference) and `BubbleEx.Verify.Staleness`.

  Every format is versioned (`schema_version` 1), decodes strictly
  (unknown members and values are `:invalid_input`) and encodes
  canonically (sorted keys, `BubbleEx.CanonicalJson`; set-like lists
  sorted), so `to_json(from_json(x))` is stable and each format's
  `sha256/1` is a content hash. Everything is keyed by Bubble IDs and
  symbolic seed keys, never target names.

  The decisions that shape these formats (WTF-358): replay runs on a child
  branch, never live (D1: `Recording` rejects `live`/`test`); Bubble
  recordings are the oracle and interpreter results are marked `model`
  (D2: `Result.bubble_verified?/1`); privacy and data differences are
  accepted only through an owner `parity_exception` decision, agents may
  quarantine other behavioural scenarios for at most 7 days, and structural
  checks are never waivable (D4: `Result` status rules); seeds, scenarios
  and recordings live in the owner repo (D6).
  """

  alias BubbleEx.Error
  alias BubbleEx.Verify.{Json, Recording, Result, Scenario, Seed}

  @modules %{
    "bubble_ex.verify.seed" => Seed,
    "bubble_ex.verify.scenario" => Scenario,
    "bubble_ex.verify.recording" => Recording,
    "bubble_ex.verify.result" => Result
  }

  @type document :: Seed.t() | Scenario.t() | Recording.t() | Result.t()

  @doc "The `format` names, sorted."
  @spec formats() :: [String.t()]
  def formats, do: @modules |> Map.keys() |> Enum.sort()

  @doc """
  Decodes any verification document by its `format` member. An unknown
  format is `:unknown_format`; an invalid document `:invalid_input`.
  """
  @spec decode(String.t() | map()) :: {:ok, document()} | {:error, Error.t()}
  def decode(text) when is_binary(text), do: Json.from_json(text, "verification", &decode/1)

  def decode(%{"format" => format} = map) do
    case Map.fetch(@modules, format) do
      {:ok, module} ->
        module.from_map(map)

      :error ->
        {:error, Error.new(:unknown_format, "unknown verification format", %{format: format})}
    end
  end

  def decode(other),
    do:
      {:error,
       Error.new(:invalid_input, "a verification document needs a format", %{value: other})}

  @doc "Canonical JSON text of any verification document."
  @spec encode(document()) :: String.t()
  def encode(%module{} = doc) when module in [Seed, Scenario, Recording, Result],
    do: module.to_json(doc)
end
