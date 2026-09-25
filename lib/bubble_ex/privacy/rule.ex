defmodule BubbleEx.Privacy.Rule do
  @moduledoc """
  One privacy rule of a data type. Users matching `condition` receive
  `permissions`; the `everyone` rule (`default?: true`) has no condition and
  applies to users no other rule matches. `path` is the rule's JSON pointer in
  the supplied app JSON.

  Rules are not ordered or exclusive: a user receives the union (logical OR)
  of the permissions of every rule whose condition they match, including the
  union of their visible and auto-binding field lists.
  """

  alias BubbleEx.Diagnostic
  alias BubbleEx.Expression.Ast
  alias BubbleEx.Privacy.Permissions

  @enforce_keys [:id, :path]
  defstruct [
    :id,
    :name,
    :comment,
    :condition,
    :permissions,
    :path,
    default?: false,
    diagnostics: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          comment: String.t() | nil,
          default?: boolean(),
          condition: Ast.t() | nil,
          permissions: Permissions.t() | nil,
          path: String.t(),
          diagnostics: [Diagnostic.t()]
        }
end
