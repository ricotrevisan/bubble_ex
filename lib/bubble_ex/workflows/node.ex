defmodule BubbleEx.Workflows.Node do
  @moduledoc false

  alias BubbleEx.AppTree.Expr
  alias BubbleEx.Workflows.Source

  @events %{
    "ButtonClicked" => "When an element is clicked",
    "PageLoaded" => "When the page loads",
    "CustomEvent" => "When a custom event is triggered",
    "APIEvent" => "When a backend workflow is called",
    "ConditionTrue" => "When a condition is true",
    "DoInterval" => "On a recurring timer"
  }
  @actions %{
    "ShowElement" => "Show an element",
    "HideElement" => "Hide an element",
    "ToggleElement" => "Toggle element visibility",
    "ResetInputs" => "Reset inputs",
    "OpenURL" => "Open a URL",
    "ChangePage" => "Navigate to a page",
    "NewThing" => "Create a data record",
    "ChangeThing" => "Change a data record",
    "DeleteThing" => "Delete a data record",
    "SetCustomState" => "Set an element custom state",
    "TriggerCustomEvent" => "Trigger a custom event",
    "ScheduleAPIEvent" => "Schedule a backend workflow",
    "APIReturnData" => "Return data from a backend workflow",
    "TerminateWorkflow" => "Stop this workflow",
    "SetFocusToElement" => "Focus an element"
  }
  @references %{
    "element_id" => "element",
    "%ei" => "element",
    "action_id" => "action",
    "custom_event" => "workflow",
    "custom_event_id" => "workflow",
    "event_id" => "workflow",
    "internal_page" => "page",
    "%pa" => "page",
    "type_to_create" => "data_type",
    "%tt" => "data_type",
    "api_event" => "backend_workflow"
  }
  @structural ~w(type %x id %id name %nm properties %p actions condition only_when %c)

  @spec index(map()) :: map()
  def index(payload), do: index_nodes(payload, [], %{})

  defp index_nodes(map, path, acc) when is_map(map) do
    acc = register(map, path, acc)
    Enum.reduce(map, acc, fn {key, value}, index -> index_nodes(value, path ++ [key], index) end)
  end

  defp index_nodes(list, path, acc) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {v, i}, index -> index_nodes(v, path ++ [i], index) end)
  end

  defp index_nodes(_, _, acc), do: acc

  defp register(node, path, acc) do
    case entity_kind(path) do
      nil ->
        acc

      kind ->
        ids =
          [List.last(path), Source.value(node, ["id", "%id"])]
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()

        ref = %{
          kind: kind,
          path: Source.pointer(path),
          name: Source.value(node, ["name", "%nm", "default_name", "display"])
        }

        Enum.reduce(ids, acc, fn id, index ->
          Map.update(index, {kind, id}, [ref], &[ref | &1])
        end)
    end
  end

  defp entity_kind(path) do
    case Enum.take(path, -2) do
      [section, _] when section in ~w(elements %el) -> "element"
      [section, _] when section in ~w(pages %p3) -> "page"
      [section, _] when section in ~w(element_definitions %ed) -> "element"
      [section, _] when section in ~w(workflows %wf) -> "workflow"
      ["api", _] -> "backend_workflow"
      [section, _] when section in ~w(actions) -> "action"
      ["user_types", _] -> "data_type"
      _ -> nil
    end
  end

  @spec workflow(term(), list(), map()) :: map()
  def workflow(value, path, index) do
    event = node(value, path, index, @events)
    {actions, ordering, findings} = actions(value, path, index)

    %{
      path: Source.pointer(path),
      key: List.last(path),
      raw: value,
      event: Map.drop(event, [:raw, :diagnostics]),
      actions: actions,
      action_metadata: Source.metadata(Source.value(value, ["actions"]), path ++ ["actions"]),
      ordering: ordering,
      diagnostics: event.diagnostics ++ findings ++ Enum.flat_map(actions, & &1.diagnostics)
    }
  end

  defp actions(value, path, index) do
    case Source.get(value, ["actions"]) do
      nil ->
        {[], "unavailable",
         [
           Source.diagnostic(
             "actions_unavailable",
             path,
             "Actions field is absent; no action list can be inferred."
           )
         ]}

      {key, actions} when is_map(actions) or is_list(actions) ->
        {entries, ordering, findings} = order(actions, path ++ [key])

        nodes =
          Enum.map(entries, fn {i, action} ->
            node(action, path ++ [key, i], index, @actions) |> Map.put(:source_key, i)
          end)

        {nodes, ordering, findings}

      {key, _} ->
        {[], "unresolved",
         [
           Source.diagnostic(
             "malformed_actions",
             path ++ [key],
             "Expected an action map or list; original value retained in workflow raw."
           )
         ]}
    end
  end

  defp order(actions, _) when is_list(actions), do: {Source.entries(actions), "array_order", []}

  defp order(actions, path) do
    entries = Source.entries(actions)
    numbers = Enum.map(entries, fn {k, _} -> Integer.parse(k) end)
    numeric? = Enum.all?(numbers, &match?({n, ""} when n >= 0, &1))
    unique? = length(Enum.uniq(numbers)) == length(numbers)

    if numeric? and unique? do
      {Enum.sort_by(entries, fn {key, _} -> String.to_integer(key) end), "numeric_keys", []}
    else
      {entries, "unresolved",
       [
         Source.diagnostic(
           "unresolved_order",
           path,
           "Map keys do not establish an unambiguous numeric action order. Display uses lexical keys, not execution order."
         )
       ]}
    end
  end

  defp node(value, path, index, vocabulary) when is_map(value) do
    type = Source.value(value, ["type", "%x"])
    explanation = Map.get(vocabulary, type)
    props = Source.value(value, ["properties", "%p"])
    refs = references(value, path, {path, type}, index)
    conditions = conditions(value, path)

    findings =
      unsupported(explanation, path) ++
        properties_findings(Source.get(value, ["properties", "%p"]), path) ++
        unknown_fields(value, path) ++
        alias_findings(value, path) ++
        Enum.flat_map(conditions, & &1.diagnostics) ++
        Enum.flat_map(refs, fn ref ->
          if ref.status == "resolved",
            do: [],
            else: [
              %{
                code: "unresolved_reference",
                path: ref.path,
                message: "Reference is #{ref.status}; raw value retained."
              }
            ]
        end)

    %{
      path: Source.pointer(path),
      id: Source.value(value, ["id", "%id"]),
      type: type,
      explanation: explanation || "Unsupported construct; inspect the retained source",
      interpretation: if(findings == [], do: "label_only", else: "partial"),
      properties: props,
      conditions: conditions,
      references: refs,
      raw: value,
      diagnostics: findings
    }
  end

  defp node(value, path, _, _) do
    %{
      path: Source.pointer(path),
      id: nil,
      type: nil,
      explanation: "Malformed construct; source value retained",
      interpretation: "malformed",
      properties: nil,
      conditions: [],
      references: [],
      raw: value,
      diagnostics: [Source.diagnostic("malformed_node", path, "Expected an object.")]
    }
  end

  defp unsupported(nil, path),
    do: [
      Source.diagnostic(
        "unsupported_type",
        path,
        "Event/action type is not in the supported explanation vocabulary."
      )
    ]

  defp unsupported(_, _), do: []
  defp properties_findings(nil, _), do: []

  defp properties_findings({_key, props}, _path) when is_map(props) and map_size(props) == 0,
    do: []

  defp properties_findings({key, props}, path) when is_map(props) do
    [
      Source.diagnostic(
        "properties_not_evaluated",
        path ++ [key],
        "Properties and expressions are retained exactly. Labels and references do not validate their Bubble runtime semantics."
      )
    ]
  end

  defp properties_findings({key, _}, path),
    do: [
      Source.diagnostic(
        "malformed_properties",
        path ++ [key],
        "Properties are not an object; value retained."
      )
    ]

  defp unknown_fields(value, path) do
    value
    |> Map.keys()
    |> Enum.reject(&(&1 in @structural))
    |> Enum.sort()
    |> Enum.map(
      &Source.diagnostic(
        "uninterpreted_field",
        path ++ [&1],
        "Field retained without semantic interpretation."
      )
    )
  end

  defp alias_findings(value, path) do
    [~w(type %x), ~w(id %id), ~w(properties %p), ~w(actions)]
    |> Enum.flat_map(fn keys ->
      if Enum.count(keys, &Map.has_key?(value, &1)) > 1,
        do: [
          Source.diagnostic(
            "alias_collision",
            path,
            "Multiple representations of #{hd(keys)} are present; the named field is displayed, all source values retained."
          )
        ],
        else: []
    end)
  end

  defp conditions(value, path) do
    own_conditions(value, path) ++
      Enum.flat_map(["properties", "%p"], fn key ->
        case Map.get(value, key) do
          props when is_map(props) -> own_conditions(props, path ++ [key])
          _ -> []
        end
      end)
  end

  defp own_conditions(value, path) do
    ~w(condition only_when %c)
    |> Enum.filter(&Map.has_key?(value, &1))
    |> Enum.map(fn key ->
      raw = Map.fetch!(value, key)
      {status, text} = condition_text(raw)

      %{
        path: Source.pointer(path ++ [key]),
        raw: raw,
        status: status,
        text: text,
        diagnostics:
          if(status == "unresolved",
            do: [
              Source.diagnostic(
                "unresolved_condition",
                path ++ [key],
                "Condition retained; no evaluation or guessed meaning."
              )
            ],
            else: []
          )
      }
    end)
  end

  defp condition_text(true), do: {"literal", "true"}
  defp condition_text(false), do: {"literal", "false"}

  defp condition_text(raw) do
    case Expr.render_condition(raw) do
      {:ok, text} -> {"unresolved", "Partial display: " <> text}
      :fallback -> {"unresolved", "Unresolved condition"}
    end
  end

  defp references(value, path, origin, index) when is_map(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, child} ->
      child_path = path ++ [key]

      own =
        case Map.get(@references, key) do
          nil -> []
          kind -> [reference(kind, child, child_path, origin, index)]
        end

      # Workflow actions are inventoried separately.
      if key in ~w(actions), do: own, else: own ++ references(child, child_path, origin, index)
    end)
  end

  defp references(value, path, origin, index) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {v, i} -> references(v, path ++ [i], origin, index) end)
  end

  defp references(_, _, _, _), do: []

  defp reference(kind, raw, path, {origin, type}, index) do
    kind = if kind == "element" and type == "ChangePage", do: "page", else: kind

    id =
      if kind == "data_type" and is_binary(raw),
        do: String.replace_prefix(raw, "custom.", ""),
        else: raw

    candidates =
      Map.get(index, {kind, id}, [])
      |> Enum.filter(&in_scope?(&1, kind, origin))
      |> Enum.uniq()
      |> Enum.sort_by(& &1.path)

    status =
      case candidates do
        [_] -> "resolved"
        [] -> "unavailable"
        _ -> "ambiguous"
      end

    %{kind: kind, value: raw, path: Source.pointer(path), status: status, candidates: candidates}
  end

  defp in_scope?(candidate, "action", origin) do
    workflow_path =
      case Enum.take(origin, -2) do
        ["actions", _] -> Enum.drop(origin, -2)
        _ -> origin
      end

    String.starts_with?(candidate.path, Source.pointer(workflow_path) <> "/")
  end

  defp in_scope?(candidate, "element", [section, owner | _]) do
    scope = Source.pointer([section, owner])
    candidate.path == scope or String.starts_with?(candidate.path, scope <> "/")
  end

  defp in_scope?(_, _, _), do: true
end
