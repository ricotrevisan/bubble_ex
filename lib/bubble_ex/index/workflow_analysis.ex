defmodule BubbleEx.Index.WorkflowAnalysis do
  @moduledoc false

  # Whole-app workflow facts that need the call graph: the privacy context
  # each workflow runs in, execution classes and invocation modes.

  alias BubbleEx.Index.{Reference, Symbol}
  alias BubbleEx.Index.Workflows

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

  @spec analyze([Symbol.t()], [Reference.t()]) :: {[Symbol.t()], [Reference.t()]}
  def analyze(symbols, refs) do
    workflows = for %{kind: :workflow} = s <- symbols, into: %{}, do: {s.id, s}
    parents = for %{kind: :action} = s <- symbols, into: %{}, do: {s.id, s.parent}

    calls =
      for %{kind: :calls_workflow} = r <- refs,
          caller = parents[r.from],
          do: {caller, r.to, r.attrs.call}

    ignoring = ignoring_privacy(workflows, calls)
    {annotate(symbols, calls, ignoring), stamp(refs, parents, ignoring)}
  end

  # --- privacy ----------------------------------------------------------------

  # A backend workflow runs ignoring privacy rules when its own setting says
  # so. A custom event runs in its caller's context, so it also ignores them
  # when triggered (or scheduled) from a workflow that does.
  defp ignoring_privacy(workflows, calls) do
    own =
      for {id, %{attrs: %{backend: true, ignore_privacy_rules: true}}} <- workflows,
          into: MapSet.new(),
          do: id

    inherits =
      for {from, to, _} <- calls,
          match?(%{attrs: %{event_type: "CustomEvent"}}, workflows[to]),
          do: {from, to}

    fixpoint(own, &spread(&1, inherits))
  end

  defp spread(set, inherits) do
    Enum.reduce(inherits, set, fn {from, to}, acc ->
      if MapSet.member?(acc, from), do: MapSet.put(acc, to), else: acc
    end)
  end

  # Every reference made inside a workflow that runs ignoring privacy rules is
  # flagged. A call edge also records whether its callee runs ignoring them.
  defp stamp(refs, parents, ignoring) do
    Enum.map(refs, fn r ->
      workflow = Map.get(parents, r.from, r.from)

      r =
        if MapSet.member?(ignoring, workflow),
          do: put_attr(r, :ignore_privacy_rules, true),
          else: r

      if r.kind == :calls_workflow and String.starts_with?(r.to, "workflow:"),
        do: put_attr(r, :callee_ignore_privacy_rules, MapSet.member?(ignoring, r.to)),
        else: r
    end)
  end

  defp put_attr(ref, key, value), do: %{ref | attrs: Map.put(ref.attrs, key, value)}

  # --- execution class and invocation modes -----------------------------------

  defp annotate(symbols, calls, ignoring) do
    workflows = for %{kind: :workflow} = s <- symbols, into: %{}, do: {s.id, s}

    inherits =
      for {from, to, kind} <- calls,
          kind in [:direct, :scheduled],
          Map.has_key?(workflows, to),
          do: {from, to}

    {own, unclassified} = own_classes(symbols)
    effective = fixpoint(own, &inherit(&1, inherits))
    modes = modes(workflows, calls)

    Enum.map(symbols, fn
      %{kind: :workflow} = s ->
        {classes, unknown?} = Map.fetch!(effective, s.id)

        attrs =
          Map.merge(s.attrs, %{
            execution_class: class(s, classes, unknown?),
            invocation_modes: modes |> Map.get(s.id, []) |> Enum.uniq() |> Enum.sort()
          })

        attrs = put_count(attrs, Map.get(unclassified, s.id, 0))

        attrs =
          if MapSet.member?(ignoring, s.id),
            do: Map.put(attrs, :runs_ignoring_privacy_rules, true),
            else: attrs

        %{s | attrs: attrs}

      s ->
        s
    end)
  end

  defp put_count(attrs, 0), do: attrs
  defp put_count(attrs, n), do: Map.put(attrs, :unclassified_actions, n)

  # Per workflow: {known classes, whether any action is unclassified}, plus
  # the unclassified action count.
  defp own_classes(symbols) do
    base = for %{kind: :workflow} = s <- symbols, into: %{}, do: {s.id, {MapSet.new(), false}}

    Enum.reduce(symbols, {base, %{}}, fn
      %{kind: :action, parent: wf, attrs: attrs}, {acc, counts} ->
        case action_class(attrs[:type]) do
          :unknown ->
            {Map.update!(acc, wf, fn {c, _} -> {c, true} end),
             Map.update(counts, wf, 1, &(&1 + 1))}

          :inherit ->
            {acc, counts}

          class ->
            {Map.update!(acc, wf, fn {c, u} -> {MapSet.put(c, class), u} end), counts}
        end

      _, acc ->
        acc
    end)
  end

  # A workflow that triggers a custom event runs that event's actions too,
  # including unclassified ones.
  defp inherit(state, inherits) do
    Enum.reduce(inherits, state, fn {from, to}, acc ->
      {callee, callee_unknown?} = Map.fetch!(acc, to)

      Map.update!(acc, from, fn {classes, unknown?} ->
        {MapSet.union(classes, callee), unknown? or callee_unknown?}
      end)
    end)
  end

  defp action_class(type) when type in @server, do: :server
  defp action_class(type) when type in @client, do: :client
  defp action_class("apiconnector2-" <> _), do: :server

  defp action_class(type) do
    case Workflows.call_kind(type) do
      {"custom_event", _} -> :inherit
      {_, _} -> :server
      nil -> :unknown
    end
  end

  defp class(%{attrs: %{backend: true}}, _classes, _unknown?), do: :server_backed

  defp class(_s, classes, unknown?) do
    case {MapSet.member?(classes, :client), MapSet.member?(classes, :server)} do
      {true, true} -> :mixed
      {_, true} -> :server_backed
      {true, false} -> :client_only
      {false, false} when unknown? -> :unknown
      {false, false} -> :client_only
    end
  end

  defp modes(workflows, calls) do
    own =
      for {id, s} <- workflows, into: %{}, do: {id, event_modes(s.attrs[:event_type], s.attrs)}

    Enum.reduce(calls, own, fn {_from, to, kind}, acc ->
      if Map.has_key?(acc, to), do: Map.update!(acc, to, &[mode(kind) | &1]), else: acc
    end)
  end

  # `:event` covers every page, element and plugin event (clicks, page load,
  # input changes, conditions becoming true, log in/out, plugin events, …).
  defp event_modes("APIEvent", attrs), do: if(attrs[:public], do: [:public_http], else: [])
  defp event_modes("CustomEvent", _), do: []
  defp event_modes("DatabaseTriggerEvent", _), do: [:database_trigger]
  defp event_modes("DoInterval", _), do: [:recurring]
  defp event_modes(_, _), do: [:event]

  defp mode(:direct), do: :direct
  defp mode(:recurring), do: :recurring
  defp mode(_scheduled), do: :scheduled

  # Iterate a monotone step to its fixpoint (sets only grow, so it ends).
  defp fixpoint(state, step) do
    next = step.(state)
    if next == state, do: state, else: fixpoint(next, step)
  end
end
