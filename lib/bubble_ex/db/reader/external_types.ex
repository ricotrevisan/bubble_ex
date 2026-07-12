defmodule BubbleEx.Db.Reader.ExternalTypes do
  @moduledoc false

  @prefix "api.apiconnector2."
  @scalars %{
    "text" => :text,
    "number" => :number,
    "boolean" => :boolean,
    "date" => :date,
    "date_unix" => :date_unix
  }

  @spec resolve([BubbleEx.Db.Reader.table()], map()) ::
          {[BubbleEx.Db.Reader.table()], [map()], [map()]}
  def resolve(tables, attrs) do
    state = %{attrs: attrs, nodes: %{}, failures: %{}, warnings: %{}}

    {tables, state} =
      Enum.map_reduce(tables, state, fn table, state ->
        {columns, state} = Enum.map_reduce(table.columns, state, &resolve_column(&1, &2))
        {%{table | columns: columns}, state}
      end)

    nodes = state.nodes |> Map.values() |> Enum.sort_by(& &1.id)

    warnings =
      state.warnings
      |> Map.values()
      |> Enum.map(&sort_occurrences/1)
      |> Enum.sort_by(&warning_key/1)

    {tables, nodes, warnings}
  end

  defp resolve_column(%{type: %{type: :api} = old} = column, state) do
    raw = raw_descriptor(old)
    root = %{table_group: column.table_group, table_id: column.table_id, field_id: column.id}
    occurrence = %{root: root, path: []}
    {type, state} = resolve_value(raw, occurrence, state)
    {%{column | type: type}, state}
  end

  defp resolve_column(column, state), do: {column, state}

  defp raw_descriptor(old) do
    prefix = if old[:is_array], do: "list.api.", else: "api."
    prefix <> to_string(old[:custom_type] || "")
  end

  defp resolve_value(raw, occurrence, state) when is_binary(raw) do
    {descriptor, cardinality} = strip_list(raw)

    cond do
      scalar = @scalars[descriptor] ->
        {%{type: :scalar, scalar: scalar, cardinality: cardinality, raw: raw}, state}

      valid_external?(descriptor) ->
        type = %{type: :external, target: descriptor, cardinality: cardinality, raw: raw}
        {type, ensure_node(descriptor, occurrence, state)}

      String.starts_with?(descriptor, "api.") ->
        type = %{type: :opaque_external, target: nil, cardinality: :unknown, raw: raw}
        {type, warn(state, :invalid_descriptor, raw_target(raw), occurrence)}

      true ->
        type = %{type: :opaque_external, target: nil, cardinality: cardinality, raw: raw}
        {type, warn(state, :field_type_unsupported, raw_target(raw), occurrence)}
    end
  end

  defp resolve_value(raw, occurrence, state) do
    type = %{type: :opaque_external, target: nil, cardinality: :unknown, raw: raw}
    {type, warn(state, :field_type_malformed, raw_target(raw), occurrence)}
  end

  defp ensure_node(id, occurrence, %{nodes: nodes} = state) when is_map_key(nodes, id) do
    case state.failures[id] do
      nil ->
        state

      category ->
        warn(state, category, external_target(id), occurrence)
    end
  end

  defp ensure_node(id, occurrence, state) do
    {connector_id, call_id} = identity_parts(id)
    provenance = %{connector_id: connector_id, call_id: call_id}
    placeholder = %{id: id, caption: nil, provenance: provenance, resolution: :opaque, fields: []}
    state = put_in(state.nodes[id], placeholder)

    if conflicting_definition?(state.attrs, id) do
      node = %{placeholder | resolution: :conflicted}

      state
      |> put_in([:nodes, id], node)
      |> fail_node(id, :conflicting_duplicate_definition, occurrence)
    else
      resolve_registry_node(state, id, connector_id, call_id, occurrence)
    end
  end

  defp resolve_registry_node(state, id, connector_id, call_id, occurrence) do
    case registry_for(state.attrs, connector_id, call_id) do
      {:error, category} -> fail_node(state, id, category, occurrence)
      {:ok, call, registry} -> resolve_registry_definition(state, id, call, registry, occurrence)
    end
  end

  defp resolve_registry_definition(state, id, call, registry, occurrence) do
    case Map.fetch(registry, id) do
      {:ok, definition} when is_map(definition) ->
        resolve_definition(id, definition, call, occurrence, state)

      _ ->
        fail_node(state, id, :exact_type_definition_missing, occurrence)
    end
  end

  defp resolve_definition(id, definition, call, occurrence, state) do
    fields = Map.get(definition, "fields")

    cond do
      not is_map(fields) ->
        fail_node(state, id, :exact_type_definition_missing, occurrence)

      map_size(fields) == 0 ->
        node = %{state.nodes[id] | caption: definition["caption"], resolution: :resolved_empty}

        state
        |> put_in([:nodes, id], node)
        |> warn(:empty_definition, external_target(id), occurrence)

      true ->
        {resolved_fields, state} = resolve_fields(id, fields, occurrence, state)

        node = %{
          state.nodes[id]
          | caption: definition["caption"],
            resolution: :resolved,
            fields: resolved_fields
        }

        state = put_in(state.nodes[id], node)
        advisory_warning(id, call, occurrence, state)
    end
  end

  defp resolve_fields(parent_id, fields, root_occurrence, state) do
    fields
    |> Enum.reject(fn {id, _} -> id == "_ignore" end)
    |> Enum.sort_by(fn {id, data} ->
      {if(is_list(data["path"]), do: data["path"], else: ["\uffff"]), id}
    end)
    |> Enum.map_reduce(state, fn {field_id, data}, state ->
      path = root_occurrence.path ++ [%{external_type_id: parent_id, field_id: field_id}]
      occurrence = %{root_occurrence | path: path}
      {raw, state} = field_descriptor(data, occurrence, state)
      {type, state} = resolve_value(raw, occurrence, state)

      state =
        if is_binary(data["caption"]) and is_list(data["path"]),
          do: state,
          else: warn(state, :incomplete_field_metadata, external_target(parent_id), occurrence)

      {%{id: field_id, caption: data["caption"], path: data["path"], type: type}, state}
    end)
  end

  defp field_descriptor(data, occurrence, state) when is_map(data) do
    values = [data["ret_btype"], data["ret_value"]] |> Enum.filter(&is_binary/1)

    case values do
      [raw] -> {raw, state}
      _ -> {nil, warn(state, :field_type_malformed, raw_target(nil), occurrence)}
    end
  end

  defp field_descriptor(_, occurrence, state),
    do: {nil, warn(state, :field_type_malformed, raw_target(nil), occurrence)}

  defp registry_for(attrs, connector_id, call_id) do
    connectors = get_in(attrs, ["settings", "client_safe", "apiconnector2"])
    fetch_connector(connectors, connector_id, call_id)
  end

  defp fetch_connector(connectors, _connector_id, _call_id) when not is_map(connectors),
    do: {:error, :connector_missing}

  defp fetch_connector(connectors, connector_id, call_id) do
    case Map.fetch(connectors, connector_id) do
      {:ok, connector} when is_map(connector) -> fetch_registry(connector, call_id)
      _ -> {:error, :connector_missing}
    end
  end

  defp fetch_registry(connector, call_id) do
    with {:ok, call} when is_map(call) <- fetch_call(connector, call_id),
         types when is_binary(types) and byte_size(types) > 0 <- call["types"] do
      decode_registry(call, types)
    else
      :error -> {:error, :call_missing}
      nil -> {:error, :registry_unavailable}
      "" -> {:error, :registry_unavailable}
      _ -> {:error, :registry_malformed}
    end
  end

  defp decode_registry(call, types) do
    case Jason.decode(types) do
      {:ok, registry} when is_map(registry) -> {:ok, call, registry}
      _ -> {:error, :registry_malformed}
    end
  end

  defp fetch_call(connector, call_id) do
    case Map.fetch(connector, call_id) do
      :error -> fetch_nested_call(connector["calls"], call_id)
      result -> result
    end
  end

  defp fetch_nested_call(calls, call_id) when is_map(calls), do: Map.fetch(calls, call_id)
  defp fetch_nested_call(_, _), do: :error

  defp conflicting_definition?(attrs, id) do
    attrs
    |> get_in(["settings", "client_safe", "apiconnector2"])
    |> all_calls()
    |> Enum.flat_map(fn call ->
      with types when is_binary(types) <- call["types"],
           {:ok, registry} when is_map(registry) <- Jason.decode(types),
           {:ok, definition} <- Map.fetch(registry, id) do
        [definition]
      else
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> length()
    |> Kernel.>(1)
  end

  defp all_calls(connectors) when is_map(connectors) do
    connectors
    |> Map.values()
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(fn connector ->
      direct = connector |> Map.delete("calls") |> Map.values()
      nested = if is_map(connector["calls"]), do: Map.values(connector["calls"]), else: []
      Enum.filter(direct ++ nested, &is_map/1)
    end)
  end

  defp all_calls(_), do: []

  defp advisory_warning(id, call, occurrence, state) do
    case call["ret_value"] do
      ^id -> state
      _ -> warn(state, :call_metadata_inconsistent, external_target(id), occurrence)
    end
  end

  defp strip_list("list." <> descriptor), do: {descriptor, :many}
  defp strip_list(descriptor), do: {descriptor, :one}

  defp valid_external?(@prefix <> rest), do: length(String.split(rest, ".")) >= 3
  defp valid_external?(_), do: false

  defp identity_parts(@prefix <> rest) do
    [connector_id, call_id | _] = String.split(rest, ".")
    {connector_id, call_id}
  end

  defp external_target(id), do: %{type: :external_type, id: id}
  defp raw_target(raw), do: %{type: :raw_descriptor, raw: raw}

  defp fail_node(state, id, category, occurrence) do
    state
    |> put_in([:failures, id], category)
    |> warn(category, external_target(id), occurrence)
  end

  defp warn(state, category, target, occurrence) do
    key = {category, target}

    warning =
      Map.get(state.warnings, key, %{
        kind: :external_type_resolution,
        category: category,
        target: target,
        occurrences: []
      })

    warning = %{warning | occurrences: Enum.uniq([occurrence | warning.occurrences])}
    put_in(state.warnings[key], warning)
  end

  defp sort_occurrences(warning),
    do: %{
      warning
      | occurrences:
          Enum.sort_by(
            warning.occurrences,
            &{&1.root.table_group, &1.root.table_id, &1.root.field_id, &1.path}
          )
    }

  defp warning_key(warning), do: {warning.category, inspect(warning.target)}
end
