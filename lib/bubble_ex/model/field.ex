defmodule BubbleEx.Model.Field do
  @moduledoc """
  A field of a data type, or an attribute of an option set.

    * `id` - the Bubble ID (e.g. `"title_text"`); identity
    * `name` - the current display name, verbatim; never identity
    * `type` - its `BubbleEx.Model.Type`
    * `deleted` - deleted in the editor; the field is kept
    * `default` - the default value as supplied (`default_val`), or `nil`
    * `system` - for Bubble's built-in fields, which role:
      `:unique_id`, `:created_date`, `:modified_date`, `:created_by`,
      `:slug` or `:email` (User only); `nil` for defined fields
    * `path` - JSON pointer to the field in the supplied app JSON (a built-in
      field's is its data type's)
    * `extra` - members kept verbatim but not modeled (diagnosed)
    * `raw` - the field itself when it is not a JSON object (diagnosed);
      then `type` is `:unknown`

  Bubble has no required fields: every field allows an empty value.
  """

  alias BubbleEx.Model.Type

  @enforce_keys [:id, :type, :path]
  defstruct [
    :id,
    :name,
    :comment,
    :type,
    :default,
    :system,
    :creation_source,
    :path,
    :raw,
    deleted: false,
    extra: %{}
  ]

  @type system ::
          :unique_id | :created_date | :modified_date | :created_by | :slug | :email

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          comment: String.t() | nil,
          type: Type.t(),
          default: term(),
          system: system() | nil,
          creation_source: String.t() | nil,
          deleted: boolean(),
          path: String.t(),
          extra: map(),
          raw: term()
        }
end
