defmodule BubbleEx.CanonicalJson do
  @moduledoc """
  Canonical JSON: recursively sorted object keys, original array order and
  preserved nulls. Two values with the same canonical form are the same JSON
  document regardless of key order or whitespace. `sha256/1` hashes that form.
  """

  @doc "Orders every map level by stringified key, for deterministic encoding."
  @spec ordered(term()) :: term()
  def ordered(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), ordered(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  def ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  def ordered(value), do: value

  @doc "Compact canonical JSON text."
  @spec encode(term()) :: String.t()
  def encode(value), do: value |> ordered() |> Jason.encode!()

  @doc "Lowercase hex SHA-256 of the canonical JSON text."
  @spec sha256(term()) :: String.t()
  def sha256(value),
    do: :sha256 |> :crypto.hash(encode(value)) |> Base.encode16(case: :lower)
end
