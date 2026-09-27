defmodule BubbleEx.Workflows.Backend.Workflow do
  @moduledoc """
  A backend workflow, lowered by `BubbleEx.Workflows.Backend`.

    * `id` - its index symbol (`workflow:<bubble id>`); `bubble_id`
    * `name` - its Bubble name (`wf_name`, or a custom event's
      `event_name`), verbatim: display text, never code
    * `folder` - its backend folder's Bubble ID, or nil
    * `kind` - `:api` (an API workflow), `:custom_event` (a backend custom
      event), `:database_trigger` or `:unsupported`; `event_type` the
      Bubble event type
    * `exposed?` - exposed as a public API endpoint (`/api/1.1/wf/<name>`)
    * `auth` - who may call an exposed workflow: `:authenticated` (a user
      token or the admin token), `:none` ("can be run without
      authentication") or `:admin_only`
    * `method` - `:get` or `:post` when the workflow names one, else nil
    * `return_200_if_not_run?` - answer 200 when its condition is false
    * `ignores_privacy?` - its own "ignore privacy rules" setting (API
      workflows only): the only reason a lowering may bypass authorization
    * `inherits_privacy?` - a custom event: it runs in its caller's
      privacy context
    * `runs_ignoring_privacy?` - `BubbleEx.Index`'s over-approximation (it
      ignores privacy rules on some call path); informational
    * `invocation_modes` - from the index (`:public_http`, `:scheduled`,
      `:direct`, `:database_trigger`)
    * `parameters` - `BubbleEx.Workflows.Lowering.Param`s, in Bubble order
    * `returns` - a custom event's `BubbleEx.Workflows.Lowering.Return`s
    * `trigger_type` - a database trigger's data type key
    * `condition` - its "Only when" `BubbleEx.Workflows.Lowering.Expr`, or nil
    * `steps` - `BubbleEx.Workflows.Backend.Step`s, in Bubble order
    * `cycle` - the ID of its call cycle (`cycle:<id>+<id>`), or nil
    * `residue` - residue of the event itself (see
      `BubbleEx.Workflows.Backend`); step residue is on the steps
    * `path` - JSON pointer of the definition
  """

  @enforce_keys [:id, :bubble_id, :kind]
  defstruct [
    :id,
    :bubble_id,
    :name,
    :folder,
    :kind,
    :event_type,
    :method,
    :trigger_type,
    :condition,
    :cycle,
    :path,
    exposed?: false,
    auth: :authenticated,
    return_200_if_not_run?: false,
    ignores_privacy?: false,
    inherits_privacy?: false,
    runs_ignoring_privacy?: false,
    invocation_modes: [],
    parameters: [],
    returns: [],
    steps: [],
    residue: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          bubble_id: String.t(),
          name: String.t() | nil,
          folder: String.t() | nil,
          kind: :api | :custom_event | :database_trigger | :unsupported,
          event_type: String.t() | nil,
          exposed?: boolean(),
          auth: :authenticated | :none | :admin_only,
          method: :get | :post | nil,
          return_200_if_not_run?: boolean(),
          ignores_privacy?: boolean(),
          inherits_privacy?: boolean(),
          runs_ignoring_privacy?: boolean(),
          invocation_modes: [atom()],
          parameters: [BubbleEx.Workflows.Lowering.Param.t()],
          returns: [BubbleEx.Workflows.Lowering.Return.t()],
          trigger_type: String.t() | nil,
          condition: BubbleEx.Workflows.Lowering.Expr.t() | nil,
          steps: [BubbleEx.Workflows.Backend.Step.t()],
          cycle: String.t() | nil,
          residue: [BubbleEx.Plan.Residue.t()],
          path: String.t() | nil
        }

  @doc "Every residue entry of the workflow: its own, then its steps'."
  @spec residue(t()) :: [BubbleEx.Plan.Residue.t()]
  def residue(%__MODULE__{} = w), do: w.residue ++ Enum.flat_map(w.steps, & &1.residue)

  @doc "Whether the workflow has no residue at all."
  @spec native?(t()) :: boolean()
  def native?(%__MODULE__{} = w), do: residue(w) == []
end

defmodule BubbleEx.Workflows.Backend.Step do
  @moduledoc """
  One action of a backend workflow: `index` (1-based, Bubble order),
  `bubble_id`, `id` (its index symbol, `action:<bubble id>`), `type` (the
  Bubble action type), `op` (see `BubbleEx.Workflows.Backend`, nil when the
  type has no lowering), `condition` ("Only when"), `args` (per `op`) and
  `residue`. A step is native when `residue` is empty.
  """

  @enforce_keys [:index, :bubble_id, :id]
  defstruct [:index, :bubble_id, :id, :type, :op, :condition, :path, args: %{}, residue: []]

  @type t :: %__MODULE__{
          index: pos_integer(),
          bubble_id: String.t(),
          id: String.t(),
          type: String.t() | nil,
          op: atom() | nil,
          condition: BubbleEx.Workflows.Lowering.Expr.t() | nil,
          args: map(),
          residue: [BubbleEx.Plan.Residue.t()],
          path: String.t() | nil
        }
end
