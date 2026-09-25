defmodule BubbleEx.Index.DataModel do
  @moduledoc false

  # Data types, fields, option sets (values, attributes) and API Connector
  # groups/calls, plus the `:field_type` edges from typed fields, all read
  # from `BubbleEx.Model` (either key form; the Model reads the JSON).

  alias BubbleEx.Expression.Vocabulary
  alias BubbleEx.Index.{Reference, Symbol, Types}
  alias BubbleEx.Model
  alias BubbleEx.Model.{Connector, DataType, Field, OptionSet, OptionValue}

  @builtins ["_id", "Created By", "Created Date", "Modified Date", "Slug"]

  @spec build(Model.t()) :: {[Symbol.t()], [Reference.t()]}
  def build(%Model{} = model) do
    parts = [
      model.data_types |> Enum.reject(& &1.synthesized) |> Enum.map(&data_type/1) |> merge(),
      model.option_sets |> Enum.map(&option_set/1) |> merge(),
      {Enum.flat_map(model.connectors, &connector/1), []}
    ]

    {Enum.flat_map(parts, &elem(&1, 0)), Enum.flat_map(parts, &elem(&1, 1))}
  end

  defp data_type(%DataType{} = type) do
    id = Symbol.id(:data_type, type.id)

    symbol = %Symbol{
      id: id,
      kind: :data_type,
      bubble_id: type.id,
      name: type.name,
      path: type.path,
      attrs: flags(type.deleted)
    }

    {fields, refs} =
      type.fields
      |> Enum.map(&typed(:field, [type.id, &1.id], &1, id))
      |> merge()

    {builtins, builtin_refs} =
      builtins(type.id, id, type.path, MapSet.new(fields, & &1.bubble_id))

    {[symbol | fields ++ builtins], refs ++ builtin_refs}
  end

  # Every data type has Bubble's built-in fields (and every User an email),
  # absent from exported field lists. They are symbols so reads of them (e.g.
  # `unique id`) are references like any other. Their path is the type's. A
  # defined field with a built-in's Bubble ID (even a deleted one) replaces
  # its symbol.
  defp builtins(key, parent, path, defined) do
    names = if key == "user", do: @builtins ++ ["email"], else: @builtins

    names
    |> Enum.reject(&MapSet.member?(defined, &1))
    |> Enum.map(fn name ->
      {kind, value_type} = Vocabulary.builtin_field(name) || {:email, "text"}
      id = Symbol.id(:field, [key, name])

      symbol = %Symbol{
        id: id,
        kind: :field,
        bubble_id: name,
        name: name,
        parent: parent,
        path: path,
        attrs: %{value_type: value_type, builtin: kind}
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
                path: path,
                attrs: %{list: false}
              }
            ]
        end

      {[symbol], refs}
    end)
    |> merge()
  end

  defp option_set(%OptionSet{} = set) do
    id = Symbol.id(:option_set, set.id)

    symbol = %Symbol{
      id: id,
      kind: :option_set,
      bubble_id: set.id,
      name: set.name,
      path: set.path,
      attrs: flags(set.deleted)
    }

    {attributes, refs} =
      set.attributes
      |> Enum.map(&typed(:option_attribute, [set.id, &1.id], &1, id))
      |> merge()

    values = Enum.map(set.values, &option_value(set.id, &1))
    {[symbol | attributes ++ values], refs}
  end

  defp option_value(set_id, %OptionValue{} = value) do
    %Symbol{
      id: Symbol.id(:option_value, [set_id, value.key]),
      kind: :option_value,
      bubble_id: value.key,
      name: value.name,
      parent: Symbol.id(:option_set, set_id),
      path: value.path,
      attrs:
        compact(%{
          key: value.id,
          sort_factor: value.sort_factor,
          deleted: if(value.deleted, do: true)
        })
    }
  end

  # A field of a data type or an attribute of an option set, with its
  # `:field_type` edge when the value type names another symbol.
  defp typed(kind, parts, %Field{} = field, parent) do
    value_type = if is_binary(field.type.source), do: field.type.source
    id = Symbol.id(kind, parts)

    symbol = %Symbol{
      id: id,
      kind: kind,
      bubble_id: field.id,
      name: field.name,
      parent: parent,
      path: field.path,
      attrs: compact(%{value_type: value_type, deleted: if(field.deleted, do: true)})
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
              path: field.path,
              attrs: Map.put(target.attrs, :list, target.list)
            }
          ]
      end

    {[symbol], refs}
  end

  defp connector(%Connector{} = connector) do
    id = Symbol.id(:api_group, connector.id)

    symbol = %Symbol{
      id: id,
      kind: :api_group,
      bubble_id: connector.id,
      name: connector.name,
      path: connector.path,
      attrs: compact(%{auth: connector.auth})
    }

    calls =
      for call <- connector.calls do
        %Symbol{
          id: Symbol.id(:api_call, [connector.id, call.id]),
          kind: :api_call,
          bubble_id: call.id,
          name: call.name,
          parent: id,
          path: call.path,
          attrs: compact(%{method: call.method, publish_as: call.publish_as})
        }
      end

    [symbol | calls]
  end

  defp merge(pairs), do: {Enum.flat_map(pairs, &elem(&1, 0)), Enum.flat_map(pairs, &elem(&1, 1))}

  defp flags(deleted), do: if(deleted, do: %{deleted: true}, else: %{})

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
