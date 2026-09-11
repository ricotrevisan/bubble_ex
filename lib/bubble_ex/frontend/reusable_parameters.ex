defmodule BubbleEx.Frontend.ReusableParameters do
  @moduledoc false

  alias BubbleEx.Frontend.{Naming, StaticExpression}
  alias BubbleEx.Frontend.Normalized.Node

  @spec expand(Node.t() | nil, Node.t()) :: Node.t() | nil
  def expand(nil, _instance), do: nil

  def expand(definition, instance) do
    parameters =
      instance.content
      |> Kernel.||(%{})
      |> Enum.filter(fn {key, _slot} -> String.starts_with?(key, "param_") end)
      |> Enum.flat_map(fn {key, slot} -> parameter(key, slot, instance.bindings[key]) end)
      |> Map.new()

    scope = Map.new([definition.map_key, definition.source.bubble_id], &{&1, parameters})

    definition
    |> project(instance.exporter_id, scope)
    |> BubbleEx.Frontend.StaticGroupData.project(
      get_in(instance.content || %{}, ["data_source", :resolved]) || :unknown
    )
  end

  defp parameter(key, %{resolved: value}, _binding), do: [{key, value}]
  defp parameter(key, %{geometry: value}, _binding), do: [{key, value}]

  defp parameter(key, _slot, %{payload: expression}) do
    case BubbleEx.Frontend.GeometryStyles.resolve(expression) do
      {:ok, value} -> [{key, value}]
      _ -> []
    end
  end

  defp parameter(_key, _slot, _binding), do: []

  defp project(node, prefix, scope) do
    id = if node.kind == :reusable_definition, do: prefix, else: Naming.expanded_id(prefix, node)

    bindings =
      Map.new(node.bindings, fn {slot, binding} ->
        {slot,
         %{binding | id: id <> " :: " <> slot, source: Map.put(binding.source, :exporter_id, id)}}
      end)

    content =
      Map.new(node.content || %{}, fn {slot, content} ->
        {slot, project_content(content, bindings[slot], scope)}
      end)

    %{
      node
      | exporter_id: id,
        content: content,
        bindings: bindings,
        children: Enum.map(node.children, &project(&1, prefix, scope))
    }
  end

  defp project_content(content, nil, _scope), do: content

  defp project_content(content, %{slot: "html_style"} = binding, scope) do
    content
    |> Map.put(:binding_id, binding.id)
    |> BubbleEx.Frontend.GeometryStyles.project(binding, scope)
  end

  defp project_content(content, binding, scope) do
    updated = Map.put(content, :binding_id, binding.id)

    case StaticExpression.resolve(binding.payload, :unknown, scope) do
      {:ok, resolved} when is_binary(resolved) or is_number(resolved) or is_boolean(resolved) ->
        Map.put(updated, :resolved, resolved)

      _ ->
        BubbleEx.Frontend.GeometryStyles.project(updated, binding, scope)
    end
  end
end
