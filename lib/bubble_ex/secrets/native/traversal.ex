defmodule BubbleEx.Secrets.Native.Traversal do
  @moduledoc """
  Enumerates every string leaf in a nested map/list structure, returning each
  leaf's root-to-leaf `path`, the nearest enclosing map `key` (carried through
  lists; `nil` at the root), and the string `value`.

  This is the scanning counterpart to `BubbleEx.DeepSearch`: DeepSearch finds
  paths to a *known* target; this enumerates *all* string leaves so detectors
  can be applied to each.
  """

  @type leaf ::
          {path :: [String.t() | non_neg_integer()], key :: String.t() | nil, value :: String.t()}

  @doc """
  Returns every string leaf in `data` (a map or list) as `{path, key, value}`;
  any other input returns `[]`.

  Each `path` is a list of string map-keys and/or integer list-indices from the
  root to the leaf, e.g. `["plugins", 0, "token"]`. Atom map keys (Elixir maps)
  are normalized to strings, so `path` and `key` are always binaries — never
  atoms.
  """
  @spec string_leaves(term()) :: [leaf()]
  def string_leaves(data) when is_map(data) or is_list(data),
    do: data |> walk([], nil, []) |> Enum.reverse()

  def string_leaves(_data), do: []

  defp walk(map, path, _key, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {k, v}, acc ->
      key = normalize_key(k)
      walk(v, [key | path], key, acc)
    end)
  end

  defp walk(list, path, key, acc) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {v, i}, acc -> walk(v, [i | path], key, acc) end)
  end

  defp walk(value, path, key, acc) when is_binary(value) do
    [{Enum.reverse(path), key, value} | acc]
  end

  defp walk(_other, _path, _key, acc), do: acc

  # Map keys may be atoms (Elixir maps) as well as strings (JSON). Normalize to
  # strings so `path` elements and the entropy key-name gate are always binaries.
  # `String.to_atom/1` is intentionally avoided (no reverse conversion needed).
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: inspect(key)
end
