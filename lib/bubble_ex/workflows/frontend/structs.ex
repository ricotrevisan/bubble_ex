defmodule BubbleEx.Workflows.Frontend.Workflow do
  @moduledoc """
  A page or reusable-element workflow, lowered by
  `BubbleEx.Workflows.Frontend`.

    * `id` - its index symbol (`workflow:<bubble id>`); `bubble_id`
    * `name` - its Bubble name, verbatim: display text, never code
    * `surface` - the page or reusable element it belongs to (`page:<id>`,
      `reusable:<id>`)
    * `kind` - the event (see `BubbleEx.Workflows.Frontend`, `:unsupported`
      without a lowering); `event_type` the Bubble event type
    * `element` - the element a `:click`, `:input_change`, `:popup_opened`
      or `:popup_closed` event listens to (its Bubble ID)
    * `condition` - "Only when" (for `:condition_true`, the condition
      itself), a `BubbleEx.Workflows.Lowering.Expr` or nil
    * `run_when` - `:every_time` or `:once` for `:condition_true`
    * `interval` - seconds between runs of `:do_every`
    * `disabled?` - disabled in the Bubble editor: never triggered
    * `parameters`, `returns` - a custom event's
      (`BubbleEx.Workflows.Lowering.Param`, `.Return`)
    * `steps` - `BubbleEx.Workflows.Frontend.Step`s, in Bubble order
    * `residue` - residue of the event itself; step residue is on the
      steps
    * `path` - JSON pointer of the definition
  """

  @enforce_keys [:id, :bubble_id, :surface, :kind]
  defstruct [
    :id,
    :bubble_id,
    :name,
    :surface,
    :kind,
    :event_type,
    :element,
    :condition,
    :run_when,
    :interval,
    :path,
    disabled?: false,
    parameters: [],
    returns: [],
    steps: [],
    residue: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          bubble_id: String.t(),
          name: String.t() | nil,
          surface: String.t(),
          kind: atom(),
          event_type: String.t() | nil,
          element: String.t() | nil,
          condition: BubbleEx.Workflows.Lowering.Expr.t() | nil,
          run_when: :every_time | :once | nil,
          interval: BubbleEx.Workflows.Lowering.Expr.t() | nil,
          disabled?: boolean(),
          parameters: [BubbleEx.Workflows.Lowering.Param.t()],
          returns: [BubbleEx.Workflows.Lowering.Return.t()],
          steps: [BubbleEx.Workflows.Frontend.Step.t()],
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

defmodule BubbleEx.Workflows.Frontend.Step do
  @moduledoc """
  One action of a page or reusable-element workflow: `index` (1-based,
  Bubble order), `bubble_id`, `id` (its index symbol, `action:<bubble
  id>`), `type` (the Bubble action type), `op` (see
  `BubbleEx.Workflows.Frontend`; nil when the type has no lowering),
  `condition` ("Only when"), `args` (per `op`) and `residue`. A step is
  native when `residue` is empty.
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
