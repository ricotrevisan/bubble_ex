defmodule BubbleEx.Frontend.StaticGroupData do
  @moduledoc false

  alias BubbleEx.Frontend.StaticExpression
  alias BubbleEx.Frontend.Normalized.Node

  @spec expand([Node.t()]) :: [Node.t()]
  def expand(nodes), do: Enum.map(nodes, &project/1)

  @spec project(Node.t(), term()) :: Node.t()
  def project(node, parent \\ :unknown) do
    content =
      Map.new(node.content || %{}, fn {slot, value} ->
        {slot, resolve(value, node.bindings[slot], parent)}
      end)

    data = group_data(content, node.kind, parent)
    %{node | content: content, children: Enum.map(node.children, &project(&1, data))}
  end

  defp group_data(content, kind, parent) do
    case content["data_source"] do
      %{data_type: type, resolved: value} -> typed_value(type, value)
      %{data_type: type} when kind == :reusable_definition -> typed_value(type, parent)
      _ -> :unknown
    end
  end

  defp typed_value("text", value) when is_binary(value), do: value
  defp typed_value("number", value) when is_number(value), do: value
  defp typed_value(_type, _value), do: :unknown

  defp resolve(content, nil, _parent), do: content

  defp resolve(content, binding, parent) do
    case StaticExpression.resolve(binding.payload, parent) do
      {:ok, value} when is_binary(value) or is_number(value) -> Map.put(content, :resolved, value)
      _ -> content
    end
  end
end
