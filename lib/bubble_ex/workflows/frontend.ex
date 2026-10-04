defmodule BubbleEx.Workflows.Frontend do
  @moduledoc """
  Stack-neutral lowering of an app's page and reusable-element workflows
  (WTF-372, T6 of WTF-359): every workflow of a page (not a mobile view) or
  a reusable element becomes a `BubbleEx.Workflows.Frontend.Workflow` with
  its event (what triggers it, on which element) and its steps, each
  lowered to a small closed set of operations whose values are compiled to
  `BubbleEx.Expression.IR` by `BubbleEx.Expression.Compiler`, or kept as
  **residue** (`BubbleEx.Plan.Residue` entries) with a
  `:frontend_workflow_residue` diagnostic. Nothing is dropped silently: an
  event, action type, option or expression without a lowering makes its
  workflow or step residue.

      {:ok, model} = BubbleEx.Model.build(app)
      {:ok, index} = BubbleEx.Index.build(app, model: model)
      {:ok, frontend} = BubbleEx.Workflows.Frontend.build(app, model, index)

  There are no target names here: a target binds names and compiles the IR
  (`BubbleEx.Target.Elixir.FrontendWorkflows` for Phoenix LiveView), adding
  its own residue where an IR or an input has no binding there. Output is
  deterministic (workflows by surface, then Bubble ID; steps in Bubble
  order). The step vocabulary is shared with the backend lowering
  (`BubbleEx.Workflows.Lowering`).

  ## Events

  | Bubble event | `Workflow.kind` | |
  |--------------|-----------------|-|
  | An element is clicked (`ButtonClicked`) | `:click` | `element` |
  | An input's value is changed (`InputChanged`) | `:input_change` | `element` |
  | Page is loaded (`PageLoaded`) | `:page_load` | |
  | Do when condition is true (`ConditionTrue`) | `:condition_true` | `condition`, `run_when` (`:every_time` or `:once`; unset is `:once`, unverified) |
  | A custom event (`CustomEvent`) | `:custom_event` | `parameters`, `returns` |
  | A popup is opened / closed | `:popup_opened` / `:popup_closed` | `element` |
  | User is logged in / out | `:logged_in` / `:logged_out` | |
  | Do every N seconds (`DoInterval`) | `:do_every` | `interval` |

  Anything else is `:unsupported` with `:unsupported_event` or
  `:plugin_event` residue. A workflow disabled in the editor
  (`workflow_disabled`) is lowered with `disabled?: true`: a target
  generates it but never triggers it, as Bubble does not run it.

  ## Operations

  | Bubble action | `Step.op` | `Step.args` |
  |---------------|-----------|-------------|
  | Show / Hide / Toggle an element | `:show` / `:hide` / `:toggle` | `element` |
  | Set focus to an element, Scroll to an element | `:focus`, `:scroll_to` | `element` |
  | Reset relevant inputs (`ResetInputs`) | `:reset_inputs` | `within` (the triggering element's container, nil for the surface) |
  | Reset a group / popup (`ResetGroup`) | `:reset_group` | `element` |
  | Display data in a group / popup (`DisplayGroupData`) | `:display_data` | `element` (a group, popup, floating group, group focus or reusable-element instance, or the reusable element itself), `value` (nil: empty), `cell` (the repeating group whose cell holds `element`, or nil) |
  | Display list in a repeating group (`DisplayListData`) | `:display_list` | `element` (a repeating group), `value`, `cell` |
  | Set state(s) (`SetCustomState`) | `:set_state` | `element`, `states` (`%{state, value}`, state `custom.<id>`) |
  | Go to page (`ChangePage`) | `:navigate` | `page` (a page's Bubble ID, or `:current`), `params` (`%{key, value}`), `thing` (the data to send, the index page and the current page included), `untyped?` (true when `thing` goes to a page with no type of content: Bubble appends it as a path segment, a thing's unique ID or a text, WTF-466), `keep_params?`, `replace?`, `new_tab?` |
  | Open an external website (`OpenURL`) | `:open_url` | `url`, `new_tab?` |
  | Refresh the page | `:refresh` | |
  | Log the user out | `:log_out` | |
  | the data operations of `BubbleEx.Workflows.Lowering` | `:create` … `:delete_list` | as there |
  | Trigger a custom event | `:call` | `workflow`, `params` |
  | Trigger a custom event from a reusable element | `:call_reusable` | `element` (the instance), `workflow`, `params` |
  | Schedule a custom event | `:schedule_custom` | `workflow`, `delay` (seconds), `params` |
  | Schedule API workflow (on a list) | `:schedule` / `:schedule_list` | `workflow`, `at`, (`list`, `interval`), `params` |
  | Terminate this workflow | `:terminate` | `returns` |
  | Add a pause before next action (`PauseWFClient`) | `:pause` | `length` (milliseconds) |

  Every step may carry a `condition` ("Only when"). A custom event called
  or scheduled must belong to the same page or reusable element, as in
  Bubble; `:call_reusable` calls one of the reusable element's own.

  ## Residue

  Entries on the workflow or action symbol (`workflow:<id>`,
  `action:<id>`), to pass to `BubbleEx.Plan.build/5` as `residue:`:
  `:uncompiled_expression`, `:unsupported_action`, `:api_connector_action`,
  `:plugin_action`, `:auth_action`, `:unsupported_event`, `:plugin_event`,
  `:unsupported_option` (a member whose semantics are not lowered, e.g. a
  page's "data to send") and `:unresolved_reference` (an element, page,
  state, field, parameter, return or callee that does not resolve).

  ## Coverage

  See `coverage/1`.
  """

  alias BubbleEx.{Diagnostic, Error, Index, Model}
  alias BubbleEx.Expression.{Env, IR, Sites, Tree}
  alias BubbleEx.Index.Symbol
  alias BubbleEx.Plan.Residue
  alias BubbleEx.Workflows.Frontend.{Step, Workflow}
  alias BubbleEx.Workflows.Lowering
  alias BubbleEx.Workflows.Lowering.Expr
  alias BubbleEx.Workflows.Source

  import Lowering, only: [map: 1, text: 1, type_text: 1, ordered: 1]

  defstruct workflows: [], elements: %{}, states: [], diagnostics: []

  @type element :: %{
          surface: String.t(),
          kind: :page | :reusable | :element,
          type: String.t() | nil,
          parent: String.t() | nil,
          instance_of: String.t() | nil,
          value: String.t() | nil,
          content: String.t() | nil
        }
  @type state :: %{
          element: String.t(),
          state: String.t(),
          type: String.t(),
          default: Expr.t() | nil
        }
  @type t :: %__MODULE__{
          workflows: [Workflow.t()],
          elements: %{String.t() => element()},
          states: [state()],
          diagnostics: [Diagnostic.t()]
        }

  @kinds %{
    "ButtonClicked" => :click,
    "InputChanged" => :input_change,
    "PageLoaded" => :page_load,
    "ConditionTrue" => :condition_true,
    "CustomEvent" => :custom_event,
    "PopupOpened" => :popup_opened,
    "PopupClosed" => :popup_closed,
    "LoggedIn" => :logged_in,
    "LoggedOut" => :logged_out,
    "DoInterval" => :do_every
  }

  @element_events [:click, :input_change, :popup_opened, :popup_closed]

  # Event members with a lowering, or without semantics (captions, colors,
  # folders, debugger breakpoints).
  @event_members ~w(element_id element_id_friendly condition wf_folder event_color breakpoint
                    workflow_disabled run_when event_name parameters return_types interval)

  @ops %{
    "ShowElement" => :show,
    "HideElement" => :hide,
    "ToggleElement" => :toggle,
    "SetFocusToElement" => :focus,
    "ScrollToElement" => :scroll_to,
    "ResetInputs" => :reset_inputs,
    "ResetGroup" => :reset_group,
    "DisplayGroupData" => :display_data,
    "DisplayListData" => :display_list,
    "SetCustomState" => :set_state,
    "ChangePage" => :navigate,
    "OpenURL" => :open_url,
    "RefreshPage" => :refresh,
    "LogOut" => :log_out,
    "TriggerCustomEvent" => :call,
    "TriggerCustomEventFromReusable" => :call_reusable,
    "ScheduleCustom" => :schedule_custom,
    "ScheduleAPIEvent" => :schedule,
    "ScheduleAPIEventOnList" => :schedule_list,
    "TerminateWorkflow" => :terminate,
    "PauseWFClient" => :pause
  }

  # Action members each operation lowers (besides `condition`); a schedule
  # also reads its `_wf_param_<key>` members. Members without semantics
  # (a debugger breakpoint, the editor's display name) are ignored.
  @members %{
    show: ~w(element_id),
    hide: ~w(element_id),
    toggle: ~w(element_id),
    focus: ~w(element_id),
    scroll_to: ~w(element_id),
    reset_inputs: [],
    reset_group: ~w(element_id),
    display_data: ~w(element_id data_source),
    display_list: ~w(element_id data_source),
    set_state: ~w(element_id custom_state value custom_states_values),
    navigate:
      ~w(element_id url_parameters add_parameters keep_current_page_params replace_history open_in_new_tab data_to_send),
    open_url: ~w(url open_in_new_tab),
    refresh: [],
    log_out: [],
    call: ~w(custom_event arguments),
    call_reusable: ~w(element_id custom_event arguments),
    schedule_custom: ~w(custom_event arguments delay),
    schedule: ~w(api_event date ignore_privacy_rules),
    schedule_list: ~w(api_event date data_source type_of_list interval ignore_privacy_rules),
    terminate: ~w(return_values),
    # `hide_status_bar` hides Bubble's page loading bar during the pause:
    # generated pages show none.
    pause: ~w(length hide_status_bar)
  }

  @ignored_members ~w(condition breakpoint element_id_friendly)

  @doc """
  Lowers the page and reusable-element workflows of decoded app JSON.
  `model` and `index` must be built from the same app
  (`BubbleEx.Index.build(app, model: model)`).
  """
  @spec build(map(), Model.t(), Index.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def build(app, model, index, opts \\ [])

  def build(app, %Model{} = model, %Index{} = index, _opts)
      when is_map(app) and not is_struct(app) do
    tree = Tree.build(app)
    env = Env.new(model, tree: tree, searches: :page)

    surfaces =
      for %{kind: kind} = s <- index.symbols,
          kind in [:page, :reusable],
          s.attrs[:section] != "mobile_views",
          into: %{},
          do: {s.id, s}

    symbols =
      for %{kind: :workflow} = s <- index.symbols,
          s.attrs[:backend] != true,
          Map.has_key?(surfaces, s.parent),
          do: s

    raws =
      for s <- symbols,
          raw = at(app, s.path),
          is_map(raw),
          into: %{},
          do: {s.id, raw}

    custom_events =
      for s <- symbols,
          s.attrs[:event_type] == "CustomEvent",
          raw = raws[s.id],
          raw != nil,
          into: %{},
          do:
            {s.bubble_id,
             %{
               surface: s.parent,
               params: Lowering.parameters(raw),
               returns: Lowering.returns(raw)
             }}

    ctx = %{
      model: model,
      index: index,
      tree: tree,
      surfaces: surfaces,
      pages: for({id, %{kind: :page}} <- surfaces, into: %{}, do: {bubble(id), id}),
      page_things: page_things(app, surfaces),
      custom_events: custom_events,
      api_workflows: api_workflows(app)
    }

    workflows =
      symbols
      |> Enum.filter(&Map.has_key?(raws, &1.id))
      |> Enum.map(&workflow(&1, raws[&1.id], env, ctx))
      |> Enum.sort_by(&{&1.surface, &1.bubble_id})

    diagnostics =
      workflows
      |> Enum.flat_map(&workflow_diagnostics/1)
      |> Diagnostic.normalize()

    elements = elements(tree, surfaces)

    {:ok,
     %__MODULE__{
       workflows: workflows,
       elements: elements,
       states: states(tree, elements, env),
       diagnostics: diagnostics
     }}
  end

  def build(_app, _model, _index, _opts),
    do: {:error, Error.new(:invalid_input, "expected app JSON, its Model and its Index")}

  @doc """
  Every residue entry (workflow and step), sorted: the
  `BubbleEx.Plan.Residue` entries to pass to `BubbleEx.Plan.build/5`.
  """
  @spec residue(t()) :: [Residue.t()]
  def residue(%__MODULE__{workflows: workflows}),
    do: workflows |> Enum.flat_map(&Workflow.residue/1) |> Residue.sort()

  @doc """
  Lowering coverage (IR level), with string keys. The metric:

    * `"workflows"` - page and reusable-element workflows; `"native"` those
      with no residue at all (the event and every step lower, and every
      value compiles to IR); `"residue"` the rest; `"disabled"` those
      disabled in the editor (counted in the others too)
    * `"steps"` - their actions; `"native"` the actions with no residue
    * `"by_kind"` - `{total, native}` per event kind; `"step_ops"` - native
      steps per operation; `"residue_reasons"` - residue entries per
      reason (a subject may have several)
    * `"by_surface"` - `{total, native}` for pages and for reusables

  A target may add residue (an IR or input with no binding there); see
  `BubbleEx.Target.Elixir.FrontendWorkflows.coverage/1`, the
  generated-code measure.
  """
  @spec coverage(t()) :: map()
  def coverage(%__MODULE__{workflows: workflows}) do
    steps = Enum.flat_map(workflows, & &1.steps)
    native = Enum.filter(workflows, &Workflow.native?/1)

    %{
      "workflows" => %{
        "total" => length(workflows),
        "native" => length(native),
        "residue" => length(workflows) - length(native),
        "disabled" => Enum.count(workflows, & &1.disabled?)
      },
      "steps" => %{
        "total" => length(steps),
        "native" => Enum.count(steps, &(&1.residue == [])),
        "residue" => Enum.count(steps, &(&1.residue != []))
      },
      "by_kind" => totals(workflows, &Atom.to_string(&1.kind)),
      "by_surface" => totals(workflows, &(&1.surface |> String.split(":") |> hd())),
      "step_ops" =>
        steps
        |> Enum.filter(&(&1.residue == [] and &1.op != nil))
        |> Enum.frequencies_by(&Atom.to_string(&1.op)),
      "residue_reasons" =>
        workflows
        |> Enum.flat_map(&Workflow.residue/1)
        |> Enum.frequencies_by(&Atom.to_string(&1.reason))
    }
  end

  defp totals(workflows, key) do
    workflows
    |> Enum.group_by(key)
    |> Map.new(fn {k, ws} ->
      {k, %{"total" => length(ws), "native" => Enum.count(ws, &Workflow.native?/1)}}
    end)
  end

  # --- workflows -------------------------------------------------------------------

  defp workflow(symbol, raw, env, ctx) do
    path = pointer_path(symbol.path)
    surface = symbol.parent
    host = bubble(surface)
    env = Sites.workflow_env(raw, path, host, env)
    props = map(Source.value(raw, ~w(properties %p)))
    event_type = Source.value(raw, ~w(type %x))
    kind = Map.get(@kinds, event_type, :unsupported)
    id = symbol.id

    ctx =
      Map.merge(ctx, %{
        workflow: symbol.bubble_id,
        surface: surface,
        returns: returns_of(kind, symbol.bubble_id, ctx)
      })

    element = text(props["element_id"])
    ppath = path ++ ["properties"]
    condition = Lowering.expr(props["condition"], ppath ++ ["condition"], env)
    run_when = run_when(props["run_when"])

    interval =
      if kind == :do_every, do: Lowering.expr(props["interval"], ppath ++ ["interval"], env)

    event_residue =
      event_residue(id, kind, event_type, props) ++
        element_residue(id, kind, element, ctx) ++
        condition_residue(id, kind, condition, run_when)

    within = if element, do: container(element, ctx), else: nil
    ctx = Map.put(ctx, :within, within)

    steps =
      raw
      |> actions(path)
      |> Enum.with_index(1)
      |> Enum.map(fn {{action, apath}, n} -> step(action, apath, n, env, ctx) end)

    %Workflow{
      id: id,
      bubble_id: symbol.bubble_id,
      name: symbol.name,
      surface: surface,
      kind: kind,
      event_type: type_text(event_type),
      element: if(kind in @element_events, do: element),
      condition: condition,
      run_when: if(kind == :condition_true and run_when != :unknown, do: run_when),
      interval: interval,
      disabled?: props["workflow_disabled"] == true,
      parameters: params_of(kind, symbol.bubble_id, ctx),
      returns: ctx.returns,
      steps: steps,
      residue: Residue.sort(event_residue ++ Lowering.expr_residue(id, [condition, interval])),
      path: symbol.path
    }
  end

  # A condition-true event needs its condition and a known "run this".
  defp condition_residue(id, :condition_true, nil, run_when),
    do: [
      Residue.entry(id, :unsupported_option, %{options: ["condition"]})
      | condition_residue(id, :other, nil, run_when)
    ]

  defp condition_residue(id, _kind, _condition, :unknown),
    do: Lowering.option_residue(id, ["run_when"])

  defp condition_residue(_id, _kind, _condition, _run_when), do: []

  defp returns_of(:custom_event, id, ctx), do: ctx.custom_events[id].returns
  defp returns_of(_kind, _id, _ctx), do: []

  defp params_of(:custom_event, id, ctx), do: ctx.custom_events[id].params
  defp params_of(_kind, _id, _ctx), do: []

  defp run_when(nil), do: :once
  defp run_when("just_once"), do: :once
  defp run_when("every_time"), do: :every_time
  defp run_when(_), do: :unknown

  defp event_residue(id, :unsupported, type, _props) do
    case Residue.plugin(type) do
      nil -> [Residue.entry(id, :unsupported_event, %{type: type_text(type)})]
      plugin -> [Residue.entry(id, :plugin_event, %{plugin: plugin})]
    end
  end

  defp event_residue(id, _kind, _type, props) do
    unknown = for {key, _} <- props, key not in @event_members, do: key
    Lowering.option_residue(id, unknown)
  end

  defp element_residue(id, kind, element, ctx) when kind in @element_events do
    if element && in_surface?(element, ctx),
      do: [],
      else: [Residue.entry(id, :unresolved_reference, %{reference: "element"})]
  end

  defp element_residue(_id, _kind, _element, _ctx), do: []

  defp actions(raw, path) do
    case Source.get(raw, ~w(actions %a)) do
      {key, actions} when is_map(actions) or is_list(actions) ->
        actions |> ordered() |> Enum.map(fn {k, a} -> {a, path ++ [key, k]} end)

      _ ->
        []
    end
  end

  # --- steps -----------------------------------------------------------------------

  defp step(action, path, n, env, ctx) when is_map(action) do
    env = Sites.action_env(action, env)
    type = Source.value(action, ~w(type %x))
    props = map(Source.value(action, ~w(properties %p)))
    bubble_id = text(Source.value(action, ~w(id %id))) || "#{ctx.workflow}/#{List.last(path)}"
    id = Symbol.id(:action, bubble_id)
    op = if is_binary(type), do: Map.get(@ops, type) || Lowering.data_op(type)
    ppath = path ++ ["properties"]
    condition = Lowering.expr(props["condition"], ppath ++ ["condition"], env)

    step = %Step{
      index: n,
      bubble_id: bubble_id,
      id: id,
      type: type_text(type),
      op: op,
      condition: condition,
      path: Source.pointer(path)
    }

    if op do
      {args, residue} = lower(op, props, ppath, id, env, ctx)
      options = unknown_members(op, props)
      exprs = [condition | Lowering.exprs_of(args)]

      %{
        step
        | args: args,
          residue:
            Residue.sort(
              residue ++ Lowering.option_residue(id, options) ++ Lowering.expr_residue(id, exprs)
            )
      }
    else
      %{
        step
        | residue:
            Residue.sort(
              Lowering.type_residue(id, type) ++ Lowering.expr_residue(id, [condition])
            )
      }
    end
  end

  defp step(_action, path, n, _env, ctx) do
    bubble_id = "#{ctx.workflow}/#{List.last(path)}"
    id = Symbol.id(:action, bubble_id)

    %Step{
      index: n,
      bubble_id: bubble_id,
      id: id,
      path: Source.pointer(path),
      residue: [Residue.entry(id, :unsupported_action, %{type: nil})]
    }
  end

  defp unknown_members(op, props) do
    known =
      @ignored_members ++
        case Map.fetch(@members, op) do
          {:ok, members} -> members
          :error -> Lowering.data_members(op)
        end

    for {key, _} <- props,
        key not in known,
        not (op in [:schedule, :schedule_list] and String.starts_with?(key, "_wf_param_")),
        do: key
  end

  # --- operations --------------------------------------------------------------------

  defp lower(op, props, _path, id, _env, ctx)
       when op in [:show, :hide, :toggle, :focus, :scroll_to, :reset_group] do
    element = text(props["element_id"])
    {%{element: element}, element_ref(id, element, ctx)}
  end

  defp lower(:reset_inputs, _props, _path, _id, _env, ctx), do: {%{within: ctx.within}, []}

  # "Display data in a group / popup" and "Display list in a repeating
  # group" (WTF-492): the element's data, until a reset or the page's next
  # load. Only a holder of group data of the workflow's surface takes it.
  defp lower(op, props, path, id, env, ctx) when op in [:display_data, :display_list] do
    element = text(props["element_id"])

    residue =
      case element_ref(id, element, ctx) do
        [] -> display_residue(id, op, Tree.node(ctx.tree, element), ctx)
        residue -> residue
      end

    value =
      case props["data_source"] do
        nil -> %Expr{path: Source.pointer(path ++ ["data_source"]), ir: IR.node(:empty)}
        value -> Lowering.expr(value, path ++ ["data_source"], env)
      end

    {%{element: element, value: value, cell: cell_of(element, ctx)}, residue}
  end

  defp lower(:set_state, props, path, id, env, ctx) do
    element = text(props["element_id"])

    entries =
      [{props["custom_state"], props["value"], path ++ ["value"]}] ++
        (props["custom_states_values"]
         |> ordered()
         |> Enum.map(fn {k, entry} ->
           entry = map(entry)
           {entry["custom_state"], entry["value"], path ++ ["custom_states_values", k, "value"]}
         end))

    {states, residue} =
      Enum.map_reduce(entries, element_ref(id, element, ctx), fn {state, value, vpath}, acc ->
        case state_ref(element, state, ctx) do
          {:ok, state} ->
            {%{state: state, value: state_value(value, vpath, env)}, acc}

          :error ->
            {nil, [Residue.entry(id, :unresolved_reference, %{reference: "state"}) | acc]}
        end
      end)

    {%{element: element, states: Enum.reject(states, &is_nil/1)}, Enum.uniq(residue)}
  end

  defp lower(:navigate, props, path, id, env, ctx) do
    target = text(props["element_id"])

    {page, residue} =
      case navigate_target(target, ctx) do
        {:ok, page} -> {page, []}
        :error -> {nil, [Residue.entry(id, :unresolved_reference, %{reference: "page"})]}
      end

    params =
      props["url_parameters"]
      |> ordered()
      |> Enum.map(fn {k, entry} ->
        entry = map(entry)

        %{
          key: text(entry["key"]),
          value: Lowering.expr(entry["value"], path ++ ["url_parameters", k, "value"], env)
        }
      end)

    {thing, untyped?, thing_residue} =
      data_to_send(props["data_to_send"], page, path, id, env, ctx)

    residue =
      residue ++
        if(Enum.any?(params, &is_nil(&1.key)),
          do: Lowering.option_residue(id, ["url_parameters"]),
          else: []
        ) ++ thing_residue

    {%{
       page: page,
       params: Enum.reject(params, &is_nil(&1.key)),
       thing: thing,
       untyped?: untyped?,
       keep_params?: props["keep_current_page_params"] == true,
       replace?: props["replace_history"] == true,
       new_tab?: props["open_in_new_tab"] == true
     }, residue}
  end

  defp lower(:open_url, props, path, _id, env, _ctx) do
    {%{
       url: Lowering.expr(props["url"], path ++ ["url"], env),
       new_tab?: props["open_in_new_tab"] == true
     }, []}
  end

  defp lower(op, _props, _path, _id, _env, _ctx) when op in [:refresh, :log_out], do: {%{}, []}

  defp lower(:call, props, path, id, env, ctx) do
    callee = text(props["custom_event"])
    callee_params = local_event(callee, ctx.surface, ctx)

    {params, residue} =
      Lowering.call_params(props["arguments"], path ++ ["arguments"], id, env, callee_params)

    {%{workflow: callee, params: params}, residue}
  end

  defp lower(:call_reusable, props, path, id, env, ctx) do
    element = text(props["element_id"])
    callee = text(props["custom_event"])

    definition =
      case element && Tree.node(ctx.tree, element) do
        %Tree.Node{instance_of: definition} = node when is_binary(definition) ->
          if node.owner == bubble(ctx.surface), do: definition

        _ ->
          nil
      end

    callee_params =
      if definition, do: local_event(callee, Symbol.id(:reusable, definition), ctx)

    residue =
      if definition,
        do: [],
        else: [Residue.entry(id, :unresolved_reference, %{reference: "element"})]

    {params, more} =
      Lowering.call_params(props["arguments"], path ++ ["arguments"], id, env, callee_params)

    {%{element: element, workflow: callee, params: params}, Enum.uniq(residue ++ more)}
  end

  defp lower(:schedule_custom, props, path, id, env, ctx) do
    callee = text(props["custom_event"])
    callee_params = local_event(callee, ctx.surface, ctx)

    {params, residue} =
      Lowering.call_params(props["arguments"], path ++ ["arguments"], id, env, callee_params)

    {%{
       workflow: callee,
       delay: Lowering.expr(props["delay"], path ++ ["delay"], env),
       params: params
     }, residue}
  end

  defp lower(op, props, path, id, env, ctx) when op in [:schedule, :schedule_list] do
    callee = text(props["api_event"])
    callee_params = Map.get(ctx.api_workflows, callee)

    {params, residue} =
      props
      |> Enum.filter(fn {k, _} -> String.starts_with?(k, "_wf_param_") end)
      |> Enum.sort()
      |> Enum.map_reduce([], fn {"_wf_param_" <> key = k, value}, residue ->
        case callee_params && Enum.find(callee_params, &(&1.key == key or &1.id == key)) do
          %{id: param} ->
            {%{param: param, value: Lowering.expr(value, path ++ [k], env)}, residue}

          _ ->
            {nil, [Residue.entry(id, :unresolved_reference, %{reference: "parameter"}) | residue]}
        end
      end)

    residue =
      if callee_params,
        do: residue,
        else: [Residue.entry(id, :unresolved_reference, %{reference: "workflow"}) | residue]

    base = %{
      workflow: callee,
      at: Lowering.expr(props["date"], path ++ ["date"], env),
      params: Enum.reject(params, &is_nil/1)
    }

    args =
      if op == :schedule_list,
        do:
          Map.merge(base, %{
            list: Lowering.expr(props["data_source"], path ++ ["data_source"], env),
            item_type: text(props["type_of_list"]),
            interval: Lowering.expr(props["interval"], path ++ ["interval"], env)
          }),
        else: base

    {args, Enum.uniq(residue)}
  end

  # "Add a pause before next action" (WTF-451): its length in milliseconds
  # (unset: no pause).
  defp lower(:pause, props, path, _id, env, _ctx),
    do: {%{length: Lowering.expr(props["length"], path ++ ["length"], env)}, []}

  defp lower(:terminate, props, path, id, env, ctx) do
    {returns, residue} =
      Lowering.terminate_returns(
        props["return_values"],
        path ++ ["return_values"],
        id,
        env,
        ctx.returns
      )

    {%{returns: returns}, residue}
  end

  defp lower(op, props, path, id, env, ctx), do: Lowering.data_args(op, props, path, id, env, ctx)

  # A value to set a state to: empty when the action leaves it unset.
  defp state_value(nil, path, _env), do: %Expr{path: Source.pointer(path), ir: IR.node(:empty)}
  defp state_value(value, path, env), do: Lowering.expr(value, path, env)

  # A custom event of `surface`: its parameters, or nil.
  defp local_event(callee, surface, ctx) do
    case callee && ctx.custom_events[callee] do
      %{surface: ^surface, params: params} -> params
      _ -> nil
    end
  end

  # --- elements ------------------------------------------------------------------------

  @group_holders ~w(Group Popup FloatingGroup GroupFocus CustomElement)

  # A display step's element must hold that kind of data: a group (or a
  # reusable-element instance, or the reusable element itself) for a
  # thing, a repeating group for a list.
  defp display_residue(id, op, %Tree.Node{} = node, ctx) do
    holds? =
      case op do
        :display_data -> node.type in @group_holders or node.id == bubble(ctx.surface)
        :display_list -> node.type == "RepeatingGroup"
      end

    surface? = node.kind == :reusable or node.kind == :element

    if holds? and surface?,
      do: [],
      else: Lowering.option_residue(id, ["element_id"])
  end

  # The repeating group whose cell holds `element` (in the same surface),
  # or nil.
  defp cell_of(element, ctx) do
    ctx.tree
    |> Tree.ancestors(element)
    |> Enum.take_while(&(&1.kind == :element))
    |> Enum.find_value(&(&1.type in ~w(RepeatingGroup Table) && &1.id))
  end

  defp element_ref(id, element, ctx) do
    if element && in_surface?(element, ctx),
      do: [],
      else: [Residue.entry(id, :unresolved_reference, %{reference: "element"})]
  end

  # An element of the workflow's page or reusable element, or the surface
  # itself.
  defp in_surface?(element, ctx) do
    case Tree.node(ctx.tree, element) do
      %Tree.Node{} = node -> node.id == bubble(ctx.surface) or node.owner == bubble(ctx.surface)
      nil -> false
    end
  end

  # `custom.<id>` of `element` (or, for a reusable instance, of its
  # reusable element).
  defp state_ref(element, "custom." <> state = full, ctx) when is_binary(element) do
    node = Tree.node(ctx.tree, element)

    definition =
      case node do
        %Tree.Node{instance_of: d} when is_binary(d) -> Tree.node(ctx.tree, d)
        _ -> nil
      end

    if (node && Map.has_key?(node.states, state)) or
         (definition && Map.has_key?(definition.states, state)),
       do: {:ok, full},
       else: :error
  end

  defp state_ref(_element, _state, _ctx), do: :error

  # The container whose inputs "Reset relevant inputs" resets: the
  # triggering element's parent (nil: the whole page or reusable element).
  defp container(element, ctx) do
    case Tree.node(ctx.tree, element) do
      %Tree.Node{parent: parent} when is_binary(parent) ->
        if parent == bubble(ctx.surface), do: nil, else: parent

      _ ->
        nil
    end
  end

  # --- elements and custom states -------------------------------------------------------

  # Every page (not a mobile view), reusable element and element of one,
  # by Bubble ID: its surface, kind, type, parent, the reusable element it
  # instantiates and the type of its value (inputs).
  defp elements(tree, surfaces) do
    owners =
      for {id, _} <- surfaces, into: %{}, do: {bubble(id), id}

    for {id, node} <- tree.nodes,
        id == node.id,
        surface = owners[node.owner],
        surface != nil,
        node.kind == :element or node.id == node.owner,
        into: %{} do
      {id,
       %{
         surface: surface,
         kind: node.kind,
         type: node.type,
         parent: node.parent,
         instance_of: node.instance_of,
         value: node.value,
         content: node.content
       }}
    end
  end

  # The custom states of those elements, sorted, with their defaults
  # (compiled like any value, in their element's environment).
  defp states(tree, elements, env) do
    for {id, _} <- Enum.sort(elements),
        node = Tree.node(tree, id),
        {state, type} <- Enum.sort(node.states) do
      default =
        case Map.fetch(node.defaults, state) do
          {:ok, value} -> Lowering.expr(value, [], %{env | host: id})
          :error -> nil
        end

      %{element: id, state: "custom." <> state, type: type, default: default}
    end
  end

  # --- backend API workflows (scheduled from the page) --------------------------------

  defp api_workflows(app) do
    case Map.get(app, "api") do
      api when is_map(api) or is_list(api) ->
        for {key, raw} <- Source.entries(api),
            is_map(raw),
            Source.value(raw, ~w(type %x)) == "APIEvent",
            into: %{},
            do: {text(Source.value(raw, ~w(id %id))) || to_string(key), Lowering.parameters(raw)}

      _ ->
        %{}
    end
  end

  # --- diagnostics ---------------------------------------------------------------------

  defp workflow_diagnostics(%Workflow{} = w) do
    subject = %{workflow: w.bubble_id}

    disabled =
      if w.disabled?,
        do: [
          Diagnostic.new(
            :frontend_workflow_disabled,
            w.path,
            "the workflow is disabled in the Bubble editor; it is generated but never triggered",
            subject: subject
          )
        ],
        else: []

    residue =
      for %{subject: s, reason: reason, detail: detail} <- Workflow.residue(w) do
        path = if s == w.id, do: w.path, else: step_path(w, s)

        Diagnostic.new(
          :frontend_workflow_residue,
          path,
          "#{s} is not lowered (#{reason}); it is left for agent work",
          subject: subject,
          details: %{subject: s, reason: Atom.to_string(reason), detail: detail}
        )
      end

    disabled ++ residue
  end

  defp step_path(w, subject), do: Enum.find_value(w.steps, w.path, &(&1.id == subject && &1.path))

  # --- helpers -------------------------------------------------------------------------

  # "Go to page"'s target (WTF-429): Bubble's "Current page" (the exact
  # value its editor stores) or a page of the app. Anything else (an
  # unknown or deleted page's ID, an empty one, a path, any other text with
  # a space) is unresolved, so the workflow refuses to run rather than go
  # somewhere else. A page whose own ID is "Current page" would make the
  # literal ambiguous: unresolved too.
  @current_page "Current page"

  defp navigate_target(@current_page, ctx) do
    if Map.has_key?(ctx.pages, @current_page), do: :error, else: {:ok, :current}
  end

  defp navigate_target(target, ctx) when is_binary(target) do
    case ctx.pages[target] do
      nil -> :error
      page -> {:ok, bubble(page)}
    end
  end

  defp navigate_target(_target, _ctx), do: :error

  # "Go to page"'s data to send (WTF-378): the path segment after the
  # page's own. To a page with a type of content it is the page's thing
  # (`/<page>/<unique id>`; the index page's is `/index/<unique id>`,
  # WTF-454). To a page with none (a value left from an earlier type of
  # content) Bubble appends it all the same and the page loads (replay,
  # WTF-466): a thing's unique ID or a text, so the step is `untyped?`.
  # The current page (WTF-454) is the workflow's own page when it is a
  # page's; a reusable element's goes to whichever page renders it, so the
  # target decides at run time.
  defp data_to_send(nil, _page, _path, _id, _env, _ctx), do: {nil, false, []}

  defp data_to_send(value, :current, path, id, env, ctx) do
    case ctx.surfaces[ctx.surface] do
      %{kind: :page} -> data_to_send(value, bubble(ctx.surface), path, id, env, ctx)
      _ -> {Lowering.expr(value, path ++ ["data_to_send"], env), false, []}
    end
  end

  defp data_to_send(value, page, path, id, env, ctx) when is_binary(page) do
    case ctx.page_things[page] do
      %{type: type} -> {Lowering.expr(value, path ++ ["data_to_send"], env), type == nil, []}
      _ -> {nil, false, Lowering.option_residue(id, ["data_to_send"])}
    end
  end

  defp data_to_send(_value, _page, _path, id, _env, _ctx),
    do: {nil, false, Lowering.option_residue(id, ["data_to_send"])}

  # Each page's type of content, by Bubble ID.
  defp page_things(app, surfaces) do
    for {id, %{kind: :page} = s} <- surfaces, into: %{} do
      raw = at(app, s.path)
      props = if is_map(raw), do: map(raw["properties"]), else: %{}
      {bubble(id), %{type: text(props["page_item_type"])}}
    end
  end

  defp bubble(symbol_id),
    do: symbol_id |> String.split(":", parts: 2) |> List.last() |> unescape()

  defp unescape(part), do: part |> String.replace("~1", "/") |> String.replace("~0", "~")

  defp pointer_path(pointer) do
    pointer
    |> String.split("/")
    |> tl()
    |> Enum.map(&unescape/1)
  end

  # The value at a JSON pointer of the app.
  defp at(app, pointer) do
    pointer
    |> pointer_path()
    |> Enum.reduce_while(app, fn segment, value ->
      case child(value, segment) do
        {:ok, child} -> {:cont, child}
        :error -> {:halt, nil}
      end
    end)
  end

  defp child(map, segment) when is_map(map), do: Map.fetch(map, segment)

  defp child(list, segment) when is_list(list) do
    case Integer.parse(segment) do
      {i, ""} when i >= 0 and i < length(list) -> {:ok, Enum.at(list, i)}
      _ -> :error
    end
  end

  defp child(_value, _segment), do: :error
end
