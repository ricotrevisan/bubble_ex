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
  | `attested` (L1) | `acceptance` | finding decision; parity exception; waiver by an agent, reviewer or owner with a reason |
  | `privacy` (L2, L4) | `privacy_read`, `privacy_spot_check` | finding decision; parity exception (owner) only, **never a waiver or quarantine** |
  | `data` (L4) | `row_counts`, `row_hashes`, `dangling_refs`, `files` | as `privacy` |
  | `auth` (L4) | `auth_users` | as `privacy` |
  | `behavior` (L2, L3) | `workflow_side_effects`, `api_workflow`, `dom_text`, `journey` | finding decision; parity exception; waiver by a reviewer or owner; an agent may only quarantine (at most 7 days) |
  | `visual` (L2) | `visual_parity` | finding decision; parity exception; waiver by a reviewer (with an attestation) or owner |
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
  @waivers %{
    attested: [:agent, :reviewer, :owner],
    behavior: [:reviewer, :owner],
    visual: [:reviewer, :owner]
  }
  # Who may quarantine, per class.
  @quarantines %{behavior: [:agent, :reviewer, :owner]}
  # Classes a parity exception can excuse (status `waived` citing it).
  @parity [:attested, :privacy, :data, :auth, :behavior, :visual]
  # Classes a finding decision can explain (status `decided_difference`).
  @decided [:traceability, :attested, :privacy, :data, :auth, :behavior, :visual]

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
