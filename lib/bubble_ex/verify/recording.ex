defmodule BubbleEx.Verify.Recording do
  @moduledoc """
  What an oracle observed when it ran a scenario (WTF-358 §3.1, §5.2).
  Stored as `.wtf/verification/recordings/<scenario id>.json`; seeds are
  synthetic, so recordings are safe to commit.

  ```json
  {
    "format": "bubble_ex.verify.recording",
    "schema_version": 1,
    "scenario": {"id": "privacy_read.custom.task.w2_member", "sha256": "…", "source_sha256": "…"},
    "seed_sha256": "…",
    "oracle": "bubble",
    "source": {"app": "acme", "branch": "wtfreplay", "app_version": "1727222400123"},
    "recorded_at": "2026-10-02T09:12:00Z",
    "t0": 1759396320000,
    "runs": 2,
    "complete": true,
    "masks": [{"op": "o2", "kind": "values", "pointer": "/Modified Date", "reason": "differential", …}],
    "observations": [{"op": "o1", "kind": "record_set", "record": null,
                      "value": {"ordered": false, "records": ["task_w2"]}}],
    "stats": {"calls": 3, "workload_units": 1.5}
  }
  ```

  **Oracles (decision D2 on WTF-358).** `bubble`: recorded from a Bubble
  replay branch; the ground truth. `source` needs `app` and `branch`, and
  the branch may not be `live` or `test` (D1: replay runs on a child branch,
  never live); `app_version` is Bubble's version marker when known.
  `model`: expectations from the model interpreter; `source` needs
  `bubble_ex` (the interpreter's version) and may carry
  `index_semantic_sha256`. A `model` recording never counts as
  Bubble-verified (see `BubbleEx.Verify.Result.bubble_verified?/1`).

  **Staleness.** A recording pins `scenario.sha256` (`Scenario.sha256/1`),
  the scenario's `source_sha256` and `seed_sha256`;
  `BubbleEx.Verify.Staleness.recording/3` lists what changed. An
  incomplete recording (`complete: false`, e.g. a budget ran out) is kept
  for diagnosis but is never an oracle.

  Observations are unique by (op, kind, record) and sorted; masks are
  sorted. `check_scenario/2` checks them against the scenario.
  """

  alias BubbleEx.{CanonicalJson, Error}
  alias BubbleEx.Verify.{Json, Mask, Observation, Scenario, Seed}

  @format "bubble_ex.verify.recording"
  @schema_version 1
  @members ~w(format schema_version scenario seed_sha256 oracle source recorded_at t0 runs
              complete masks observations stats)
  @required ~w(format schema_version scenario seed_sha256 oracle source recorded_at t0 complete
               observations)
  @oracles [:bubble, :model]
  @forbidden_branches ~w(live test)

  @type oracle :: :bubble | :model
  @type t :: %__MODULE__{
          scenario: %{id: String.t(), sha256: String.t(), source_sha256: String.t()},
          seed_sha256: String.t(),
          oracle: oracle(),
          source: map(),
          recorded_at: DateTime.t(),
          t0: integer(),
          runs: pos_integer(),
          complete: boolean(),
          masks: [Mask.t()],
          observations: [Observation.t()],
          stats: %{calls: non_neg_integer() | nil, workload_units: float() | nil}
        }

  @enforce_keys [:scenario, :seed_sha256, :oracle, :source, :recorded_at, :t0, :complete]
  defstruct [
    :scenario,
    :seed_sha256,
    :oracle,
    :source,
    :recorded_at,
    :t0,
    :complete,
    runs: 1,
    masks: [],
    observations: [],
    stats: %{calls: nil, workload_units: nil}
  ]

  @doc "The `format` member."
  @spec format() :: String.t()
  def format, do: @format

  @doc "The JSON format version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds and validates a recording from atom-keyed attributes (as `from_map/1`)."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    __MODULE__
    |> struct(Map.new(attrs))
    |> to_map()
    |> from_map()
  end

  @doc """
  A recording skeleton for `scenario` and `seed`: the scenario and seed
  hashes filled in from the current files.
  """
  @spec for_scenario(Scenario.t(), Seed.t(), map() | keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def for_scenario(%Scenario{} = scenario, %Seed{} = seed, attrs) do
    attrs
    |> Map.new()
    |> Map.merge(%{
      scenario: %{
        id: scenario.id,
        sha256: Scenario.sha256(scenario),
        source_sha256: scenario.source_sha256
      },
      seed_sha256: Seed.sha256(seed)
    })
    |> new()
  end

  @doc "Decodes and validates the JSON form."
  @spec from_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(map) do
    with :ok <- Json.envelope(map, @format, @schema_version, @members, @required, "recording"),
         {:ok, scenario} <- scenario_ref(map["scenario"]),
         {:ok, seed} <- Json.sha256(map["seed_sha256"], "recording seed_sha256"),
         {:ok, oracle} <- Json.enum(map["oracle"], @oracles, "recording oracle"),
         {:ok, source} <- source(oracle, map["source"]),
         {:ok, recorded_at} <- Json.timestamp(map["recorded_at"], "recorded_at"),
         {:ok, t0} <- t0(map["t0"]),
         {:ok, runs} <- runs(Map.get(map, "runs", 1)),
         {:ok, complete} <- Json.boolean(map["complete"], "recording complete"),
         {:ok, masks} <-
           Json.list(Map.get(map, "masks") || [], "recording masks", &Mask.from_map/1),
         {:ok, observations} <-
           Json.list(map["observations"], "recording observations", &Observation.from_map/1),
         :ok <- Json.unique(observations, &Observation.key/1, "observations"),
         {:ok, stats} <- stats(Map.get(map, "stats") || %{}) do
      {:ok,
       %__MODULE__{
         scenario: scenario,
         seed_sha256: seed,
         oracle: oracle,
         source: source,
         recorded_at: recorded_at,
         t0: t0,
         runs: runs,
         complete: complete,
         masks: Mask.sort(masks),
         observations: Observation.sort(observations),
         stats: stats
       }}
    end
  end

  defp scenario_ref(map) do
    with :ok <-
           Json.members(
             map,
             ~w(id sha256 source_sha256),
             ~w(id sha256 source_sha256),
             "recording scenario"
           ),
         {:ok, id} <- Json.symbol(map["id"], "recording scenario id"),
         {:ok, sha} <- Json.sha256(map["sha256"], "recording scenario sha256"),
         {:ok, source} <- Json.sha256(map["source_sha256"], "recording scenario source_sha256") do
      {:ok, %{id: id, sha256: sha, source_sha256: source}}
    end
  end

  defp source(:bubble, map) do
    with :ok <- Json.members(map, ~w(app branch app_version), ~w(app branch), "bubble source"),
         {:ok, app} <- Json.string(map["app"], "source app"),
         {:ok, branch} <- Json.string(map["branch"], "source branch"),
         :ok <- replay_branch(branch),
         {:ok, version} <- Json.optional_string(map["app_version"], "source app_version") do
      {:ok, %{app: app, branch: branch, app_version: version}}
    end
  end

  defp source(:model, map) do
    with :ok <-
           Json.members(map, ~w(bubble_ex index_semantic_sha256), ~w(bubble_ex), "model source"),
         {:ok, version} <- Json.string(map["bubble_ex"], "source bubble_ex"),
         {:ok, sha} <-
           Json.optional_sha256(map["index_semantic_sha256"], "source index_semantic_sha256") do
      {:ok, %{bubble_ex: version, index_semantic_sha256: sha}}
    end
  end

  # D1: never live, never the shared test version.
  defp replay_branch(branch) do
    if String.downcase(branch) in @forbidden_branches,
      do:
        Json.error("Bubble recordings come from a replay child branch, never live or test", %{
          branch: branch
        }),
      else: :ok
  end

  defp t0(ms) when is_integer(ms), do: {:ok, ms}
  defp t0(v), do: Json.error("t0 must be integer milliseconds (UTC)", %{value: v})

  defp runs(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp runs(n), do: Json.error("runs must be a positive integer", %{value: n})

  defp stats(map) do
    with :ok <- Json.members(map, ~w(calls workload_units), [], "recording stats"),
         {:ok, calls} <- Json.count(map["calls"], "stats calls", :optional) do
      case map["workload_units"] do
        nil -> {:ok, %{calls: calls, workload_units: nil}}
        n when is_number(n) and n >= 0 -> {:ok, %{calls: calls, workload_units: n / 1}}
        n -> Json.error("stats workload_units must be a non-negative number", %{value: n})
      end
    end
  end

  @doc "JSON form."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = r) do
    %{
      "format" => @format,
      "schema_version" => @schema_version,
      "scenario" => Json.json(r.scenario),
      "seed_sha256" => r.seed_sha256,
      "oracle" => Json.json(r.oracle),
      "source" => Json.json(r.source),
      "recorded_at" => Json.json(r.recorded_at),
      "t0" => r.t0,
      "runs" => r.runs,
      "complete" => r.complete,
      "masks" => r.masks |> Mask.sort() |> Enum.map(&Mask.to_map/1),
      "observations" => r.observations |> Observation.sort() |> Enum.map(&Observation.to_map/1),
      "stats" => Json.json(r.stats)
    }
  end

  @doc "Canonical JSON text."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = r), do: r |> to_map() |> Json.encode()

  @doc "Decodes JSON text (see `from_map/1`)."
  @spec from_json(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_json(text), do: Json.from_json(text, "recording", &from_map/1)

  @doc "SHA-256 of the canonical JSON: what results pin as `oracle.recording_sha256`."
  @spec sha256(t()) :: String.t()
  def sha256(%__MODULE__{} = r), do: r |> to_map() |> CanonicalJson.sha256()

  @doc """
  Checks the recording against `scenario`: same ID; every observation
  belongs to an op the scenario has and is a kind that op observes; a per-record
  observation of a `get` is about that op's record; a `record_set` is
  ordered exactly when its `search` declares a sort; masks name ops the
  scenario has. Hash drift is not an error here: it is staleness
  (`BubbleEx.Verify.Staleness.recording/3`).
  """
  @spec check_scenario(t(), Scenario.t()) :: :ok | {:error, Error.t()}
  def check_scenario(%__MODULE__{} = r, %Scenario{} = s) do
    ops = Map.new(s.ops, &{&1.id, &1})

    cond do
      r.scenario.id != s.id ->
        Json.error("recording is for another scenario", %{scenario: r.scenario.id, given: s.id})

      (bad = Enum.reject(r.observations, &fits?(&1, ops[&1.op]))) != [] ->
        Json.error("observations do not fit the scenario's ops", %{
          observations: Enum.map(bad, &Observation.key/1)
        })

      (bad = Enum.reject(r.masks, &Map.has_key?(ops, &1.op))) != [] ->
        Json.error("recording masks name unknown ops", %{ops: Enum.map(bad, & &1.op)})

      true ->
        :ok
    end
  end

  defp fits?(_obs, nil), do: false

  defp fits?(%Observation{kind: kind} = obs, op) do
    kind in op.observe and
      case {op.op, kind} do
        {:get, _} -> obs.record == op.record
        {:search, :record_set} -> obs.value.ordered == not is_nil(op.sort)
        _ -> true
      end
  end

  @doc """
  The recording's observations as JSON values with the scenario's and the
  recording's ignoring masks applied (`BubbleEx.Verify.Mask.masked_value/2`),
  keyed by `Observation.key/1`: what a comparator compares.
  """
  @spec comparable(t(), [Mask.t()]) :: %{
          {String.t(), Observation.kind(), String.t() | nil} => term()
        }
  def comparable(%__MODULE__{} = r, scenario_masks \\ []) do
    masks = scenario_masks ++ r.masks
    Map.new(r.observations, &{Observation.key(&1), Mask.masked_value(&1, masks)})
  end
end
