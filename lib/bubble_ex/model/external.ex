defmodule BubbleEx.Model.External do
  @moduledoc false

  # API Connector types for the Model: runs `BubbleEx.Model.External.Resolver`
  # over every `api.` field and attribute, deleted ones included (the Model
  # keeps them), converts its nodes into Model structs and marks the edges
  # that close cycles.

  alias BubbleEx.Model.{DataType, ExternalField, ExternalType, OptionSet, Type}
  alias BubbleEx.Model.External.Resolver

  @spec resolve([DataType.t()], [OptionSet.t()], map(), [BubbleEx.Model.Connector.t()]) ::
          {[DataType.t()], [OptionSet.t()], [ExternalType.t()], [BubbleEx.Diagnostic.t()]}
  def resolve(data_types, option_sets, app, connectors) do
    roots =
      Enum.flat_map(data_types, &roots(:custom, &1.id, &1.fields)) ++
        Enum.flat_map(option_sets, &roots(:option, &1.id, &1.attributes))

    {values, nodes, diagnostics} = Resolver.resolve(roots, resolver_source(app), connectors)

    external_types = nodes |> Enum.map(&external_type/1) |> mark_cycles()
    known = for t <- external_types, ExternalType.known?(t), into: MapSet.new(), do: t.id
    types = Map.new(values, fn {key, value} -> {key, convert(value, known)} end)

    data_types =
      Enum.map(data_types, fn t ->
        %{t | fields: Enum.map(t.fields, &patch(&1, types[{:custom, t.id, &1.id}]))}
      end)

    option_sets =
      Enum.map(option_sets, fn s ->
        %{s | attributes: Enum.map(s.attributes, &patch(&1, types[{:option, s.id, &1.id}]))}
      end)

    {data_types, option_sets, external_types, diagnostics}
  end

  defp roots(group, owner, fields) do
    for %{type: %Type{kind: :external, source: source}} = field <- fields do
      %{group: group, owner: owner, field: field.id, descriptor: source}
    end
  end

  defp patch(field, nil), do: field

  # The `list.` prefix is Bubble's own, so the field's cardinality is certain
  # even when the resolver cannot tell it (`:unknown` for an invalid `api.`
  # descriptor).
  defp patch(field, type), do: %{field | type: %{type | cardinality: field.type.cardinality}}

  # The resolver reads only these members (to point diagnostics at field
  # descriptors); everything else is left out so a malformed section
  # elsewhere in the app cannot reach it. API Connector calls come from the
  # Model's connectors.
  defp resolver_source(app) do
    %{
      "user_types" => objects(Map.get(app, "user_types")),
      "option_sets" => objects(Map.get(app, "option_sets"))
    }
  end

  defp objects(map) when is_map(map), do: Map.filter(map, fn {_, v} -> is_map(v) end)
  defp objects(_), do: %{}

  defp external_type(node) do
    %ExternalType{
      id: node.id,
      name: node.caption,
      connector: node.provenance.connector_id,
      call: node.provenance.call_id,
      resolution: node.resolution,
      path: node.source_path,
      fields:
        Enum.map(node.fields, fn f ->
          %ExternalField{
            id: f.id,
            name: if(is_binary(f.caption), do: f.caption),
            response_path: f.path,
            type: convert(f.type, nil)
          }
        end)
    }
  end

  defp convert(%{type: :scalar} = v, _known),
    do: %Type{kind: :scalar, base: v.scalar, cardinality: v.cardinality, source: v.raw}

  defp convert(%{type: :external} = v, known),
    do: %Type{
      kind: :external,
      target: v.target,
      resolved: if(known, do: MapSet.member?(known, v.target)),
      cardinality: v.cardinality,
      source: v.raw
    }

  defp convert(%{type: :opaque_external} = v, _known),
    do: %Type{kind: :opaque, cardinality: v.cardinality, source: v.raw}

  # Nested field types are converted before the set of known types exists;
  # resolve them now, then mark the edges that close a cycle. Depth-first
  # from each type in Bubble ID order, fields in order.
  defp mark_cycles(types) do
    known = for t <- types, ExternalType.known?(t), into: MapSet.new(), do: t.id

    types =
      Enum.map(types, fn t ->
        %{t | fields: Enum.map(t.fields, &resolve_nested(&1, known))}
      end)

    by_id = Map.new(types, &{&1.id, &1})

    {cuts, _visited} =
      types
      |> Enum.map(& &1.id)
      |> Enum.sort()
      |> Enum.reduce({MapSet.new(), MapSet.new()}, &visit(&1, by_id, &2, MapSet.new()))

    Enum.map(types, fn t ->
      %{t | fields: Enum.map(t.fields, &%{&1 | cycle: MapSet.member?(cuts, {t.id, &1.id})})}
    end)
  end

  defp resolve_nested(%ExternalField{type: %Type{kind: :external} = type} = f, known),
    do: %{f | type: %{type | resolved: MapSet.member?(known, type.target)}}

  defp resolve_nested(f, _known), do: f

  defp visit(id, by_id, {cuts, visited}, active) do
    if MapSet.member?(visited, id) or not Map.has_key?(by_id, id) do
      {cuts, visited}
    else
      active = MapSet.put(active, id)

      {cuts, visited} =
        by_id[id].fields
        |> Enum.filter(&(&1.type.kind == :external))
        |> Enum.reduce({cuts, visited}, &follow(&1, id, by_id, &2, active))

      {cuts, MapSet.put(visited, id)}
    end
  end

  # An edge back into the active path closes a cycle: cut it.
  defp follow(field, from, by_id, {cuts, visited}, active) do
    if MapSet.member?(active, field.type.target),
      do: {MapSet.put(cuts, {from, field.id}), visited},
      else: visit(field.type.target, by_id, {cuts, visited}, active)
  end
end
