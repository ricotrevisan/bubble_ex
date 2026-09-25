defmodule BubbleEx.Index.DataModel do
  @moduledoc false

  # Data types, fields, option sets (values, attributes) and API Connector
  # groups/calls, plus the `:field_type` edges from typed fields. Reads both
  # key forms: `.bubble` exports (`display`, `fields`, `value`, `deleted`) and
  # the live payload (`%d`, `%f3`, `%v`, `%del`).

  alias BubbleEx.Index.{Reference, Symbol, Types}
  alias BubbleEx.Workflows.Source

  @spec build(map()) :: {[Symbol.t()], [Reference.t()]}
  def build(app) do
    parts = [
      data_types(Map.get(app, "user_types")),
      option_sets(Map.get(app, "option_sets")),
      api_connector(app)
    ]

    {Enum.flat_map(parts, &elem(&1, 0)), Enum.flat_map(parts, &elem(&1, 1))}
  end

  defp data_types(types) when is_map(types) do
    types
    |> entries()
    |> Enum.map(fn {key, type} -> data_type(key, type) end)
    |> merge()
  end

  defp data_types(_), do: {[], []}

  defp data_type(key, type) do
    id = Symbol.id(:data_type, key)
    path = ["user_types", key]

    symbol = %Symbol{
      id: id,
      kind: :data_type,
      bubble_id: key,
      name: text(type, ~w(display %d)),
      path: Source.pointer(path),
      attrs: flags(type)
    }

    {fields, refs} =
      type
      |> Source.get(~w(fields %f3))
      |> members(path, fn fkey, field, fpath ->
        typed(:field, [key, fkey], fkey, field, id, fpath)
      end)

    {[symbol | fields], refs}
  end

  defp option_sets(sets) when is_map(sets) do
    sets
    |> entries()
    |> Enum.map(fn {key, set} -> option_set(key, set) end)
    |> merge()
  end

  defp option_sets(_), do: {[], []}

  defp option_set(key, set) do
    id = Symbol.id(:option_set, key)
    path = ["option_sets", key]

    symbol = %Symbol{
      id: id,
      kind: :option_set,
      bubble_id: key,
      name: text(set, ~w(display %d)),
      path: Source.pointer(path),
      attrs: flags(set)
    }

    {attributes, refs} =
      set
      |> Source.get(["attributes"])
      |> members(path, fn akey, attr, apath ->
        typed(:option_attribute, [key, akey], akey, attr, id, apath)
      end)

    {values, _} =
      set
      |> Source.get(["values"])
      |> members(path, fn vkey, value, vpath -> {[option_value(key, vkey, value, vpath)], []} end)

    {[symbol | attributes ++ values], refs}
  end

  defp option_value(set_key, key, value, path) do
    db_value = text(value, ["db_value"]) || key

    %Symbol{
      id: Symbol.id(:option_value, [set_key, db_value]),
      kind: :option_value,
      bubble_id: db_value,
      name: text(value, ~w(display %d)),
      parent: Symbol.id(:option_set, set_key),
      path: Source.pointer(path),
      attrs:
        compact(%{
          key: key,
          sort_factor: if(is_map(value), do: value["sort_factor"]),
          deleted: deleted(value)
        })
    }
  end

  # A field of a data type or an attribute of an option set, with its
  # `:field_type` edge when the value type names another symbol.
  defp typed(kind, parts, key, field, parent, path) do
    value_type = text(field, ~w(value %v))
    id = Symbol.id(kind, parts)

    symbol = %Symbol{
      id: id,
      kind: kind,
      bubble_id: key,
      name: text(field, ~w(display %d)),
      parent: parent,
      path: Source.pointer(path),
      attrs: compact(%{value_type: value_type, deleted: deleted(field)})
    }

    refs =
      case Types.target(value_type) do
        nil ->
          []

        target ->
          [
            %Reference{
              from: id,
              to: target.id,
              kind: :field_type,
              path: Source.pointer(path),
              attrs: Map.put(target.attrs, :list, target.list)
            }
          ]
      end

    {[symbol], refs}
  end

  defp api_connector(app) do
    groups =
      with settings when is_map(settings) <- Map.get(app, "settings"),
           client_safe when is_map(client_safe) <- Map.get(settings, "client_safe"),
           groups when is_map(groups) <- Map.get(client_safe, "apiconnector2") do
        groups
      else
        _ -> %{}
      end

    path = ["settings", "client_safe", "apiconnector2"]

    groups
    |> entries()
    |> Enum.filter(fn {_, group} -> is_map(group) end)
    |> Enum.flat_map(fn {gkey, group} -> api_group(gkey, group, path ++ [gkey]) end)
    |> then(&{&1, []})
  end

  defp api_group(key, group, path) do
    id = Symbol.id(:api_group, key)

    symbol = %Symbol{
      id: id,
      kind: :api_group,
      bubble_id: key,
      name: text(group, ~w(human name)),
      path: Source.pointer(path),
      attrs: compact(%{auth: text(group, ["auth"])})
    }

    {calls, _} =
      group
      |> Source.get(["calls"])
      |> members(path, fn ckey, call, cpath -> {[api_call(key, ckey, call, cpath)], []} end)

    [symbol | calls]
  end

  defp api_call(group, key, call, path) do
    %Symbol{
      id: Symbol.id(:api_call, [group, key]),
      kind: :api_call,
      bubble_id: key,
      name: text(call, ["name"]),
      parent: Symbol.id(:api_group, group),
      path: Source.pointer(path),
      attrs: compact(%{method: text(call, ["method"]), publish_as: text(call, ["publish_as"])})
    }
  end

  # Entries of a `{key, members}` pair from `Source.get/2`; builds each with
  # `fun.(member_key, member, member_path)`.
  defp members({key, map}, path, fun) when is_map(map) do
    map
    |> entries()
    |> Enum.map(fn {mkey, member} -> fun.(mkey, member, path ++ [key, mkey]) end)
    |> merge()
  end

  defp members(_, _, _), do: {[], []}

  defp merge(pairs), do: {Enum.flat_map(pairs, &elem(&1, 0)), Enum.flat_map(pairs, &elem(&1, 1))}

  defp entries(map) when is_map(map),
    do: map |> Enum.filter(fn {k, _} -> is_binary(k) end) |> Enum.sort_by(&elem(&1, 0))

  defp flags(map), do: compact(%{deleted: deleted(map)})

  defp deleted(map) when is_map(map) do
    case Source.value(map, ~w(deleted %del)) do
      true -> true
      _ -> nil
    end
  end

  defp deleted(_), do: nil

  defp text(map, keys) when is_map(map) do
    case Source.value(map, keys) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp text(_, _), do: nil

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
