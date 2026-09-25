defmodule BubbleEx.Index.Workflows do
  @moduledoc false

  # Workflow and action symbols from the `BubbleEx.Workflows` inventory, with
  # their calls, data writes, API calls, element targets and expression
  # reads; then the call graph, execution classes and invocation modes.

  alias BubbleEx.Diagnostic
  alias BubbleEx.Index.{Reads, Reference, Symbol, Types}
  alias BubbleEx.Workflows.Source

  # Action type -> {workflow property, call kind}.
  @calls %{
    "TriggerCustomEvent" => {"custom_event", :direct},
    "TriggerCustomEventFromReusable" => {"custom_event", :direct},
    "ScheduleCustom" => {"custom_event", :scheduled},
    "ScheduleAPIEvent" => {"api_event", :scheduled},
    "ScheduleAPIEventOnList" => {"api_event", :list_scheduled}
  }

  # Where each built-in action runs. Calls to custom events inherit the
  # callee's class; plugin and unknown actions are unclassified.
  @server ~w(NewThing ChangeThing DeleteThing DeleteListOfThings ChangeListOfThings CopyListOfThings
             MakeChangeCurrentUser ScheduleAPIEvent ScheduleAPIEventOnList CancelScheduledAPIEvent
             CancelListScheduledAPIEvent APIReturnData SignUp LogIn LogOut OAuthLogin CreateUserAccount
             ResetPassword SendEmail SendMagicLink SetTemporaryPassword UpdateCredentials
             DeleteUploadedFile)
  @client ~w(ShowElement HideElement ToggleElement ResetInputs ResetGroup OpenURL ChangePage
             SetCustomState SetFocusToElement DisplayGroupData DisplayListData AnimateElement
             ListGoToPage ListClear ScrollToElement ScrollToListEntry RefreshPage PauseWFClient
             TerminateWorkflow)

  @type ctx :: %{schema: map(), owners: map(), bubble_ids: map()}

  @spec build(map(), ctx()) :: {[Symbol.t()], [Reference.t()], [Diagnostic.t()]}
  def build(inventory, ctx) do
    built = Enum.map(inventory.workflows, &workflow(&1, ctx))

    symbols = Enum.flat_map(built, & &1.symbols)
    refs = Enum.flat_map(built, & &1.references)
    diags = Enum.flat_map(built, & &1.diagnostics)

    {classify(symbols, refs), refs, diags}
  end

  defp workflow(entry, ctx) do
    segments = segments(entry.path)
    event = entry.event
    props = map_or_empty(event.properties)
    wf_bubble_id = present(event.id) || to_string(entry.key)
    id = Symbol.id(:workflow, wf_bubble_id)
    backend? = match?(["api" | _], segments)
    ignore? = backend? and props["ignore_privacy_rules"] == true

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
          backend: backend?,
          public: if(backend?, do: props["expose"] == true),
          ignore_privacy_rules: if(ignore?, do: true)
        })
    }

    wf_ctx =
      Map.merge(ctx, %{
        trigger_type:
          if(event.type == "DatabaseTriggerEvent", do: text(props["data_trigger_type"])),
        attrs: if(ignore?, do: %{ignore_privacy_rules: true}, else: %{}),
        subject: %{workflow: wf_bubble_id}
      })

    event_raw = if is_map(entry.raw), do: Map.drop(entry.raw, ["actions"]), else: %{}

    event_refs =
      listens_to(event.type, props, id, entry.path, ctx) ++
        Reads.scan(event_raw, segments, id, wf_ctx)

    actions =
      entry.actions
      |> Enum.with_index()
      |> Enum.map(fn {action, index} -> action(action, index, id, wf_bubble_id, wf_ctx) end)

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
    ignore? = props["ignore_privacy_rules"] == true
    attrs = if ignore?, do: %{ignore_privacy_rules: true}, else: Map.get(ctx, :attrs, %{})
    ctx = %{ctx | attrs: attrs}

    symbol = %Symbol{
      id: id,
      kind: :action,
      bubble_id: bubble_id,
      parent: workflow_id,
      path: action.path,
      attrs: compact(%{type: type, index: index, ignore_privacy_rules: if(ignore?, do: true)})
    }

    {writes, diags} = writes(type, props, id, segments, ctx)

    own =
      calls(type, props, id, segments) ++
        api_action(type, id, action.path) ++
        targets(props, id, segments, ctx) ++ writes

    own = Enum.map(own, &%{&1 | attrs: Map.merge(&1.attrs, attrs)})
    reads = Reads.scan(action.raw, segments, id, ctx)

    %{symbols: [symbol], references: own ++ reads, diagnostics: diags}
  end

  # --- edges ------------------------------------------------------------------

  defp calls(type, props, id, segments) do
    with {key, kind} <- call_kind(type),
         target when is_binary(target) <- present(props[key]) do
      [
        %Reference{
          from: id,
          to: Symbol.id(:workflow, target),
          kind: :calls_workflow,
          path: Source.pointer(segments ++ ["properties", key]),
          attrs: %{call: kind}
        }
      ]
    else
      _ -> []
    end
  end

  # Recurring scheduling is recognized by type name; no sample of it exists in
  # the fixtures this was built against.
  defp call_kind(type) when is_binary(type) do
    cond do
      call = @calls[type] -> call
      String.contains?(type, "Recurring") -> {"api_event", :recurring}
      true -> nil
    end
  end

  defp call_kind(_), do: nil

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

  defp writes(type, props, id, segments, ctx) do
    case write_target(type, props, ctx) do
      nil ->
        {[], []}

      {operation, nil, source_key} ->
        case infer_type(operation, props, ctx.schema) do
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
             ]}

          data_type ->
            write_refs(
              operation,
              data_type,
              %{target: :inferred},
              props,
              id,
              segments,
              source_key
            )
        end

      {operation, data_type, source_key} ->
        write_refs(operation, data_type, %{}, props, id, segments, source_key)
    end
  end

  defp write_refs(operation, data_type, attrs, props, id, segments, source_key) do
    type_ref = %Reference{
      from: id,
      to: Symbol.id(:data_type, data_type),
      kind: :writes_type,
      path: Source.pointer(segments ++ ["properties", source_key]),
      attrs: Map.put(attrs, :operation, operation)
    }

    {[type_ref | field_writes(props, operation, data_type, attrs, id, segments)], []}
  end

  # When the changed thing's expression has no known type (element data,
  # previous steps, …), the type is still certain if exactly one data type
  # has every changed field.
  defp infer_type(:update, props, schema) do
    keys = for {_, %{"key" => key}} <- ordered(props["changes"]), is_binary(key), do: key

    candidates =
      for {type, %{fields: fields}} <- schema,
          keys != [],
          Enum.all?(keys, &Map.has_key?(fields, &1)),
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

  # --- execution class and invocation modes -----------------------------------

  defp classify(symbols, refs) do
    actions = for %{kind: :action} = s <- symbols, into: %{}, do: {s.id, s}
    workflows = for %{kind: :workflow} = s <- symbols, into: %{}, do: {s.id, s}

    calls =
      for %{kind: :calls_workflow} = r <- refs,
          caller = actions[r.from],
          do: {caller.parent, r.to, r.attrs.call}

    own = own_classes(symbols)

    inherits =
      for {from, to, kind} <- calls,
          kind in [:direct, :scheduled],
          Map.has_key?(workflows, to),
          do: {from, to}

    effective = propagate(own, inherits)
    modes = modes(workflows, calls)

    Enum.map(symbols, fn
      %{kind: :workflow} = s ->
        {classes, unknown} = Map.fetch!(effective, s.id)

        attrs =
          Map.merge(s.attrs, %{
            execution_class: class(s, classes, unknown),
            invocation_modes: Map.get(modes, s.id, []) |> Enum.uniq() |> Enum.sort()
          })

        attrs = if unknown > 0, do: Map.put(attrs, :unclassified_actions, unknown), else: attrs
        %{s | attrs: attrs}

      s ->
        s
    end)
  end

  defp own_classes(symbols) do
    base = for %{kind: :workflow} = s <- symbols, into: %{}, do: {s.id, {MapSet.new(), 0}}

    Enum.reduce(symbols, base, fn
      %{kind: :action, parent: wf, attrs: attrs}, acc ->
        Map.update!(acc, wf, &add_class(&1, action_class(attrs[:type])))

      _, acc ->
        acc
    end)
  end

  defp add_class({classes, unknown}, :unknown), do: {classes, unknown + 1}
  defp add_class(own, :inherit), do: own
  defp add_class({classes, unknown}, class), do: {MapSet.put(classes, class), unknown}

  defp action_class(type) when type in @server, do: :server
  defp action_class(type) when type in @client, do: :client
  defp action_class("apiconnector2-" <> _), do: :server

  defp action_class(type) when is_binary(type) do
    case call_kind(type) do
      {"custom_event", _} -> :inherit
      {_, _} -> :server
      nil -> :unknown
    end
  end

  defp action_class(_), do: :unknown

  # A workflow that triggers a custom event runs that event's actions too.
  # Iterate to a fixpoint (class sets only grow, so this terminates).
  defp propagate(own, inherits) do
    next =
      Enum.reduce(inherits, own, fn {from, to}, acc ->
        {callee, _} = Map.fetch!(acc, to)

        Map.update!(acc, from, fn {classes, unknown} ->
          {MapSet.union(classes, callee), unknown}
        end)
      end)

    if next == own, do: own, else: propagate(next, inherits)
  end

  defp class(%{attrs: %{backend: true}}, _classes, _unknown), do: :server_backed

  defp class(_s, classes, unknown) do
    case {MapSet.member?(classes, :client), MapSet.member?(classes, :server)} do
      {true, true} -> :mixed
      {_, true} -> :server_backed
      {true, false} -> :client_only
      {false, false} when unknown > 0 -> :unknown
      {false, false} -> :client_only
    end
  end

  defp modes(workflows, calls) do
    own =
      for {id, s} <- workflows, into: %{} do
        {id, event_modes(s.attrs[:event_type], s.attrs)}
      end

    Enum.reduce(calls, own, fn {_from, to, kind}, acc ->
      if Map.has_key?(acc, to), do: Map.update!(acc, to, &[mode(kind) | &1]), else: acc
    end)
  end

  defp event_modes("APIEvent", attrs), do: if(attrs[:public], do: [:public_http], else: [])
  defp event_modes("CustomEvent", _), do: []
  defp event_modes("DatabaseTriggerEvent", _), do: [:database_trigger]
  defp event_modes("DoInterval", _), do: [:recurring]
  defp event_modes(_, _), do: [:event]

  defp mode(:direct), do: :direct
  defp mode(:recurring), do: :recurring
  defp mode(_scheduled), do: :scheduled

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

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_), do: nil

  defp map_or_empty(map) when is_map(map), do: map
  defp map_or_empty(_), do: %{}

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
