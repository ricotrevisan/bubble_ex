defmodule BubbleEx.Editor.Plan do
  @moduledoc """
  Validation and expansion of guarded Bubble editor plans.

  Plans are intentionally JSON-shaped maps. Every operation contains `path`,
  `expected`, and (except for removal) `value`. Whole-node creation generates
  Bubble's ID-path and issue-index maintenance operations internally.
  """

  alias BubbleEx.Editor.{PluginSchema, Snapshot}
  alias BubbleEx.Error

  @element_types ~w(Page CustomDefinition Group Text Button Popup CustomElement)
  @workflow_types ~w(ButtonClicked)
  @action_types ~w(ShowElement HideElement SetCustomState)
  @expression_types ~w(TextExpression GetElement Message ArbitraryText PageData State)

  @property_keys ~w(
    %3 %br %bs %bw %bc %fc %fs %lh %ls %bas %bgc %bos %iv %h %w %l %t %z
    order opacity row_gap column_gap use_gap fit_width fit_height single_width
    single_height min_width_css max_width_css min_height_css max_height_css
    margin_top margin_right margin_bottom margin_left padding_top padding_right
    padding_bottom padding_left container_layout horiz_alignment vert_alignment
    container_horiz_alignment container_vert_alignment collapse_when_hidden
    font_family font_weight tag_type button_type overflow html_id
  )

  @type t :: %{
          appname: String.t(),
          version: String.t(),
          base_last_change: non_neg_integer(),
          plugin_types: [String.t()],
          references: %{optional(String.t()) => String.t()},
          semantic_operations: [map()],
          operations: [map()],
          source: map()
        }

  @spec schema() :: map()
  def schema do
    %{
      owners: ["%p3 web pages", "%ed reusable definitions"],
      elements: @element_types,
      properties: @property_keys,
      plugins: "Discover installed contracts with schema APP VERSION [PLUGIN_GROUP ...]",
      expressions: @expression_types,
      workflows: @workflow_types ++ ["discovered installed plugin events"],
      actions: @action_types ++ ["discovered installed plugin actions"]
    }
  end

  @spec load_file(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def load_file(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      new(decoded)
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         Error.new(:parse_failed, "editor plan is not valid JSON", %{
           reason: Exception.message(error)
         })}

      {:error, reason} ->
        {:error,
         Error.new(:invalid_input, "editor plan could not be read", %{
           path: path,
           reason: inspect(reason)
         })}
    end
  end

  @spec new(map(), map() | nil) :: {:ok, t()} | {:error, Error.t()}
  def new(plan, schemas \\ nil)

  def new(plan, schemas) when is_map(plan) do
    with {:ok, appname} <- required_string(plan, "appname"),
         {:ok, version} <- required_string(plan, "version"),
         {:ok, revision} <- revision(Map.get(plan, "base_last_change")),
         {:ok, plugin_types} <- plugin_types(Map.get(plan, "plugin_types", [])),
         {:ok, references} <- references(Map.get(plan, "references", %{})),
         context = %{groups: plugin_types, schemas: schemas},
         {:ok, operations} <- operations(Map.get(plan, "operations"), context),
         :ok <- validate_created_ids_and_references(operations, references) do
      {:ok,
       %{
         appname: appname,
         version: version,
         base_last_change: revision,
         plugin_types: plugin_types,
         references: references,
         source: plan,
         semantic_operations: operations,
         operations: expand_operations(operations) ++ reference_guards(references, operations)
       }}
    end
  end

  def new(_plan, _schemas), do: invalid("editor plan must be a JSON object")

  @spec paths(t()) :: [Snapshot.path()]
  def paths(plan), do: plan.operations |> Enum.map(& &1.path) |> Enum.uniq()

  @spec check(t(), Snapshot.t()) :: :ok | {:error, Error.t()}
  def check(plan, %Snapshot{} = snapshot) do
    with :ok <- same_target(plan, snapshot),
         :ok <- same_revision(plan, snapshot) do
      Enum.reduce_while(plan.operations, :ok, fn operation, :ok ->
        check_operation(operation, snapshot)
      end)
    end
  end

  defp check_operation(operation, snapshot) do
    case Snapshot.fetch(snapshot, operation.path) do
      {:ok, actual} when actual === operation.expected ->
        {:cont, :ok}

      {:ok, actual} ->
        {:halt, stale_value(operation, actual)}

      :error ->
        {:halt, invalid("editor read omitted a planned path", %{path: operation.path})}
    end
  end

  @spec intended?(map(), term()) :: boolean()
  def intended?(%{op: :remove}, actual), do: is_nil(actual)
  def intended?(%{value: value}, actual), do: actual === value

  @spec changes(t(), String.t()) :: [map()]
  def changes(plan, session_id) do
    plan.operations
    |> Enum.reject(&(&1.op == :guard))
    |> Enum.with_index(1)
    |> Enum.map(fn {operation, id} -> change(operation, session_id, id) end)
  end

  @spec inverse(t(), non_neg_integer()) :: map()
  def inverse(plan, revision) do
    %{
      "appname" => plan.appname,
      "version" => plan.version,
      "base_last_change" => revision,
      "plugin_types" => plan.plugin_types,
      "plugin_schema_hashes" => Map.get(plan.source, "plugin_schema_hashes", %{}),
      "references" => plan.references,
      "operations" =>
        plan.semantic_operations
        |> Enum.map(&inverse_operation/1)
    }
  end

  defp operations(value, plugin_types) when is_list(value) and value != [] do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {operation, index}, {:ok, acc} ->
      case operation(operation, plugin_types) do
        {:ok, normalized} ->
          {:cont, {:ok, [normalized | acc]}}

        {:error, %Error{} = error} ->
          {:halt, {:error, put_context(error, :operation_index, index)}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp operations(_value, _plugin_types),
    do: invalid("editor plan requires at least one operation")

  defp operation(%{"op" => op, "path" => path} = operation, plugin_types)
       when op in ["set", "put", "remove"] do
    with :ok <- valid_path(path),
         {:ok, expected} <- required_key(operation, "expected"),
         {:ok, value} <- operation_value(op, operation),
         source = operation_source(op, expected, value),
         :ok <- supported_operation(op, path, source, plugin_types, operation),
         {:ok, index_context} <- index_context(op, path, operation, source) do
      {:ok,
       Map.merge(
         %{
           op: String.to_existing_atom(op),
           path: path,
           expected: expected,
           value: value,
           plugin_type: Map.get(operation, "plugin_type"),
           internal: false
         },
         index_context
       )}
    end
  end

  defp operation(%{"op" => "move", "from" => from, "to" => to} = operation, plugin_types) do
    with :ok <- valid_path(from),
         :ok <- valid_path(to),
         :ok <- validate_move_paths(from, to),
         {:ok, expected} <- required_key(operation, "expected"),
         true <- is_map(expected),
         :ok <- validate_node(expected, plugin_types) do
      {:ok, %{op: :move, from: from, to: to, expected: expected, internal: false}}
    else
      false -> invalid("move expected value must be the complete source node")
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp operation(_operation, _plugin_types),
    do: invalid("operation must be set, put, remove, or move and include its required paths")

  defp operation_value("remove", _operation), do: {:ok, nil}
  defp operation_value(_op, operation), do: required_key(operation, "value")

  defp operation_source("remove", expected, _value), do: expected
  defp operation_source(_op, _expected, value), do: value

  defp index_context(op, path, operation, source)
       when op in ["put", "remove"] and length(path) > 2 do
    with {:ok, owner_id} <- required_string(operation, "owner_id"),
         {:ok, owner_issue_ids} <- owner_issue_ids(Map.get(operation, "owner_issue_ids")),
         changed_ids = source |> collect_ids(path) |> Enum.map(&elem(&1, 0)),
         calculated_after = update_owner_issue_ids(op, owner_issue_ids, changed_ids),
         {:ok, owner_issue_ids_after} <-
           owner_issue_ids_after(Map.get(operation, "owner_issue_ids_after"), calculated_after) do
      {:ok,
       %{
         owner_id: owner_id,
         owner_issue_ids: owner_issue_ids,
         owner_issue_ids_after: owner_issue_ids_after
       }}
    end
  end

  defp index_context(_op, _path, _operation, _source), do: {:ok, %{}}

  defp owner_issue_ids(ids) when is_list(ids) do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) and length(ids) == length(Enum.uniq(ids)) do
      {:ok, ids}
    else
      invalid("owner_issue_ids must contain unique non-empty Bubble IDs")
    end
  end

  defp owner_issue_ids(_ids),
    do: invalid("nested node edits require the owner's exact owner_issue_ids array")

  defp owner_issue_ids_after(nil, calculated), do: {:ok, calculated}

  defp owner_issue_ids_after(ids, calculated) do
    with {:ok, ids} <- owner_issue_ids(ids) do
      if Enum.sort(ids) == Enum.sort(calculated),
        do: {:ok, ids},
        else: invalid("owner_issue_ids_after cannot add or remove unrelated owner IDs")
    end
  end

  defp update_owner_issue_ids("put", before_ids, changed_ids),
    do: before_ids ++ Enum.reject(changed_ids, &(&1 in before_ids))

  defp update_owner_issue_ids("remove", before_ids, changed_ids),
    do: Enum.reject(before_ids, &(&1 in changed_ids))

  defp supported_operation("set", path, value, plugin_types, operation) do
    cond do
      supported_plugin_leaf?(path, plugin_types, operation) ->
        validate_plugin_value(plugin_types, operation["plugin_type"], List.last(path), value)

      supported_leaf?(path) ->
        validate_leaf_value(path, value, plugin_types)

      true ->
        unsupported(path, "unsupported property path or value")
    end
  end

  defp supported_operation(op, path, value, plugin_types, _operation)
       when op in ["put", "remove"] do
    cond do
      removable_node_path?(path) and is_map(value) ->
        validate_node_for_path(path, value, plugin_types)

      creatable_node_path?(path) and is_map(value) ->
        validate_node_for_path(path, value, plugin_types)

      true ->
        unsupported(path, "whole-node operation is outside the first-release boundary")
    end
  end

  defp supported_leaf?([root, _owner | rest]) when root in ["%p3", "%ed"] do
    case Enum.reverse(rest) do
      ["%nm" | _] ->
        true

      [property, "%p" | _] ->
        property in @property_keys

      [field, _state, "custom_states" | _] ->
        field in ["%d", "%v", "rank", "default_val", "make_static"]

      _ ->
        false
    end
  end

  defp supported_leaf?(_path), do: false

  defp validate_leaf_value(path, value, plugin_types) do
    if json_value?(value) do
      validate_typed_values(value, plugin_types)
    else
      unsupported(path, "property values must be JSON-compatible")
    end
  end

  defp validate_typed_values(value, plugin_types) do
    value
    |> typed_nodes()
    |> Enum.reduce_while(:ok, fn node, :ok ->
      case validate_node(node, plugin_types) do
        :ok -> {:cont, :ok}
        {:error, _error} = result -> {:halt, result}
      end
    end)
  end

  defp supported_plugin_leaf?(path, plugin_types, operation) do
    plugin_type = Map.get(operation, "plugin_type")
    property = List.last(path)

    match?(["%p", _property], Enum.take(path, -2)) and
      is_binary(plugin_type) and
      plugin_type?(plugin_type, plugin_types) and
      (is_nil(plugin_types.schemas) or
         not is_nil(PluginSchema.field(plugin_types.schemas, plugin_type, property))) and
      Enum.take(path, 1) in [["%p3"], ["%ed"]]
  end

  defp validate_plugin_value(%{schemas: nil}, _type, _key, _value), do: :ok

  defp validate_plugin_value(context, type, key, value) do
    case PluginSchema.field(context.schemas, type, key) do
      nil -> invalid("unknown plugin property", %{node_type: type, property: key})
      field -> PluginSchema.validate_value(field, value)
    end
  end

  defp creatable_node_path?(["%p3", _key]), do: true
  defp creatable_node_path?(["%ed", _key]), do: true

  defp creatable_node_path?([root, _owner | rest]) when root in ["%p3", "%ed"] do
    suffix = Enum.reverse(rest)
    match?([_key, "%el" | _], suffix) or match?([_key, "%wf" | _], suffix)
  end

  defp creatable_node_path?(_path), do: false

  defp removable_node_path?(path), do: creatable_node_path?(path)

  defp validate_node_for_path(["%p3", _key], %{"%x" => "Page"} = node, plugin_types),
    do: validate_node(node, plugin_types)

  defp validate_node_for_path(["%ed", _key], %{"%x" => "CustomDefinition"} = node, plugin_types),
    do: validate_node(node, plugin_types)

  defp validate_node_for_path(path, %{"%x" => type} = node, plugin_types) do
    suffix = Enum.reverse(path)

    cond do
      match?([_key, "%el" | _], suffix) and element_type?(type, plugin_types) ->
        validate_node(node, plugin_types)

      match?([_key, "%wf" | _], suffix) and workflow_type?(type, plugin_types) ->
        validate_node(node, plugin_types)

      true ->
        unsupported(path, "node type is not supported at this Bubble path")
    end
  end

  defp validate_node_for_path(path, _node, _plugin_types),
    do: unsupported(path, "created nodes require a supported %x discriminator")

  defp element_type?(type, plugin_types) do
    type in ~w(Group Text Button Popup CustomElement) or
      plugin_role?(type, plugin_types, :elements)
  end

  defp workflow_type?(type, plugin_types) do
    type in @workflow_types or plugin_role?(type, plugin_types, :workflows)
  end

  defp validate_node(%{"%x" => type} = node, plugin_types) when is_binary(type) do
    cond do
      type in @element_types ->
        validate_children(node, plugin_types)

      type in @workflow_types ->
        validate_workflow(node, plugin_types)

      type in @action_types ->
        validate_children(node, plugin_types)

      type in @expression_types ->
        validate_children(node, plugin_types)

      plugin_type?(type, plugin_types) ->
        validate_plugin_node(node, plugin_types)

      true ->
        invalid("unsupported Bubble node type", %{node_type: type, reason: :unsupported_node})
    end
  end

  defp validate_node(_node, _plugin_types),
    do: invalid("created nodes must contain a supported %x discriminator")

  defp validate_plugin_node(node, context) do
    with :ok <- validate_plugin_properties(node, context) do
      if plugin_role?(node["%x"], context, :workflows),
        do: validate_workflow(node, context),
        else: validate_children(node, context)
    end
  end

  defp validate_plugin_properties(_node, %{schemas: nil}), do: :ok

  defp validate_plugin_properties(%{"%x" => type} = node, context) do
    Enum.reduce_while(Map.get(node, "%p", %{}), :ok, fn {key, value}, :ok ->
      result =
        if key in @property_keys or key == "%ei",
          do: :ok,
          else: validate_plugin_value(context, type, key, value)

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_workflow(node, plugin_types) do
    actions = Map.get(node, "actions", %{})

    with true <- is_map(actions),
         :ok <- validate_action_nodes(actions, plugin_types),
         :ok <- validate_children(Map.delete(node, "actions"), plugin_types) do
      :ok
    else
      false -> invalid("workflow actions must be an ordered map", %{reason: :invalid_actions})
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_action_nodes(actions, plugin_types) do
    Enum.reduce_while(actions, :ok, fn {_order, action}, :ok ->
      case validate_action_node(action, plugin_types) do
        :ok -> {:cont, :ok}
        {:error, _error} = result -> {:halt, result}
      end
    end)
  end

  defp validate_action_node(%{"%x" => type} = action, plugin_types)
       when type in @action_types,
       do: validate_node(action, plugin_types)

  defp validate_action_node(%{"%x" => type} = action, plugin_types) do
    if plugin_role?(type, plugin_types, :actions),
      do: validate_node(action, plugin_types),
      else: invalid("unsupported workflow action", %{node_type: type})
  end

  defp validate_action_node(_action, _plugin_types),
    do: invalid("workflow actions require a supported %x discriminator")

  defp validate_children(node, plugin_types) do
    node
    |> nested_typed_nodes()
    |> Enum.reduce_while(:ok, fn child, :ok ->
      case validate_node(child, plugin_types) do
        :ok -> {:cont, :ok}
        {:error, _error} = result -> {:halt, result}
      end
    end)
  end

  defp nested_typed_nodes(node) do
    node
    |> Map.delete("%x")
    |> Map.values()
    |> Enum.flat_map(&typed_nodes/1)
  end

  defp typed_nodes(value) when is_map(value) do
    own = if is_binary(Map.get(value, "%x")), do: [value], else: []
    own ++ (value |> Map.values() |> Enum.flat_map(&typed_nodes/1))
  end

  defp typed_nodes(value) when is_list(value), do: Enum.flat_map(value, &typed_nodes/1)
  defp typed_nodes(_value), do: []

  defp plugin_type?(type, plugin_types) do
    Enum.any?([:elements, :workflows, :actions], &plugin_role?(type, plugin_types, &1))
  end

  defp plugin_role?(type, plugin_types, role) when is_binary(type) do
    declared? = Enum.any?(plugin_types.groups, &String.starts_with?(type, &1 <> "-"))

    case plugin_types.schemas do
      nil -> declared?
      schemas -> declared? and match?(%{role: ^role}, PluginSchema.node(schemas, type))
    end
  end

  defp expand_operations(operations) do
    Enum.flat_map(operations, &expand_operation/1)
  end

  defp expand_operation(%{op: :move} = operation), do: move_operations(operation)

  defp expand_operation(%{op: op} = operation) when op in [:put, :remove] do
    source = if op == :put, do: operation.value, else: operation.expected
    [operation | index_operations(operation, source)]
  end

  defp expand_operation(%{op: :set} = operation),
    do: [operation | plugin_type_guard(operation)]

  defp expand_operation(operation), do: [operation]

  defp plugin_type_guard(%{plugin_type: plugin_type, path: path}) when is_binary(plugin_type) do
    node_type_path = Enum.drop(path, -2) ++ ["%x"]

    [
      %{
        op: :guard,
        path: node_type_path,
        expected: plugin_type,
        value: plugin_type,
        internal: true
      }
    ]
  end

  defp plugin_type_guard(_operation), do: []

  defp move_operations(operation) do
    put = %{
      op: :put,
      path: operation.to,
      expected: nil,
      value: operation.expected,
      internal: false
    }

    remove = %{
      op: :remove,
      path: operation.from,
      expected: operation.expected,
      value: nil,
      internal: false
    }

    old_paths = collect_ids(operation.expected, operation.from) |> Map.new()
    new_paths = collect_ids(operation.expected, operation.to) |> Map.new()

    indexes =
      Enum.map(old_paths, fn {id, old_path} ->
        internal(
          :set,
          ["_index", "id_to_path", id],
          Enum.join(old_path, "."),
          Enum.join(Map.fetch!(new_paths, id), ".")
        )
      end)

    [put, remove | indexes]
  end

  defp index_operations(operation, source) when is_map(source) do
    ids = collect_ids(source, operation.path)

    id_operations =
      Enum.flat_map(ids, fn {id, path} ->
        path_value = Enum.join(path, ".")

        case operation.op do
          :put ->
            [
              internal(:set, ["_index", "id_to_path", id], nil, path_value),
              internal(:set, ["_index", "issues_list", id], nil, "[]")
            ]

          :remove ->
            [
              internal(:set, ["_index", "id_to_path", id], path_value, nil),
              internal(:set, ["_index", "issues_list", id], "[]", nil)
            ]
        end
      end)

    issue_sub = issue_sub_operations(operation, source, ids)

    id_operations ++ issue_sub
  end

  defp index_operations(_operation, _source), do: []

  defp issue_sub_operations(%{path: path} = operation, source, ids) when length(path) == 2 do
    root_id = Map.get(source, "id")
    child_ids = ids |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 == root_id))

    if is_binary(root_id) do
      encoded = Jason.encode!(child_ids)
      expected = if operation.op == :put, do: nil, else: encoded
      value = if operation.op == :put, do: encoded, else: nil
      [internal(:set, ["_index", "issues_sub", root_id], expected, value)]
    else
      []
    end
  end

  defp issue_sub_operations(operation, _source, _ids) do
    before_ids = operation.owner_issue_ids
    after_ids = operation.owner_issue_ids_after

    [
      internal(
        :set,
        ["_index", "issues_sub", operation.owner_id],
        Jason.encode!(before_ids),
        Jason.encode!(after_ids)
      )
    ]
  end

  defp collect_ids(node, path) when is_map(node) do
    own =
      case Map.get(node, "id") do
        id when is_binary(id) and id != "" -> [{id, path}]
        _ -> []
      end

    children =
      [
        {"%el", Map.get(node, "%el")},
        {"%wf", Map.get(node, "%wf")},
        {"actions", Map.get(node, "actions")}
      ]
      |> Enum.flat_map(fn
        {section, values} when is_map(values) ->
          Enum.flat_map(values, fn {key, value} -> collect_ids(value, path ++ [section, key]) end)

        _ ->
          []
      end)

    own ++ children
  end

  defp collect_ids(_node, _path), do: []

  defp validate_created_ids_and_references(operations, references) do
    created_nodes =
      Enum.flat_map(operations, fn
        %{op: :put, value: value, path: path} -> collect_ids(value, path)
        _operation -> []
      end)

    created_ids = Enum.map(created_nodes, &elem(&1, 0))

    local_ids =
      operations
      |> Enum.flat_map(fn
        %{op: :put, value: value, path: path} -> collect_ids(value, path)
        %{op: :remove, expected: value, path: path} -> collect_ids(value, path)
        _operation -> []
      end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    if length(created_ids) == length(Enum.uniq(created_ids)) do
      validate_external_references(operations, local_ids, references)
    else
      invalid("created Bubble IDs must be unique within a plan", %{reason: :duplicate_id})
    end
  end

  defp validate_external_references(operations, created_ids, references) do
    unresolved =
      operations
      |> Enum.flat_map(fn
        %{op: :put, value: value} -> collect_reference_ids(value)
        %{op: :remove, expected: value} -> collect_reference_ids(value)
        _operation -> []
      end)
      |> Enum.uniq()
      |> Enum.reject(&(MapSet.member?(created_ids, &1) or Map.has_key?(references, &1)))

    case unresolved do
      [] -> :ok
      ids -> invalid("created nodes contain unresolved Bubble references", %{references: ids})
    end
  end

  defp collect_reference_ids(value) when is_map(value) do
    own =
      Enum.flat_map(value, fn
        {key, id} when key in ["%ci", "%ei"] and is_binary(id) and id != "" -> [id]
        _entry -> []
      end)

    own ++ (value |> Map.values() |> Enum.flat_map(&collect_reference_ids/1))
  end

  defp collect_reference_ids(value) when is_list(value),
    do: Enum.flat_map(value, &collect_reference_ids/1)

  defp collect_reference_ids(_value), do: []

  defp reference_guards(references, operations) do
    created_ids =
      operations
      |> Enum.flat_map(fn
        %{op: :put, value: value, path: path} -> collect_ids(value, path)
        _operation -> []
      end)
      |> Map.new(fn {id, _path} -> {id, true} end)

    references
    |> Enum.reject(fn {id, _path} -> Map.has_key?(created_ids, id) end)
    |> Enum.map(fn {id, expected_path} ->
      %{
        op: :guard,
        path: ["_index", "id_to_path", id],
        expected: expected_path,
        value: expected_path,
        internal: true
      }
    end)
  end

  defp internal(op, path, expected, value),
    do: %{op: op, path: path, expected: expected, value: value, internal: true}

  defp change(operation, session_id, id) do
    version = if operation.internal, do: 4, else: 5
    intent = if operation.internal, do: %{"name" => "Update index"}, else: intent(operation, id)

    %{
      "path_array" => operation.path,
      "body" => operation.value,
      "intent" => intent,
      "version_control_api_version" => version,
      "changelog_data" => [],
      "session_id" => session_id
    }
  end

  defp intent(%{op: :remove}, id),
    do: %{"name" => "RemoveElement", "id" => id, "source_appname" => ""}

  defp intent(%{op: :put}, id),
    do: %{"name" => "CreateElement", "id" => id, "source_appname" => ""}

  defp intent(_operation, id), do: %{"name" => "SetData", "id" => id, "source_appname" => ""}

  defp inverse_operation(%{op: :put} = operation) do
    %{"op" => "remove", "path" => operation.path, "expected" => operation.value}
    |> put_inverse_index_context(operation, operation.value)
  end

  defp inverse_operation(%{op: :remove} = operation) do
    %{"op" => "put", "path" => operation.path, "expected" => nil, "value" => operation.expected}
    |> put_inverse_index_context(operation, operation.expected)
  end

  defp inverse_operation(%{op: :move} = operation) do
    %{
      "op" => "move",
      "from" => operation.to,
      "to" => operation.from,
      "expected" => operation.expected
    }
  end

  defp inverse_operation(operation) do
    inverse = %{
      "op" => "set",
      "path" => operation.path,
      "expected" => operation.value,
      "value" => operation.expected
    }

    if is_binary(operation.plugin_type),
      do: Map.put(inverse, "plugin_type", operation.plugin_type),
      else: inverse
  end

  defp put_inverse_index_context(inverse, %{owner_id: owner_id} = operation, _source) do
    Map.merge(inverse, %{
      "owner_id" => owner_id,
      "owner_issue_ids" => operation.owner_issue_ids_after,
      "owner_issue_ids_after" => operation.owner_issue_ids
    })
  end

  defp put_inverse_index_context(inverse, _operation, _source), do: inverse

  defp same_target(plan, snapshot) do
    if plan.appname == snapshot.appname and plan.version == snapshot.version,
      do: :ok,
      else: invalid("editor snapshot target does not match the plan", %{reason: :target_mismatch})
  end

  defp same_revision(plan, snapshot) do
    if plan.base_last_change == snapshot.last_change do
      :ok
    else
      invalid("editor plan is stale", %{
        reason: :stale_revision,
        expected_last_change: plan.base_last_change,
        actual_last_change: snapshot.last_change
      })
    end
  end

  defp stale_value(operation, actual) do
    invalid("editor plan expected value is stale", %{
      reason: :stale_value,
      path: operation.path,
      expected: operation.expected,
      actual: actual
    })
  end

  defp valid_path(path) when is_list(path) and path != [] do
    if Enum.all?(path, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: invalid("operation path segments must be non-empty strings")
  end

  defp valid_path(_path), do: invalid("operation path must be a non-empty string array")

  defp validate_move_paths(from, to) do
    cond do
      not element_node_path?(from) or not element_node_path?(to) ->
        invalid("moves are limited to element nodes", %{reason: :unsupported_edit})

      Enum.take(from, 2) != Enum.take(to, 2) ->
        invalid("cross-owner moves are not supported", %{reason: :cross_owner_move})

      from == to ->
        invalid("move source and destination must differ", %{reason: :invalid_move})

      Enum.take(to, length(from)) == from ->
        invalid("an element cannot be moved inside itself", %{reason: :invalid_move})

      true ->
        :ok
    end
  end

  defp element_node_path?([root, _owner | rest]) when root in ["%p3", "%ed"] do
    match?([_key, "%el" | _], Enum.reverse(rest))
  end

  defp element_node_path?(_path), do: false

  defp json_value?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  defp json_value?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and json_value?(item) end)

  defp json_value?(_value), do: false

  defp plugin_types(types) when is_list(types) do
    if Enum.all?(types, &(is_binary(&1) and Regex.match?(~r/\A\d+x\d+(?:_current)?\z/, &1))) do
      {:ok, Enum.uniq(types)}
    else
      invalid("plugin_types must contain installed plugin group IDs")
    end
  end

  defp plugin_types(_types), do: invalid("plugin_types must be an array")

  defp references(references) when is_map(references) do
    if Enum.all?(references, fn {id, path} ->
         is_binary(id) and id != "" and is_binary(path) and path != ""
       end) do
      {:ok, references}
    else
      invalid("references must map Bubble IDs to exact id_to_path strings")
    end
  end

  defp references(_references),
    do: invalid("references must be a JSON object")

  defp revision(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp revision(_value), do: invalid("base_last_change must be a non-negative integer")

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> invalid("#{key} must be a non-empty string")
    end
  end

  defp required_key(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> invalid("operation is missing #{key}")
    end
  end

  defp unsupported(path, message), do: invalid(message, %{path: path, reason: :unsupported_edit})
  defp invalid(message, context \\ %{}), do: {:error, Error.new(:invalid_input, message, context)}

  defp put_context(%Error{} = error, key, value),
    do: %{error | context: Map.put(error.context, key, value)}
end
