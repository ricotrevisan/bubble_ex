defmodule BubbleEx.Target.Phoenix.BlockedWorkflows do
  @moduledoc """
  The owner's list of workflows that cannot run (WTF-607), printed by
  `BubbleEx.Target.Phoenix.render/2` as the generated
  `.wtf/blocked_workflows.md`, next to the generation's other reports.

  A workflow runs whole or not at all: when one of its steps, its event or
  its "Only when" condition was not converted, or it triggers or
  schedules a workflow that cannot run, the runtime refuses it before its
  first step (`blocked` in the page's `__bubble__(:workflows)`, a backend
  body's `not_lowered`), so the steps before the one that blocks do not
  run either. In Bubble they would have. This report tells the owner, in
  Bubble's words, which workflows that is and why, so they can change the
  workflow in Bubble or decide about it.

  `notes/3` reads the page and reusable-element workflows
  (`BubbleEx.Target.Elixir.FrontendWorkflows.Spec`) and the backend ones
  (`BubbleEx.Target.Ash.Workflows.Spec`): one note per workflow that is
  not native (`native?/1` of its Spec) and not disabled in the editor,
  for the **first** thing that blocks it, in Bubble order: its event or
  condition, else its first step that was not converted or that triggers
  or schedules a workflow that cannot run. A note:

      %{workflow, symbol, where, event, name, blocker, reason, detail, plugin}

    * `where` - `{:page | :reusable, name}` or `{:backend, nil}`
    * `blocker` - `:event` (the event or the "Only when" condition),
      `{:step, index, type}` (Bubble's action type) or `{:calls, index,
      type, names}` (the step running workflows that cannot run, by name;
      `index` nil when no step names them)
    * `reason` - the group: a `BubbleEx.Plan.Residue` reason, the first by
      `reasons/0` order when a step has several, or `:calls_blocked`
    * `detail` - what the reason names (constructs, inputs, options), for
      the owner's developer; `plugin` the plugin ID of a plugin reason

  `markdown/1` groups them by reason, largest group first: a short summary
  table, then per reason one line per workflow, with why and what the
  owner can do. A printer only: names come from the normalized frontend
  (`:frontend`) and plugin names from the public catalog
  (`BubbleEx.Plugins.Catalog`); without them a Bubble ID stands in.
  """

  alias BubbleEx.Plugins.Catalog
  alias BubbleEx.Target.Ash.Workflows.Spec, as: BackendSpec
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec, as: FrontendSpec

  @path ".wtf/blocked_workflows.md"

  # Group order when a step has several reasons: the one the owner can act
  # on most directly first.
  @reasons [
    :plugin_action,
    :script_action,
    :plugin_event,
    :trigger_dropped,
    :reads_dropped_plugin,
    :uses_dropped,
    :auth_action,
    :unsupported_action,
    :unsupported_event,
    :api_connector_action,
    :unresolved_reference,
    :trigger_not_normalized,
    :trigger_in_runtime_template,
    :target_not_rendered,
    :backend_workflow,
    :unavailable_input,
    :unsupported_option,
    :uncompiled_expression,
    :calls_blocked
  ]

  # Reasons a workflow's own residue has when it is about its event.
  @event_reasons [
    :plugin_event,
    :unsupported_event,
    :trigger_not_normalized,
    :trigger_in_runtime_template,
    :trigger_dropped
  ]

  @type note :: %{
          workflow: String.t(),
          symbol: String.t(),
          where: {:page | :reusable, String.t()} | {:backend, nil},
          event: String.t(),
          name: String.t() | nil,
          blocker:
            :event
            | {:step, pos_integer(), String.t() | nil}
            | {:calls, pos_integer() | nil, String.t() | nil, [String.t()]},
          reason: atom(),
          detail: [String.t()],
          plugin: String.t() | nil
        }

  @doc "The report's path in the rendered project."
  @spec path() :: String.t()
  def path, do: @path

  @doc "The reason groups, in tie-break order."
  @spec reasons() :: [atom()]
  def reasons, do: @reasons

  @doc """
  One note per workflow that cannot run, sorted by where it is, then its
  Bubble ID. Option `:frontend` (`BubbleEx.Frontend.Normalized`, for
  page, reusable and element names).
  """
  @spec notes(FrontendSpec.t() | nil, BackendSpec.t() | nil, keyword()) :: [note()]
  def notes(frontend_spec, backend_spec, opts \\ []) do
    names = names(Keyword.get(opts, :frontend))
    frontend = if frontend_spec, do: FrontendSpec.workflows(frontend_spec), else: []
    backend = if backend_spec, do: BackendSpec.actions(backend_spec), else: []
    callee_names = callee_names(frontend, backend, names)

    front =
      for w <- frontend, not w.disabled?, not FrontendSpec.native?(w) do
        surface = frontend_spec.surfaces[w.surface]

        note(w, callee_names, names, %{
          where: {surface.kind, names[w.surface] || w.surface},
          event: frontend_event(w, names),
          name: w.name
        })
      end

    back =
      for a <- backend, not BackendSpec.native?(a) do
        note(a, callee_names, names, %{
          where: {:backend, nil},
          event: backend_event(a),
          name: a.bubble_name
        })
      end

    Enum.sort_by(front ++ back, &{where_order(&1.where), &1.workflow})
  end

  @doc "How many notes per reason, as `%{\"reason\" => count}`."
  @spec counts([note()]) :: %{String.t() => pos_integer()}
  def counts(notes), do: Enum.frequencies_by(notes, &Atom.to_string(&1.reason))

  @doc "The owner's report: the notes grouped by reason, largest group first."
  @spec markdown([note()]) :: String.t()
  def markdown([]) do
    """
    # Workflows that cannot run yet

    Every workflow of the app was converted completely: none is refused.
    """
  end

  def markdown(notes) do
    groups =
      notes
      |> Enum.group_by(& &1.reason)
      |> Enum.sort_by(fn {reason, ns} ->
        {-length(ns), Enum.find_index(@reasons, &(&1 == reason))}
      end)

    summary =
      Enum.map_join(groups, "\n", fn {reason, ns} ->
        "| #{title(reason)} | #{length(ns)} |"
      end)

    sections = Enum.map_join(groups, "\n", fn {reason, ns} -> section(reason, ns) end)

    """
    # Workflows that cannot run yet

    #{count(length(notes))} of this app cannot run in the converted app. A workflow
    runs whole or not at all: when one part of it could not be converted,
    none of its steps run, not even the steps before that part (in Bubble
    they would). When a click or an input change triggers one, the page
    shows "This action isn't available yet." instead.

    This list is from the latest conversion, not from the code: the
    workflow files are yours after the first conversion, so a workflow you
    fix in Bubble later also needs its file updated by a developer, and one
    a developer wrote by hand stays listed here.

    Each workflow is listed once, under the first thing that stops it. Fix
    that and it may show up under the next one. For each, you can:

    - **change it in Bubble** (what to change is under each reason below), then
      convert the app again, or
    - **drop it** if you don't need it: record a drop decision for its ID
      (`workflow:...`) in your decisions file, and the conversion leaves it
      out (workflows that call it then need changing too).

    A developer can also write the missing part by hand in the generated
    code (search for `TODO(bubble:`).

    | Why it cannot run | Workflows |
    |---|---|
    #{summary}

    #{sections}
    """
  end

  # --- notes --------------------------------------------------------------------------

  defp note(w, callee_names, names, base) do
    {blocker, residue} = blocker(w, callee_names)
    entry = primary(residue)
    reason = if entry, do: entry.reason, else: :calls_blocked

    Map.merge(base, %{
      workflow: w.workflow,
      symbol: "workflow:" <> w.workflow,
      blocker: blocker,
      reason: reason,
      detail: if(entry, do: detail(entry, names), else: []),
      plugin: plugin(entry)
    })
  end

  # The first thing that stops it, in Bubble order: its event or
  # condition, then its steps, each either not converted or running a
  # workflow that cannot run.
  defp blocker(%{residue: [_ | _] = residue}, _callee_names), do: {:event, residue}

  defp blocker(w, callee_names) do
    blocked = for "workflow:" <> id <- Map.get(w, :blocked_by, []), into: MapSet.new(), do: id
    name = &Map.get(callee_names, &1, "workflow:" <> &1)

    step =
      w.steps
      |> Enum.sort_by(& &1.index)
      |> Enum.find(&(&1.residue != [] or Enum.any?(step_callees(&1), fn id -> id in blocked end)))

    cond do
      step && step.residue != [] ->
        {{:step, step.index, step.type}, step.residue}

      step ->
        callees = step |> step_callees() |> Enum.filter(&(&1 in blocked)) |> Enum.map(name)
        {{:calls, step.index, step.type, Enum.sort(callees)}, []}

      true ->
        {{:calls, nil, nil, blocked |> Enum.map(name) |> Enum.sort()}, []}
    end
  end

  # The workflows a step triggers or schedules (Bubble IDs): a custom
  # event (page) or a backend workflow (page or backend).
  defp step_callees(%{args: args}) when is_map(args) do
    [Map.get(args, :callee), Map.get(args, :backend), Map.get(args, :workflow)]
    |> Enum.flat_map(fn
      %{workflow: id} when is_binary(id) -> [id]
      id when is_binary(id) -> [id]
      _ -> []
    end)
  end

  defp step_callees(_step), do: []

  defp primary([]), do: nil

  defp primary(residue),
    do: Enum.min_by(residue, &(Enum.find_index(@reasons, fn r -> r == &1.reason end) || 999))

  defp plugin(%{detail: %{plugin: id}}) when is_binary(id) do
    case Catalog.fetch(id) do
      {:ok, %{name: name}} -> %{id: id, name: name}
      :error -> %{id: id, name: nil}
    end
  end

  defp plugin(_entry), do: nil

  # The event already names the element that starts the workflow.
  defp detail(%{reason: reason}, _names) when reason in @event_reasons, do: []

  defp detail(%{detail: detail}, names) do
    element =
      with id when is_binary(id) <- detail[:element],
           do: quoted(names[String.replace_prefix(id, "element:", "")]) || id

    ([element] ++
       Enum.flat_map(
         [:constructs, :inputs, :options, :reference, :type, :symbol, :reads, :call, :why],
         &List.wrap(Map.get(detail, &1))
       ))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_text/1)
    |> Enum.uniq()
  end

  defp to_text(v) when is_binary(v), do: v
  defp to_text(v) when is_atom(v), do: Atom.to_string(v)
  defp to_text(v), do: inspect(v)

  # The names of workflows another one may call: custom events by name.
  defp callee_names(frontend, backend, names) do
    front =
      Map.new(frontend, fn w ->
        {w.workflow, quoted(w.name) || frontend_event(w, names)}
      end)

    back =
      Map.new(
        backend,
        &{&1.workflow,
         Enum.join(["backend workflow", quoted(&1.bubble_name) || &1.workflow], " ")}
      )

    Map.merge(front, back)
  end

  defp frontend_event(w, names) do
    element =
      quoted(names[w.element]) ||
        if(is_binary(w.element), do: "element " <> w.element, else: "an element")

    event_text(w, element)
  end

  defp event_text(%{kind: :click}, element), do: "when #{element} is clicked"
  defp event_text(%{kind: :input_change}, element), do: "when #{element}'s value is changed"
  defp event_text(%{kind: :popup_opened}, element), do: "when popup #{element} is opened"
  defp event_text(%{kind: :popup_closed}, element), do: "when popup #{element} is closed"

  defp event_text(%{kind: :js_publish}, element),
    do: "when Javascript to Bubble element #{element} publishes"

  defp event_text(%{kind: :condition_true, run_when: :once}, _element),
    do: "when a condition is true (just once)"

  defp event_text(%{kind: :custom_event, name: name}, _element),
    do: "custom event #{quoted(name) || "(unnamed)"}"

  defp event_text(%{kind: kind}, _element),
    do:
      Map.get(
        %{
          page_load: "when the page is loaded",
          condition_true: "when a condition is true",
          do_every: "do every N seconds",
          logged_in: "when the user is logged in",
          logged_out: "when the user is logged out"
        },
        kind,
        "on an event of a plugin or of a kind that is not converted"
      )

  defp backend_event(%{kind: :api}), do: "API workflow"
  defp backend_event(%{kind: :database_trigger}), do: "database trigger event"
  defp backend_event(%{kind: :custom_event}), do: "backend custom event"
  defp backend_event(_a), do: "backend workflow"

  defp quoted(nil), do: nil
  defp quoted(""), do: nil
  defp quoted(name), do: "\"" <> clean(name) <> "\""

  # Names are the owner's text: one line, no Markdown table or code breaks.
  defp clean(text), do: text |> to_string() |> String.replace(~r/[\r\n|`]+/, " ") |> String.trim()

  # Page, reusable and element names by Bubble ID.
  defp names(nil), do: %{}

  defp names(frontend) do
    (List.wrap(frontend.pages) ++ List.wrap(frontend.reusables))
    |> Enum.flat_map(&nodes/1)
    |> Enum.reduce(%{}, fn n, acc ->
      case n do
        %{source: %{bubble_id: id}, name: name} when is_binary(id) and is_binary(name) ->
          Map.put_new(acc, id, name)

        _ ->
          acc
      end
    end)
  end

  defp nodes(n), do: [n | Enum.flat_map(n.children || [], &nodes/1)]

  defp where_order({:page, name}), do: {0, name}
  defp where_order({:reusable, name}), do: {1, name}
  defp where_order({:backend, _}), do: {2, ""}

  # --- printing ---------------------------------------------------------------------------

  defp section(reason, notes) do
    {why, todo} = explain(reason)

    lines =
      Enum.map_join(notes, "\n", fn n ->
        "- #{where(n.where)}, #{n.event}#{name(n)}: #{blocked_at(n)}#{technical(n)} (`#{n.symbol}`)"
      end)

    """
    ## #{title(reason)} (#{count(length(notes))})

    Why: #{why}

    What you can do: #{todo}

    #{lines}
    """
  end

  defp where({:page, name}), do: "Page \"#{clean(name)}\""
  defp where({:reusable, name}), do: "Reusable element \"#{clean(name)}\""
  defp where({:backend, _}), do: "Backend"

  # The workflow's own name, when it is not already the event's.
  defp name(%{name: nil}), do: ""
  defp name(%{name: ""}), do: ""

  defp name(%{event: event, name: name}) do
    if String.contains?(event, "\"#{clean(name)}\""), do: "", else: " (#{quoted(name)})"
  end

  defp blocked_at(%{blocker: :event, reason: reason}) when reason in @event_reasons,
    do: "its event"

  defp blocked_at(%{blocker: :event}), do: "its \"Only when\" condition or its event's settings"

  defp blocked_at(%{blocker: {:step, index, type}} = n),
    do: "step #{index}, #{action(type, n.plugin)}"

  defp blocked_at(%{blocker: {:calls, nil, _type, names}}),
    do: "it runs #{Enum.join(names, ", ")}"

  defp blocked_at(%{blocker: {:calls, index, type, names}}),
    do: "step #{index}, #{action(type, nil)}, runs #{Enum.join(names, ", ")}"

  # What the developer needs: the plugin's ID (its plan question is
  # `decision:plugin/<id>`), or what the reason names.
  defp technical(%{plugin: %{id: id}}), do: " [plugin #{clean(id)}]"
  defp technical(%{detail: []}), do: ""

  defp technical(%{detail: detail}),
    do: " [#{Enum.map_join(detail, ", ", &clean/1)}]"

  defp action(_type, %{id: id, name: name}),
    do: "an action of the plugin #{quoted(name) || id}"

  defp action("apiconnector2-" <> _, nil), do: "an API Connector call"
  defp action(type, nil), do: Map.get(actions(), type) || "\"#{clean(type || "unknown")}\""

  defp count(1), do: "1 workflow"
  defp count(n), do: "#{n} workflows"

  # Bubble's own action names, as the workflow editor shows them.
  defp actions do
    %{
      "ShowElement" => "Show an element",
      "HideElement" => "Hide an element",
      "ToggleElement" => "Toggle an element",
      "AnimateElement" => "Animate an element",
      "SetFocusToElement" => "Set focus to an element",
      "ScrollToElement" => "Scroll to element",
      "ResetInputs" => "Reset relevant inputs",
      "ResetGroup" => "Reset a group/popup",
      "DisplayGroupData" => "Display data in a group/popup",
      "DisplayListData" => "Display list in a repeating group",
      "OpenURL" => "Open an external website",
      "ChangePage" => "Go to page",
      "RefreshPage" => "Refresh the page",
      "GoBack" => "Go to previous page",
      "NewThing" => "Create a new thing",
      "ChangeThing" => "Make changes to a thing",
      "ChangeListOfThings" => "Make changes to a list of things",
      "DeleteThing" => "Delete thing",
      "DeleteListOfThings" => "Delete a list of things",
      "CopyListOfThings" => "Copy a list of things",
      "MakeChangeCurrentUser" => "Make changes to current user",
      "SetCustomState" => "Set state",
      "TriggerCustomEvent" => "Trigger a custom event",
      "TriggerCustomEventFromReusable" => "Trigger a custom event from a reusable element",
      "TriggerCustomOnChange" => "Trigger a custom event when data changes",
      "ScheduleCustom" => "Schedule a custom event",
      "ScheduleAPIEvent" => "Schedule API Workflow",
      "ScheduleAPIEventOnList" => "Schedule API Workflow on a list",
      "CancelScheduledAPIEvent" => "Cancel a scheduled API Workflow",
      "CancelListScheduledAPIEvent" => "Cancel a list of scheduled API Workflows",
      "APIReturnData" => "Return data from API",
      "TerminateWorkflow" => "Terminate this workflow",
      "ListGoToPage" => "Go to page of a repeating group",
      "ListClear" => "Clear list",
      "ScrollToListEntry" => "Scroll to entry of a repeating group",
      "DeleteUploadedFile" => "Delete an uploaded file",
      "SendEmail" => "Send email",
      "AlertShowMessage" => "Show message in an alert",
      "PauseWFClient" => "Add a pause before next action",
      "SendPasswordResetEmail" => "Send password reset email",
      "SignUp" => "Sign the user up",
      "LogIn" => "Log the user in",
      "LogOut" => "Log the user out",
      "SendMagicLink" => "Send magic login link",
      "ResetPassword" => "Send password reset email",
      "UpdateCredentials" => "Update the user's credentials",
      "CreateUserAccount" => "Create an account for someone else",
      "SetTemporaryPassword" => "Assign a temp password to a user",
      "OAuthLogin" => "Signup/login with a social network"
    }
  end

  defp title(:plugin_action), do: "A step uses a plugin action"
  defp title(:script_action), do: "A step runs JavaScript a developer has to port"
  defp title(:plugin_event), do: "It is started by a plugin's event"
  defp title(:trigger_dropped), do: "It was started by a plugin you dropped"
  defp title(:reads_dropped_plugin), do: "It reads a plugin you dropped"
  defp title(:uses_dropped), do: "It uses something you dropped"
  defp title(:auth_action), do: "A step signs up, logs in or changes credentials"
  defp title(:unsupported_action), do: "A step uses an action that is not converted yet"
  defp title(:unsupported_event), do: "Its event is not converted yet"
  defp title(:api_connector_action), do: "A step calls the API Connector"
  defp title(:unresolved_reference), do: "It refers to something that no longer exists"
  defp title(:trigger_not_normalized), do: "It is started by an element the page doesn't have"

  defp title(:trigger_in_runtime_template),
    do: "It is started by an element inside a repeating group or table"

  defp title(:target_not_rendered), do: "A step acts on an element the page doesn't show"
  defp title(:backend_workflow), do: "A step schedules a backend workflow"
  defp title(:unavailable_input), do: "It reads a value the converted page doesn't keep"
  defp title(:unsupported_option), do: "It uses a setting that is not converted yet"
  defp title(:uncompiled_expression), do: "An expression in it is not converted yet"
  defp title(:calls_blocked), do: "It runs another workflow that cannot run"
  defp title(reason), do: "Other: #{reason}"

  @change "or change the workflow in Bubble so it does without it"

  defp explain(:plugin_action),
    do:
      {"the conversion does not run plugin actions. Until you decide what to do with the plugin, " <>
         "every workflow using one of its actions waits.",
       "decide about the plugin (drop it, replace it with a native equivalent, or have it " <>
         "rebuilt): it is an owner question in the migration plan " <>
         "(`mix wtf.task show decision:plugin/<plugin ID>`), " <> @change <> "."}

  defp explain(:script_action),
    do:
      {"the step runs JavaScript (Toolbox's \"Run javascript\") that does more than change the " <>
         "page: it calls the network or code the app doesn't define, or it builds code from " <>
         "data. The conversion runs only scripts that touch the page alone; this one is not run.",
       "have a developer port the script (the line says why; the migration plan's residue " <>
         "for the step holds a rewrite brief), " <> @change <> "."}

  defp explain(:plugin_event),
    do:
      {"the workflow starts on an event of a plugin element, which the converted page does not fire.",
       "decide about the plugin in the migration plan " <>
         "(`mix wtf.task show decision:plugin/<plugin ID>`); if " <>
         "you drop it, the workflow needs another event, e.g. a click."}

  defp explain(:trigger_dropped),
    do:
      {"you dropped the plugin whose event started it, and it does more than run the plugin.",
       "give it another event in Bubble, or drop the workflow too."}

  defp explain(:reads_dropped_plugin),
    do:
      {"it reads a state, a result or a data type of a plugin you dropped.",
       "change the expression in Bubble so it reads something else, or drop the workflow too."}

  defp explain(:uses_dropped),
    do:
      {"it reads, writes, calls or goes to something you dropped in the decisions file.",
       "change the step in Bubble, drop the workflow too, or withdraw that drop."}

  defp explain(:auth_action),
    do:
      {"signing up, logging in and changing credentials are converted with the app's sign-in, " <>
         "not as workflow steps.",
       "nothing in Bubble: this is part of the sign-in task of the migration plan (`auth`)."}

  defp explain(:unsupported_action),
    do:
      {"this kind of action (named in each line) is not converted yet.",
       "use another action in Bubble that does the same (e.g. a backend workflow you schedule), " <>
         "or drop the workflow if you don't need it."}

  defp explain(:unsupported_event),
    do:
      {"this kind of event is not converted yet.",
       "start it another way in Bubble, " <> @change <> "."}

  defp explain(:api_connector_action),
    do:
      {"the step calls an API Connector call that was not converted (its client could not be " <>
         "generated: a setting of the call is not supported).",
       "simplify the call in the API Connector, or have a developer write the client."}

  defp explain(:unresolved_reference),
    do:
      {"a step or condition names a data type, field, element or parameter that no longer " <>
         "exists in the app (usually deleted in Bubble, the workflow still pointing at it).",
       "open the workflow in Bubble: the editor flags the broken reference in red. Fix or remove it."}

  defp explain(:trigger_not_normalized),
    do:
      {"the element that starts it is not on the converted page.",
       "check the element still exists in Bubble; if it was deleted, delete the workflow too."}

  defp explain(:trigger_in_runtime_template),
    do:
      {"the element that starts it is inside a repeating group (or table, or plugin container) " <>
         "whose cells the converted page does not render yet.",
       "nothing to change in Bubble for now: it waits for that list's conversion. Drop the " <>
         "workflow if you don't need it."}

  defp explain(:target_not_rendered),
    do:
      {"a step shows, hides, resets or focuses an element the converted page does not render " <>
         "(inside a repeating group's cells, or not converted).",
       "nothing to change in Bubble for now; drop the workflow if you don't need it."}

  defp explain(:backend_workflow),
    do:
      {"it schedules a backend workflow, and the backend workflows were not converted with it.",
       "convert the backend workflows too."}

  defp explain(:unavailable_input),
    do:
      {"it reads a value the converted page does not keep yet: a group's or cell's data, an " <>
         "element's state (e.g. a repeating group's page number), the page's thing (in brackets).",
       "where you can, read the value another way in Bubble (e.g. a custom state you set), " <>
         @change <> "."}

  defp explain(:unsupported_option),
    do:
      {"a setting of the step or event (in brackets) is not converted yet.",
       "if the setting isn't needed, turn it off in Bubble, " <> @change <> "."}

  defp explain(:uncompiled_expression),
    do:
      {"a dynamic expression in the workflow (a value, a search, an \"Only when\" condition) uses " <>
         "something the conversion cannot translate yet (in brackets, e.g. a search with an " <>
         "operator it does not know).",
       "simplify the expression in Bubble where you can (e.g. save the value in a field or a " <>
         "custom state first), or have a developer write it by hand."}

  defp explain(:calls_blocked),
    do:
      {"it triggers or schedules a workflow that cannot run itself (named in each line). It " <>
         "runs whole or not at all, so it waits for that one.",
       "fix the workflow it runs (listed elsewhere in this report, unless it is disabled in " <>
         "the Bubble editor: then enable it, or remove the step): this one then runs too."}

  defp explain(_reason),
    do:
      {"a part of it could not be converted.",
       "change the workflow in Bubble so it does without it, or drop the workflow."}
end
