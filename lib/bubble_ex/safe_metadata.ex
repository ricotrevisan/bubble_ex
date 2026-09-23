defmodule BubbleEx.SafeMetadata do
  @moduledoc "Bounded diagnostic metadata, never request bodies, credentials or arbitrary strings."

  @identity_keys ~w(input url bubble_id requested_url final_url)a
  @max_depth 6

  @doc "Sanitizes nested metadata before emission. Unknown strings are redacted, not inspected."
  @spec sanitize(term()) :: term()
  def sanitize(value), do: sanitize(value, 0)

  defp sanitize(_value, depth) when depth > @max_depth, do: "[redacted]"
  defp sanitize(value, _depth) when is_atom(value) or is_number(value), do: value
  defp sanitize(value, _depth) when is_binary(value), do: "[redacted]"

  defp sanitize(%module{} = value, depth) do
    fields =
      Map.new(Map.from_struct(value), fn {key, item} ->
        {key, sanitize_field(key, item, depth + 1)}
      end)

    Map.put(fields, :__struct__, module)
  end

  defp sanitize(value, depth) when is_map(value) do
    value
    |> Enum.take(50)
    |> Map.new(fn {key, item} -> {safe_key(key), sanitize_field(key, item, depth + 1)} end)
  end

  defp sanitize(value, depth) when is_list(value), do: sanitize_list(value, depth + 1, 50)

  defp sanitize(value, depth) when is_tuple(value),
    do:
      value
      |> Tuple.to_list()
      |> Enum.take(50)
      |> Enum.map(&sanitize(&1, depth + 1))
      |> List.to_tuple()

  defp sanitize(_value, _depth), do: "[redacted]"

  # Exception reasons may contain improper lists; Enum cannot safely traverse them.
  defp sanitize_list([], _depth, _remaining), do: []
  defp sanitize_list(_value, _depth, 0), do: []

  # Integers in lists may be Erlang character data (including nested iodata).
  # Only scalar numeric measurements are retained; numeric arrays are redacted.
  defp sanitize_list([head | tail], depth, remaining) when is_integer(head),
    do: ["[redacted]" | sanitize_list(tail, depth, remaining - 1)]

  defp sanitize_list([head | tail], depth, remaining),
    do: [sanitize(head, depth) | sanitize_list(tail, depth, remaining - 1)]

  defp sanitize_list(_tail, _depth, _remaining), do: ["[redacted]"]

  defp sanitize_field(key, value, _depth) when key in @identity_keys, do: identity(value)

  defp sanitize_field(key, value, depth) when is_binary(key) do
    if key in Enum.map(@identity_keys, &Atom.to_string/1),
      do: identity(value),
      else: sanitize(value, depth)
  end

  defp sanitize_field(_key, value, depth), do: sanitize(value, depth)

  defp safe_key(key) when is_atom(key), do: key
  defp safe_key(_key), do: "[redacted]"

  @doc "Public identity for monitoring. URLs retain only their origin; paths may contain secrets."
  @spec identity(term()) :: String.t() | nil
  def identity(nil), do: nil

  def identity(value) when is_binary(value) and byte_size(value) <= 2048 do
    if Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, value) and byte_size(value) <= 63,
      do: value,
      else: origin(value)
  end

  def identity(_value), do: "[redacted]"

  defp origin(value) do
    with {:ok, uri} <- URI.new(value),
         true <- uri.scheme in ["http", "https"],
         host when is_binary(host) <- uri.host,
         true <- byte_size(host) <= 253 and Regex.match?(~r/\A[a-zA-Z0-9.:-]+\z/, host) do
      URI.to_string(%{uri | userinfo: nil, path: nil, query: nil, fragment: nil})
    else
      _ -> "[redacted]"
    end
  end
end
