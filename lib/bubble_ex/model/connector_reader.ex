defmodule BubbleEx.Model.ConnectorReader do
  @moduledoc false

  # Reads API Connector groups and calls (`settings.client_safe.apiconnector2`)
  # in either key form (`.bubble` exports: `name`, `key`; the live payload:
  # `%nm`, `%k`) into `BubbleEx.Model.Connector`s.
  #
  # Leak safety: calls carry credentials (header and parameter values, URL
  # user info, query strings, tokens in paths, bodies). Only these are read:
  # the URL's host (`host/1`), parameter names (`key`/`%k`) and their
  # `private` and `querystring` flags, and the request template
  # (`BubbleEx.Model.ConnectorRequest`, WTF-374), which keeps a URL's path
  # and query and a body's structure with placeholders and only literals
  # that cannot hold a credential. Parameter values (`value`/`%v`) are
  # never read, except a group's non-private shared values, which go
  # through the same literal check.

  alias BubbleEx.Diagnostic
  alias BubbleEx.Model.{Connector, ConnectorCall, ConnectorParameter}
  alias BubbleEx.Model.ConnectorRequest.Reader, as: RequestReader

  @connectors ["settings", "client_safe", "apiconnector2"]

  # Members that make a member of the group itself a call.
  @call_members ~w(types ret_value publish_as method url)

  # Parameter collections of a call and of a group (shared by its calls):
  # member => where the parameter goes.
  @call_parameters [{"headers", :header}, {"url_params", :url}, {"body_params", :body}]
  @shared_parameters [{"shared_headers", :header}]

  @spec read(map()) :: [Connector.t()]
  def read(%{"settings" => %{"client_safe" => %{"apiconnector2" => groups}}})
      when is_map(groups),
      do: for({id, group} <- entries(groups), is_map(group), do: connector(id, group))

  def read(_app), do: []

  @doc """
  The host of `url`: what follows `scheme://` up to the first `/`, `?` or
  `#`, without port. Bubble `[parameter]` placeholders are kept
  as supplied. Nil when `url` has no scheme, starts with a placeholder, has
  an `@` anywhere after `//` (user info, which may hold credentials and end
  past a `/`, `?` or `#`), or its host is anything but dot-separated labels
  of letters, digits, `-`, `_` and placeholders.
  """
  @spec host(term()) :: String.t() | nil
  def host(url) when is_binary(url) do
    with [_, after_scheme] <- Regex.run(~r{\A\s*[A-Za-z][A-Za-z0-9+.\-]*://(.*)\z}s, url),
         # User info (and so credentials) may end anywhere: at the host, or
         # past a `/`, `?` or `#` it contains. Any `@` means no host.
         false <- String.contains?(after_scheme, "@"),
         [host_port | _] <- String.split(after_scheme, ["/", "?", "#", "\\"], parts: 2),
         host = String.replace(host_port, ~r/:(?:\d*|\[[^\[\]]*\])\z/, ""),
         true <- host?(host) do
      host
    else
      _ -> nil
    end
  end

  def host(_), do: nil

  # Dot-separated labels of letters, digits, `-`, `_` and `[parameter]`
  # placeholders.
  defp host?(host),
    do:
      Regex.match?(
        ~r/\A(?:[A-Za-z0-9_\-]|\[[^\[\]:]+\])+(?:\.(?:[A-Za-z0-9_\-]|\[[^\[\]:]+\])+)*\z/,
        host
      )

  defp connector(id, group) do
    path = @connectors ++ [id]

    direct =
      for {cid, call} <- entries(group),
          cid != "calls",
          is_map(call) and Enum.any?(@call_members, &Map.has_key?(call, &1)),
          do: call(cid, call, :direct, path ++ [cid])

    nested =
      case member(group, ["calls"]) do
        {key, calls} when is_map(calls) ->
          for {cid, call} <- entries(calls), do: call(cid, call, :nested, path ++ [key, cid])

        _ ->
          []
      end

    parameters = parameters(group, @shared_parameters ++ [{"shared_params", :param}], path)

    %Connector{
      id: id,
      name: first_text(group, ~w(human name)),
      auth: first_text(group, ["auth"]),
      key_name: parameter_name(first_text(group, ["token_param_name"]), :query),
      parameters: parameters,
      shared_values: RequestReader.shared_values(group, parameters),
      path: pointer(path),
      calls: Enum.sort_by(direct ++ nested, &{&1.id, &1.placement})
    }
  end

  defp call(id, call, placement, path) when is_map(call) do
    types = Map.get(call, "types")
    registry = registry(types)
    parameters = parameters(call, @call_parameters ++ [{"params", :param}], path)

    %ConnectorCall{
      id: id,
      name: first_text(call, ~w(name %nm)),
      method: first_text(call, ["method"]),
      publish_as: first_text(call, ["publish_as"]),
      host: host(Map.get(call, "url")),
      parameters: parameters,
      request: RequestReader.read(call, parameters),
      returns: first_text(call, ["ret_value"]),
      registry: registry,
      types: if(is_nil(registry) and types not in [nil, ""], do: :malformed),
      placement: placement,
      path: pointer(path)
    }
  end

  defp call(id, call, placement, path),
    do: %ConnectorCall{id: id, placement: placement, path: pointer(path), raw: json_type(call)}

  # What a call that is not an object is, never its content.
  defp json_type(value) when is_binary(value), do: :string
  defp json_type(value) when is_number(value), do: :number
  defp json_type(value) when is_boolean(value), do: :boolean
  defp json_type(nil), do: :null
  defp json_type(value) when is_list(value), do: :array
  defp json_type(_), do: :other

  # Every parameter of `owner`'s `collections`, by location then Bubble ID.
  # A `params` entry flagged `querystring` goes in the query string.
  defp parameters(owner, collections, path) do
    for {member, location} <- collections,
        is_map(params = Map.get(owner, member)),
        {pid, param} <- entries(params) do
      raw = if is_map(param), do: param, else: %{}
      location = if location == :param and raw["querystring"] == true, do: :query, else: location

      %ConnectorParameter{
        id: pid,
        in: location,
        name: parameter_name(first_text(raw, ~w(key %k)), location),
        private: raw["private"] == true,
        path: pointer(path ++ [member, pid])
      }
    end
    |> Enum.sort_by(&{ConnectorParameter.order(&1.in), &1.id})
  end

  # Header names are HTTP tokens; anything else (e.g. `Authorization: Bearer
  # …` typed into the key) is not a name and is dropped. Other names are
  # dropped when they hold `=`, `:` or whitespace (a `key=value` or
  # `key: value` pair) or are implausibly long.
  @token ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z\-]{1,128}\z/
  defp parameter_name(nil, _), do: nil

  defp parameter_name(name, :header),
    do: if(Regex.match?(@token, name), do: name)

  defp parameter_name(name, _) do
    if String.length(name) in 1..128 and not String.match?(name, ~r/[=:\s\x00-\x1f\x7f]/u),
      do: name
  end

  # A types registry is the JSON text of an object: type ID => definition.
  # Only its type shapes are kept. Bubble stores the "initialize call"
  # response in it too (fields' `sample_value`: real response data), and
  # that, like any other member, is dropped.
  defp registry(types) when is_binary(types) do
    case Jason.decode(types) do
      {:ok, registry} when is_map(registry) ->
        Map.new(registry, fn {id, d} -> {id, definition(d)} end)

      _ ->
        nil
    end
  end

  defp registry(_), do: nil

  # A definition keeps its caption and its fields' shapes; one that is not
  # an object (or its `fields` when not an object) becomes nil, which the
  # resolver diagnoses just the same.
  defp definition(definition) when is_map(definition) do
    fields =
      case Map.get(definition, "fields") do
        fields when is_map(fields) -> Map.new(fields, fn {id, f} -> {id, registry_field(f)} end)
        _ -> nil
      end

    definition |> Map.take(["caption"]) |> keep_text(["caption"]) |> put_some("fields", fields)
  end

  defp definition(_), do: nil

  @field_shape ~w(caption ret_btype ret_value)
  defp registry_field(field) when is_map(field) do
    field
    |> Map.take(@field_shape)
    |> keep_text(@field_shape)
    |> put_some("path", response_path(Map.get(field, "path")))
  end

  defp registry_field(_), do: nil

  # A response path is a list of keys and indices.
  defp response_path(path) when is_list(path) do
    if Enum.all?(path, &(is_binary(&1) or is_integer(&1))), do: path
  end

  defp response_path(_), do: nil

  defp keep_text(map, keys),
    do: Map.reject(map, fn {k, v} -> k in keys and not is_binary(v) end)

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  defp entries(map),
    do: map |> Map.filter(fn {k, _} -> is_binary(k) end) |> Enum.sort_by(&elem(&1, 0))

  defp member(raw, keys) do
    case Enum.find(keys, &Map.has_key?(raw, &1)) do
      nil -> nil
      key -> {key, Map.fetch!(raw, key)}
    end
  end

  # The first of `keys` present in `map`, when it is a string.
  defp first_text(map, keys) when is_map(map) do
    case member(map, keys) do
      {_, value} when is_binary(value) -> value
      _ -> nil
    end
  end

  defp pointer(path), do: Diagnostic.pointer(path)
end
