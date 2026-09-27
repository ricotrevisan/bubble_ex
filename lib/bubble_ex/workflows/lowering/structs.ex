defmodule BubbleEx.Workflows.Lowering.Expr do
  @moduledoc """
  A value or condition of a lowered workflow: `path` (JSON pointer of its
  source) and `ir` (`BubbleEx.Expression.IR`), or nil with `constructs`
  naming what stopped it (as `BubbleEx.Plan.Residue.constructs/1`).
  """

  @enforce_keys [:path]
  defstruct [:path, :ir, constructs: []]

  @type t :: %__MODULE__{
          path: String.t(),
          ir: BubbleEx.Expression.IR.t() | nil,
          constructs: [String.t()]
        }
end

defmodule BubbleEx.Workflows.Lowering.Change do
  @moduledoc """
  One field change of a create or update step: `field` (the field's Bubble
  ID), `op` (`:set`, `:add`, `:remove`, `:add_list`, `:remove_list`,
  `:set_list` or `:clear_list`) and `value` (nil for `:clear_list`).
  """

  @enforce_keys [:field, :op]
  defstruct [:field, :op, :value]

  @type t :: %__MODULE__{
          field: String.t(),
          op: :set | :add | :remove | :add_list | :remove_list | :set_list | :clear_list,
          value: BubbleEx.Workflows.Lowering.Expr.t() | nil
        }
end

defmodule BubbleEx.Workflows.Lowering.Param do
  @moduledoc """
  A workflow parameter: `id` (what expressions reference: `param_id`, or an
  API workflow's key), `key` (the name callers pass; display text), `type`
  (the Bubble type descriptor, `list.` for lists, or nil when not
  declared), `optional?` and `in_url?`.
  """

  @enforce_keys [:id, :key]
  defstruct [:id, :key, :type, optional?: false, in_url?: false]

  @type t :: %__MODULE__{
          id: String.t(),
          key: String.t(),
          type: String.t() | nil,
          optional?: boolean(),
          in_url?: boolean()
        }
end

defmodule BubbleEx.Workflows.Lowering.Return do
  @moduledoc """
  A value a custom event returns: `id` (`return_id`), `name` (its caption,
  display text) and `type` (a Bubble type descriptor, or nil).
  """

  @enforce_keys [:id, :name]
  defstruct [:id, :name, :type]

  @type t :: %__MODULE__{id: String.t(), name: String.t(), type: String.t() | nil}
end
