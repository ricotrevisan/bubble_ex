defmodule BubbleEx.Index.Workflows do
  @moduledoc false

  # Workflow and action symbols from the `BubbleEx.Workflows` inventory, with
  # their calls, data writes, API calls, element targets and expression
  # reads; then the call graph, execution classes and invocation modes.

  alias BubbleEx.Diagnostic
  alias BubbleEx.Index.{Reads, Reference, Symbol, Types, WorkflowAnalysis}
  alias BubbleEx.Workflows.Source

  # Action type -> {workflow property, call kind}.
  @calls %{
    "TriggerCustomEvent" => {"custom_event", :direct},
    "TriggerCustomEventFromReusable" => {"custom_event", :direct},
    "ScheduleCustom" => {"custom_event", :scheduled},
    "ScheduleAPIEvent" => {"api_event", :scheduled},
    "ScheduleAPIEventOnList" => {"api_event", :list_scheduled}
  }

  # UNVERIFIED (follow-up): no available export contains a recurring schedule, so
  # these Bubble action type names are assumptions to confirm against one.
  @recurring ~w(ScheduleAPIEventRecurring ScheduleRecurringAPIEvent)

  @type ctx :: %{
          schema: map(),
          owners: map(),
          bubble_ids: map(),
          live_fields: %{String.t() => MapSet.t()}
        }

  @spec build(map(), ctx()) :: {[Symbol.t()], [Reference.t()], [Diagnostic.t()]}
  def build(inventory, ctx) do
    built = Enum.map(inventory.workflows, &workflow(&1, ctx))

    symbols = Enum.flat_map(built, & &1.symbols)
    refs = Enum.flat_map(built, & &1.references)
    diags = Enum.flat_map(built, & &1.diagnostics)

    {symbols, refs} = WorkflowAnalysis.analyze(symbols, refs)
    {symbols, refs, diags}
  end

  @doc "Call kind of an action type: `{workflow property, kind}` or nil."
  @spec call_kind(term()) :: {String.t(), atom()} | nil
  def call_kind(type) when type in @recurring, do: {"api_event", :recurring}
  def call_kind(type) when is_binary(type), do: @calls[type]
  def call_kind(_), do: nil

  defp workflow(entry, ctx) do
    segments = segments(entry.path)
    event = entry.event
    props = map_or_empty(event.properties)
    wf_bubble_id = present(event.id) || to_string(entry.key)
    id = Symbol.id(:workflow, wf_bubble_id)
    backend? = match?(["api" | _], segments)

    symbol = %Symbol{
      id: id,
      kind: :workflow,
      bubble_id: wf_bubble_id,
      name: text(props["wf_name"]) || text(props["event_name"]),
      parent: owner(segments, ctx),
      path: entry.path,
      attrs:
        compact(%{
          event_type: event.type,
          folder: text(props["wf_folder"]),
          backend: backend?,
          public: if(backend?, do: props["expose"] == true),
          ignore_privacy_rules: if(backend?, do: boolean(props["ignore_privacy_rules"]))
        })
    }

    wf_ctx =
      Map.merge(ctx, %{
        trigger_type:
          if(event.type == "DatabaseTriggerEvent", do: text(props["data_trigger_type"])),
        step_types: %{},
        subject: %{workflow: wf_bubble_id}
      })

    event_raw = if is_map(entry.raw), do: Map.drop(entry.raw, ["actions"]), else: %{}

    event_refs =
      listens_to(event.type, props, id, entry.path, ctx) ++
        Reads.scan(event_raw, segments, id, wf_ctx)

    # Each step's result type is known to the steps after it.
    {actions, _} =
      entry.actions
      |> Enum.with_index()
      |> Enum.map_reduce(wf_ctx, fn {action, index}, ctx ->
        built = action(action, index, id, wf_bubble_id, ctx)

        ctx =
          if built.result_type && built.bubble_id,
            do: %{ctx | step_types: Map.put(ctx.step_types, built.bubble_id, built.result_type)},
            else: ctx

        {built, ctx}
      end)

    %{
      symbols: [symbol | Enum.flat_map(actions, & &1.symbols)],
      references: event_refs ++ Enum.flat_map(actions, & &1.references),
      diagnostics: Enum.flat_map(actions, & &1.diagnostics)
    }
  end

  defp action(action, index, workflow_id, wf_bubble_id, ctx) do
    props = map_or_empty(action.properties)
    type = action.type
    bubble_id = present(action.id) || "#{wf_bubble_id}/#{action.source_key}"
    id = Symbol.id(:action, bubble_id)
    segments = segments(action.path)
    ignore = boolean(props["ignore_privacy_rules"])

    symbol = %Symbol{
      id: id,
      kind: :action,
      bubble_id: bubble_id,
      parent: workflow_id,
      path: action.path,
      attrs: compact(%{type: type, index: index, ignore_privacy_rules: ignore})
    }

    {writes, diags, result_type} = writes(type, props, id, segments, ctx)

    own =
      calls(type, props, id, segments, ignore) ++
        api_action(type, id, action.path) ++
        targets(props, id, segments, ctx) ++ writes

    reads = Reads.scan(action.raw, segments, id, ctx)

    %{
      symbols: [symbol],
      references: own ++ reads,
      diagnostics: diags,
      bubble_id: present(action.id),
      result_type: result_type
    }
  end

  # --- edges ------------------------------------------------------------------

  # The action's own `ignore_privacy_rules` setting is recorded on the call
  # edge; the privacy the callee runs with is its own (see WorkflowAnalysis).
  defp calls(type, props, id, segments, ignore) do
    with {key, kind} <- call_kind(type),
         target when is_binary(target) <- present(props[key]) do
      [
        %Reference{
          from: id,
          to: Symbol.id(:workflow, target),
          kind: :calls_workflow,
          path: Source.pointer(segments ++ ["properties", key]),
          attrs: compact(%{call: kind, action_ignore_privacy_rules: ignore})
        }
      ]
    else
      _ -> []
    end
  end

  defp api_action("apiconnector2-" <> ref, id, path) do
    case String.split(ref, ".", parts: 2) do
      [group, call] ->
        [
          %Reference{
            from: id,
            to: Symbol.id(:api_call, [group, call]),
            kind: :calls_api,
            path: path,
            attrs: %{via: :action}
          }
        ]

      _ ->
        []
    end
  end

  defp api_action(_, _, _), do: []

  defp targets(props, id, segments, ctx) do
    case element_ref(props) do
      nil ->
        []

      element ->
        [
          %Reference{
            from: id,
            to: element_symbol(element, ctx),
            kind: :targets_element,
            path: Source.pointer(segments ++ ["properties", "element_id"])
          }
        ]
    end
  end

  defp listens_to("DatabaseTriggerEvent", props, id, path, _ctx) do
    case Types.data_type_key(props["data_trigger_type"]) do
      nil ->
        []

      key ->
        [
          %Reference{
            from: id,
            to: Symbol.id(:data_type, key),
            kind: :listens_to,
            path: path <> "/properties/data_trigger_type"
          }
        ]
    end
  end

  defp listens_to(_type, props, id, path, ctx) do
    case element_ref(props) do
      nil ->
        []

      element ->
        [
          %Reference{
            from: id,
            to: element_symbol(element, ctx),
            kind: :listens_to,
            path: path <> "/properties/element_id"
          }
        ]
    end
  end

  # Bubble IDs never contain whitespace; values such as "Current page" name
  # the context, not a definition.
  defp element_ref(props) do
    case present(props["element_id"]) do
      nil -> nil
      value -> if String.match?(value, ~r/\s/), do: nil, else: value
    end
  end

  defp element_symbol(bubble_id, ctx),
    do: Map.get(ctx.bubble_ids, bubble_id, Symbol.id(:element, bubble_id))

  # --- data writes --------------------------------------------------------------

  # Returns the write edges, diagnostics, and the step's result type (the
  # record(s) it creates or changes) for later previous-step references.
  defp writes(type, props, id, segments, ctx) do
    case write_target(type, props, ctx) do
      nil ->
        {[], [], nil}

      {operation, nil, source_key} ->
        case infer_type(operation, props, ctx.live_fields) do
          nil ->
            {[],
             [
               Diagnostic.new(
                 :index_unresolved_reference,
                 segments ++ ["properties", source_key],
                 "#{type} target data type could not be resolved; its writes are not indexed",
                 subject: ctx.subject,
                 details: %{action: id, action_type: type}
               )
             ], nil}

          data_type ->
            attrs = %{target: :inferred}
            refs = write_refs(operation, data_type, attrs, props, id, segments, source_key)
            {refs, [], result_type(type, data_type)}
        end

      {operation, data_type, source_key} ->
        refs = write_refs(operation, data_type, %{}, props, id, segments, source_key)
        {refs, [], result_type(type, data_type)}
    end
  end

  defp result_type(type, data_type) when type in ~w(NewThing ChangeThing),
    do: Types.record_type(data_type)

  defp result_type(type, data_type) when type in ~w(CopyListOfThings ChangeListOfThings),
    do: "list." <> Types.record_type(data_type)

  defp result_type(_, _), do: nil

  defp write_refs(operation, data_type, attrs, props, id, segments, source_key) do
    type_ref = %Reference{
      from: id,
      to: Symbol.id(:data_type, data_type),
      kind: :writes_type,
      path: Source.pointer(segments ++ ["properties", source_key]),
      attrs: Map.put(attrs, :operation, operation)
    }

    [type_ref | field_writes(props, operation, data_type, attrs, id, segments)]
  end

  # When the changed thing's expression has no known type (element data,
  # …), the type is still certain if exactly one data type that is not
  # deleted has every changed field (deleted fields excluded).
  defp infer_type(:update, props, live_fields) do
    keys = for {_, %{"key" => key}} <- ordered(props["changes"]), is_binary(key), do: key

    candidates =
      for {type, fields} <- live_fields,
          keys != [],
          Enum.all?(keys, &MapSet.member?(fields, &1)),
          do: type

    case candidates do
      [type] -> type
      _ -> nil
    end
  end

  defp infer_type(_, _, _), do: nil

  defp write_target("NewThing", props, _ctx),
    do: {:insert, Types.data_type_key(props["thing_type"]), "thing_type"}

  defp write_target("ChangeThing", props, ctx),
    do:
      {:update,
       Types.data_type_key(Reads.type_of(props["to_change"], ctx)) ||
         Types.data_type_key(props["thing_type"]), "to_change"}

  defp write_target("ChangeListOfThings", props, ctx),
    do:
      {:update,
       Types.data_type_key(props["type_to_change"]) ||
         Types.data_type_key(Reads.type_of(props["to_change"], ctx)), "to_change"}

  defp write_target("MakeChangeCurrentUser", _props, _ctx), do: {:update, "user", "changes"}

  defp write_target("DeleteThing", props, ctx),
    do: {:delete, Types.data_type_key(Reads.type_of(props["to_delete"], ctx)), "to_delete"}

  defp write_target("DeleteListOfThings", props, ctx),
    do:
      {:delete,
       Types.data_type_key(props["type_to_delete"]) ||
         Types.data_type_key(Reads.type_of(props["to_delete"], ctx)), "to_delete"}

  defp write_target("CopyListOfThings", props, ctx),
    do:
      {:insert,
       Types.data_type_key(props["type_to_copy"]) ||
         Types.data_type_key(Reads.type_of(props["to_copy"], ctx)), "type_to_copy"}

  defp write_target(_, _, _), do: nil

  defp field_writes(props, operation, data_type, attrs, id, segments) do
    {key, entries} =
      case operation do
        :insert -> {"initial_values", props["initial_values"]}
        _ -> {"changes", props["changes"]}
      end

    entries
    |> ordered()
    |> Enum.flat_map(fn {ekey, entry} ->
      case entry do
        %{"key" => field} when is_binary(field) ->
          [
            %Reference{
              from: id,
              to: Symbol.id(:field, [data_type, field]),
              kind: :writes_field,
              path: Source.pointer(segments ++ ["properties", key, ekey]),
              attrs: Map.merge(attrs, %{operation: operation, change: change(entry["action"])})
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp change(op) when is_binary(op), do: op
  defp change(_), do: "set"

  defp ordered(map) when is_map(map), do: Enum.sort_by(map, &elem(&1, 0))

  defp ordered(list) when is_list(list),
    do: list |> Enum.with_index() |> Enum.map(fn {v, i} -> {i, v} end)

  defp ordered(_), do: []

  # --- helpers ----------------------------------------------------------------

  defp owner(["api" | _], _ctx), do: nil
  defp owner([section, key | _], ctx), do: Map.get(ctx.owners, {section, key})
  defp owner(_, _), do: nil

  @spec segments(String.t()) :: [String.t()]
  def segments(pointer) do
    pointer
    |> String.split("/")
    |> tl()
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
  end

  defp boolean(value) when is_boolean(value), do: value
  defp boolean(_), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_), do: nil

  defp map_or_empty(map) when is_map(map), do: map
  defp map_or_empty(_), do: %{}

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
