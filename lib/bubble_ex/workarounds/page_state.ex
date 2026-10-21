defmodule BubbleEx.Workarounds.PageState do
  @moduledoc """
  Which workaround elements (`BubbleEx.Workarounds`, WTF-586) are lowered
  to page state, from the applied decisions alone: the one answer the
  generator (`BubbleEx.Target.Phoenix`), the plan (`BubbleEx.Plan`) and
  decision checks (`BubbleEx.Decision.Params`) read. It depends on nothing
  but the applied entries, so the renderers stay off the Model.
  """

  @types ~w(Group FloatingGroup RepeatingGroup)

  @doc """
  The Bubble IDs of the elements lowered to page state by `applied`
  (`BubbleEx.Decision.Applied` entries of `:workaround_element` findings):
  option `:page_state`, a Group, Floating Group or Repeating Group, and
  every candidate it holds (`proposal.holds`) lowered too. Their contents
  are not rendered.
  """
  @spec lowered([map()]) :: MapSet.t(String.t())
  def lowered(applied) when is_list(applied) do
    chosen =
      for %{transform: :lower_workaround, proposal: %{option: :page_state} = p} <- applied,
          type?(Map.get(p, :type)),
          into: %{},
          do: {p.element, Map.get(p, :holds, [])}

    chosen
    |> settle()
    |> MapSet.new(fn "element:" <> id -> id end)
  end

  @doc "Whether an element of Bubble type `type` lowers to page state."
  @spec type?(term()) :: boolean()
  def type?(type), do: type in @types

  # Drops holders whose held candidates are not all lowered, until none.
  defp settle(chosen) do
    kept = Map.filter(chosen, fn {_, holds} -> Enum.all?(holds, &Map.has_key?(chosen, &1)) end)
    if map_size(kept) == map_size(chosen), do: Map.keys(kept), else: settle(kept)
  end
end
