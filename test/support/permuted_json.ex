defmodule BubbleEx.Test.PermutedJson do
  @moduledoc false

  # JSON text of a decoded value with every object's members in random
  # order (`:rand`, so seed it). Bubble serializes object members in no fixed
  # order, and API Connector `types` registries are JSON strings embedded in
  # the app JSON: those are re-encoded with their own members shuffled, so
  # the decoded input really differs (a different string) while meaning the
  # same thing.

  @spec encode(term()) :: String.t()
  def encode(map) when is_map(map) do
    members =
      map
      |> Enum.shuffle()
      |> Enum.map(fn {k, v} -> Jason.encode!(k) <> ":" <> encode(embedded(k, v)) end)

    "{" <> Enum.join(members, ",") <> "}"
  end

  def encode(list) when is_list(list), do: "[" <> Enum.map_join(list, ",", &encode/1) <> "]"
  def encode(value), do: Jason.encode!(value)

  defp embedded("types", value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, registry} when is_map(registry) -> encode(registry)
      _ -> value
    end
  end

  defp embedded(_key, value), do: value
end
