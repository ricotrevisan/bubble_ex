defmodule BubbleEx.Model.Connector do
  @moduledoc """
  An API Connector group (a connector) and its calls, as defined in the app's
  settings (`settings.client_safe.apiconnector2`, in either key form),
  whether or not any field uses them. The types their calls return are
  `BubbleEx.Model.ExternalType`s.

    * `id` - the group's Bubble ID; identity
    * `name` - its display name (`human`, else `name`), verbatim
    * `auth` - its authentication kind as supplied, e.g. `"none"`
    * `parameters` - `BubbleEx.Model.ConnectorParameter`s shared by its calls
      (`shared_headers`, `shared_params`)
    * `calls` - `BubbleEx.Model.ConnectorCall`s in Bubble ID order (then
      placement): every entry of the group's `calls` object, and every member
      of the group itself shaped like a call (an object with a `types`,
      `ret_value`, `publish_as`, `method` or `url` member), which some
      exports use instead
    * `path` - JSON pointer to the group

  Groups that are not JSON objects are left out. No value that could hold a
  credential is read (see `BubbleEx.Model.ConnectorParameter`). The API Connector types
  (`BubbleEx.Model.ExternalType`) are resolved against these calls' `types`
  registries.
  """

  alias BubbleEx.Model.ConnectorCall

  @enforce_keys [:id, :path]
  defstruct [:id, :name, :auth, :path, parameters: [], calls: []]

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
          parameters: [BubbleEx.Model.ConnectorParameter.t()],
          path: String.t(),
          calls: [ConnectorCall.t()]
        }
end

defmodule BubbleEx.Model.ConnectorCall do
  @moduledoc """
  A call of a `BubbleEx.Model.Connector`.

    * `id` - its Bubble ID; identity within the connector
    * `name` - its display name (`name`, live payload `%nm`), verbatim
    * `method` - the HTTP method as supplied
    * `host` - the host of its URL, without scheme, user info, port, path or
      query string; Bubble `[parameter]` placeholders kept. Nil when the URL
      has no plain host (see `BubbleEx.Model.ConnectorReader.host/1`)
    * `parameters` - its `BubbleEx.Model.ConnectorParameter`s (headers, URL,
      body and query parameters), by location then Bubble ID
    * `publish_as` - how it is used as supplied (`"data"` or `"action"`)
    * `returns` - the type descriptor it returns (`ret_value`) when it is a
      string, verbatim
    * `registry` - its types registry (`types`, JSON text) decoded to type
      shapes only, from which `BubbleEx.Model.ExternalType`s are resolved:
      type ID => `%{"caption", "fields"}`, each field `%{"caption", "path",
      "ret_btype", "ret_value"}` (members kept only when well-typed; a
      definition or field that is not an object is nil). Everything else,
      notably the "initialize call" response's `sample_value`s, is dropped.
      Nil when `types` is not the JSON text of an object
    * `types` - `:malformed` when `types` is present, not empty and not the
      JSON text of an object (its content is not kept), else nil
    * `placement` - `:nested` (under the group's `calls`) or `:direct` (a
      member of the group itself)
    * `path` - JSON pointer to the call
    * `raw` - when the call is not a JSON object (only under `calls`), what
      it is instead (`:string`, `:number`, `:boolean`, `:null`, `:array`),
      never its content; then it has only `id`, `placement` and `path`
  """

  @enforce_keys [:id, :path, :placement]
  defstruct [
    :id,
    :name,
    :method,
    :publish_as,
    :host,
    :returns,
    :registry,
    :types,
    :placement,
    :path,
    :raw,
    parameters: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          method: String.t() | nil,
          publish_as: String.t() | nil,
          host: String.t() | nil,
          parameters: [BubbleEx.Model.ConnectorParameter.t()],
          returns: String.t() | nil,
          registry: map() | nil,
          types: :malformed | nil,
          placement: :direct | :nested,
          path: String.t(),
          raw: :string | :number | :boolean | :null | :array | :other | nil
        }
end

defmodule BubbleEx.Model.ConnectorParameter do
  @moduledoc """
  A header or parameter of a `BubbleEx.Model.ConnectorCall`, or one shared by
  a `BubbleEx.Model.Connector`'s calls. Its name and whether it is private
  only: its value is never read, since it may be a credential.

    * `id` - its Bubble ID; identity within its collection
    * `in` - where it goes: `:header` (`headers`, `shared_headers`), `:url`
      (`url_params`, a `[placeholder]` in the URL), `:body` (`body_params`),
      `:query` (`params` flagged `querystring`) or `:param` (other `params`,
      `shared_params`)
    * `name` - its key (`key`, live payload `%k`), verbatim; nil when absent
      (Bubble strips the key of some private headers) or not a name: a
      header key that is not an HTTP token, or another key holding `=`, `:`
      or whitespace, empty or longer than 128 characters
    * `private` - Bubble's `private` flag: its value is a secret kept on the
      server
    * `path` - JSON pointer to it
  """

  @enforce_keys [:id, :in, :path]
  defstruct [:id, :in, :name, :path, private: false]

  @type location :: :header | :url | :body | :query | :param

  @type t :: %__MODULE__{
          id: String.t(),
          in: location(),
          name: String.t() | nil,
          private: boolean(),
          path: String.t()
        }

  @doc "Sort rank of a location: headers, then URL, body, query and other."
  @spec order(location()) :: non_neg_integer()
  def order(:header), do: 0
  def order(:url), do: 1
  def order(:body), do: 2
  def order(:query), do: 3
  def order(:param), do: 4
end
