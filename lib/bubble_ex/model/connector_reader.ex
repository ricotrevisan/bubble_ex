defmodule BubbleEx.Model.ConnectorReader do
  @moduledoc false

  # Reads API Connector groups and calls (`settings.client_safe.apiconnector2`)
  # in either key form (`.bubble` exports: `name`, `key`; the live payload:
  # `%nm`, `%k`) into `BubbleEx.Model.Connector`s.
  #
  # Leak safety: calls carry credentials (header and parameter values, URL
  # user info, query strings, tokens in paths, bodies). Only these are read:
  # the URL's host (`host/1`), parameter names (`key`/`%k`) and their
  # `private` and `querystring` flags. Values (`value`/`%v`), bodies
  # (`body`/`%b3`) and the rest of the URL are never read, so they cannot
  # reach the Model or anything built from it.

  alias BubbleEx.Diagnostic
  alias BubbleEx.Model.{Connector, ConnectorCall, ConnectorParameter}

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
  `#`, without user info or port. Bubble `[parameter]` placeholders are kept
  as supplied. Nil when `url` has no scheme, starts with a placeholder, has
  an `@` in its path (where user info might end), or its host is anything
  but dot-separated labels of letters, digits, `-`, `_` and placeholders.
  """
  @spec host(term()) :: String.t() | nil
  def host(url) when is_binary(url) do
    with [_, authority, rest] <-
           Regex.run(~r{\A\s*[A-Za-z][A-Za-z0-9+.\-]*://([^/?#\\]*)([^?#]*)}, url),
         # An `@` after the authority may end user info that holds a `/`.
         false <- String.contains?(rest, "@"),
         host_port = authority |> String.split("@") |> List.last(),
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

    %Connector{
      id: id,
      name: first_text(group, ~w(human name)),
      auth: first_text(group, ["auth"]),
      parameters: parameters(group, @shared_parameters ++ [{"shared_params", :param}], path),
      path: pointer(path),
      calls: Enum.sort_by(direct ++ nested, &{&1.id, &1.placement})
    }
  end

  defp call(id, call, placement, path) when is_map(call) do
    registry = registry(Map.get(call, "types"))

    %ConnectorCall{
      id: id,
      name: first_text(call, ~w(name %nm)),
      method: first_text(call, ["method"]),
      publish_as: first_text(call, ["publish_as"]),
      host: host(Map.get(call, "url")),
      parameters: parameters(call, @call_parameters ++ [{"params", :param}], path),
      returns: Map.get(call, "ret_value"),
      registry: registry,
      types: if(is_nil(registry), do: Map.get(call, "types")),
      placement: placement,
      path: pointer(path)
    }
  end

  defp call(id, call, placement, path),
    do: %ConnectorCall{id: id, placement: placement, path: pointer(path), raw: call}

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
  # kept unless they span lines or are implausibly long.
  @token ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z\-]{1,128}\z/
  defp parameter_name(nil, _), do: nil

  defp parameter_name(name, :header),
    do: if(Regex.match?(@token, name), do: name)

  defp parameter_name(name, _) do
    if String.length(name) <= 128 and not String.match?(name, ~r/[\x00-\x1f\x7f]/u),
      do: name
  end

  # A types registry is the JSON text of an object.
  defp registry(types) when is_binary(types) do
    case Jason.decode(types) do
      {:ok, registry} when is_map(registry) -> registry
      _ -> nil
    end
  end

  defp registry(_), do: nil

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

  defp first_text(_, _), do: nil

  defp pointer(path), do: Diagnostic.pointer(path)
end
