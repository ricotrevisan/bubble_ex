defmodule BubbleEx.Decision.Resolved do
  @moduledoc """
  The result of `BubbleEx.Decision.resolve/3`: every decision record with
  its computed state, and the decision findings nobody has decided.

    * `entries` - one per record, sorted by key and revision:
      `%{decision: BubbleEx.Decision.t(), state: state(), reasons: [reason()]}`
    * `undecided` - IDs of `:decision` findings without a current record,
      sorted. Hint findings are never undecided: they apply by default.

  States (computed on every snapshot, never stored):

  | State | Rule |
  |-------|------|
  | `:active` | the current record of its key and still valid |
  | `:stale` | a finding decision (any choice) whose finding is present with another `proposal_sha256` or `basis_sha256`, or whose `modify` parameters no longer fit its proposal or the index |
  | `:orphaned` | a finding decision (not an acknowledgement) whose finding is absent, or a rename whose subject is gone |
  | `:acknowledged` | an `acknowledge` whose finding is absent, or present with the recorded hashes; applies nothing |
  | `:withdrawn` | a withdrawn rename or parity exception; applies nothing |
  | `:superseded` | a newer revision of the key exists |
  | `:expired` | a parity exception past `expires_at`, or whose scenario hash changed or is unknown |

  Reasons: `:proposal_changed`, `:basis_changed`, `:params_invalid` and
  `:analyzer_updated` (stale; the last one when the recorded `bubble_ex`
  version differs from the current one, so a UI can say "analyzer updated"
  rather than "Bubble changed"); `:finding_absent` with `:subject_present`
  or `:subject_gone` (orphaned, acknowledged); `:subject_gone` (orphaned
  rename); `:newer_revision` (superseded); `:expired`, `:scenario_changed`
  and `:scenario_unknown` (expired).

  ## Publication (WTF-352 D2)

  `blocking/1` is exactly what blocks publishing: current accepts and
  modifies that are `:stale`, or `:orphaned` while their subject still
  exists. The owner re-decides or acknowledges each
  (`BubbleEx.Decision.acknowledge/2`). `archived/1` is what is archived
  automatically: orphans whose subject is gone. Stale rejects and
  acknowledgements, expired parity exceptions and renames never block:
  they apply nothing, so generation stays source-faithful.
  """

  alias BubbleEx.Decision

  @type state ::
          :active | :stale | :orphaned | :acknowledged | :withdrawn | :superseded | :expired
  @type reason ::
          :proposal_changed
          | :basis_changed
          | :params_invalid
          | :analyzer_updated
          | :finding_absent
          | :subject_present
          | :subject_gone
          | :newer_revision
          | :expired
          | :scenario_changed
          | :scenario_unknown
  @type entry :: %{decision: Decision.t(), state: state(), reasons: [reason()]}
  @type t :: %__MODULE__{entries: [entry()], undecided: [String.t()]}

  defstruct entries: [], undecided: []

  @doc "The states, in lifecycle order."
  @spec states() :: [state()]
  def states, do: [:active, :stale, :orphaned, :acknowledged, :withdrawn, :superseded, :expired]

  @doc "The entries in `state`."
  @spec in_state(t(), state()) :: [entry()]
  def in_state(%__MODULE__{entries: entries}, state),
    do: Enum.filter(entries, &(&1.state == state))

  @doc """
  The entries that block publication: current finding accepts and
  modifies that are `:stale`, or `:orphaned` with `:subject_present`.
  """
  @spec blocking(t()) :: [entry()]
  def blocking(%__MODULE__{entries: entries}) do
    Enum.filter(entries, fn
      %{decision: %{kind: :finding, choice: c}, state: :stale} when c in [:accept, :modify] ->
        true

      %{decision: %{kind: :finding, choice: c}, state: :orphaned, reasons: reasons}
      when c in [:accept, :modify] ->
        :subject_present in reasons

      _ ->
        false
    end)
  end

  @doc "The orphaned entries whose subject is gone: archived automatically, never blocking."
  @spec archived(t()) :: [entry()]
  def archived(%__MODULE__{entries: entries}),
    do: Enum.filter(entries, &(&1.state == :orphaned and :subject_gone in &1.reasons))

  @doc "Counts of entries by state (every state present), plus `undecided`."
  @spec summary(t()) :: %{atom() => non_neg_integer()}
  def summary(%__MODULE__{} = resolved) do
    counts = Enum.frequencies_by(resolved.entries, & &1.state)

    states()
    |> Map.new(&{&1, Map.get(counts, &1, 0)})
    |> Map.put(:undecided, length(resolved.undecided))
  end
end
