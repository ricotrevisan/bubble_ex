defmodule BubbleEx.Expression.Env do
  @moduledoc """
  What typing and compiling one expression needs to know about where it
  sits (`BubbleEx.Expression.Typing`, `BubbleEx.Expression.Compiler`).

    * `model` - the app's `BubbleEx.Model` (field, option-set and external
      type lookups); `schema` is its `BubbleEx.Model.schema/1`
    * `tree` - the app's `BubbleEx.Expression.Tree` (element, page and
      reusable context)
    * `this_type` / `this_binder` - the type of `This Thing` and which
      record it is (see `BubbleEx.Expression.Ast.ThisThing`); a privacy
      rule's condition has `:rule_record`
    * `host` - the Bubble ID of the element, page or reusable whose property
      holds the expression (`This element`, `Parent group`, the current
      cell), or nil
    * `trigger_type` - in a database-trigger workflow, the type of the
      record it fired for (`Thing now` / `Thing before change`)
    * `steps` - result types of the workflow's steps by action Bubble ID
      (`Result of step N`)
    * `subject` / `path` - the diagnostic subject (Bubble IDs) and the
      expression's source path, prefixed to diagnostic pointers
    * `ignore_empty_constraints` - what a search or `:filtered` that does
      not state Bubble's `ignore_empty_constraints` does with a constraint
      whose value is empty: `nil` (unknown, the default: such a constraint
      is not compiled), `true` (ignored) or `false` (compared). Most
      searches do not state it and Bubble's default is not verified.

  Build it with `new/2`.
  """

  alias BubbleEx.Expression.{Ast, Tree}
  alias BubbleEx.Model

  defstruct model: nil,
            schema: %{},
            tree: %Tree{},
            this_type: nil,
            this_binder: :context,
            host: nil,
            trigger_type: nil,
            steps: %{},
            subject: %{},
            path: [],
            ignore_empty_constraints: nil

  @type t :: %__MODULE__{
          model: Model.t() | nil,
          schema: BubbleEx.Expression.Schema.t(),
          tree: Tree.t(),
          this_type: String.t() | nil,
          this_binder: Ast.ThisThing.binder(),
          host: String.t() | nil,
          trigger_type: String.t() | nil,
          steps: %{String.t() => String.t()},
          subject: BubbleEx.Diagnostic.subject(),
          path: [String.t() | integer()],
          ignore_empty_constraints: boolean() | nil
        }

  @type option ::
          {:tree, Tree.t()}
          | {:this_type, String.t() | nil}
          | {:this_binder, Ast.ThisThing.binder()}
          | {:host, String.t() | nil}
          | {:trigger_type, String.t() | nil}
          | {:steps, map()}
          | {:subject, map()}
          | {:path, list()}
          | {:ignore_empty_constraints, boolean() | nil}

  @doc "An environment for expressions of `model`; see the moduledoc for the options."
  @spec new(Model.t(), [option()]) :: t()
  def new(%Model{} = model, opts \\ []) do
    struct!(%__MODULE__{model: model, schema: Model.schema(model)}, opts)
  end

  @doc "A copy for the expression at `path` with diagnostic `subject`."
  @spec at(t(), list(), map()) :: t()
  def at(%__MODULE__{} = env, path, subject), do: %{env | path: path, subject: subject}
end
