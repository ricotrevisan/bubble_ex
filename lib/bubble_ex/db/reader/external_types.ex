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

  alias BubbleEx.Diagnostic

  @spec resolve([BubbleEx.Db.Reader.table()], map()) ::
          {[BubbleEx.Db.Reader.table()], [map()], [Diagnostic.t()]}
  def resolve(tables, attrs) do
    state = %{attrs: attrs, nodes: %{}, failures: %{}, diagnostics: []}

    {tables, state} =
      Enum.map_reduce(tables, state, fn table, state ->
        {columns, state} = Enum.map_reduce(table.columns, state, &resolve_column(&1, &2))
        {%{table | columns: columns}, state}
      end)

    nodes = state.nodes |> Map.values() |> Enum.sort_by(& &1.id)

    {tables, nodes, state.diagnostics |> Enum.reverse() |> Diagnostic.normalize()}
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

    placeholder = %{
      id: id,
      caption: nil,
      provenance: provenance,
      resolution: :opaque,
      fields: [],
      source_path: nil
    }

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
      {:error, category} ->
        fail_node(state, id, category, occurrence)

      {:ok, call, registry} ->
        source_path = Diagnostic.pointer(call_path(state.attrs, id) ++ ["types"])

        state
        |> put_in([:nodes, id, :source_path], source_path)
        |> resolve_registry_definition(id, call, registry, occurrence)
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

  # One diagnostic per occurrence. Its subject and path are the field whose
  # type descriptor raised it: a data-type or option-set field for a root
  # occurrence, or an external type's field (`%{type: external_type_id,
  # field: field_id}`) for a nested one. Nested definitions live inside the
  # call's JSON-encoded `types` string, so `path` points at that string and
  # `details.embedded_path` is a JSON pointer into its decoded value.
  # Definition-level codes are about the external type itself.
  @definition_codes [:empty_definition, :call_metadata_inconsistent]

  defp warn(state, code, target, occurrence) do
    {subject, path, located} = locate(code, target, occurrence, state.attrs)
    details = target_details(target) |> Map.merge(located)

    diagnostic =
      Diagnostic.new(code, path, message(code, target), subject: subject, details: details)

    %{state | diagnostics: [diagnostic | state.diagnostics]}
  end

  defp locate(code, %{type: :external_type, id: id}, _occurrence, attrs)
       when code in @definition_codes do
    member = if code == :call_metadata_inconsistent, do: "ret_value", else: "types"
    details = if member == "types", do: %{embedded_path: Diagnostic.pointer([id])}, else: %{}
    {%{type: id}, call_path(attrs, id) ++ [member], details}
  end

  defp locate(_code, _target, %{root: root, path: []}, attrs),
    do: {root_subject(root), root_path(attrs, root), %{}}

  defp locate(_code, _target, %{root: root, path: path}, attrs) do
    %{external_type_id: type_id, field_id: field_id} = List.last(path)

    {%{type: type_id, field: field_id}, call_path(attrs, type_id) ++ ["types"],
     %{
       root: root_subject(root),
       embedded_path: Diagnostic.pointer([type_id, "fields", field_id])
     }}
  end

  defp root_subject(%{table_group: :option, table_id: id, field_id: field}),
    do: %{option_set: id, field: field}

  defp root_subject(%{table_id: id, field_id: field}), do: %{type: id, field: field}

  defp root_path(attrs, %{table_group: group, table_id: id, field_id: field}) do
    BubbleEx.Db.Reader.field_pointer(attrs, group, id, field) ||
      Diagnostic.pointer([if(group == :option, do: "option_sets", else: "user_types"), id])
  end

  defp call_path(attrs, id) do
    {connector_id, call_id} = identity_parts(id)
    base = ["settings", "client_safe", "apiconnector2", connector_id]

    case get_in(attrs, ["settings", "client_safe", "apiconnector2", connector_id]) do
      %{^call_id => _} -> base ++ [call_id]
      %{"calls" => %{^call_id => _}} -> base ++ ["calls", call_id]
      _ -> base ++ [call_id]
    end
  end

  defp target_details(%{type: :external_type, id: id}), do: %{external_type: id}
  defp target_details(%{type: :raw_descriptor, raw: raw}), do: %{descriptor: raw}

  @messages %{
    invalid_descriptor: "invalid API Connector type descriptor",
    field_type_unsupported: "unsupported external field type",
    field_type_malformed: "missing or malformed external field type",
    conflicting_duplicate_definition: "API Connector type has conflicting definitions",
    connector_missing: "API Connector is missing",
    call_missing: "API Connector call is missing",
    registry_unavailable: "API Connector call has no types registry",
    registry_malformed: "API Connector call types registry is malformed",
    exact_type_definition_missing: "API Connector type definition is missing",
    empty_definition: "API Connector type has no fields",
    incomplete_field_metadata: "external type field lacks a caption or path",
    call_metadata_inconsistent: "API Connector call returns a different type"
  }

  defp message(code, %{type: :external_type, id: id}), do: "#{@messages[code]}: #{id}"

  defp message(code, %{type: :raw_descriptor, raw: raw}),
    do: "#{@messages[code]}: #{inspect(raw)}"
end
