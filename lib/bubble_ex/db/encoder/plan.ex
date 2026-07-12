defmodule BubbleEx.Db.Encoder.Plan do
  @moduledoc false

  @type edge_key :: {String.t(), String.t()}
  @type t :: %{
          nodes: %{String.t() => map()},
          names: %{String.t() => String.t()},
          field_names: %{{String.t(), String.t()} => String.t()},
          order: [String.t()],
          cycle_edges: MapSet.t(edge_key()),
          edge_occurrences: %{edge_key() => [map()]}
        }

  @spec build(map(), keyword()) :: t()
  def build(db_map, opts \\ []) do
    nodes =
      db_map
      |> Map.get(:external_types, [])
      |> Enum.filter(&(&1.resolution == :resolved and &1.fields != []))
      |> Map.new(&{&1.id, sort_fields(&1)})

    ids = nodes |> Map.keys() |> Enum.sort()
    names = collision_safe_names(nodes, opts)
    field_names = collision_safe_field_names(nodes, opts)

    {order, cycle_edges, _visited} =
      Enum.reduce(ids, {[], MapSet.new(), MapSet.new()}, &visit(&1, nodes, &2, MapSet.new()))

    edge_occurrences = collect_occurrences(db_map, nodes)

    %{
      nodes: nodes,
      names: names,
      field_names: field_names,
      order: Enum.reverse(order),
      cycle_edges: cycle_edges,
      edge_occurrences: edge_occurrences
    }
  end

  @spec resolved?(t(), String.t()) :: boolean()
  def resolved?(plan, id), do: Map.has_key?(plan.nodes, id)

  @spec name(t(), String.t()) :: String.t()
  def name(plan, id), do: Map.get(plan.names, id, base_name(id))

  @spec field_name(t(), String.t(), map()) :: String.t()
  def field_name(plan, parent, field),
    do: Map.get(plan.field_names, {parent, field.id}, Map.get(field, :caption) || field.id)

  @spec cycle_edge?(t(), String.t(), String.t()) :: boolean()
  def cycle_edge?(plan, parent, field_id),
    do: MapSet.member?(plan.cycle_edges, {parent, field_id})

  @spec occurrences(t(), String.t(), String.t()) :: [map()]
  def occurrences(plan, parent, field_id),
    do: Map.get(plan.edge_occurrences, {parent, field_id}, [])

  defp visit(id, nodes, {order, cycles, visited}, active) do
    if MapSet.member?(visited, id) do
      {order, cycles, visited}
    else
      do_visit(id, nodes, {order, cycles, visited}, active)
    end
  end

  defp do_visit(id, nodes, {order, cycles, visited}, active) do
    active = MapSet.put(active, id)

    {order, cycles, visited} =
      nodes[id].fields
      |> Enum.filter(&(&1.type.type == :external))
      |> Enum.reduce({order, cycles, visited}, fn field, acc ->
        target = field.type.target

        cond do
          not Map.has_key?(nodes, target) ->
            acc

          MapSet.member?(active, target) ->
            put_elem(acc, 1, MapSet.put(elem(acc, 1), {id, field.id}))

          true ->
            visit(target, nodes, acc, active)
        end
      end)

    {[id | order], cycles, MapSet.put(visited, id)}
  end

  defp sort_fields(node) do
    %{node | fields: Enum.sort_by(node.fields, &{Map.get(&1, :path) || ["\uffff"], &1.id})}
  end

  defp collision_safe_names(nodes, opts) do
    nodes
    |> Map.keys()
    |> Enum.group_by(&type_candidate(nodes[&1], opts))
    |> Enum.flat_map(fn {base, grouped} ->
      Enum.map(grouped, fn id ->
        {id, if(length(grouped) == 1, do: base, else: "#{base}_#{raw_suffix(id)}")}
      end)
    end)
    |> Map.new()
  end

  defp collision_safe_field_names(nodes, opts) do
    nodes
    |> Enum.flat_map(fn {parent, node} ->
      node.fields
      |> Enum.group_by(&normalized_field_name(&1, opts))
      |> Enum.flat_map(fn {_normalized, fields} -> allocate_field_group(parent, fields, opts) end)
    end)
    |> Map.new()
  end

  defp allocate_field_group(parent, fields, opts) do
    Enum.map(fields, fn field ->
      base = field_candidate(field, opts)
      name = if length(fields) == 1, do: base, else: "#{base}_#{raw_suffix(field.id)}"
      {{parent, field.id}, name}
    end)
  end

  defp normalized_field_name(field, opts) do
    field_candidate(field, opts)
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "")
  end

  defp type_candidate(node, opts) do
    source =
      if Keyword.get(opts, :naming, :proper) == :proper,
        do: Map.get(node, :caption) || node.id,
        else: node.id

    base_name(source)
  end

  defp field_candidate(field, opts) do
    if Keyword.get(opts, :naming, :proper) == :proper,
      do: Map.get(field, :caption) || field.id,
      else: field.id
  end

  defp raw_suffix(value), do: value

  defp collect_occurrences(db_map, nodes) do
    db_map
    |> Map.get(:tables, [])
    |> Enum.flat_map(fn table -> Enum.map(table.columns, &{table, &1}) end)
    |> Enum.filter(fn {_table, column} -> column.type.type == :external end)
    |> Enum.reduce(%{}, fn {table, column}, acc ->
      root = %{table_group: table.group, table_id: table.id, field_id: column.id}
      collect_node_occurrences(column.type.target, root, [], nodes, MapSet.new(), acc)
    end)
    |> Map.new(fn {key, values} -> {key, Enum.sort_by(Enum.uniq(values), &inspect/1)} end)
  end

  defp collect_node_occurrences(id, root, path, nodes, visited, acc) do
    if MapSet.member?(visited, id) or not Map.has_key?(nodes, id) do
      acc
    else
      visited = MapSet.put(visited, id)

      Enum.reduce(
        nodes[id].fields,
        acc,
        &collect_field_occurrence(&1, &2, id, root, path, nodes, visited)
      )
    end
  end

  defp collect_field_occurrence(
         %{type: %{type: :external}} = field,
         acc,
         id,
         root,
         path,
         nodes,
         visited
       ) do
    step = %{external_type_id: id, field_id: field.id, source_path: Map.get(field, :path)}
    occurrence = %{root: root, path: path ++ [step]}
    acc = Map.update(acc, {id, field.id}, [occurrence], &[occurrence | &1])
    collect_node_occurrences(field.type.target, root, occurrence.path, nodes, visited, acc)
  end

  defp collect_field_occurrence(_field, acc, _id, _root, _path, _nodes, _visited), do: acc

  defp base_name(id) do
    id
    |> String.split(".")
    |> List.last()
    |> String.replace(~r/[^A-Za-z0-9]+/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map_join("", &capitalize_word/1)
    |> case do
      "" -> "ExternalType"
      <<first, _::binary>> = name when first in ?0..?9 -> "Type" <> name
      name -> name
    end
  end

  defp capitalize_word(<<first::utf8, rest::binary>>),
    do: String.upcase(<<first::utf8>>) <> rest
end
