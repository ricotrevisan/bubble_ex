defmodule BubbleEx.Frontend.Json do
  @moduledoc false

  @spec encode(term()) :: String.t()
  def encode(term) do
    term
    |> normalize()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
    |> String.replace("\r\n", "\n")
  end

  @spec sha256(term()) :: String.t()
  def sha256(term) do
    term
    |> normalize()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec normalize(term()) :: term()
  def normalize(%_{} = struct), do: struct |> Map.from_struct() |> normalize()

  def normalize(map) when is_map(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {to_string(k), normalize(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)

  def normalize(atom) when is_atom(atom) and atom not in [true, false, nil],
    do: Atom.to_string(atom)

  def normalize(other), do: other
end
