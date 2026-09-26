defmodule BubbleEx.Plan.Task do
  @moduledoc """
  One node of a `BubbleEx.Plan`: a unit of migration work, keyed by Bubble
  IDs only.

    * `id` - stable: the kind plus the Bubble IDs it covers
      (`"surface:page/bUwyg1"`, `"workflow:bTuV"`, `"backend:bTcaH"`), never
      a display name, so it survives renames in the Bubble editor
    * `kind` - see `BubbleEx.Plan`
    * `actor` - who closes it: `:generator`, `:agent`, `:reviewer` (a
      different agent from the implementer), `:owner`, `:loader` or
      `:harness`
    * `status` - `:auto` (nothing to hand-write: closes by itself once
      generated and its criteria pass), `:open` (work for its actor) or
      `:closed` (closed by the owner decision named in `closed_by`)
    * `parent` - the parent task's ID for a subtask (a workflow under its
      surface, backend folder or cycle; an API call under its group), else nil
    * `subjects` - the index symbol IDs (or `style:<key>`) it covers
    * `label` - the Bubble name of its main subject, for people only; not
      part of any hash
    * `batch` - scheduling affinity: tasks of one batch are ordered together
    * `order` - position in the plan (dependencies first, then batch
      affinity, then kind, then ID); subtasks follow their parent
    * `depends_on` - `%{task, kind, via}` edges: `kind` is the rule (see
      `BubbleEx.Plan`), `via` the symbol IDs that justify it
    * `decisions` - keys of the effective decisions (`BubbleEx.Decision.Applied`)
      on its subjects
    * `closed_by` - the decision key that closes it (`status: :closed`)
    * `residue` - what the generator cannot lower (`BubbleEx.Plan.Residue`)
    * `criteria` - abstract checks, `%{id, check, args, waiver}`; a target
      adapter binds each `check` to a command (`BubbleEx.Plan.Criteria`)
    * `decisions_sha256` - hash of the effective decisions on its covered
      symbols (their generation inputs) and of every current decision record
      naming one, with its resolved state (`BubbleEx.Plan.build/5`
      `resolved:`); nil when there are none
    * `source_sha256` - hash of what the task covers (its subgraph): the
      semantic digest of each covered symbol (its subjects and everything
      they contain; see `BubbleEx.Plan` "Semantic hashes"), its residue,
      `decisions_sha256` and, for style tasks, the normalized named styles.
      A change means the task needs re-verifying (`BubbleEx.Plan.diff/2`)
  """

  @type actor :: :generator | :agent | :reviewer | :owner | :loader | :harness
  @type status :: :auto | :open | :closed
  @type dependency :: %{task: String.t(), kind: atom(), via: [String.t()]}
  @type criterion :: %{
          id: pos_integer(),
          check: atom(),
          args: map(),
          waiver: :forbidden | :allowed
        }

  @type t :: %__MODULE__{
          id: String.t(),
          kind: atom(),
          actor: actor(),
          status: status(),
          parent: String.t() | nil,
          subjects: [String.t()],
          label: String.t() | nil,
          batch: String.t() | nil,
          order: non_neg_integer() | nil,
          depends_on: [dependency()],
          decisions: [String.t()],
          closed_by: String.t() | nil,
          residue: [BubbleEx.Plan.Residue.t()],
          criteria: [criterion()],
          decisions_sha256: String.t() | nil,
          source_sha256: String.t() | nil
        }

  @enforce_keys [:id, :kind, :actor]
  defstruct [
    :id,
    :kind,
    :actor,
    :parent,
    :label,
    :batch,
    :order,
    :closed_by,
    :decisions_sha256,
    :source_sha256,
    status: :open,
    subjects: [],
    depends_on: [],
    decisions: [],
    residue: [],
    criteria: []
  ]
end
