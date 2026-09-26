defmodule BubbleEx.Test.HostileIds do
  @moduledoc """
  Rewrites Bubble IDs of an app JSON into hostile ones (WTF-370): quotes,
  `\#{`, a space, a newline, `*/`, `--%>`, an EEx tag and braces, so a test can check
  that generated source quotes them instead of splicing them in. Used by
  the pages test and the Phoenix compile check (`hostile_ids`), which
  compiles and runs the result.
  """

  @doc "The hostile version of `id` (still unique: it keeps `id`)."
  @spec hostile(String.t()) :: String.t()
  def hostile(id), do: ~s(#{id}"\#{raise "injected"} a\nb*/--%><%= raise "eex" %>}{)

  @doc "`app` with every string value equal to one of `ids` made hostile."
  @spec rename(term(), [String.t()]) :: term()
  def rename(app, ids), do: walk(app, Map.new(ids, &{&1, hostile(&1)}))

  defp walk(value, map) when is_map(value), do: Map.new(value, fn {k, v} -> {k, walk(v, map)} end)
  defp walk(value, map) when is_list(value), do: Enum.map(value, &walk(&1, map))
  defp walk(value, map) when is_binary(value), do: Map.get(map, value, value)
  defp walk(value, _map), do: value
end
