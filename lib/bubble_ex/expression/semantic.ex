defmodule BubbleEx.Expression.Semantic do
  @moduledoc false

  # The canonical, stack-neutral form of an AST: plain JSON-able maps with a
  # "node" discriminator, no source-form `meta`. Two expressions with the same
  # semantics in different key spellings share this form (and its hash).

  alias BubbleEx.Expression.Ast
  alias BubbleEx.Expression.Ast.Constraint

  @spec to_map(Ast.t()) :: map()
  def to_map(%module{} = node) do
    node
    |> Map.from_struct()
    |> Map.delete(:meta)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), value(v)} end)
    |> Map.put("node", kind(module))
  end

  defp value(%Constraint{} = c),
    do:
      c
      |> Map.from_struct()
      |> Map.delete(:meta)
      |> Map.new(fn {k, v} -> {Atom.to_string(k), value(v)} end)

  defp value(%_{} = node), do: to_map(node)
  defp value(list) when is_list(list), do: Enum.map(list, &value/1)
  defp value(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)
  defp value(other), do: other

  @spec kind(module()) :: String.t()
  def kind(module), do: module |> Module.split() |> List.last() |> Macro.underscore()
end
