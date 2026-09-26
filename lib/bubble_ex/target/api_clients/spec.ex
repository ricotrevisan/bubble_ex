defmodule BubbleEx.Target.ApiClients.Spec do
  @moduledoc """
  The API Connector clients of an app described as plain data: what
  `BubbleEx.Target.ApiClients.map/2` derives from a `BubbleEx.Model`, and
  all a renderer (`BubbleEx.Target.Phoenix`) needs to print them. It holds
  no secret: private values and redacted literals are environment variable
  names (`env`), never values.

    * `groups` - `BubbleEx.Target.ApiClients.Group`s in Bubble ID order
    * `env` - every environment variable the clients read, sorted by name:
      `%{name, kind, group, call, parameter, description}` where `kind` is
      `:private` (a private parameter's value), `:private_line` (a private
      header or parameter whose name Bubble stripped: the variable holds
      `Name: value` for a header, `name=value` for a parameter), `:auth`
      (the group's key, user name or password) or `:literal` (a literal
      that is not structure, see `BubbleEx.Model.ConnectorRequest`)
    * `types` - the response shapes of the external types calls decode
      into: external type ID => `%{field ID => response path}`
    * `residue` - calls not generated: `%{group, call, name, reasons}`
      (reason atoms, sorted), in Bubble ID order

  ## Values and templates

  A value is `{:literal, text}`, `{:arg, key}` (the call's parameter
  `key`), `{:env, name}` or `{:env_line, name}`. A JSON template node is
  `{:object, [{key, node}]}`, `{:array, [node]}`, `{:text, [value]}` (a
  string), `{:json, value}` (a number, boolean or null), `{:arg, key}` or
  `{:env_json, name}` (a JSON value).
  """

  alias BubbleEx.CanonicalJson

  @schema_version 1

  defstruct schema_version: @schema_version, groups: [], env: [], types: %{}, residue: []

  @type value ::
          {:literal, String.t()}
          | {:arg, String.t()}
          | {:env, String.t()}
          | {:env_line, String.t()}

  @type template ::
          {:object, [{String.t(), template()}]}
          | {:array, [template()]}
          | {:text, [value()]}
          | {:json, number() | boolean() | nil}
          | {:arg, String.t()}
          | {:env_json, String.t()}

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          groups: [BubbleEx.Target.ApiClients.Group.t()],
          env: [map()],
          types: %{String.t() => %{String.t() => [String.t() | integer()]}},
          residue: [map()]
        }

  @doc "JSON form: string keys, tuples as lists."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = spec), do: json(spec)

  @doc "SHA-256 of the canonical JSON of `to_map/1`."
  @spec sha256(t()) :: String.t()
  def sha256(%__MODULE__{} = spec), do: spec |> to_map() |> CanonicalJson.sha256()

  @doc """
  Counts (string keys): groups, calls generated (and of those, how many
  read environment variables) and in residue, residue reasons,
  environment variables by kind, typed responses.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = spec) do
    calls = Enum.flat_map(spec.groups, & &1.calls)
    generated = length(calls)

    %{
      "groups" => length(spec.groups),
      "calls" => generated + length(spec.residue),
      "generated" => generated,
      "generated_env_configured" => Enum.count(calls, &(&1.env != [])),
      "residue" => length(spec.residue),
      "residue_reasons" =>
        spec.residue
        |> Enum.flat_map(& &1.reasons)
        |> Enum.frequencies()
        |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end),
      "env" =>
        spec.env
        |> Enum.frequencies_by(& &1.kind)
        |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end),
      "typed_responses" => Enum.count(calls, &(&1.response.type != nil))
    }
  end

  defp json(%_{} = struct), do: struct |> Map.from_struct() |> json()
  defp json(map) when is_map(map), do: Map.new(map, fn {k, v} -> {key(k), json(v)} end)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json()
  defp json(value) when value in [true, false, nil], do: value
  defp json(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json(value), do: value

  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: k
end

defmodule BubbleEx.Target.ApiClients.Group do
  @moduledoc """
  An API Connector group as a client module.

    * `id` / `bubble_name` - its Bubble ID and name
    * `module` - the module segment (`"Payments"` for
      `<App>.ApiClients.Payments`)
    * `calls` - the generated `BubbleEx.Target.ApiClients.Call`s, in
      Bubble ID order
  """

  @enforce_keys [:id, :module]
  defstruct [:id, :bubble_name, :module, calls: []]

  @type t :: %__MODULE__{
          id: String.t(),
          bubble_name: String.t() | nil,
          module: String.t(),
          calls: [BubbleEx.Target.ApiClients.Call.t()]
        }
end

defmodule BubbleEx.Target.ApiClients.Call do
  @moduledoc """
  An API Connector call as a client function.

    * `id` / `bubble_name` - its Bubble ID and name; `function` its function
      name
    * `method` - `:get`, `:post`, `:put`, `:patch` or `:delete`
    * `publish_as` - Bubble's `"data"` or `"action"`, as supplied
    * `base` - `%{scheme, host: [value], port}`
    * `path` - segments, each a list of values
    * `query`, `headers`, `form` - `%{name, value}` entries, `value` a list
      of values sent concatenated (`name` nil for an `[{:env_line, _}]`
      value)
    * `json` - the JSON body template, or nil
    * `auth` - nil or `{:basic, user_env, password_env}`
    * `args` - its parameters: `%{key, parameter, in, name}` (`key` the
      argument name, `name` Bubble's key)
    * `env` - the environment variables it reads, sorted
    * `response` - `%{kind: :json | :text | :empty, list: boolean, type:
      external type ID or nil}`
  """

  @enforce_keys [:id, :function, :method]
  defstruct [
    :id,
    :bubble_name,
    :function,
    :method,
    :publish_as,
    :base,
    :json,
    :auth,
    :response,
    path: [],
    query: [],
    headers: [],
    form: [],
    args: [],
    env: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          bubble_name: String.t() | nil,
          function: String.t(),
          method: :get | :post | :put | :patch | :delete,
          publish_as: String.t() | nil,
          base: map(),
          path: [[BubbleEx.Target.ApiClients.Spec.value()]],
          query: [map()],
          headers: [map()],
          form: [map()],
          json: BubbleEx.Target.ApiClients.Spec.template() | nil,
          auth: nil | {:basic, String.t(), String.t()},
          args: [map()],
          env: [String.t()],
          response: map()
        }
end
