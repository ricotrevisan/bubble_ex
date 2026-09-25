defmodule BubbleEx.Model.OptionValue do
  @moduledoc """
  One value of an option set.

    * `id` - the value's Bubble ID (its key in the set)
    * `key` - the stable key Bubble stores in data (`db_value`). A value
      without one uses `id` (diagnosed as `:model_option_key_missing`).
    * `name` - the display text, verbatim
    * `sort_factor` - Bubble's ordering number, as supplied
    * `attributes` - attribute values by attribute Bubble ID, as supplied
    * `deleted` - deleted in the editor; the value is kept
    * `extra` / `raw` - members kept verbatim but not modeled / the value
      itself when it is not a JSON object
  """

  @enforce_keys [:id, :key, :path]
  defstruct [
    :id,
    :key,
    :name,
    :comment,
    :sort_factor,
    :path,
    :raw,
    deleted: false,
    attributes: %{},
    extra: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          key: String.t(),
          name: String.t() | nil,
          comment: String.t() | nil,
          sort_factor: term(),
          deleted: boolean(),
          path: String.t(),
          attributes: %{String.t() => term()},
          extra: map(),
          raw: term()
        }
end
