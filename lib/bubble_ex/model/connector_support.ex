defmodule BubbleEx.Model.ConnectorSupport do
  @moduledoc """
  Whether an API Connector call can be generated as a client function,
  from the Model alone (WTF-412). It is the one decision both
  `BubbleEx.Target.ApiClients` (which calls it generates) and
  `BubbleEx.Plan.Residue` (which calls are `:not_generated` residue) use,
  so the plan and the generator never disagree about a call.

  `unsupported/2` lists why a call cannot be generated, sorted:

  | reason | when |
  |--------|------|
  | `:malformed_call` | the call is not a JSON object (`raw`); nothing else is checked |
  | `:unsupported_auth` | its group authenticates with anything but none, `private_key_header`, `private_key_url` or `basic_auth` (OAuth, JWT, custom token, …) |
  | `:method` | its method is not GET, POST, PUT, PATCH or DELETE |
  | `:unnamed_parameter` | a non-private parameter of the call or its group has no usable name |
  | the reasons of `BubbleEx.Model.ConnectorRequest`'s `unsupported` | its request template does not describe the request (`:raw_body`, `:file_parameter`, `:query`, `:no_url`, `:no_host`, …) |

  A malformed `types` registry does not stop generation: it only leaves
  the response untyped.
  """

  alias BubbleEx.Model.{Connector, ConnectorCall, ConnectorRequest}

  @methods %{
    "get" => :get,
    "post" => :post,
    "put" => :put,
    "patch" => :patch,
    "delete" => :delete
  }

  @auth [nil, "none", "private_key_header", "private_key_url", "basic_auth"]

  @doc "The HTTP method of `call` (`:get`, `:post`, `:put`, `:patch`, `:delete`), or nil."
  @spec method(ConnectorCall.t()) :: :get | :post | :put | :patch | :delete | nil
  def method(%ConnectorCall{method: method}),
    do: Map.get(@methods, ConnectorRequest.Reader.method(method))

  @doc "Whether `group`'s authentication kind can be generated."
  @spec auth_supported?(Connector.t()) :: boolean()
  def auth_supported?(%Connector{auth: auth}), do: auth in @auth

  @doc "Why `call` of `group` cannot be generated, sorted; `[]` when it can."
  @spec unsupported(Connector.t(), ConnectorCall.t()) :: [atom()]
  def unsupported(%Connector{}, %ConnectorCall{raw: raw}) when raw != nil, do: [:malformed_call]

  def unsupported(%Connector{} = group, %ConnectorCall{} = call) do
    unnamed =
      Enum.any?(group.parameters ++ call.parameters, &(not &1.private and is_nil(&1.name)))

    (if(auth_supported?(group), do: [], else: [:unsupported_auth]) ++
       call.request.unsupported ++
       if(method(call), do: [], else: [:method]) ++
       if(unnamed, do: [:unnamed_parameter], else: []))
    |> Enum.uniq()
    |> Enum.sort()
  end
end
