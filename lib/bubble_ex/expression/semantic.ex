defmodule BubbleEx.Expression.Semantic do
  @moduledoc false

  # The canonical, stack-neutral form of an AST: plain JSON-able maps with a
  # "node" discriminator. It identifies what the expression says, so it omits
  # everything that can change without changing that:
  #
  #   * `meta` (key spelling, editor metadata);
  #   * `display` captions and inferred `type`s, which come from the schema
  #     and change when a field is renamed or retyped, not when the expression
  #     does (field IDs stay in the form);
  #   * compact key spellings inside verbatim payloads (`Raw.raw`, `Scope.ref`,
  #     `options`), rewritten to readable keys via `Keys.normalize/1`; compact
  #     keys outside the alias table remain as supplied;
  #   * integral floats, written as integers: Bubble JSON comes from
  #     JavaScript, which has a single number type, so `1` and `1.0` are the
  #     same value.

  alias BubbleEx.Expression.{Ast, Keys}
  alias BubbleEx.Expression.Ast.Constraint

  @omitted [:meta, :display, :type]

  @spec to_map(Ast.t()) :: map()
  def to_map(%module{} = node), do: node |> fields() |> Map.put("node", kind(module))

  defp fields(struct) do
    struct
    |> Map.from_struct()
    |> Map.drop(@omitted)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), value(v)} end)
  end

  defp value(%Constraint{} = c), do: fields(c)
  defp value(%_{} = node), do: to_map(node)
  defp value(list) when is_list(list), do: Enum.map(list, &value/1)
  defp value(map) when is_map(map), do: map |> Keys.normalize() |> numbers()
  defp value(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)
  defp value(other), do: numbers(other)

  defp numbers(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, numbers(v)} end)
  defp numbers(list) when is_list(list), do: Enum.map(list, &numbers/1)
  defp numbers(float) when is_float(float) and float == trunc(float), do: trunc(float)
  defp numbers(other), do: other

  @spec kind(module()) :: String.t()
  def kind(module), do: module |> Module.split() |> List.last() |> Macro.underscore()
end
