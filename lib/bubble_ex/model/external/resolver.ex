defmodule BubbleEx.Model.External.Resolver do
  @moduledoc false

  # The one reading of API Connector (`api.apiconnector2.…`) types. Given the
  # `api.` descriptors of data-type fields and option-set attributes (the
  # roots), it resolves each against the call's `types` registry in the app
  # JSON (the Model's `BubbleEx.Model.Connector` calls), depth-first, and returns the external-type nodes reached and one
  # `BubbleEx.Diagnostic` (stage `:read`) per occurrence it could not read
  # faithfully. `BubbleEx.Model.External` converts the result into Model
  # structs. API Connector settings are read once, into the Model's
  # connectors; this reads the calls from there.

  @prefix "api.apiconnector2."
  @scalars %{
    "text" => :text,
    "number" => :number,
    "boolean" => :boolean,
    "date" => :date,
    "date_unix" => :date_unix
  }

  alias BubbleEx.Diagnostic
  alias BubbleEx.Model.{Connector, ConnectorCall}

  @type group :: :custom | :option
  @type root :: %{group: group(), owner: String.t(), field: String.t(), descriptor: term()}
  @type value ::
          %{type: :scalar, scalar: atom(), cardinality: :one | :many, raw: String.t()}
          | %{type: :external, target: String.t(), cardinality: :one | :many, raw: String.t()}
          | %{
              type: :opaque_external,
              target: nil,
              cardinality: :one | :many | :unknown,
              raw: term()
            }

  @doc """
  Resolves `roots` against the `connectors`' calls; `attrs` (data types and
  option sets of the app JSON, either key form) locates root diagnostics. Returns
  each root's value keyed by `{group, owner, field}`, the external-type nodes
  reached (in ID order) and the normalized diagnostics.
  """
  @spec resolve([root()], map(), [Connector.t()]) ::
          {%{{group(), String.t(), String.t()} => value()}, [map()], [Diagnostic.t()]}
  def resolve(roots, attrs, connectors) do
    state = %{
      attrs: attrs,
      connectors: Map.new(connectors, &{&1.id, &1}),
      nodes: %{},
      failures: %{},
      diagnostics: []
    }

    {values, state} =
      Enum.map_reduce(roots, state, fn root, state ->
        occurrence = %{
          root: %{table_group: root.group, table_id: root.owner, field_id: root.field},
          path: []
        }

        {value, state} = resolve_value(root.descriptor, occurrence, state)
        {{{root.group, root.owner, root.field}, value}, state}
      end)

    nodes = state.nodes |> Map.values() |> Enum.sort_by(& &1.id)

    {Map.new(values), nodes, state.diagnostics |> Enum.reverse() |> Diagnostic.normalize()}
  end

  @doc """
  JSON pointer to a data-type field's or option-set attribute's type
  descriptor in `source` (either key form), or `nil` when the source does not
  spell one out.
  """
  @spec descriptor_pointer(map(), group(), String.t(), String.t()) :: String.t() | nil
  def descriptor_pointer(source, group, owner, field) do
    {collection, containers} =
      case group do
        :custom -> {"user_types", ~w(%f3 fields)}
        :option -> {"option_sets", ["attributes"]}
      end

    with %{} = definition <- get(source, collection) |> get(owner),
         container when is_binary(container) <-
           Enum.find(containers, &is_map(get(get(definition, &1), field))),
         %{} = raw <- definition |> get(container) |> get(field),
         key when is_binary(key) <- Enum.find(~w(%v value), &Map.has_key?(raw, &1)) do
      Diagnostic.pointer([collection, owner, container, field, key])
    else
      _ -> nil
    end
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

    if conflicting_definition?(state.connectors, id) do
      node = %{placeholder | resolution: :conflicted}

      state
      |> put_in([:nodes, id], node)
      |> fail_node(id, :conflicting_duplicate_definition, occurrence)
    else
      resolve_registry_node(state, id, connector_id, call_id, occurrence)
    end
  end

  defp resolve_registry_node(state, id, connector_id, call_id, occurrence) do
    case registry_for(state.connectors, connector_id, call_id) do
      {:error, category} ->
        fail_node(state, id, category, occurrence)

      {:ok, call, registry} ->
        source_path = call_path(state.connectors, id) <> "/types"

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
      {if(is_list(get(data, "path")), do: get(data, "path"), else: ["\uffff"]), id}
    end)
    |> Enum.map_reduce(state, fn {field_id, data}, state ->
      path = root_occurrence.path ++ [%{external_type_id: parent_id, field_id: field_id}]
      occurrence = %{root_occurrence | path: path}
      {raw, state} = field_descriptor(data, occurrence, state)
      {type, state} = resolve_value(raw, occurrence, state)

      state =
        if is_binary(get(data, "caption")) and is_list(get(data, "path")),
          do: state,
          else: warn(state, :incomplete_field_metadata, external_target(parent_id), occurrence)

      {%{id: field_id, caption: get(data, "caption"), path: get(data, "path"), type: type}, state}
    end)
  end

  # A registry field definition that is not an object has no members (its
  # type is then diagnosed as malformed).
  defp get(data, key) when is_map(data), do: Map.get(data, key)
  defp get(_data, _key), do: nil

  defp field_descriptor(data, occurrence, state) when is_map(data) do
    values = [data["ret_btype"], data["ret_value"]] |> Enum.filter(&is_binary/1)

    case values do
      [raw] -> {raw, state}
      _ -> {nil, warn(state, :field_type_malformed, raw_target(nil), occurrence)}
    end
  end

  defp field_descriptor(_, occurrence, state),
    do: {nil, warn(state, :field_type_malformed, raw_target(nil), occurrence)}

  defp registry_for(connectors, connector_id, call_id) do
    case Map.fetch(connectors, connector_id) do
      {:ok, connector} -> call_registry(Connector.call(connector, call_id))
      :error -> {:error, :connector_missing}
    end
  end

  defp call_registry(nil), do: {:error, :call_missing}

  defp call_registry(%ConnectorCall{raw: nil, registry: registry} = call) when is_map(registry),
    do: {:ok, call, registry}

  defp call_registry(%ConnectorCall{raw: nil, types: types}) when types in [nil, ""],
    do: {:error, :registry_unavailable}

  defp call_registry(_), do: {:error, :registry_malformed}

  # Whether more than one call defines `id`, differently.
  defp conflicting_definition?(connectors, id) do
    connectors
    |> Map.values()
    |> Enum.flat_map(& &1.calls)
    |> Enum.flat_map(fn call ->
      case call.registry do
        %{^id => definition} -> [definition]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> length()
    |> Kernel.>(1)
  end

  defp advisory_warning(id, call, occurrence, state) do
    case call.returns do
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
  # occurrence, or an external type's field (`%{external_type: id, field:
  # field_id}`) for a nested one. Nested definitions live inside the call's
  # JSON-encoded `types` string, so `path` points at that string and
  # `details.embedded_path` is a JSON pointer into its decoded value. A nested
  # diagnostic also keeps the data-type field it was reached from
  # (`details.root`) and every hop from there (`details.via`, ending at the
  # subject). Definition-level codes are about the external type itself.
  @definition_codes [:empty_definition, :call_metadata_inconsistent]

  defp warn(state, code, target, occurrence) do
    {subject, path, located} = locate(code, target, occurrence, state)
    details = target_details(target) |> Map.merge(located)

    diagnostic =
      Diagnostic.new(code, path, message(code, target), subject: subject, details: details)

    %{state | diagnostics: [diagnostic | state.diagnostics]}
  end

  defp locate(code, %{type: :external_type, id: id}, _occurrence, state)
       when code in @definition_codes do
    member = if code == :call_metadata_inconsistent, do: "ret_value", else: "types"
    details = if member == "types", do: %{embedded_path: Diagnostic.pointer([id])}, else: %{}
    {%{external_type: id}, call_path(state.connectors, id) <> "/" <> member, details}
  end

  defp locate(_code, _target, %{root: root, path: []}, state),
    do: {root_subject(root), root_path(state.attrs, root), %{}}

  defp locate(_code, _target, %{root: root, path: path}, state) do
    %{external_type_id: type_id, field_id: field_id} = List.last(path)

    via = Enum.map(path, &%{external_type: &1.external_type_id, field: &1.field_id})

    {%{external_type: type_id, field: field_id}, call_path(state.connectors, type_id) <> "/types",
     %{
       root: root_subject(root),
       via: via,
       embedded_path: Diagnostic.pointer([type_id, "fields", field_id])
     }}
  end

  defp root_subject(%{table_group: :option, table_id: id, field_id: field}),
    do: %{option_set: id, field: field}

  defp root_subject(%{table_id: id, field_id: field}), do: %{type: id, field: field}

  defp root_path(attrs, %{table_group: group, table_id: id, field_id: field}) do
    descriptor_pointer(attrs, group, id, field) ||
      Diagnostic.pointer([if(group == :option, do: "option_sets", else: "user_types"), id])
  end

  # JSON pointer to the call an external type `id` names (where it would be
  # placed directly in its group when there is no such call).
  defp call_path(connectors, id) do
    {connector_id, call_id} = identity_parts(id)

    with {:ok, connector} <- Map.fetch(connectors, connector_id),
         %ConnectorCall{path: path} <- Connector.call(connector, call_id) do
      path
    else
      _ -> Diagnostic.pointer(["settings", "client_safe", "apiconnector2", connector_id, call_id])
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
