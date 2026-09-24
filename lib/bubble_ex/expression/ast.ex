defmodule BubbleEx.Expression.Ast do
  @moduledoc """
  Typed, stack-neutral nodes for Bubble expressions.

  Nodes describe Bubble semantics only — what the app says — never how a
  target stack would enforce it. Bubble evaluates an expression left to right:
  a source (`Current User`, `This Thing`, a search, …) followed by a chain of
  operators, so `Current User's workspace is This Thing's workspace` becomes
  `%Compare{left: %Field{subject: %CurrentUser{}}, right: %Field{subject:
  %ThisThing{}}}`.

  Every node carries:

    * `type` — the Bubble value type when known (`"user"`, `"custom.task"`,
      `"list.custom.task"`, `"option.status"`, `"text"`, …), otherwise nil.
    * `meta` — source-form details (key spelling, editor metadata such as
      `is_slidable`) needed to re-emit the original JSON. It never carries
      semantics and is excluded from the canonical form and hash.

  Anything the vocabulary does not model is kept verbatim in a `Raw` node and
  reported by a diagnostic — never dropped.
  """

  @type meta :: map()
  @type value_type :: String.t() | nil

  @type t ::
          __MODULE__.Literal.t()
          | __MODULE__.Empty.t()
          | __MODULE__.CurrentUser.t()
          | __MODULE__.ThisThing.t()
          | __MODULE__.Scope.t()
          | __MODULE__.OptionValue.t()
          | __MODULE__.AllOptions.t()
          | __MODULE__.DynamicText.t()
          | __MODULE__.ArbitraryText.t()
          | __MODULE__.Search.t()
          | __MODULE__.Field.t()
          | __MODULE__.Property.t()
          | __MODULE__.Compare.t()
          | __MODULE__.Logical.t()
          | __MODULE__.Check.t()
          | __MODULE__.Arithmetic.t()
          | __MODULE__.ListOp.t()
          | __MODULE__.Filter.t()
          | __MODULE__.Fallback.t()
          | __MODULE__.Raw.t()

  @node_modules Enum.map(
                  ~w(Literal Empty CurrentUser ThisThing Scope OptionValue AllOptions DynamicText
                     ArbitraryText Search Field Property Compare Logical Check Arithmetic ListOp
                     Filter Fallback Raw),
                  &Module.concat(__MODULE__, &1)
                )

  @doc "True when `term` is one of the AST node structs."
  @spec node?(term()) :: boolean()
  def node?(%module{}), do: module in @node_modules
  def node?(_), do: false

  defmodule Literal do
    @moduledoc "A JSON literal operand: text, number, boolean or null."
    defstruct [:value, type: nil, meta: %{}]
    @type t :: %__MODULE__{value: term(), type: String.t() | nil, meta: map()}
  end

  defmodule Empty do
    @moduledoc "Bubble's explicit empty value."
    defstruct type: nil, meta: %{}
    @type t :: %__MODULE__{type: nil, meta: map()}
  end

  defmodule CurrentUser do
    @moduledoc "The user of the current session (logged in or not)."
    defstruct type: "user", meta: %{}
    @type t :: %__MODULE__{type: String.t(), meta: map()}
  end

  defmodule ThisThing do
    @moduledoc """
    The record being evaluated: `This <Type>` in a privacy rule, or the item
    under test in a search/filter constraint (Bubble's `InjectedValue`).
    """
    defstruct type: nil, meta: %{}
    @type t :: %__MODULE__{type: String.t() | nil, meta: map()}
  end

  defmodule Scope do
    @moduledoc """
    A value supplied by page, element, workflow or API context (page thing,
    workflow parameter, element, previous step, URL parameter, …). `ref` keeps
    the identifying properties verbatim; they are not interpreted further.
    """
    defstruct [:kind, :source_type, ref: %{}, type: nil, meta: %{}]

    @type t :: %__MODULE__{
            kind: atom(),
            source_type: String.t(),
            ref: map(),
            type: String.t() | nil,
            meta: map()
          }
  end

  defmodule OptionValue do
    @moduledoc "A single option of an option set."
    defstruct [:option_set, :value, type: nil, meta: %{}]

    @type t :: %__MODULE__{
            option_set: String.t(),
            value: String.t(),
            type: String.t() | nil,
            meta: map()
          }
  end

  defmodule AllOptions do
    @moduledoc "Every option of an option set."
    defstruct [:option_set, type: nil, meta: %{}]
    @type t :: %__MODULE__{option_set: String.t(), type: String.t() | nil, meta: map()}
  end

  defmodule DynamicText do
    @moduledoc "Text assembled from static strings and expressions, in order."
    defstruct parts: [], type: "text", meta: %{}

    @type t :: %__MODULE__{
            parts: [String.t() | BubbleEx.Expression.Ast.t()],
            type: String.t(),
            meta: map()
          }
  end

  defmodule ArbitraryText do
    @moduledoc "Bubble's `Arbitrary text` source wrapping dynamic text."
    defstruct [:text, type: "text", meta: %{}]
    @type t :: %__MODULE__{text: BubbleEx.Expression.Ast.t(), type: String.t(), meta: map()}
  end

  defmodule Constraint do
    @moduledoc """
    One search or filter constraint: `key` (a field ID, or
    `_advanced_search_constraint`), comparison `op` (nil when Bubble stores no
    operator) and the `value` expression.
    """
    defstruct [:key, :op, :value, meta: %{}]

    @type t :: %__MODULE__{
            key: String.t(),
            op: atom() | String.t() | nil,
            value: BubbleEx.Expression.Ast.t() | nil,
            meta: map()
          }
  end

  defmodule Search do
    @moduledoc """
    `Do a search for` a data type. `options` holds non-constraint settings
    (sort field, direction, ignore-empty) verbatim.
    """
    defstruct [:data_type, constraints: [], options: %{}, type: nil, meta: %{}]

    @type t :: %__MODULE__{
            data_type: String.t() | nil,
            constraints: [BubbleEx.Expression.Ast.Constraint.t()],
            options: map(),
            type: String.t() | nil,
            meta: map()
          }
  end

  defmodule Field do
    @moduledoc """
    `subject's field`. `field` is the Bubble field ID; `builtin` names Bubble's
    built-in fields (`:created_by`, `:created_date`, `:modified_date`, `:slug`,
    `:unique_id`). `display` is the field caption when the schema supplies it.
    """
    defstruct [:subject, :field, builtin: nil, display: nil, type: nil, meta: %{}]

    @type t :: %__MODULE__{
            subject: BubbleEx.Expression.Ast.t(),
            field: String.t(),
            builtin: atom() | nil,
            display: String.t() | nil,
            type: String.t() | nil,
            meta: map()
          }
  end

  defmodule Property do
    @moduledoc """
    `subject's name` where `name` is not a known field of the subject's type:
    element and plugin states, API response fields, or fields on a subject of
    unknown type. Structured, but always reported by a diagnostic.
    """
    defstruct [:subject, :name, type: nil, meta: %{}]

    @type t :: %__MODULE__{
            subject: BubbleEx.Expression.Ast.t(),
            name: String.t(),
            type: nil,
            meta: map()
          }
  end

  defmodule Compare do
    @moduledoc "Comparison: `:equals`, `:not_equals`, `:greater_than`, `:less_than`, `:greater_or_equal`, `:less_or_equal`."
    defstruct [:op, :left, :right, type: "boolean", meta: %{}]

    @type t :: %__MODULE__{
            op: atom(),
            left: BubbleEx.Expression.Ast.t(),
            right: BubbleEx.Expression.Ast.t(),
            type: String.t(),
            meta: map()
          }
  end

  defmodule Logical do
    @moduledoc "`:and` / `:or`. Bubble groups strictly left to right."
    defstruct [:op, :left, :right, type: "boolean", meta: %{}]

    @type t :: %__MODULE__{
            op: :and | :or,
            left: BubbleEx.Expression.Ast.t(),
            right: BubbleEx.Expression.Ast.t(),
            type: String.t(),
            meta: map()
          }
  end

  defmodule Check do
    @moduledoc "Unary predicate: `:is_empty`, `:is_not_empty`, `:is_true`, `:is_false`, `:logged_in`, `:logged_out`."
    defstruct [:op, :subject, type: "boolean", meta: %{}]

    @type t :: %__MODULE__{
            op: atom(),
            subject: BubbleEx.Expression.Ast.t(),
            type: String.t(),
            meta: map()
          }
  end

  defmodule Arithmetic do
    @moduledoc "`:plus`, `:minus`, `:times`, `:divided_by`, `:modulo`."
    defstruct [:op, :left, :right, type: nil, meta: %{}]

    @type t :: %__MODULE__{
            op: atom(),
            left: BubbleEx.Expression.Ast.t(),
            right: BubbleEx.Expression.Ast.t(),
            type: String.t() | nil,
            meta: map()
          }
  end

  defmodule ListOp do
    @moduledoc """
    A list operator applied to `subject`: `:count`, `:first_item`,
    `:last_item`, `:unique`, `:as_list`, `:contains`, `:not_contains`,
    `:contains_list`, `:is_contained_by`, `:is_not_contained_by`,
    `:item_number`, `:limit_to`, `:merged_with`, `:minus_list`,
    `:intersect_with`, `:plus_item`, `:minus_item`, `:sorted`. `arg` is the
    operand expression where the operator takes one; `options` holds sort
    settings verbatim.
    """
    defstruct [:op, :subject, arg: nil, options: %{}, type: nil, meta: %{}]

    @type t :: %__MODULE__{
            op: atom(),
            subject: BubbleEx.Expression.Ast.t(),
            arg: BubbleEx.Expression.Ast.t() | nil,
            options: map(),
            type: String.t() | nil,
            meta: map()
          }
  end

  defmodule Filter do
    @moduledoc "`subject:filtered` by constraints; `options` holds sort settings verbatim."
    defstruct [:subject, constraints: [], options: %{}, type: nil, meta: %{}]

    @type t :: %__MODULE__{
            subject: BubbleEx.Expression.Ast.t(),
            constraints: [BubbleEx.Expression.Ast.Constraint.t()],
            options: map(),
            type: String.t() | nil,
            meta: map()
          }
  end

  defmodule Fallback do
    @moduledoc "`subject defaulting to fallback`."
    defstruct [:subject, :fallback, type: nil, meta: %{}]

    @type t :: %__MODULE__{
            subject: BubbleEx.Expression.Ast.t(),
            fallback: BubbleEx.Expression.Ast.t(),
            type: String.t() | nil,
            meta: map()
          }
  end

  defmodule Raw do
    @moduledoc """
    Unmodeled Bubble JSON, preserved verbatim. For an unknown operator,
    `subject` is the structured expression it applies to and `raw` is the
    operator object without its `next` link; for an unknown source `subject`
    is nil. `reason` matches the diagnostic code reported for it.
    """
    defstruct [:raw, :reason, subject: nil, type: nil, meta: %{}]

    @type t :: %__MODULE__{
            raw: term(),
            reason: atom(),
            subject: BubbleEx.Expression.Ast.t() | nil,
            type: nil,
            meta: map()
          }
  end
end
