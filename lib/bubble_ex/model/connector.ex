defmodule BubbleEx.Model.Connector do
  @moduledoc """
  An API Connector group (a connector) and its calls, as defined in the app's
  settings (`settings.client_safe.apiconnector2`, exports only), whether or
  not any field uses them. The types their calls return are
  `BubbleEx.Model.ExternalType`s.

    * `id` - the group's Bubble ID; identity
    * `name` - its display name (`human`, else `name`), verbatim
    * `auth` - its authentication kind as supplied, e.g. `"none"`
    * `calls` - `BubbleEx.Model.ConnectorCall`s in Bubble ID order
    * `path` - JSON pointer to the group

  Groups that are not JSON objects are left out.
  """

  alias BubbleEx.Model.ConnectorCall

  @enforce_keys [:id, :path]
  defstruct [:id, :name, :auth, :path, calls: []]

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
    * `path` - JSON pointer to the call

  A call that is not a JSON object is kept with only `id` and `path`.
  """

  @enforce_keys [:id, :path]
  defstruct [:id, :name, :method, :publish_as, :path]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          method: String.t() | nil,
          publish_as: String.t() | nil,
          path: String.t()
        }
end
