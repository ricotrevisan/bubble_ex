defmodule BubbleEx.Frontend.SafeUrl do
  @moduledoc false

  alias BubbleEx.Error

  @sensitive_query ~r/(?:pass|password|token|auth|cookie|secret|session|key|credential)/i

  @type origin :: {String.t(), String.t(), non_neg_integer()}

  @spec safe(term(), [String.t()]) :: String.t()
  def safe(url, taints \\ [])

  def safe(url, taints) when is_binary(url) and is_list(taints) do
    uri = URI.parse(url)

    uri
    |> Map.put(:userinfo, nil)
    |> Map.put(:fragment, nil)
    |> Map.put(:query, safe_query(uri.query))
    |> URI.to_string()
    |> redact(taints)
  rescue
    _ -> "[invalid URL]"
  end

  def safe(_url, _taints), do: "[invalid URL]"

  @spec origin(String.t()) :: {:ok, origin()} | {:error, Error.t()}
  def origin(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        scheme = String.downcase(scheme)
        {:ok, {scheme, String.downcase(host), effective_port(uri, scheme)}}

      _ ->
        {:error, Error.new(:invalid_input, "app URL has no valid origin", %{url: safe(url)})}
    end
  rescue
    _ -> {:error, Error.new(:invalid_input, "app URL has no valid origin", %{})}
  end

  @spec same_origin?(origin(), String.t()) :: boolean()
  def same_origin?(origin, url) do
    case origin(url) do
      {:ok, ^origin} -> true
      _ -> false
    end
  end

  @spec resolve(String.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def resolve(base, reference) when is_binary(base) and is_binary(reference) do
    uri = URI.merge(base, reference)
    url = URI.to_string(uri)

    if is_nil(uri.userinfo) do
      case origin(url) do
        {:ok, _} -> {:ok, url}
        {:error, _} = error -> error
      end
    else
      {:error, Error.new(:invalid_input, "URL userinfo is not allowed here", %{url: safe(url)})}
    end
  rescue
    _ -> {:error, Error.new(:invalid_input, "asset URL is invalid", %{url: safe(reference)})}
  end

  @spec https?(String.t()) :: boolean()
  def https?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when is_binary(scheme) -> String.downcase(scheme) == "https"
      _ -> false
    end
  rescue
    _ -> false
  end

  @spec pin_public_http_destination(String.t(), timeout()) ::
          {:ok, {String.t(), String.t()}} | {:error, Error.t()}
  def pin_public_http_destination(url, timeout) do
    pin_public_http_destination(url, timeout, &resolve_host/2)
  end

  @doc false
  @spec pin_public_http_destination(String.t(), timeout(), function()) ::
          {:ok, {String.t(), String.t()}} | {:error, Error.t()}
  def pin_public_http_destination(url, timeout, resolver)
      when is_binary(url) and is_integer(timeout) and is_function(resolver, 2) do
    with %URI{scheme: scheme, host: host} = uri <- URI.parse(url),
         true <- scheme in ["http", "https"] and is_binary(host),
         true <- uri.port in [nil, 80, 443],
         {:ok, addresses} <- resolver.(host, timeout),
         true <- addresses != [] and Enum.all?(addresses, &public_ip?/1) do
      address = Enum.min_by(addresses, &:erlang.term_to_binary/1)
      pinned_host = address |> :inet.ntoa() |> to_string()
      {:ok, {URI.to_string(%{uri | host: pinned_host}), host}}
    else
      _ ->
        {:error,
         Error.new(:invalid_input, "URL is not a public network destination", %{url: safe(url)})}
    end
  rescue
    _ -> {:error, Error.new(:invalid_input, "URL is not a public network destination", %{})}
  end

  @spec bubbleapps_host?(String.t()) :: boolean()
  def bubbleapps_host?(url), do: host_matches?(url, ~r/(?:^|\.)bubbleapps\.io$/i)

  @spec dedicated_host?(String.t()) :: boolean()
  def dedicated_host?(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        host = String.downcase(host)
        host != "bubble.is" and String.ends_with?(host, ".bubble.is")

      _ ->
        false
    end
  end

  @spec userinfo?(String.t()) :: boolean()
  def userinfo?(url) do
    case URI.parse(url) do
      %URI{userinfo: userinfo} -> not is_nil(userinfo)
      _ -> false
    end
  rescue
    _ -> false
  end

  @spec normalize(String.t()) :: String.t()
  def normalize(url) do
    uri = URI.parse(url)
    scheme = if uri.scheme, do: String.downcase(uri.scheme)
    host = if uri.host, do: String.downcase(uri.host)
    port = normalize_port(uri.port, scheme)

    %{uri | scheme: scheme, host: host, port: port, fragment: nil, userinfo: nil}
    |> URI.to_string()
  rescue
    _ -> safe(url)
  end

  defp resolve_host(host, timeout) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, [address]}
      {:error, _} -> bounded_resolve(String.to_charlist(host), timeout)
    end
  end

  defp bounded_resolve(host, timeout) do
    task =
      Task.async(fn ->
        [:inet, :inet6]
        |> Enum.flat_map(&resolve_family(host, &1))
        |> Enum.uniq()
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, addresses} -> {:ok, addresses}
      _ -> {:error, :resolution_failed}
    end
  end

  defp resolve_family(host, family) do
    case :inet.getaddrs(host, family) do
      {:ok, values} -> values
      {:error, _} -> []
    end
  end

  defp public_ip?({a, _, _, _}) when a in [0, 10, 127], do: false
  defp public_ip?({100, b, _, _}) when b in 64..127, do: false
  defp public_ip?({169, 254, _, _}), do: false
  defp public_ip?({172, b, _, _}) when b in 16..31, do: false
  defp public_ip?({192, 0, 0, _}), do: false
  defp public_ip?({192, 0, 2, _}), do: false
  defp public_ip?({192, 168, _, _}), do: false
  defp public_ip?({198, b, _, _}) when b in [18, 19], do: false
  defp public_ip?({198, 51, 100, _}), do: false
  defp public_ip?({203, 0, 113, _}), do: false
  defp public_ip?({a, _, _, _}) when a >= 224, do: false
  defp public_ip?({_, _, _, _}), do: true

  defp public_ip?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    public_ip?({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})
  end

  defp public_ip?({0, 0, 0, 0, 0, 0, _, _}), do: false
  defp public_ip?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: false
  defp public_ip?({a, _, _, _, _, _, _, _}) when a in 0x2000..0x3FFF, do: true
  defp public_ip?({_, _, _, _, _, _, _, _}), do: false
  defp public_ip?(_address), do: false

  defp redact(value, taints) do
    Enum.reduce(taints, value, fn
      taint, acc when is_binary(taint) and taint != "" -> String.replace(acc, taint, "[REDACTED]")
      _, acc -> acc
    end)
  end

  defp safe_query(nil), do: nil
  defp safe_query(""), do: ""

  defp safe_query(query) do
    query
    |> URI.query_decoder()
    |> Enum.map(fn {key, value} ->
      if Regex.match?(@sensitive_query, key), do: {key, "[REDACTED]"}, else: {key, value}
    end)
    |> URI.encode_query()
  rescue
    _ -> "[REDACTED]"
  end

  defp effective_port(%URI{port: port}, _scheme) when is_integer(port), do: port
  defp effective_port(_uri, "https"), do: 443
  defp effective_port(_uri, "http"), do: 80
  defp effective_port(_uri, _scheme), do: 0

  defp normalize_port(443, "https"), do: nil
  defp normalize_port(80, "http"), do: nil
  defp normalize_port(port, _), do: port

  defp host_matches?(url, regex) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> Regex.match?(regex, host)
      _ -> false
    end
  end
end
