defmodule BubbleEx.Verify.Result do
  @moduledoc """
  One check's outcome in one run: the evidence record every verification
  level writes (WTF-358 §5.1, `CheckResult`). Results are CI artifacts,
  not committed.

  ```json
  {
    "format": "bubble_ex.verify.result",
    "schema_version": 1,
    "id": "privacy_read.custom.task.w2_member",
    "check": "privacy_read",
    "level": "L2",
    "class": "privacy",
    "status": "decided_difference",
    "subjects": {"type": "custom.task"},
    "tasks": ["generate:policies"],
    "scenario": {"id": "privacy_read.custom.task.w2_member", "sha256": "…",
                 "source_sha256": "…", "seed_sha256": "…"},
    "oracle": {"kind": "bubble", "sha256": "…", "branch": "wtfreplay"},
    "basis": {"source_sha256": "…", "decisions_sha256": "…"},
    "subject_build": {"git_sha": "0a1b2c3", "generated_manifest_sha256": "…"},
    "diff": [{"op": "field_visible", "record": "task_w1", "field": "notes_text",
              "expected": false, "actual": true}],
    "evidence": [{"kind": "recording", "ref": ".wtf/verification/recordings/….json", "sha256": "…"}],
    "decision": {"key": "finding:privacy_access_list:9f2c…", "proposal_sha256": "…"},
    "waiver": null,
    "reason": null,
    "stale_reasons": [],
    "actor": "ci",
    "ran_at": "2026-10-02T09:15:00Z"
  }
  ```

  `level` and `class` come from the check (`BubbleEx.Verify.Check`); a
  result that states others is `:invalid_input`.

  ## Statuses

  Decoding (`from_map/1`) enforces each status's shape; whether a result
  **counts** is only known after `evaluate/3` has checked it against the
  decision store. A decoded result alone never counts as passing.

  | status | counts after `evaluate/3` | rule (enforced by `from_map/1`) |
  |--------|---------------------------|---------------------------------|
  | `pass` | yes | no diff, decision or waiver |
  | `decided_difference` | yes, if the decision links | a diff explained by a **finding** decision: `decision` = its `key` + the finding's `proposal_sha256`; the class must be decidable |
  | `waived` | yes (listed at cutover), if the decision links or the reviewer is trusted | a diff excused by an owner **parity exception** (`decision` = its `key`, `proposal_sha256` null, no `waiver`), or by a `waiver` from an agent or reviewer the class allows (visual reviewer waivers need an `attestation` with its `sha256` in `evidence`). Owner waivers are refused: owners accept through decisions |
  | `quarantined` | no, blocks cutover | `behavior` checks only: a `waiver` with a reason, `since` (the first quarantine, not after `ran_at`) and `expires_at` after `ran_at` and at most 7 days after `since`; no decision |
  | `fail` | no | no decision or waiver |
  | `stale` | no | `stale_reasons` (`BubbleEx.Verify.Staleness`); the rest is kept as it was |
  | `skipped` | no for privacy, data and auth; yes elsewhere | a `reason` |
  | `error` | no | a `reason` |

  So agents can never accept a privacy, data or auth difference: those
  classes have no waivers and no quarantine, and a finding decision or
  parity exception must be the owner's (`link_decision/3` checks the
  author recorded in the decision store). Structural and gate checks accept
  no difference at all.

  L2 and L3 results other than `stale`, `skipped` and `error` need a
  `scenario` and an `oracle`. A Bubble oracle names its replay branch
  (`BubbleEx.Verify.Replay`). A result whose oracle is `model` (the
  interpreter) never counts as Bubble-verified at any level (`evaluate/3`,
  decision D2 on WTF-358).

  ## Decisions

  `decision` references a `BubbleEx.Decision` by `key`: a `finding:` key
  with the finding's `proposal_sha256`, or a `parity_exception:` key with
  `proposal_sha256` null (parity exceptions are the `BubbleEx.Decision`
  envelope of kind `:parity_exception`; they have no proposal).
  `link_decision/3` checks the reference against `BubbleEx.Decision.resolve/3`
  output (author, relevance, hashes) and turns the result `stale` when the
  decision no longer holds.
  """

  alias BubbleEx.{CanonicalJson, Decision, Error, Finding}
  alias BubbleEx.Decision.Resolved
  alias BubbleEx.Verify.{Check, Json, Recording, Replay, Scenario}

  @format "bubble_ex.verify.result"
  @schema_version 1
  @members ~w(format schema_version id check level class status subjects tasks scenario oracle
              basis subject_build diff evidence decision waiver reason stale_reasons actor ran_at)
  @required ~w(format schema_version id check status actor ran_at)

  @statuses [:pass, :decided_difference, :waived, :quarantined, :fail, :stale, :skipped, :error]
  @stale_reasons [
    :scenario_changed,
    :source_changed,
    :seed_changed,
    :recording_changed,
    :recording_incomplete,
    :decisions_changed,
    :decision_changed,
    :decision_stale,
    :decision_orphaned,
    :decision_expired,
    :decision_withdrawn
  ]
  @oracles [:bubble, :model, :export]
  @actors [:agent, :reviewer]
  @evidence [:recording, :scenario, :seed, :attestation, :screenshot, :artifact, :log, :decision]
  @diff_ops ~w(record_visible field_visible field_value record_set record_created record_updated
               record_deleted field_changed status response_field step_order dom_text pixel_ratio
               row_count row_hash dangling_refs file auth_user file_changed not_deterministic
               compile_error lint boundary migration symbol_uncovered rule_uncovered
               bypass_unlisted secret_found marker_missing criterion gate)
  @diff_members ~w(op type record field element workflow rule path expected actual detail)
  @diff_atoms Map.new(@diff_members, &{&1, String.to_atom(&1)})
  @quarantine_days 7

  @type status ::
          :pass
          | :decided_difference
          | :waived
          | :quarantined
          | :fail
          | :stale
          | :skipped
          | :error
  @type decision_ref :: %{
          key: String.t(),
          kind: :finding | :parity_exception,
          proposal_sha256: String.t() | nil
        }
  @type waiver :: %{
          actor: %{kind: Check.actor(), id: String.t() | nil},
          reason: String.t(),
          expires_at: DateTime.t() | nil
        }
  @type t :: %__MODULE__{
          id: String.t(),
          check: String.t(),
          level: Check.level(),
          class: Check.class(),
          status: status(),
          subjects: %{atom() => String.t()},
          tasks: [String.t()],
          scenario: map() | nil,
          oracle: map() | nil,
          basis: %{source_sha256: String.t() | nil, decisions_sha256: String.t() | nil},
          subject_build: map() | nil,
          diff: [map()],
          evidence: [map()],
          decision: decision_ref() | nil,
          waiver: waiver() | nil,
          reason: String.t() | nil,
          stale_reasons: [atom()],
          actor: String.t(),
          ran_at: DateTime.t()
        }

  @enforce_keys [:id, :check, :status, :actor, :ran_at]
  defstruct [
    :id,
    :check,
    :level,
    :class,
    :status,
    :scenario,
    :oracle,
    :subject_build,
    :decision,
    :waiver,
    :reason,
    :actor,
    :ran_at,
    subjects: %{},
    tasks: [],
    basis: %{source_sha256: nil, decisions_sha256: nil},
    diff: [],
    evidence: [],
    stale_reasons: []
  ]

  @doc "The `format` member."
  @spec format() :: String.t()
  def format, do: @format

  @doc "The JSON format version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "The statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "The stale reasons."
  @spec stale_reasons() :: [atom()]
  def stale_reasons, do: @stale_reasons

  @doc """
  Builds and validates a result from atom-keyed attributes (as
  `from_map/1`); `level` and `class` are filled in from the check.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    attrs = Map.new(attrs)

    with {:ok, {level, class}} <- Check.fetch(attrs[:check]) do
      __MODULE__
      |> struct(attrs)
      |> Map.merge(%{level: level, class: class})
      |> to_map()
      |> from_map()
    end
  end

  # --- decoding ---------------------------------------------------------------

  @doc "Decodes and validates the JSON form, including the status rules."
  @spec from_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(map) do
    with :ok <- Json.envelope(map, @format, @schema_version, @members, @required, "result"),
         {:ok, result} <- fields(map),
         :ok <- status_rules(result) do
      {:ok, result}
    end
  end

  defp fields(map) do
    with {:ok, id} <- Json.symbol(map["id"], "result id"),
         {:ok, check} <- Json.string(map["check"], "result check"),
         {:ok, {level, class}} <- Check.fetch(check),
         :ok <- stated(map["level"], Check.level_json(level), "level"),
         :ok <- stated(map["class"], Atom.to_string(class), "class"),
         {:ok, status} <- Json.enum(map["status"], @statuses, "result status"),
         {:ok, subjects} <- Check.subjects(Map.get(map, "subjects") || %{}),
         {:ok, tasks} <- Json.string_set(Map.get(map, "tasks") || [], "result tasks"),
         {:ok, scenario} <- scenario_ref(map["scenario"]),
         {:ok, oracle} <- oracle(map["oracle"]),
         {:ok, basis} <- basis(Map.get(map, "basis") || %{}),
         {:ok, build} <- subject_build(map["subject_build"]),
         {:ok, diff} <- Json.list(Map.get(map, "diff") || [], "result diff", &diff_entry/1),
         {:ok, evidence} <-
           Json.list(Map.get(map, "evidence") || [], "result evidence", &evidence/1),
         {:ok, decision} <- decision_ref(map["decision"]),
         {:ok, waiver} <- waiver(map["waiver"]),
         {:ok, reason} <- Json.optional_string(map["reason"], "result reason"),
         {:ok, stale} <- stale(Map.get(map, "stale_reasons") || []),
         {:ok, actor} <- Json.string(map["actor"], "result actor"),
         {:ok, ran_at} <- Json.timestamp(map["ran_at"], "ran_at") do
      {:ok,
       %__MODULE__{
         id: id,
         check: check,
         level: level,
         class: class,
         status: status,
         subjects: subjects,
         tasks: tasks,
         scenario: scenario,
         oracle: oracle,
         basis: basis,
         subject_build: build,
         diff: diff,
         evidence: Enum.sort_by(evidence, &{&1.kind, &1.ref}),
         decision: decision,
         waiver: waiver,
         reason: reason,
         stale_reasons: stale,
         actor: actor,
         ran_at: ran_at
       }}
    end
  end

  defp stated(nil, _expected, _name), do: :ok
  defp stated(expected, expected, _name), do: :ok

  defp stated(given, expected, name),
    do: Json.error("result #{name} does not match its check", %{given: given, expected: expected})

  defp scenario_ref(nil), do: {:ok, nil}

  defp scenario_ref(map) do
    keys = ~w(id sha256 source_sha256 seed_sha256)

    with :ok <- Json.members(map, keys, keys, "result scenario"),
         {:ok, id} <- Json.symbol(map["id"], "result scenario id"),
         {:ok, sha} <- Json.sha256(map["sha256"], "result scenario sha256"),
         {:ok, source} <- Json.sha256(map["source_sha256"], "result scenario source_sha256"),
         {:ok, seed} <- Json.sha256(map["seed_sha256"], "result scenario seed_sha256") do
      {:ok, %{id: id, sha256: sha, source_sha256: source, seed_sha256: seed}}
    end
  end

  defp oracle(nil), do: {:ok, nil}

  defp oracle(map) do
    with :ok <- Json.members(map, ~w(kind sha256 branch), ~w(kind sha256), "result oracle"),
         {:ok, kind} <- Json.enum(map["kind"], @oracles, "oracle kind"),
         {:ok, sha} <- Json.sha256(map["sha256"], "oracle sha256"),
         {:ok, branch} <- oracle_branch(kind, map["branch"]) do
      {:ok, %{kind: kind, sha256: sha, branch: branch}}
    end
  end

  defp oracle_branch(:bubble, branch), do: Replay.branch(branch)
  defp oracle_branch(_kind, nil), do: {:ok, nil}
  defp oracle_branch(kind, _branch), do: Json.error("a #{kind} oracle has no branch")

  defp basis(map) do
    with :ok <- Json.members(map, ~w(source_sha256 decisions_sha256), [], "result basis"),
         {:ok, source} <- Json.optional_sha256(map["source_sha256"], "basis source_sha256"),
         {:ok, decisions} <-
           Json.optional_sha256(map["decisions_sha256"], "basis decisions_sha256") do
      {:ok, %{source_sha256: source, decisions_sha256: decisions}}
    end
  end

  defp subject_build(nil), do: {:ok, nil}

  defp subject_build(map) do
    keys = ~w(git_sha generated_manifest_sha256)

    with :ok <- Json.members(map, keys, ~w(git_sha), "result subject_build"),
         {:ok, git} <- git_sha(map["git_sha"]),
         {:ok, manifest} <-
           Json.optional_sha256(map["generated_manifest_sha256"], "generated_manifest_sha256") do
      {:ok, %{git_sha: git, generated_manifest_sha256: manifest}}
    end
  end

  defp git_sha(sha) when is_binary(sha) do
    if sha =~ ~r/\A[0-9a-f]{7,64}\z/,
      do: {:ok, sha},
      else: Json.error("subject_build git_sha must be a hex commit ID", %{value: sha})
  end

  defp git_sha(sha),
    do: Json.error("subject_build git_sha must be a hex commit ID", %{value: sha})

  defp diff_entry(map) do
    with :ok <- Json.members(map, @diff_members, ~w(op), "diff entry"),
         {:ok, op} <- Json.string(map["op"], "diff op"),
         :ok <- known_diff_op(op) do
      {:ok, Map.new(map, fn {k, v} -> {Map.fetch!(@diff_atoms, k), v} end)}
    end
  end

  defp known_diff_op(op) do
    if op in @diff_ops,
      do: :ok,
      else: Json.error("unknown diff op", %{op: op, allowed: @diff_ops})
  end

  defp evidence(map) do
    with :ok <- Json.members(map, ~w(kind ref sha256), ~w(kind ref), "evidence"),
         {:ok, kind} <- Json.enum(map["kind"], @evidence, "evidence kind"),
         {:ok, ref} <- evidence_ref(map["ref"]),
         {:ok, sha} <- Json.optional_sha256(map["sha256"], "evidence sha256") do
      {:ok, %{kind: kind, ref: ref, sha256: sha}}
    end
  end

  # A repository-relative path or an artifact ID: never absolute, never
  # outside the repository, never a URL (which could carry a token).
  defp evidence_ref(ref) when is_binary(ref) and ref != "" do
    cond do
      String.starts_with?(ref, ["/", "~"]) or ref =~ ~r/\A[A-Za-z]:/ or ref =~ ~r/:\/\// ->
        Json.error("evidence ref must be repository-relative or an artifact ID", %{ref: ref})

      ".." in String.split(ref, ["/", "\\"]) ->
        Json.error("evidence ref must stay inside the repository", %{ref: ref})

      true ->
        {:ok, ref}
    end
  end

  defp evidence_ref(ref), do: Json.error("evidence ref must be a non-empty string", %{ref: ref})

  defp decision_ref(nil), do: {:ok, nil}

  defp decision_ref(map) do
    with :ok <- Json.members(map, ~w(key proposal_sha256), ~w(key), "result decision"),
         {:ok, key} <- Json.string(map["key"], "decision key"),
         {:ok, sha} <- Json.optional_sha256(map["proposal_sha256"], "decision proposal_sha256") do
      decision_kind(key, sha)
    end
  end

  defp decision_kind("finding:" <> _ = key, sha) when is_binary(sha),
    do: {:ok, %{key: key, kind: :finding, proposal_sha256: sha}}

  defp decision_kind("finding:" <> _, nil),
    do: Json.error("a finding decision reference needs the finding's proposal_sha256")

  defp decision_kind("parity_exception:" <> _ = key, nil),
    do: {:ok, %{key: key, kind: :parity_exception, proposal_sha256: nil}}

  defp decision_kind("parity_exception:" <> _, _),
    do: Json.error("a parity exception has no proposal_sha256")

  defp decision_kind(key, _),
    do: Json.error("a result cites a finding decision or a parity exception", %{key: key})

  defp waiver(nil), do: {:ok, nil}

  defp waiver(map) do
    with :ok <- Json.members(map, ~w(actor reason expires_at since), ~w(actor reason), "waiver"),
         {:ok, actor} <- waiver_actor(map["actor"]),
         {:ok, reason} <- Json.string(map["reason"], "waiver reason"),
         {:ok, expires} <- Json.optional_timestamp(map["expires_at"], "waiver expires_at"),
         {:ok, since} <- Json.optional_timestamp(map["since"], "waiver since") do
      {:ok, %{actor: actor, reason: reason, expires_at: expires, since: since}}
    end
  end

  # An owner never waives by declaration: the owner's acceptance is a
  # parity exception decision, whose author the decision store records.
  defp waiver_actor(%{"kind" => "owner"}),
    do:
      Json.error(
        "an owner accepts a difference through a parity exception decision, not a waiver"
      )

  defp waiver_actor(map) do
    with :ok <- Json.members(map, ~w(kind id), ~w(kind id), "waiver actor"),
         {:ok, kind} <- Json.enum(map["kind"], @actors, "waiver actor kind"),
         {:ok, id} <- Json.string(map["id"], "waiver actor id") do
      {:ok, %{kind: kind, id: id}}
    end
  end

  defp stale(reasons) do
    with {:ok, list} <- Json.string_set(reasons, "stale_reasons") do
      Json.list(list, "stale_reasons", &Json.enum(&1, @stale_reasons, "stale reason"))
    end
  end

  # --- status rules -------------------------------------------------------------

  defp status_rules(%__MODULE__{} = r) do
    with :ok <- stale_rule(r),
         :ok <- since_rule(r),
         :ok <- status_rule(r.status, r) do
      evidence_rule(r)
    end
  end

  defp since_rule(%{waiver: %{since: since}, status: status})
       when since != nil and status not in [:quarantined, :stale],
       do: Json.error("only a quarantine has since")

  defp since_rule(_), do: :ok

  defp stale_rule(%{status: :stale, stale_reasons: []}),
    do: Json.error("a stale result needs stale_reasons")

  defp stale_rule(%{status: :stale}), do: :ok
  defp stale_rule(%{stale_reasons: []}), do: :ok
  defp stale_rule(_), do: Json.error("only stale results have stale_reasons")

  defp status_rule(:pass, r) do
    with :ok <- none(r, [:decision, :waiver]) do
      if r.diff == [], do: :ok, else: Json.error("a passing result has no diff")
    end
  end

  defp status_rule(:fail, r), do: none(r, [:decision, :waiver])

  defp status_rule(:decided_difference, r) do
    with :ok <- none(r, [:waiver]),
         :ok <- differs(r) do
      cond do
        not Check.decidable?(r.class) ->
          no_acceptance(r)

        match?(%{kind: :finding}, r.decision) ->
          :ok

        true ->
          Json.error("a decided difference cites a finding decision (key and proposal_sha256)", %{
            decision: r.decision
          })
      end
    end
  end

  defp status_rule(:waived, r) do
    with :ok <- differs(r), do: waived(r)
  end

  defp status_rule(:quarantined, r) do
    with :ok <- none(r, [:decision]),
         :ok <- differs(r),
         :ok <- actor_allowed(r, Check.quarantiners(r.class), "quarantine") do
      quarantine_window(r)
    end
  end

  defp status_rule(:stale, _r), do: :ok

  defp status_rule(status, r) when status in [:skipped, :error] do
    with :ok <- none(r, [:decision, :waiver]) do
      if r.reason, do: :ok, else: Json.error("a #{status} result needs a reason")
    end
  end

  defp waived(%{decision: %{kind: :parity_exception}} = r) do
    cond do
      not Check.parity_exception?(r.class) -> no_acceptance(r)
      r.waiver != nil -> Json.error("a parity exception is the waiver; give no waiver as well")
      true -> :ok
    end
  end

  defp waived(%{decision: %{kind: :finding}}),
    do: Json.error("a finding decision makes a decided_difference, not a waiver")

  defp waived(%{waiver: nil} = r) do
    if Check.parity_exception?(r.class),
      do: Json.error("a waived #{r.class} result needs a parity exception or a waiver"),
      else: no_acceptance(r)
  end

  defp waived(r), do: actor_allowed(r, Check.waivers(r.class), "waive")

  defp actor_allowed(%{waiver: nil} = r, _allowed, verb),
    do: Json.error("to #{verb} a result needs a waiver (actor and reason)", %{check: r.check})

  defp actor_allowed(r, allowed, verb) do
    cond do
      allowed == [] ->
        no_acceptance(r)

      r.waiver.actor.kind in allowed ->
        :ok

      true ->
        Json.error("a #{r.waiver.actor.kind} may not #{verb} a #{r.class} check", %{
          allowed: allowed
        })
    end
  end

  defp no_acceptance(%{class: class}) when class in [:privacy, :data, :auth],
    do: Json.error("#{class} differences are accepted only through an owner parity exception")

  defp no_acceptance(%{class: class, status: status}),
    do: Json.error("a #{class} check cannot be #{status}", %{class: class})

  defp quarantine_window(%{waiver: %{expires_at: nil}}),
    do: Json.error("a quarantine needs expires_at")

  defp quarantine_window(%{waiver: %{since: nil}}),
    do: Json.error("a quarantine needs since (when the scenario was first quarantined)")

  # `since` is the first quarantine: renewing never extends past 7 days
  # from it.
  defp quarantine_window(%{waiver: %{expires_at: expires, since: since}, ran_at: ran_at}) do
    limit = DateTime.add(since, @quarantine_days * 86_400, :second)

    cond do
      DateTime.compare(since, ran_at) == :gt ->
        Json.error("a quarantine's since is before ran_at", %{since: since})

      DateTime.compare(expires, ran_at) == :gt and DateTime.compare(expires, limit) != :gt ->
        :ok

      true ->
        Json.error(
          "a quarantine expires after ran_at and within #{@quarantine_days} days of its first quarantine",
          %{expires_at: expires, since: since}
        )
    end
  end

  defp none(r, members) do
    case Enum.filter(members, &(Map.fetch!(r, &1) != nil)) do
      [] -> :ok
      present -> Json.error("a #{r.status} result has no #{Enum.join(present, " or ")}")
    end
  end

  defp differs(%{diff: []} = r), do: Json.error("a #{r.status} result needs the diff it accepts")
  defp differs(_), do: :ok

  # Behavioural results need what they were compared against, and a
  # reviewer's visual waiver needs the attestation.
  defp evidence_rule(r) do
    with :ok <- compared_rule(r), do: attestation_rule(r)
  end

  defp compared_rule(%{level: level, status: status} = r)
       when level in [:l2, :l3] and status not in [:stale, :skipped, :error] do
    if is_nil(r.scenario) or is_nil(r.oracle),
      do: Json.error("an #{Check.level_json(level)} result needs its scenario and oracle"),
      else: :ok
  end

  defp compared_rule(_r), do: :ok

  defp attestation_rule(%{class: :visual, waiver: %{actor: %{kind: :reviewer}}} = r) do
    if Enum.any?(r.evidence, &(&1.kind == :attestation and &1.sha256 != nil)),
      do: :ok,
      else:
        Json.error(
          "a reviewer's visual waiver needs an attestation (with its sha256) in evidence"
        )
  end

  defp attestation_rule(_r), do: :ok

  # --- encoding -----------------------------------------------------------------

  @doc "JSON form."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = r) do
    %{
      "format" => @format,
      "schema_version" => @schema_version,
      "id" => r.id,
      "check" => r.check,
      "level" => r.level && Check.level_json(r.level),
      "class" => Json.json(r.class),
      "status" => Json.json(r.status),
      "subjects" => Json.json(r.subjects),
      "tasks" => Enum.sort(r.tasks),
      "scenario" => Json.json(r.scenario),
      "oracle" => Json.json(r.oracle),
      "basis" => Json.json(r.basis),
      "subject_build" => Json.json(r.subject_build),
      "diff" => Json.json(r.diff),
      "evidence" => r.evidence |> Enum.sort_by(&{&1.kind, &1.ref}) |> Json.json(),
      "decision" =>
        r.decision && %{"key" => r.decision.key, "proposal_sha256" => r.decision.proposal_sha256},
      "waiver" => Json.json(r.waiver),
      "reason" => r.reason,
      "stale_reasons" => r.stale_reasons |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
      "actor" => r.actor,
      "ran_at" => Json.json(r.ran_at)
    }
  end

  @doc "Canonical JSON text."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = r), do: r |> to_map() |> Json.encode()

  @doc "Decodes JSON text (see `from_map/1`)."
  @spec from_json(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_json(text), do: Json.from_json(text, "result", &from_map/1)

  @doc "SHA-256 of the canonical JSON."
  @spec sha256(t()) :: String.t()
  def sha256(%__MODULE__{} = r), do: r |> to_map() |> CanonicalJson.sha256()

  # --- reading results ------------------------------------------------------------

  @typedoc "What `evaluate/3` concludes about a result."
  @type verdict :: %{result: t(), passing: boolean(), bubble_verified: boolean()}

  @doc """
  Evaluates a decoded result against the current decisions. This is the
  only way to learn whether a result counts: decoding checks a result's
  shape and status rules, but a `waived` or `decided_difference` result
  only counts once its decision is checked against the decision store, and
  a reviewer's waiver only once the reviewer is known.

  `resolved` is `BubbleEx.Decision.resolve/3` output. Options:

    * `:now` (required) - a `ran_at` more than `:skew_seconds` (default
      300) after it is `:invalid_input`
    * `:reviewers` - IDs of the acceptance reviewers the caller trusts
      (default `[]`). A reviewer's waiver whose actor ID is not listed does
      not count: waiver actors are self-declared
    * `:findings`, `:scenario` - passed to `link_decision/3` (relevance)
    * `:recording` - the recording the oracle cites (`check_recording/2`).
      Without it a `bubble` oracle is not trusted, so the result is not
      Bubble-verified

  Returns the result after `link_decision/3` (possibly `stale`) and:

    * `passing` - `pass`, `decided_difference` or `waived` (a reviewer
      waiver only from a trusted reviewer), and `skipped` outside the
      privacy, data and auth classes
    * `bubble_verified` - passing and, for privacy, data, auth, behaviour
      and visual checks at any level, compared against a `bubble` oracle
      whose recording was given and matches, or an `export` oracle (L4
      data). A `model` oracle (the interpreter) never counts (decision D2)
  """
  @spec evaluate(t(), Resolved.t(), keyword()) :: {:ok, verdict()} | {:error, Error.t()}
  def evaluate(%__MODULE__{} = r, %Resolved{} = resolved, opts) do
    with :ok <- not_future(r, opts),
         {:ok, linked} <- link_decision(r, resolved, opts),
         :ok <- maybe_recording(linked, opts[:recording]) do
      passing = counts?(linked, Keyword.get(opts, :reviewers, []))

      {:ok,
       %{
         result: linked,
         passing: passing,
         bubble_verified: passing and oracle_verified?(linked, opts[:recording])
       }}
    end
  end

  @doc "`evaluate/3`'s `passing`; `false` when the result does not evaluate."
  @spec passing?(t(), Resolved.t(), keyword()) :: boolean()
  def passing?(r, resolved, opts),
    do: match?({:ok, %{passing: true}}, evaluate(r, resolved, opts))

  @doc "`evaluate/3`'s `bubble_verified`; `false` when the result does not evaluate."
  @spec bubble_verified?(t(), Resolved.t(), keyword()) :: boolean()
  def bubble_verified?(r, resolved, opts),
    do: match?({:ok, %{bubble_verified: true}}, evaluate(r, resolved, opts))

  defp not_future(r, opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now ->
        limit = DateTime.add(now, Keyword.get(opts, :skew_seconds, 300), :second)

        if DateTime.compare(r.ran_at, limit) == :gt,
          do: Json.error("result ran_at is in the future", %{ran_at: r.ran_at, now: now}),
          else: :ok

      _ ->
        Json.error("evaluate needs now: %DateTime{}")
    end
  end

  defp maybe_recording(_r, nil), do: :ok
  defp maybe_recording(r, recording), do: check_recording(r, recording)

  defp counts?(%{status: status}, _) when status in [:pass, :decided_difference], do: true

  defp counts?(%{status: :waived, waiver: %{actor: %{kind: :reviewer, id: id}}}, reviewers),
    do: id in reviewers

  defp counts?(%{status: :waived}, _), do: true
  defp counts?(%{status: :skipped, class: class}, _), do: class not in [:privacy, :data, :auth]
  defp counts?(_, _), do: false

  @oracle_classes [:privacy, :data, :auth, :behavior, :visual]

  defp oracle_verified?(%{class: class, oracle: oracle}, recording)
       when class in @oracle_classes do
    case oracle do
      %{kind: :bubble} -> recording != nil
      %{kind: :export} -> class in [:data, :auth, :privacy]
      _ -> false
    end
  end

  defp oracle_verified?(%{oracle: %{kind: :model}}, _), do: false
  defp oracle_verified?(_, _), do: true

  @doc """
  Checks that the result's oracle is `recording`: same SHA-256, same kind
  (`bubble` / `model`), same branch, and the same scenario.
  """
  @spec check_recording(t(), Recording.t()) :: :ok | {:error, Error.t()}
  def check_recording(%__MODULE__{oracle: oracle} = r, %Recording{} = rec) do
    branch = if rec.oracle == :bubble, do: rec.source.branch

    cond do
      oracle == nil ->
        Json.error("the result has no oracle to check")

      oracle.sha256 != Recording.sha256(rec) ->
        Json.error("the result's oracle is another recording", %{sha256: oracle.sha256})

      oracle.kind != rec.oracle ->
        Json.error("the result's oracle kind differs from its recording's", %{
          kind: oracle.kind,
          recording: rec.oracle
        })

      oracle.branch != branch ->
        Json.error("the result's oracle branch differs from its recording's", %{
          branch: oracle.branch
        })

      r.scenario == nil or r.scenario.id != rec.scenario.id ->
        Json.error("the recording is for another scenario", %{scenario: rec.scenario.id})

      true ->
        :ok
    end
  end

  @doc """
  The result turned `stale` for `reasons` (a subset of `stale_reasons/0`),
  keeping everything else as evidence. `error` and `skipped` results, and
  an empty reason list, leave it unchanged; reasons accumulate.
  """
  @spec mark_stale(t(), [atom()]) :: t()
  def mark_stale(%__MODULE__{} = r, []), do: r
  def mark_stale(%__MODULE__{status: status} = r, _) when status in [:error, :skipped], do: r

  def mark_stale(%__MODULE__{} = r, reasons) do
    unknown = reasons -- @stale_reasons

    if unknown != [],
      do: raise(ArgumentError, "unknown stale reasons: #{inspect(unknown)}")

    %{r | status: :stale, stale_reasons: Enum.sort(Enum.uniq(r.stale_reasons ++ reasons))}
  end

  @doc """
  Checks the result's `decision` against the resolved decision records
  (`BubbleEx.Decision.resolve/3`) and returns the result, turned `stale`
  when the decision no longer holds:

    * finding decisions: the current record of the key must accept or
      modify, and be **relevant**: its subject is contained in the result's
      subjects, or `opts[:scenario]` is the result's scenario (same ID and
      hash) and lists the finding in `covers.findings`. For privacy, data
      and auth checks it must also be authored by the **owner**. A
      different `proposal_sha256` is `:decision_changed`; a `:stale` or
      `:orphaned` record is `:decision_stale` / `:decision_orphaned`
    * parity exceptions: the current record must accept, be authored by the
      **owner** (an agent's parity exception excuses nothing), have a `scope`
      equal to the result's scenario ID or result ID, a subject whose every
      entry the result's subjects contain and, when the result has a
      scenario, pin it: `basis.scenario_sha256` is required, and a
      different hash is `:decision_changed`. An `:expired` or `:withdrawn`
      one is `:decision_expired` / `:decision_withdrawn`

  A key with no record, or a record that breaks these rules, is
  `:invalid_input`. A result without a decision is returned unchanged.
  Options: `:scenario` (a `BubbleEx.Verify.Scenario`), `:findings` (the
  current `BubbleEx.Finding`s; a finding listed in the scenario's covers
  must also be among them when given).
  """
  @spec link_decision(t(), Resolved.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def link_decision(result, resolved, opts \\ [])
  def link_decision(%__MODULE__{decision: nil} = r, %Resolved{}, _opts), do: {:ok, r}

  def link_decision(%__MODULE__{decision: ref} = r, %Resolved{entries: entries}, opts) do
    case Enum.find(entries, &(&1.decision.key == ref.key and &1.state != :superseded)) do
      nil -> Json.error("the result cites a decision that does not exist", %{key: ref.key})
      entry -> linked(r, ref, entry, opts)
    end
  end

  defp linked(r, %{kind: :finding} = ref, %{decision: %Decision{} = d, state: state}, opts) do
    cond do
      d.choice not in [:accept, :modify] ->
        Json.error("only an accepted or modified finding explains a difference", %{
          key: ref.key,
          choice: d.choice
        })

      r.class in [:privacy, :data, :auth] and not owner?(d) ->
        Json.error("#{r.class} differences are explained only by the owner's decisions", %{
          key: ref.key,
          author: d.author
        })

      not relevant?(r, d, opts) ->
        Json.error("the finding decision is about another subject or scenario", %{
          key: ref.key,
          subject: d.subject
        })

      d.basis[:proposal_sha256] != ref.proposal_sha256 ->
        {:ok, mark_stale(r, [:decision_changed])}

      true ->
        {:ok, mark_stale(r, state_reasons(state))}
    end
  end

  defp linked(r, %{kind: :parity_exception}, %{state: :withdrawn}, _),
    do: {:ok, mark_stale(r, [:decision_withdrawn])}

  defp linked(r, %{kind: :parity_exception} = ref, %{decision: %Decision{} = d, state: state}, _) do
    with :ok <- parity_owner(ref, d),
         :ok <- parity_covers(r, d),
         :ok <- parity_pins(r, ref, d) do
      if r.scenario != nil and d.basis.scenario_sha256 != r.scenario.sha256,
        do: {:ok, mark_stale(r, [:decision_changed])},
        else: {:ok, mark_stale(r, state_reasons(state))}
    end
  end

  defp parity_owner(ref, d) do
    if owner?(d),
      do: :ok,
      else:
        Json.error("only an owner's parity exception excuses a difference", %{
          key: ref.key,
          author: d.author
        })
  end

  defp parity_covers(r, d) do
    cond do
      d.params.scope not in [r.id, r.scenario && r.scenario.id] ->
        Json.error("the parity exception's scope is another scenario or check", %{
          scope: d.params.scope,
          result: r.id
        })

      not within?(d.subject, r.subjects) ->
        Json.error("the parity exception is about another subject", %{subject: d.subject})

      true ->
        :ok
    end
  end

  defp parity_pins(%{scenario: nil}, _ref, _d), do: :ok

  defp parity_pins(_r, ref, d) do
    if d.basis[:scenario_sha256],
      do: :ok,
      else:
        Json.error("a parity exception on a scenario must pin basis.scenario_sha256", %{
          key: ref.key
        })
  end

  defp owner?(%Decision{author: author}), do: match?(%{kind: :owner}, author)

  defp within?(subject, subjects),
    do: map_size(subject) > 0 and Enum.all?(subject, fn {k, v} -> Map.get(subjects, k) == v end)

  defp relevant?(r, d, opts) do
    within?(d.subject, r.subjects) or covered?(r, d, opts[:scenario], opts[:findings])
  end

  defp covered?(%{scenario: %{id: id, sha256: sha}}, d, %Scenario{id: id} = s, findings) do
    finding_id = d.basis[:finding_id]

    Scenario.sha256(s) == sha and finding_id in s.covers.findings and
      (findings == nil or Enum.any?(findings, &match?(%Finding{id: ^finding_id}, &1)))
  end

  defp covered?(_r, _d, _scenario, _findings), do: false

  defp state_reasons(:active), do: []
  defp state_reasons(:stale), do: [:decision_stale]
  defp state_reasons(:orphaned), do: [:decision_orphaned]
  defp state_reasons(:expired), do: [:decision_expired]
  defp state_reasons(:withdrawn), do: [:decision_withdrawn]
  defp state_reasons(_other), do: [:decision_stale]
end
