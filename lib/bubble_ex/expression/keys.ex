defmodule BubbleEx.Expression.Keys do
  @moduledoc false

  # Bubble serializes expressions with readable keys in `.bubble` exports and
  # editor JSON, and with compact aliases in the live app payload. Each logical
  # key maps to its [readable, compact] spellings. Only aliases observed in
  # real payloads are listed; anything else is preserved verbatim.

  @aliases %{
    type: ["type", "%x"],
    properties: ["properties", "%p"],
    next: ["next", "%n"],
    name: ["name", "%nm"],
    args: ["args", "%a"],
    entries: ["entries", "%e"],
    constraints: ["constraints", "%co"],
    type_to_find: ["type_to_find", "%t5"],
    key: ["key", "%k"],
    constraint_type: ["constraint_type", "%c2"],
    value: ["value", "%v"]
  }

  @type logical ::
          :type
          | :properties
          | :next
          | :name
          | :args
          | :entries
          | :constraints
          | :type_to_find
          | :key
          | :constraint_type
          | :value

  @spec spellings(logical()) :: [String.t()]
  def spellings(logical), do: Map.fetch!(@aliases, logical)

  @doc "Returns `{actual_key, value}` for the first spelling present, or nil."
  @spec get(map(), logical()) :: {String.t(), term()} | nil
  def get(map, logical) when is_map(map) do
    Enum.find_value(spellings(logical), fn key ->
      if Map.has_key?(map, key), do: {key, Map.fetch!(map, key)}
    end)
  end

  def get(_, _), do: nil

  @spec value(term(), logical()) :: term()
  def value(map, logical) do
    case get(map, logical) do
      {_, v} -> v
      nil -> nil
    end
  end

  @doc "Logical keys spelled both ways in the same object."
  @spec collisions(map(), [logical()]) :: [logical()]
  def collisions(map, logicals) do
    Enum.filter(logicals, fn logical ->
      Enum.count(spellings(logical), &Map.has_key?(map, &1)) > 1
    end)
  end

  @doc """
  Splits `map` into the actual spellings used for `logicals` and the remaining
  (uninterpreted) members.
  """
  @spec split(map(), [logical()]) :: {%{optional(logical()) => String.t()}, map()}
  def split(map, logicals) do
    used =
      for logical <- logicals, {key, _} <- [get(map, logical)], into: %{}, do: {logical, key}

    {used, Map.drop(map, Map.values(used))}
  end

  @doc "The key to write for `logical`, honoring the spelling recorded at parse time."
  @spec key(map(), logical()) :: String.t()
  def key(used, logical), do: Map.get(used, logical) || hd(spellings(logical))
end
