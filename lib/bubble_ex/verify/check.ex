defmodule BubbleEx.Verify.Check do
  @moduledoc """
  The registry of verification checks (WTF-358 §2, §3, §4): each check has
  a level and a class, and the class decides who may accept a difference
  (§5.4, decision D4 on WTF-358). A result names its check; its level and
  class come from here, so a result cannot relabel a privacy check to make
  it waivable.

  | class | checks | accepted differences |
  |-------|--------|----------------------|
  | `structural` (L0) | `generated_unchanged`, `deterministic`, `compiles`, `lint`, `boundary`, `migrations_in_sync`, `symbol_coverage`, `policy_coverage`, `bypass_inventory`, `secrets_absent` | none: fix it, or change the generator or a decision |
  | `traceability` (L1) | `traceability.source`, `traceability.rendered` | a finding decision (`decided_difference`) only |
  | `attested` (L1) | `acceptance` | finding decision; parity exception; waiver by an agent or reviewer with a reason |
  | `privacy` (L2, L4) | `privacy_read`, `privacy_spot_check` | the owner's finding decision or parity exception only, **never a waiver or quarantine** |
  | `data` (L4) | `row_counts`, `row_hashes`, `dangling_refs`, `files` | as `privacy` |
  | `auth` (L4) | `auth_users` | as `privacy` |
  | `behavior` (L2, L3) | `workflow_side_effects`, `api_workflow`, `dom_text`, `journey` | finding decision; parity exception; waiver by a reviewer; an agent may only quarantine (at most 7 days from the first quarantine) |
  | `visual` (L2) | `visual_parity` | finding decision; parity exception; waiver by a reviewer with an attestation |

  The owner accepts only through decisions (the decision store records the
  author); a waiver's actor is self-declared, so a result never carries an
  owner waiver, and a reviewer's waiver counts only for reviewers the caller
  trusts (`BubbleEx.Verify.Result.evaluate/3`).
  | `gate` (L5) | `cutover_gate` | none: the owner's sign-off is the gate |
  """

  alias BubbleEx.Verify.Json

  @checks %{
    "generated_unchanged" => {:l0, :structural},
    "deterministic" => {:l0, :structural},
    "compiles" => {:l0, :structural},
    "lint" => {:l0, :structural},
    "boundary" => {:l0, :structural},
    "migrations_in_sync" => {:l0, :structural},
    "symbol_coverage" => {:l0, :structural},
    "policy_coverage" => {:l0, :structural},
    "bypass_inventory" => {:l0, :structural},
    "secrets_absent" => {:l0, :structural},
    "traceability.source" => {:l1, :traceability},
    "traceability.rendered" => {:l1, :traceability},
    "acceptance" => {:l1, :attested},
    "privacy_read" => {:l2, :privacy},
    "workflow_side_effects" => {:l2, :behavior},
    "api_workflow" => {:l2, :behavior},
    "dom_text" => {:l2, :behavior},
    "visual_parity" => {:l2, :visual},
    "journey" => {:l3, :behavior},
    "row_counts" => {:l4, :data},
    "row_hashes" => {:l4, :data},
    "dangling_refs" => {:l4, :data},
    "files" => {:l4, :data},
    "auth_users" => {:l4, :auth},
    "privacy_spot_check" => {:l4, :privacy},
    "cutover_gate" => {:l5, :gate}
  }

  # Who may waive (status `waived` with a `waiver`), per class.
  # Owners never appear: an owner accepts through a parity exception.
  @waivers %{
    attested: [:agent, :reviewer],
    behavior: [:reviewer],
    visual: [:reviewer]
  }
  # Who may quarantine, per class.
  @quarantines %{behavior: [:agent, :reviewer]}
  # Classes a parity exception can excuse (status `waived` citing it).
  @parity [:attested, :privacy, :data, :auth, :behavior, :visual]
  # Classes a finding decision can explain (status `decided_difference`).
  @decided [:traceability, :attested, :privacy, :data, :auth, :behavior, :visual]

  # Which finding kinds can explain which differences: the checks and the
  # diff ops an accepted finding of that kind may account for. A finding
  # outside this map (or a hint) explains nothing.
  @writes ~w(field_changed record_updated)
  @explains %{
    privacy_access_list:
      {~w(privacy_read privacy_spot_check), ~w(record_visible field_visible record_set)},
    denormalized_field:
      {~w(row_hashes workflow_side_effects api_workflow), ~w(row_hash field_value) ++ @writes},
    redundant_reverse_list:
      {~w(row_hashes workflow_side_effects api_workflow), ~w(row_hash field_value) ++ @writes},
    list_relationship:
      {~w(row_hashes dangling_refs workflow_side_effects api_workflow),
       ~w(row_hash field_value dangling_refs record_created) ++ @writes},
    id_in_text: {~w(row_hashes dangling_refs), ~w(row_hash field_value dangling_refs)},
    number_type:
      {~w(row_hashes workflow_side_effects api_workflow),
       ~w(row_hash field_value response_field) ++ @writes},
    search_index: {[], []},
    # A plugin decision changes what renders and runs; differences it causes
    # are excused by parity exceptions, not explained by the finding.
    plugin: {[], []}
  }

  for kind <- BubbleEx.Finding.Kinds.all(), not Map.has_key?(@explains, kind) do
    raise "finding kind #{inspect(kind)} has no entry in BubbleEx.Verify.Check @explains"
  end

  @subject_keys [:type, :option_set, :external_type, :field, :rule, :workflow, :page, :element]

  @type level :: :l0 | :l1 | :l2 | :l3 | :l4 | :l5
  @type class ::
          :structural
          | :traceability
          | :attested
          | :privacy
          | :data
          | :auth
          | :behavior
          | :visual
          | :gate
  @type actor :: :agent | :reviewer | :owner

  @doc "Every check name, sorted."
  @spec names() :: [String.t()]
  def names, do: @checks |> Map.keys() |> Enum.sort()

  @doc "`{level, class}` of a check, or `:invalid_input` for an unknown one."
  @spec fetch(term()) :: {:ok, {level(), class()}} | {:error, BubbleEx.Error.t()}
  def fetch(name) do
    case Map.fetch(@checks, name) do
      {:ok, entry} -> {:ok, entry}
      :error -> Json.error("unknown check", %{check: name})
    end
  end

  @doc "The actors who may waive a check of `class` with a waiver."
  @spec waivers(class()) :: [actor()]
  def waivers(class), do: Map.get(@waivers, class, [])

  @doc "The actors who may quarantine a check of `class`."
  @spec quarantiners(class()) :: [actor()]
  def quarantiners(class), do: Map.get(@quarantines, class, [])

  @doc "Whether an owner parity exception can excuse a difference in `class`."
  @spec parity_exception?(class()) :: boolean()
  def parity_exception?(class), do: class in @parity

  @doc "Whether a finding decision can explain a difference in `class`."
  @spec decidable?(class()) :: boolean()
  def decidable?(class), do: class in @decided

  @doc """
  Whether an accepted finding of `kind` can explain a difference of diff op
  `op` in `check`. The map, by finding kind:

  | finding kind | checks | diff ops |
  |--------------|--------|----------|
  | `privacy_access_list` | `privacy_read`, `privacy_spot_check` | `record_visible`, `field_visible`, `record_set` |
  | `denormalized_field`, `redundant_reverse_list` | `row_hashes`, `workflow_side_effects`, `api_workflow` | `row_hash`, `field_value`, `field_changed`, `record_updated` |
  | `list_relationship` | the same plus `dangling_refs` | the same plus `dangling_refs`, `record_created` |
  | `id_in_text` | `row_hashes`, `dangling_refs` | `row_hash`, `field_value`, `dangling_refs` |
  | `number_type` | `row_hashes`, `workflow_side_effects`, `api_workflow` | `row_hash`, `field_value`, `response_field`, `field_changed`, `record_updated` |
  | `search_index` (a hint) | none | none |
  | `plugin` | none (differences need a parity exception) | none |

  Renames are not findings and explain nothing: a rename changes names,
  not behaviour.
  """
  @spec explains?(atom(), String.t(), String.t()) :: boolean()
  def explains?(kind, check, op) do
    case Map.fetch(@explains, kind) do
      {:ok, {checks, ops}} -> check in checks and op in ops
      :error -> false
    end
  end

  @doc "The subject keys results and scenarios use (all Bubble IDs)."
  @spec subject_keys() :: [atom()]
  def subject_keys, do: @subject_keys

  @doc "Decodes a subject: an object of `subject_keys/0` to non-empty Bubble IDs."
  @spec subjects(term()) :: {:ok, %{atom() => String.t()}} | {:error, BubbleEx.Error.t()}
  def subjects(map) when is_map(map) do
    names = Map.new(@subject_keys, &{Atom.to_string(&1), &1})

    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case Map.fetch(names, k) do
        {:ok, key} when is_binary(v) and v != "" ->
          {:cont, {:ok, Map.put(acc, key, v)}}

        _ ->
          {:halt, Json.error("invalid subject entry", %{entry: {k, v}, allowed: @subject_keys})}
      end
    end)
  end

  def subjects(other), do: Json.error("subjects must be an object", %{value: other})

  @doc "`\"L0\"`…`\"L5\"`."
  @spec level_json(level()) :: String.t()
  def level_json(level), do: level |> Atom.to_string() |> String.upcase()
end
