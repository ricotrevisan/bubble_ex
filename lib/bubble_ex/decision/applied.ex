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
          params: map()
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
    automatic: false,
    proposal: %{},
    params: %{}
  ]
end
