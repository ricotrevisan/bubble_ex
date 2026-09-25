defmodule BubbleEx.Model.DataType do
  @moduledoc """
  A Bubble data type.

    * `id` - the Bubble ID (e.g. `"task"`, `"user"`); identity
    * `name` - the current display name, verbatim
    * `fields` - the defined fields (`BubbleEx.Model.Field`), deleted ones
      included, in Bubble ID order
    * `system_fields` - Bubble's built-in fields every record has: unique id
      (`_id`), `Created Date`, `Modified Date`, `Created By`, `Slug`, and
      `email` on User. A defined field with a built-in's Bubble ID replaces
      it unless that field is deleted or malformed.
    * `deleted` - deleted in the editor; the type is kept
    * `synthesized` - true only for the User type (`"user"`) when the source
      does not define it. User is built into every Bubble app, so references
      to it (`Created By`, `user` fields) always resolve; the synthesized type
      has only the built-in fields (diagnosed as
      `:model_synthesized_user_type`).
    * `exposed_api` - the type-level Data API switch, `nil` when not supplied
    * `privacy` - `:present`, `:none` or `:unavailable`, and `rules` the
      `BubbleEx.Privacy.Rule`s, both as `BubbleEx.Privacy` parses them
    * `extra` - type-level members kept verbatim but not modeled
    * `raw` - the type itself when it is not a JSON object; then it has no
      fields
  """

  alias BubbleEx.Model.Field
  alias BubbleEx.Privacy.Rule

  @enforce_keys [:id, :path]
  defstruct [
    :id,
    :name,
    :comment,
    :exposed_api,
    :path,
    :raw,
    deleted: false,
    synthesized: false,
    privacy: :unavailable,
    fields: [],
    system_fields: [],
    rules: [],
    extra: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          comment: String.t() | nil,
          exposed_api: boolean() | nil,
          deleted: boolean(),
          synthesized: boolean(),
          privacy: :present | :none | :unavailable,
          path: String.t(),
          fields: [Field.t()],
          system_fields: [Field.t()],
          rules: [Rule.t()],
          extra: map(),
          raw: term()
        }
end
