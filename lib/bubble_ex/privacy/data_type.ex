defmodule BubbleEx.Privacy.DataType do
  @moduledoc """
  The privacy rules of one data type.

  `availability` separates "no rules" from "not supplied":

    * `:present` - the source includes the type's rules
    * `:none` - a `.bubble` export lists the type without rules (no
      `privacy_role`, or an empty one). Bubble's public defaults then apply to
      every user: view all fields, find in searches and view attachments are
      allowed; auto-binding is not, and no Data API create/modify/delete
      permission is granted.
    * `:unavailable` - the source (e.g. the live payload, which never ships
      privacy rules) cannot say

  Rule semantics: a user gets the union (logical OR) of the permissions of
  every rule whose condition they match; the `everyone` rule applies to users
  matching no other rule. Visible and auto-binding field lists are unioned the
  same way.

  `exposed_api` is the type-level Data API switch; the rule-level
  `create_via_api` / `modify_via_api` / `delete_via_api` flags only take effect
  when it is true. `deleted` marks a type deleted in the editor. Other
  type-level members are kept in `extra` and diagnosed.
  """

  alias BubbleEx.Diagnostic
  alias BubbleEx.Privacy.Rule

  @enforce_keys [:id, :availability, :path]
  defstruct [
    :id,
    :name,
    :comment,
    :availability,
    :path,
    exposed_api: nil,
    deleted: nil,
    rules: [],
    extra: %{},
    diagnostics: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          comment: String.t() | nil,
          exposed_api: boolean() | nil,
          deleted: boolean() | nil,
          extra: map(),
          availability: :present | :none | :unavailable,
          path: String.t(),
          rules: [Rule.t()],
          diagnostics: [Diagnostic.t()]
        }
end
