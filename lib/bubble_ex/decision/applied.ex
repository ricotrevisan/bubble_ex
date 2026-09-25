defmodule BubbleEx.Decision.Applied do
  @moduledoc """
  One change a generator may apply, from `BubbleEx.Decision.applicable/2`.

    * `key` - the decision key (`"finding:<finding id>"`, `"rename:…"`)
    * `kind` - `:finding` or `:rename`
    * `decision_id` - the applied record's `id`; `nil` for a hint applied
      by default
    * `automatic` - true for a hint finding nobody decided, applied by
      default
    * `finding_id` - the finding's ID (finding kinds only)
    * `transform` - the finding transform to apply (after `modify`), or
      `:rename`
    * `subject` - Bubble IDs, as on the decision
    * `target` - the target stack of a rename (`"ash"`), else `nil`
    * `proposal` - the finding's proposal with the `modify` parameters
      merged in (`BubbleEx.Decision.Params.apply/2`); `%{}` for a rename
    * `params` - the decision's parameters as recorded
    * `proposal_sha256`, `basis_sha256` - the finding's current hashes
      (finding kinds only)
    * `basis` - the hashes the decision was recorded against
      (`%{proposal_sha256, basis_sha256}`); `nil` for a hint applied by
      default and for a rename. `applicable/2` only lists active decisions,
      so they equal the finding's; a generator rejects an entry where they
      differ (a stale decision)

  ## Input contract of a generator

  A list of these, exactly as `BubbleEx.Decision.applicable/2` returns
  them, is what a target generator (`BubbleEx.Target.Ash.map/3`) takes.
  Raw `BubbleEx.Decision` records are not generation input: they must be
  resolved first, so stale, orphaned and superseded ones never apply.
  """

  @type t :: %__MODULE__{
          key: String.t(),
          kind: :finding | :rename,
          decision_id: String.t() | nil,
          automatic: boolean(),
          finding_id: String.t() | nil,
          transform: atom(),
          subject: map(),
          target: String.t() | nil,
          proposal: map(),
          params: map(),
          proposal_sha256: String.t() | nil,
          basis_sha256: String.t() | nil,
          basis: %{proposal_sha256: String.t(), basis_sha256: String.t()} | nil
        }

  @enforce_keys [:key, :kind, :transform, :subject]
  defstruct [
    :key,
    :kind,
    :decision_id,
    :finding_id,
    :transform,
    :subject,
    :target,
    :proposal_sha256,
    :basis_sha256,
    :basis,
    automatic: false,
    proposal: %{},
    params: %{}
  ]
end
