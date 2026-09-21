defmodule BubbleEx.HTTP.Destination do
  @moduledoc false
  import Bitwise

  # Conservative IANA special-purpose registries (2026-09): deny entire ranges,
  # including globally reachable exceptions. IPv6 must be native global unicast;
  # mapped, NAT64, Teredo, 6to4, documentation and protocol assignments are denied.
  @v4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 3}
  ]
  @v6 [
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
    {{0x3FFF, 0, 0, 0, 0, 0, 0, 0}, 20}
  ]

  @spec pin(String.t(), pos_integer(), function()) ::
          {:ok, {tuple(), String.t()}} | {:error, atom()}
  def pin(url, timeout, resolver \\ &resolve/2) do
    with {:ok, uri} <- parse(url),
         {:ok, addresses} <- addresses(uri.host, timeout, resolver),
         true <- addresses != [] and Enum.all?(addresses, &public_ip?/1) do
      {:ok, {Enum.min(addresses), uri.host}}
    else
      false -> {:error, :unsafe_destination}
      error -> error
    end
  rescue
    _ -> {:error, :unsafe_destination}
  end

  @spec parse(String.t()) :: {:ok, URI.t()} | {:error, :unsafe_destination}
  def parse(url) when is_binary(url) do
    with false <- Regex.match?(~r/[\x00-\x20\x7f\\]/, url),
         {:ok, %URI{host: host, scheme: scheme} = uri} <- URI.new(url),
         true <- scheme in ["http", "https"] and is_binary(host),
         true <- is_nil(uri.userinfo),
         true <- uri.port == if(scheme == "https", do: 443, else: 80),
         true <- valid_host?(host),
         true <- valid_authority?(uri, url) do
      {:ok, uri}
    else
      _ -> {:error, :unsafe_destination}
    end
  end

  def parse(_), do: {:error, :unsafe_destination}

  @doc false
  def redirect(base, location) do
    with false <- Regex.match?(~r/[\x00-\x20\x7f\\]/, location),
         {:ok, reference} <- URI.new(location) do
      cond do
        reference.scheme -> parse(location)
        String.starts_with?(location, "//") -> parse(base.scheme <> ":" <> location)
        true -> base |> URI.merge(location) |> URI.to_string() |> parse()
      end
    else
      _ -> {:error, :unsafe_destination}
    end
  rescue
    _ -> {:error, :unsafe_destination}
  end

  defp valid_authority?(uri, url) do
    host = if String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host

    case Regex.run(~r/\Ahttps?:\/\/([^\/?#]*)/, url) do
      [_, authority] -> authority in [host, "#{host}:#{uri.port}"]
      _ -> false
    end
  end

  defp valid_host?(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} when tuple_size(address) == 4 ->
        to_string(:inet.ntoa(address)) == host

      {:ok, _address} ->
        not String.contains?(host, "%")

      _ ->
        byte_size(host) <= 253 and String.contains?(host, ".") and
          not Regex.match?(~r/(?:^|\.)(?:0x[0-9a-f]+|[0-9]+)$/i, host) and
          Enum.all?(String.split(host, "."), fn label ->
            Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i, label)
          end)
    end
  end

  defp addresses(host, timeout, resolver) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, [ip]}
      _ -> bounded(fn -> resolver.(host, timeout) end, timeout)
    end
  end

  # Bound even an injected resolver. No task remains alive after timeout.
  defp bounded(fun, timeout) when timeout > 0 do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          _ -> {:error, :dns_error}
        catch
          _, _ -> {:error, :dns_error}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :dns_timeout}
    end
  end

  defp bounded(_, _), do: {:error, :total_timeout}

  @doc false
  def resolve(host, _timeout) do
    results = Enum.map([:inet, :inet6], &:inet.getaddrs(String.to_charlist(host), &1))

    # An absent family is normal; a failed family must not conceal private answers.
    if Enum.all?(results, &(match?({:ok, _}, &1) or &1 == {:error, :nxdomain})) do
      addresses =
        Enum.flat_map(results, fn
          {:ok, ips} -> ips
          _ -> []
        end)

      if addresses == [], do: {:error, :nxdomain}, else: {:ok, Enum.uniq(addresses)}
    else
      {:error, :dns_error}
    end
  end

  @doc false
  def public_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 4 do
    valid_ip?(ip, 255) and not Enum.any?(@v4, &in_range?(ip, &1, 8))
  end

  def public_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 8 do
    valid_ip?(ip, 65_535) and elem(ip, 0) in 0x2000..0x3FFF and
      not Enum.any?(@v6, &in_range?(ip, &1, 16))
  end

  def public_ip?(_), do: false

  defp valid_ip?(ip, max),
    do: ip |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 >= 0 and &1 <= max))

  defp integer(ip, bits), do: ip |> Tuple.to_list() |> Enum.reduce(0, &((&2 <<< bits) + &1))

  defp in_range?(ip, {network, prefix}, bits) do
    shift = tuple_size(ip) * bits - prefix
    integer(ip, bits) >>> shift == integer(network, bits) >>> shift
  end
end
