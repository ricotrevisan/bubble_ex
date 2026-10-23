defmodule BubbleEx.Workarounds.Skip do
  @moduledoc """
  Which unused workaround elements (`BubbleEx.Workarounds`, WTF-606) are
  not generated, from the applied decisions alone, as
  `BubbleEx.Workarounds.PageState` does for page state: the generator
  (`BubbleEx.Target.Phoenix`) and the plan (`BubbleEx.Plan`) read it.
  """

  @doc """
  The Bubble IDs of the elements skipped by `applied`
  (`BubbleEx.Decision.Applied` entries of `:workaround_element` findings):
  option `:skip`, with every candidate it holds (`proposal.holds`) and the
  unused candidate holding it (`proposal.inside`), if any, skipped too. An
  owner's `keep` or `reject` on any element of a nest of unused elements
  so keeps the whole nest. The elements and their contents are not
  generated.
  """
  @spec skipped([map()]) :: MapSet.t(String.t())
  def skipped(applied) when is_list(applied) do
    chosen =
      for %{transform: :lower_workaround, proposal: %{option: :skip} = p} <- applied,
          into: %{},
          do: {p.element, Map.get(p, :holds, []) ++ List.wrap(Map.get(p, :inside))}

    chosen
    |> settle()
    |> MapSet.new(fn "element:" <> id -> id end)
  end

  # Drops elements whose nest is not all skipped, until none.
  defp settle(chosen) do
    kept = Map.filter(chosen, fn {_, nest} -> Enum.all?(nest, &Map.has_key?(chosen, &1)) end)
    if map_size(kept) == map_size(chosen), do: Map.keys(kept), else: settle(kept)
  end
end
