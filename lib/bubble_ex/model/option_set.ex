defmodule BubbleEx.Model.OptionSet do
  @moduledoc """
  A Bubble option set: a finite collection of named values.

    * `id` - the Bubble ID; identity
    * `name` - the current display name, verbatim
    * `attributes` - its attributes as `BubbleEx.Model.Field`s (deleted ones
      included), in Bubble ID order. Every value also has its display text
      (`BubbleEx.Model.OptionValue.name`), which is not listed here.
    * `values` - `BubbleEx.Model.OptionValue`s in source order (Bubble's
      `sort_factor`, then Bubble ID)
    * `deleted` - deleted in the editor; the set is kept
    * `extra` / `raw` - as for `BubbleEx.Model.DataType`
  """

  alias BubbleEx.Model.{Field, OptionValue}

  @enforce_keys [:id, :path]
  defstruct [
    :id,
    :name,
    :comment,
    :creation_source,
    :path,
    :raw,
    deleted: false,
    attributes: [],
    values: [],
    extra: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          comment: String.t() | nil,
          creation_source: String.t() | nil,
          deleted: boolean(),
          path: String.t(),
          attributes: [Field.t()],
          values: [OptionValue.t()],
          extra: map(),
          raw: term()
        }
end
