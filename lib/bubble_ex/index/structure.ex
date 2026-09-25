defmodule BubbleEx.Index.Structure do
  @moduledoc false

  # Pages, mobile views, reusable elements and their element trees, in either
  # key form (`pages`/`%p3`, `element_definitions`/`%ed`, `elements`/`%el`,
  # `id`/`%id`, `type`/`%x`, `properties`/`%p`). Also returns what later passes
  # need: the owner symbol of each owner key, and each definition's own JSON
  # (children removed) for expression scanning.

  alias BubbleEx.Index.{Reference, Symbol}
  alias BubbleEx.Workflows.Source

  @owners [
    {~w(pages %p3), :page},
    {["mobile_views"], :page},
    {~w(element_definitions %ed), :reusable}
  ]
  @children ~w(elements %el workflows %wf)

  @type host :: %{symbol: Symbol.id(), value: map(), path: list()}
  @type t :: %{
          symbols: [Symbol.t()],
          references: [Reference.t()],
          owners: %{{String.t(), String.t()} => Symbol.id()},
          hosts: [host()],
          bubble_ids: %{String.t() => Symbol.id()}
        }

  @spec build(map()) :: t()
  def build(app) do
    nodes =
      for {sections, kind} <- @owners,
          section <- sections,
          owners = Map.get(app, section),
          is_map(owners),
          {key, owner} <- entries(owners),
          is_map(owner),
          node <- owner(section, key, owner, kind),
          do: node

    by_bubble_id = Map.new(nodes, &{&1.symbol.bubble_id, &1.symbol.id})

    reusables =
      for %{symbol: %{kind: :reusable} = s} <- nodes, into: %{}, do: {s.bubble_id, s.id}

    %{
      symbols: Enum.map(nodes, & &1.symbol),
      references: Enum.flat_map(nodes, &instance_of(&1, reusables)),
      owners: for(%{owner_key: {_, _} = k, symbol: s} <- nodes, into: %{}, do: {k, s.id}),
      hosts: Enum.map(nodes, &%{symbol: &1.symbol.id, value: &1.own, path: &1.path}),
      bubble_ids: by_bubble_id
    }
  end

  defp owner(section, key, owner, kind) do
    path = [section, key]
    id = Symbol.id(kind, bubble_id(owner, key))

    root = %{
      symbol: %Symbol{
        id: id,
        kind: kind,
        bubble_id: bubble_id(owner, key),
        name: name(owner),
        path: Source.pointer(path),
        attrs: compact(%{section: section, type: type(owner)})
      },
      owner_key: {section, key},
      own: Map.drop(owner, @children),
      path: path,
      custom: nil
    }

    [root | elements(owner, path, id)]
  end

  defp elements(node, path, parent) do
    case Source.get(node, ~w(elements %el)) do
      {ekey, children} when is_map(children) ->
        for {key, child} <- entries(children),
            is_map(child),
            n <- element(key, child, path ++ [ekey, key], parent),
            do: n

      _ ->
        []
    end
  end

  defp element(key, element, path, parent) do
    id = Symbol.id(:element, bubble_id(element, key))

    node = %{
      symbol: %Symbol{
        id: id,
        kind: :element,
        bubble_id: bubble_id(element, key),
        name: name(element),
        parent: parent,
        path: Source.pointer(path),
        attrs: compact(%{type: type(element)})
      },
      owner_key: nil,
      own: Map.drop(element, @children),
      path: path,
      custom: custom(element, path)
    }

    [node | elements(element, path, id)]
  end

  # A reusable element instance names its definition in `custom_id`.
  defp custom(element, path) do
    case Source.get(element, ~w(properties %p)) do
      {pkey, %{"custom_id" => id}} when is_binary(id) -> {id, path ++ [pkey, "custom_id"]}
      _ -> nil
    end
  end

  defp instance_of(%{custom: nil}, _), do: []

  defp instance_of(%{custom: {custom_id, path}, symbol: symbol}, reusables) do
    [
      %Reference{
        from: symbol.id,
        to: Map.get(reusables, custom_id, Symbol.id(:reusable, custom_id)),
        kind: :instance_of,
        path: Source.pointer(path)
      }
    ]
  end

  defp bubble_id(node, key) do
    case Source.value(node, ~w(id %id)) do
      id when is_binary(id) and id != "" -> id
      _ -> key
    end
  end

  defp name(node) do
    case Source.value(node, ~w(name %nm default_name)) do
      name when is_binary(name) -> name
      _ -> nil
    end
  end

  defp type(node) do
    case Source.value(node, ~w(type %x)) do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp entries(map),
    do: map |> Enum.filter(fn {k, _} -> is_binary(k) end) |> Enum.sort_by(&elem(&1, 0))

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
