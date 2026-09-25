defmodule BubbleEx.Model.Connector do
  @moduledoc """
  An API Connector group (a connector) and its calls, as defined in the app's
  settings (`settings.client_safe.apiconnector2`, exports only), whether or
  not any field uses them. The types their calls return are
  `BubbleEx.Model.ExternalType`s.

    * `id` - the group's Bubble ID; identity
    * `name` - its display name (`human`, else `name`), verbatim
    * `auth` - its authentication kind as supplied, e.g. `"none"`
    * `calls` - `BubbleEx.Model.ConnectorCall`s in Bubble ID order (then
      placement): every entry of the group's `calls` object, and every member
      of the group itself shaped like a call (an object with a `types`,
      `ret_value`, `publish_as`, `method` or `url` member), which some
      exports use instead
    * `path` - JSON pointer to the group

  Groups that are not JSON objects are left out. The API Connector types
  (`BubbleEx.Model.ExternalType`) are resolved against these calls' `types`
  registries.
  """

  alias BubbleEx.Model.ConnectorCall

  @enforce_keys [:id, :path]
  defstruct [:id, :name, :auth, :path, calls: []]

  @doc """
  The call `id` of `connector`: one placed directly in the group first, then
  one under `calls`; nil when there is none.
  """
  @spec call(t(), String.t()) :: ConnectorCall.t() | nil
  def call(%__MODULE__{calls: calls}, id) do
    Enum.find(calls, &(&1.id == id and &1.placement == :direct)) ||
      Enum.find(calls, &(&1.id == id and &1.placement == :nested))
  end

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          auth: String.t() | nil,
          path: String.t(),
          calls: [ConnectorCall.t()]
        }
end

defmodule BubbleEx.Model.ConnectorCall do
  @moduledoc """
  A call of a `BubbleEx.Model.Connector`.

    * `id` - its Bubble ID; identity within the connector
    * `name` - its display name, verbatim
    * `method` - the HTTP method as supplied
    * `publish_as` - how it is used as supplied (`"data"` or `"action"`)
    * `returns` - the type descriptor it returns (`ret_value`), as supplied
    * `registry` - its types registry (`types`, JSON text) decoded, from
      which `BubbleEx.Model.ExternalType`s are resolved; nil when `types` is
      not the JSON text of an object
    * `types` - `types` as supplied when it is not (absent, empty or
      malformed), else nil
    * `placement` - `:nested` (under the group's `calls`) or `:direct` (a
      member of the group itself)
    * `path` - JSON pointer to the call
    * `raw` - the call itself when it is not a JSON object (only under
      `calls`); then it has only `id`, `placement` and `path`
  """

  @enforce_keys [:id, :path, :placement]
  defstruct [
    :id,
    :name,
    :method,
    :publish_as,
    :returns,
    :registry,
    :types,
    :placement,
    :path,
    :raw
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          method: String.t() | nil,
          publish_as: String.t() | nil,
          returns: term(),
          registry: map() | nil,
          types: term(),
          placement: :direct | :nested,
          path: String.t(),
          raw: term()
        }
end
