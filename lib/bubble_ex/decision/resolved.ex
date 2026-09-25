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
  | `:stale` | a finding decision whose finding is present with another `proposal_sha256` or `basis_sha256`, or whose `modify` parameters no longer fit its proposal |
  | `:orphaned` | a finding decision whose finding is absent, or a rename whose subject is gone |
  | `:superseded` | a newer revision of the key exists |
  | `:expired` | a parity exception past `expires_at`, or whose scenario hash changed |

  Reasons: `:proposal_changed`, `:basis_changed`, `:params_invalid` and
  `:analyzer_updated` (stale; the last one when the recorded `bubble_ex`
  version differs from the current one, so a UI can say "analyzer updated"
  rather than "Bubble changed"); `:finding_absent`, `:subject_present` and
  `:subject_gone` (orphaned; the subject ones only with an index);
  `:newer_revision` (superseded); `:expired` and `:scenario_changed`
  (expired).
  """

  alias BubbleEx.Decision

  @type state :: :active | :stale | :orphaned | :superseded | :expired
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
  @type entry :: %{decision: Decision.t(), state: state(), reasons: [reason()]}
  @type t :: %__MODULE__{entries: [entry()], undecided: [String.t()]}

  defstruct entries: [], undecided: []

  @doc "The states, in lifecycle order."
  @spec states() :: [state()]
  def states, do: [:active, :stale, :orphaned, :superseded, :expired]

  @doc "The entries in `state`."
  @spec in_state(t(), state()) :: [entry()]
  def in_state(%__MODULE__{entries: entries}, state),
    do: Enum.filter(entries, &(&1.state == state))

  @doc "Counts of entries by state (every state present), plus `undecided`."
  @spec summary(t()) :: %{atom() => non_neg_integer()}
  def summary(%__MODULE__{} = resolved) do
    counts = Enum.frequencies_by(resolved.entries, & &1.state)

    states()
    |> Map.new(&{&1, Map.get(counts, &1, 0)})
    |> Map.put(:undecided, length(resolved.undecided))
  end
end
