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
      (`Result of step N`): a type descriptor, or `{:returns, returns}`
      for a "Trigger a custom event" step, whose result is the custom
      event's return values (`BubbleEx.Workflows.Lowering.Return`s), read
      by return ID (`Result of step N's <return>`)
    * `custom_events` - the declared return values of the app's custom
      events (page, reusable element and backend), by the event's Bubble
      ID; `BubbleEx.Expression.Sites.custom_events/1` builds it
    * `subject` / `path` - the diagnostic subject (Bubble IDs) and the
      expression's source path, prefixed to diagnostic pointers
    * `searches` - where the expression's searches run, which decides what
      a constraint whose value is empty does (replay, 2026-10-01):
      `:page` (a page's data source, element or workflow: the constraint
      matches nothing unless the search states
      `ignore_empty_constraints: true`, which drops it), `:backend` (a
      backend workflow: it matches nothing, whatever the search states)
      or `nil` (not known, the default: `ignore_empty_constraints` below
      decides)
    * `ignore_empty_constraints` - what a `:filtered`, or a search where
      `searches` is nil, that does not state Bubble's
      `ignore_empty_constraints` does with a constraint whose value is
      empty: `nil` (unknown, the default: such a constraint is not
      compiled), `true` (ignored) or `false` (compared). A page's
      `:filtered` (`searches: :page`) follows the page rule instead
      (replay 2026-10-07).
    * `loading_status` - what a repeating group's `is loading` is:
      `:residue` (the default: not compiled) or `:constant` (a constant
      no, for a page's visibility conditionals and shown values). In
      Bubble it stays no while a search waits and flashes yes for a few
      milliseconds after each response (replay 2026-10-19): what is shown
      cannot rely on that flash, but a workflow's trigger or condition
      ("Do when … is loading") may fire on it, so there it stays residue.

  Build it with `new/2`.
  """

  alias BubbleEx.Expression.{Ast, Tree}
  alias BubbleEx.Model
  alias BubbleEx.Workflows.Lowering.Return

  defstruct model: nil,
            schema: %{},
            tree: %Tree{},
            this_type: nil,
            this_binder: :context,
            host: nil,
            trigger_type: nil,
            steps: %{},
            custom_events: %{},
            subject: %{},
            path: [],
            searches: nil,
            ignore_empty_constraints: nil,
            loading_status: :residue

  @type t :: %__MODULE__{
          model: Model.t() | nil,
          schema: BubbleEx.Expression.Schema.t(),
          tree: Tree.t(),
          this_type: String.t() | nil,
          this_binder: Ast.ThisThing.binder(),
          host: String.t() | nil,
          trigger_type: String.t() | nil,
          steps: %{String.t() => String.t() | {:returns, [Return.t()]}},
          custom_events: %{String.t() => [Return.t()]},
          subject: BubbleEx.Diagnostic.subject(),
          path: [String.t() | integer()],
          searches: searches(),
          ignore_empty_constraints: boolean() | nil,
          loading_status: :residue | :constant
        }

  @type searches :: :page | :backend | nil

  @type option ::
          {:tree, Tree.t()}
          | {:this_type, String.t() | nil}
          | {:this_binder, Ast.ThisThing.binder()}
          | {:host, String.t() | nil}
          | {:trigger_type, String.t() | nil}
          | {:steps, map()}
          | {:custom_events, map()}
          | {:subject, map()}
          | {:path, list()}
          | {:searches, searches()}
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
