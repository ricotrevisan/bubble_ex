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
      |> Enum.filter(fn {key, slot} ->
        String.starts_with?(key, "param_") and Map.has_key?(slot, :resolved)
      end)
      |> Map.new(fn {key, slot} -> {key, slot[:resolved]} end)

    scope = Map.new([definition.map_key, definition.source.bubble_id], &{&1, parameters})
    project(definition, instance.exporter_id, scope)
  end

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

  defp project_content(content, binding, scope) do
    updated = Map.put(content, :binding_id, binding.id)

    case StaticExpression.resolve(binding.payload, :unknown, scope) do
      {:ok, resolved} when is_binary(resolved) or is_number(resolved) or is_boolean(resolved) ->
        Map.put(updated, :resolved, resolved)

      _ ->
        updated
    end
  end
end
