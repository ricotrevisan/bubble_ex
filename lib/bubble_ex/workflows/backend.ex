defmodule BubbleEx.Workflows.Backend do
  @moduledoc """
  Stack-neutral lowering of an app's backend workflows (WTF-373, T7 of
  WTF-359): every workflow of the root `api` collection (API workflows,
  backend custom events, database triggers) becomes a
  `BubbleEx.Workflows.Backend.Workflow` with its entry point (kind,
  exposure, authentication, privacy context, parameters, returns) and its
  steps, each lowered to a small closed set of operations whose values are
  compiled to `BubbleEx.Expression.IR` by `BubbleEx.Expression.Compiler`,
  or kept as **residue** (`BubbleEx.Plan.Residue` entries) with a
  diagnostic. Nothing is dropped silently: an action type, an option or an
  expression without a lowering makes its step residue.

      {:ok, model} = BubbleEx.Model.build(app)
      {:ok, index} = BubbleEx.Index.build(app, model: model)
      {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)

  There are no target names here (no modules, atoms or Elixir source): a
  target adapter (`BubbleEx.Target.Ash.Workflows` for Ash and Oban) binds
  names and compiles the IR to its language, adding its own residue when
  an IR does not compile there. Output is deterministic (workflows in
  Bubble ID order, steps in Bubble order).

  ## Operations

  | Bubble action | `Step.op` | `Step.args` |
  |---------------|-----------|-------------|
  | Create a new thing (`NewThing`) | `:create` | `data_type`, `changes` |
  | Make changes to a thing (`ChangeThing`) | `:update` | `data_type`, `target`, `changes` |
  | Make changes to the current user (`MakeChangeCurrentUser`) | `:update_current_user` | `data_type` (`"user"`), `changes` |
  | Delete a thing (`DeleteThing`) | `:delete` | `data_type`, `target` |
  | Make changes to a list of things (`ChangeListOfThings`) | `:update_list` | `data_type`, `target`, `changes` |
  | Delete a list of things (`DeleteListOfThings`) | `:delete_list` | `data_type`, `target` |
  | Schedule API workflow (`ScheduleAPIEvent`) | `:schedule` | `workflow`, `at`, `params` |
  | Schedule API workflow on a list (`ScheduleAPIEventOnList`) | `:schedule_list` | `workflow`, `at`, `list`, `item_type`, `interval`, `params` |
  | Trigger a custom event (`TriggerCustomEvent`) | `:call` | `workflow`, `params` |
  | Terminate this workflow (`TerminateWorkflow`) | `:terminate` | `returns` |
  | Return data from API (`APIReturnData`) | `:return` | `values` (key/value pairs) or `text` and `content_type` |

  A change (`BubbleEx.Workflows.Backend.Change`) sets a field or edits a
  list field (`:set`, `:add`, `:remove`, `:add_list`, `:remove_list`,
  `:set_list`, `:clear_list`). Every step may carry a `condition` ("Only
  when"). Values are `BubbleEx.Workflows.Backend.Expr`s: an IR, or the
  constructs that stopped it.

  ## Residue

  Residue entries are `BubbleEx.Plan.Residue` entries on the workflow or
  action symbol (`workflow:<id>`, `action:<id>`), so they can be passed to
  `BubbleEx.Plan.build/5` as `residue:`:

    * `:uncompiled_expression` - a value or condition with no IR
      (`detail.constructs`)
    * `:unsupported_action` - no lowering for the action type (cancelling
      a scheduled workflow needs Bubble's scheduled IDs, sending email and
      deleting files need an owner choice, …)
    * `:api_connector_action` - an API Connector call; it waits for the
      generated Req clients (WTF-374)
    * `:plugin_action`, `:auth_action` - as in `BubbleEx.Plan.Residue`
    * `:unsupported_event`, `:plugin_event` - an event with no backend
      lowering (recurring events are unverified: no export has one)
    * `:unsupported_option` - an event or action member whose semantics are
      not lowered (`detail.options`): detected request data
      (`parameter_def: "auto"`, whose sample request is never read: it can
      hold credentials), request headers as parameters, a terminate
      message, an unknown change operation
    * `:unresolved_reference` - a data type, field, parameter, return or
      callee that does not resolve

  ## Privacy

  `ignores_privacy?` is the workflow's own "ignore privacy rules" setting;
  only such a workflow may run with authorization bypassed, and each one
  gets a `:workflow_privacy_bypass` warning. A custom event has no setting
  of its own: it runs in its caller's context, so a target passes the
  caller's authorization through at run time (`inherits_privacy?`). The
  `ignore_privacy_rules` option of a scheduling action is not a bypass: the
  scheduled workflow's own setting decides (as in `BubbleEx.Index`), and
  the option gets a `:workflow_action_privacy_option` diagnostic.

  ## Coverage

  See `coverage/1`: a workflow is **native** when it has no residue at all
  (its event and every step lower); a step is native when it has none.
  Entry points (one per workflow) are always generated.
  """

  alias BubbleEx.{Diagnostic, Error, Expression, Index, Model}
  alias BubbleEx.Expression.{Compiler, Env, IR, Sites, Tree}
  alias BubbleEx.Index.{Symbol, WorkflowAnalysis}
  alias BubbleEx.Model.Type
  alias BubbleEx.Plan.Residue
  alias BubbleEx.Workflows.Backend.{Change, Expr, Param, Return, Step, Workflow}
  alias BubbleEx.Workflows.Source

  defstruct workflows: [], cycles: [], diagnostics: []

  @type cycle :: %{
          id: String.t(),
          workflows: [String.t()],
          bubble_ids: [String.t()],
          synchronous: boolean()
        }
  @type t :: %__MODULE__{
          workflows: [Workflow.t()],
          cycles: [cycle()],
          diagnostics: [Diagnostic.t()]
        }

  @kinds %{
    "APIEvent" => :api,
    "CustomEvent" => :custom_event,
    "DatabaseTriggerEvent" => :database_trigger
  }

  # Event members with a lowering, or without semantics (captions, colors).
  @event_members ~w(wf_name event_name wf_folder expose auth_unecessary ignore_privacy_rules
                    parameters condition data_trigger_type return_types event_color
                    return_200_if_not_run trigger_option waiting_for_data)

  @ops %{
    "NewThing" => :create,
    "ChangeThing" => :update,
    "MakeChangeCurrentUser" => :update_current_user,
    "DeleteThing" => :delete,
    "ChangeListOfThings" => :update_list,
    "DeleteListOfThings" => :delete_list,
    "ScheduleAPIEvent" => :schedule,
    "ScheduleAPIEventOnList" => :schedule_list,
    "TriggerCustomEvent" => :call,
    "TerminateWorkflow" => :terminate,
    "APIReturnData" => :return
  }

  # Action members each operation lowers (besides `condition`); a schedule
  # also reads its `_wf_param_<key>` members.
  @members %{
    create: ~w(thing_type initial_values),
    update: ~w(to_change changes thing_type),
    update_current_user: ~w(changes),
    delete: ~w(to_delete),
    update_list: ~w(to_change changes type_to_change),
    delete_list: ~w(to_delete type_to_delete),
    schedule: ~w(api_event date ignore_privacy_rules),
    schedule_list: ~w(api_event date data_source type_of_list interval ignore_privacy_rules),
    call: ~w(custom_event arguments),
    terminate: ~w(return_values),
    return: ~w(parameters_actions return_plain_text custom_text custom_content_type)
  }

  @change_ops %{
    "add" => :add,
    "remove" => :remove,
    "add_list" => :add_list,
    "remove_list" => :remove_list,
    "set_list" => :set_list,
    "clear_list" => :clear_list
  }

  @doc """
  Lowers the backend workflows of decoded app JSON. `model` and `index`
  must be built from the same app (`BubbleEx.Index.build(app, model:
  model)`).
  """
  @spec build(map(), Model.t(), Index.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def build(app, model, index, opts \\ [])

  def build(app, %Model{} = model, %Index{} = index, _opts)
      when is_map(app) and not is_struct(app) do
    env = Env.new(model, tree: Tree.build(app))

    raws =
      case Map.get(app, "api") do
        api when is_map(api) or is_list(api) -> Source.entries(api)
        _ -> []
      end

    entries =
      for {key, raw} <- raws, is_map(raw) do
        id = text(Source.value(raw, ~w(id %id))) || to_string(key)
        {id, raw, ["api", key]}
      end

    params = Map.new(entries, fn {id, raw, _} -> {id, parameters(raw)} end)
    returns = Map.new(entries, fn {id, raw, _} -> {id, returns(raw)} end)
    cycles = cycles(index, Map.new(entries, &{elem(&1, 0), true}))
    in_cycle = for c <- cycles, w <- c.workflows, into: %{}, do: {w, c.id}

    ctx = %{
      model: model,
      index: index,
      params: params,
      returns: returns,
      cycles: in_cycle
    }

    workflows =
      entries
      |> Enum.map(fn {id, raw, path} -> workflow(id, raw, path, env, ctx) end)
      |> Enum.sort_by(& &1.bubble_id)

    diagnostics =
      workflows
      |> Enum.flat_map(&workflow_diagnostics/1)
      |> Diagnostic.normalize()

    {:ok, %__MODULE__{workflows: workflows, cycles: cycles, diagnostics: diagnostics}}
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
  Lowering coverage, with string keys. The metric:

    * `"workflows"` - backend workflows (every one gets a generated entry
      point); `"native"` those with no residue at all: the event and every
      step lower and every value compiles to IR; `"residue"` the rest
    * `"steps"` - actions of those workflows; `"native"` the actions with
      no residue, `"residue"` the rest
    * `"by_kind"` - `{workflows, native}` per workflow kind
    * `"step_ops"` - native steps per operation
    * `"residue_reasons"` - residue entries per reason (a subject may have
      several)
    * `"privacy_bypasses"` - workflows lowered with authorization bypassed
      (their own "ignore privacy rules"); `"inherits_privacy"` custom
      events that run in their caller's privacy context
    * `"exposed"` - workflows exposed as public API endpoints; `"cycles"`
      call cycles among backend workflows

  This is IR-level coverage: a target may add residue when an IR does not
  compile to its language (see `BubbleEx.Target.Ash.Workflows.coverage/1`,
  the generated-code measure).
  """
  @spec coverage(t()) :: map()
  def coverage(%__MODULE__{workflows: workflows, cycles: cycles}) do
    steps = Enum.flat_map(workflows, & &1.steps)
    native = Enum.filter(workflows, &Workflow.native?/1)

    %{
      "workflows" => %{
        "total" => length(workflows),
        "native" => length(native),
        "residue" => length(workflows) - length(native)
      },
      "steps" => %{
        "total" => length(steps),
        "native" => Enum.count(steps, &(&1.residue == [])),
        "residue" => Enum.count(steps, &(&1.residue != []))
      },
      "by_kind" =>
        workflows
        |> Enum.group_by(&Atom.to_string(&1.kind))
        |> Map.new(fn {kind, ws} ->
          {kind, %{"total" => length(ws), "native" => Enum.count(ws, &Workflow.native?/1)}}
        end),
      "step_ops" =>
        steps
        |> Enum.filter(&(&1.residue == [] and &1.op != nil))
        |> Enum.frequencies_by(&Atom.to_string(&1.op)),
      "residue_reasons" =>
        workflows
        |> Enum.flat_map(&Workflow.residue/1)
        |> Enum.frequencies_by(&Atom.to_string(&1.reason)),
      "privacy_bypasses" => Enum.count(workflows, & &1.ignores_privacy?),
      "inherits_privacy" => Enum.count(workflows, & &1.inherits_privacy?),
      "exposed" => Enum.count(workflows, & &1.exposed?),
      "cycles" => length(cycles)
    }
  end

  # --- workflows -------------------------------------------------------------------

  defp workflow(id, raw, path, env, ctx) do
    env = Sites.workflow_env(raw, path, nil, env)
    props = map(Source.value(raw, ~w(properties %p)))
    event_type = Source.value(raw, ~w(type %x))
    symbol_id = Symbol.id(:workflow, id)
    symbol = Index.symbol(ctx.index, symbol_id)
    ctx = Map.put(ctx, :workflow, id)
    attrs = if symbol, do: symbol.attrs, else: %{}
    kind = Map.get(@kinds, event_type, :unsupported)
    pointer = Source.pointer(path)

    trigger_type =
      if kind == :database_trigger, do: data_type_key(props["data_trigger_type"])

    event_residue =
      event_residue(symbol_id, kind, event_type, props) ++
        trigger_residue(symbol_id, kind, trigger_type, ctx.model)

    condition = expr(props["condition"], path ++ ["properties", "condition"], env)

    steps =
      raw
      |> actions(path)
      |> Enum.with_index(1)
      |> Enum.map(fn {{action, apath}, n} -> step(action, apath, n, id, env, ctx) end)

    %Workflow{
      id: symbol_id,
      bubble_id: id,
      name: text(props["wf_name"]) || text(props["event_name"]),
      folder: text(props["wf_folder"]),
      kind: kind,
      event_type: type_text(event_type),
      exposed?: kind == :api and props["expose"] == true,
      auth: auth(props["auth_unecessary"]),
      method: method(props["trigger_option"]),
      return_200_if_not_run?: props["return_200_if_not_run"] == true,
      ignores_privacy?: kind == :api and props["ignore_privacy_rules"] == true,
      inherits_privacy?: kind == :custom_event,
      runs_ignoring_privacy?: attrs[:runs_ignoring_privacy_rules] == true,
      invocation_modes: Map.get(attrs, :invocation_modes, []),
      parameters: Map.fetch!(ctx.params, id),
      returns: Map.fetch!(ctx.returns, id),
      trigger_type: trigger_type,
      condition: condition,
      steps: steps,
      cycle: Map.get(ctx.cycles, symbol_id),
      residue: event_residue ++ expr_residue(symbol_id, [condition]),
      path: pointer
    }
  end

  defp actions(raw, path) do
    case Source.get(raw, ~w(actions %a)) do
      {key, actions} when is_map(actions) or is_list(actions) ->
        actions |> ordered() |> Enum.map(fn {k, a} -> {a, path ++ [key, k]} end)

      _ ->
        []
    end
  end

  defp event_residue(id, :unsupported, type, _props) do
    case Residue.plugin(type) do
      nil -> [Residue.entry(id, :unsupported_event, %{type: type_text(type)})]
      plugin -> [Residue.entry(id, :plugin_event, %{plugin: plugin})]
    end
  end

  # `raw_data` is a sample request (it can hold credentials) and
  # `data_type` the shape detected from it: never read, only whether the
  # workflow detects its parameters from request data.
  defp event_residue(id, _kind, _type, props) do
    unknown =
      for {key, _} <- props,
          key not in @event_members,
          key not in ~w(raw_data data_type include_headers parameter_def),
          do: key

    options =
      Enum.sort(
        unknown ++
          if(props["include_headers"] == true, do: ["include_headers"], else: []) ++
          if(props["parameter_def"] == "auto", do: ["parameter_def"], else: [])
      )

    if options == [],
      do: [],
      else: [Residue.entry(id, :unsupported_option, %{options: options})]
  end

  defp trigger_residue(id, :database_trigger, nil, _model),
    do: [Residue.entry(id, :unresolved_reference, %{reference: "data_type"})]

  defp trigger_residue(id, :database_trigger, type, model) do
    if Model.data_type(model, type),
      do: [],
      else: [Residue.entry(id, :unresolved_reference, %{reference: "data_type"})]
  end

  defp trigger_residue(_id, _kind, _type, _model), do: []

  defp auth(true), do: :none
  defp auth("admin_only"), do: :admin_only
  defp auth(_), do: :authenticated

  defp method("get"), do: :get
  defp method("post"), do: :post
  defp method(_), do: nil

  # --- parameters and returns --------------------------------------------------------

  # API workflows define `{key, value (the type), is_list, optional,
  # in_url}`; custom events `{param_id, param_name, btype_id, is_list,
  # optional}`. Expressions reference a parameter by `param_id` (for API
  # workflows the key when there is no `param_id`).
  defp parameters(raw) do
    raw
    |> Source.value(~w(properties %p))
    |> map()
    |> Map.get("parameters")
    |> ordered()
    |> Enum.flat_map(fn {_, p} ->
      p = map(p)
      id = text(p["param_id"]) || text(p["key"])
      base = text(p["btype_id"]) || text(p["value"])

      if id do
        [
          %Param{
            id: id,
            key: text(p["key"]) || text(p["param_name"]) || id,
            type: base && if(p["is_list"] == true, do: Type.listed(base), else: base),
            optional?: p["optional"] == true,
            in_url?: p["in_url"] == true
          }
        ]
      else
        []
      end
    end)
  end

  defp returns(raw) do
    raw
    |> Source.value(~w(properties %p))
    |> map()
    |> Map.get("return_types")
    |> ordered()
    |> Enum.flat_map(fn {_, r} ->
      r = map(r)

      case text(r["return_id"]) do
        nil ->
          []

        id ->
          base = text(r["btype_id"])

          [
            %Return{
              id: id,
              name: text(r["display"]) || id,
              type: base && if(r["is_list"] == true, do: Type.listed(base), else: base)
            }
          ]
      end
    end)
  end

  # --- steps -------------------------------------------------------------------------

  defp step(action, path, n, workflow, env, ctx) when is_map(action) do
    type = Source.value(action, ~w(type %x))
    props = map(Source.value(action, ~w(properties %p)))
    bubble_id = text(Source.value(action, ~w(id %id))) || "#{workflow}/#{List.last(path)}"
    id = Symbol.id(:action, bubble_id)
    op = if is_binary(type), do: Map.get(@ops, type)
    ppath = path ++ ["properties"]
    condition = expr(props["condition"], ppath ++ ["condition"], env)

    step = %Step{
      index: n,
      bubble_id: bubble_id,
      id: id,
      type: type_text(type),
      op: op,
      condition: condition,
      path: Source.pointer(path)
    }

    case type_residue(id, type, op) do
      [] ->
        {args, residue} = lower(op, props, ppath, id, env, ctx)
        options = unknown_members(op, props)

        option_residue =
          if options == [],
            do: [],
            else: [Residue.entry(id, :unsupported_option, %{options: options})]

        exprs = [condition | exprs_of(args)]

        %{
          step
          | args: args,
            residue: Residue.sort(residue ++ option_residue ++ expr_residue(id, exprs))
        }

      residue ->
        %{step | op: nil, residue: residue ++ expr_residue(id, [condition])}
    end
  end

  defp step(_action, path, n, workflow, _env, _ctx) do
    bubble_id = "#{workflow}/#{List.last(path)}"
    id = Symbol.id(:action, bubble_id)

    %Step{
      index: n,
      bubble_id: bubble_id,
      id: id,
      type: nil,
      path: Source.pointer(path),
      residue: [Residue.entry(id, :unsupported_action, %{type: nil})]
    }
  end

  defp type_residue(_id, _type, op) when op != nil, do: []

  defp type_residue(id, "apiconnector2-" <> call, nil),
    do: [Residue.entry(id, :api_connector_action, %{call: call})]

  defp type_residue(id, type, nil) do
    cond do
      p = Residue.plugin(type) -> [Residue.entry(id, :plugin_action, %{plugin: p})]
      type in Residue.auth_actions() -> [Residue.entry(id, :auth_action, %{type: type})]
      true -> [Residue.entry(id, :unsupported_action, %{type: type_text(type)})]
    end
  end

  defp unknown_members(op, props) do
    known = ["condition" | Map.fetch!(@members, op)]

    for {key, _} <- props,
        key not in known,
        not (op in [:schedule, :schedule_list] and String.starts_with?(key, "_wf_param_")),
        do: key
  end

  # --- operations --------------------------------------------------------------------

  defp lower(:create, props, path, id, env, ctx) do
    type = data_type_key(props["thing_type"]) || written_type(ctx, id)

    changes(props["initial_values"], path ++ ["initial_values"], type, id, env, ctx)
    |> with_type(type, id, %{})
  end

  defp lower(op, props, path, id, env, ctx) when op in [:update, :update_list] do
    type = written_type(ctx, id)
    target = expr(props["to_change"], path ++ ["to_change"], env)

    changes(props["changes"], path ++ ["changes"], type, id, env, ctx)
    |> with_type(type, id, %{target: target})
  end

  defp lower(:update_current_user, props, path, id, env, ctx) do
    changes(props["changes"], path ++ ["changes"], "user", id, env, ctx)
    |> with_type("user", id, %{})
  end

  defp lower(op, props, path, id, env, ctx) when op in [:delete, :delete_list] do
    type = written_type(ctx, id)
    target = expr(props["to_delete"], path ++ ["to_delete"], env)
    with_type({[], []}, type, id, %{target: target})
  end

  defp lower(:schedule, props, path, id, env, ctx) do
    {callee, params, residue} = scheduled(props, path, id, env, ctx)
    at = expr(props["date"], path ++ ["date"], env)
    {%{workflow: callee, at: at, params: params, privacy_option: privacy_option(props)}, residue}
  end

  defp lower(:schedule_list, props, path, id, env, ctx) do
    {callee, params, residue} = scheduled(props, path, id, env, ctx)

    args = %{
      workflow: callee,
      at: expr(props["date"], path ++ ["date"], env),
      list: expr(props["data_source"], path ++ ["data_source"], env),
      item_type: text(props["type_of_list"]),
      interval: expr(props["interval"], path ++ ["interval"], env),
      params: params,
      privacy_option: privacy_option(props)
    }

    {args, residue}
  end

  defp lower(:call, props, path, id, env, ctx) do
    callee = text(props["custom_event"])
    callee_params = Map.get(ctx.params, callee)

    {params, residue} =
      props["arguments"]
      |> ordered()
      |> Enum.map_reduce([], fn {k, arg}, residue ->
        arg = map(arg)
        param = text(arg["param_id"])
        value = expr(arg["arg_value"], path ++ ["arguments", k, "arg_value"], env)

        if callee_params && Enum.any?(callee_params, &(&1.id == param)),
          do: {%{param: param, value: value}, residue},
          else:
            {nil, [Residue.entry(id, :unresolved_reference, %{reference: "parameter"}) | residue]}
      end)

    residue =
      if callee_params,
        do: residue,
        else: [Residue.entry(id, :unresolved_reference, %{reference: "workflow"}) | residue]

    {%{workflow: callee, params: Enum.reject(params, &is_nil/1)}, Enum.uniq(residue)}
  end

  defp lower(:terminate, props, path, id, env, ctx) do
    known = Map.get(ctx.returns, ctx.workflow, [])

    {returns, residue} =
      props["return_values"]
      |> ordered()
      |> Enum.map_reduce([], fn {k, r}, residue ->
        r = map(r)
        return = text(r["return_id"])

        cond do
          not Enum.any?(known, &(&1.id == return)) ->
            {nil, [Residue.entry(id, :unresolved_reference, %{reference: "return"}) | residue]}

          not Map.has_key?(r, "return_value") ->
            {nil, residue}

          true ->
            value = expr(r["return_value"], path ++ ["return_values", k, "return_value"], env)
            {%{return: return, value: value}, residue}
        end
      end)

    {%{returns: Enum.reject(returns, &is_nil/1)}, Enum.uniq(residue)}
  end

  defp lower(:return, props, path, id, env, _ctx) do
    if props["return_plain_text"] in [true, "custom_content"] do
      {%{
         text: expr(props["custom_text"], path ++ ["custom_text"], env),
         content_type: expr(props["custom_content_type"], path ++ ["custom_content_type"], env)
       }, []}
    else
      {values, residue} =
        props["parameters_actions"]
        |> ordered()
        |> Enum.map_reduce([], fn {k, entry}, residue ->
          return_value(map(entry), path ++ ["parameters_actions", k, "content"], id, env, residue)
        end)

      {%{values: Enum.reject(values, &is_nil/1)}, Enum.uniq(residue)}
    end
  end

  # `value` is the returned type's name; an expression there is not a
  # shape this lowering knows.
  defp return_value(entry, path, id, env, residue) do
    key = text(entry["key"])

    if key && (is_binary(entry["value"]) or is_nil(entry["value"])) do
      {%{key: key, list?: entry["list"] == true, value: expr(entry["content"], path, env)},
       residue}
    else
      {nil,
       [Residue.entry(id, :unsupported_option, %{options: ["parameters_actions"]}) | residue]}
    end
  end

  defp with_type({changes, residue}, nil, id, args),
    do:
      {Map.merge(args, %{data_type: nil, changes: changes}),
       [Residue.entry(id, :unresolved_reference, %{reference: "data_type"}) | residue]}

  defp with_type({changes, residue}, type, _id, args),
    do: {Map.merge(args, %{data_type: type, changes: changes}), residue}

  defp scheduled(props, path, id, env, ctx) do
    callee = text(props["api_event"])
    callee_params = Map.get(ctx.params, callee)

    {params, residue} =
      props
      |> Enum.filter(fn {k, _} -> String.starts_with?(k, "_wf_param_") end)
      |> Enum.sort()
      |> Enum.map_reduce([], fn {"_wf_param_" <> key = k, value}, residue ->
        case callee_params && Enum.find(callee_params, &(&1.key == key or &1.id == key)) do
          %Param{id: param} ->
            {%{param: param, value: expr(value, path ++ [k], env)}, residue}

          _ ->
            {nil, [Residue.entry(id, :unresolved_reference, %{reference: "parameter"}) | residue]}
        end
      end)

    residue =
      if callee_params,
        do: residue,
        else: [Residue.entry(id, :unresolved_reference, %{reference: "workflow"}) | residue]

    {callee, Enum.reject(params, &is_nil/1), Enum.uniq(residue)}
  end

  # A diagnostic, not residue: see the moduledoc, "Privacy".
  defp privacy_option(props), do: props["ignore_privacy_rules"] == true

  defp changes(entries, path, type, id, env, ctx) do
    fields = fields(ctx.model, type)

    entries
    |> ordered()
    |> Enum.map_reduce([], fn {k, entry}, residue ->
      entry = map(entry)

      change(
        entry,
        change_op(entry["action"]),
        type,
        fields,
        path ++ [k, "value"],
        id,
        env,
        residue
      )
    end)
    |> then(fn {changes, residue} -> {Enum.reject(changes, &is_nil/1), Enum.uniq(residue)} end)
  end

  defp change(_entry, nil, _type, _fields, _path, id, _env, residue),
    do: {nil, [Residue.entry(id, :unsupported_option, %{options: ["changes"]}) | residue]}

  defp change(entry, op, type, fields, path, id, env, residue) do
    field = text(entry["key"])

    cond do
      type != nil and not MapSet.member?(fields, field) ->
        {nil, [Residue.entry(id, :unresolved_reference, %{reference: "field"}) | residue]}

      op == :clear_list ->
        {%Change{field: field, op: op, value: nil}, residue}

      true ->
        {%Change{field: field, op: op, value: expr(entry["value"], path, env)}, residue}
    end
  end

  defp change_op(%{"type" => "Empty"}), do: :set
  defp change_op(nil), do: :set
  defp change_op(name) when is_binary(name), do: Map.get(@change_ops, name)
  defp change_op(_), do: nil

  defp fields(_model, nil), do: MapSet.new()

  defp fields(model, type) do
    case Model.data_type(model, type) do
      nil ->
        MapSet.new()

      data_type ->
        for f <- data_type.fields, not f.deleted, f.raw == nil, into: MapSet.new(), do: f.id
    end
  end

  # The data type an action writes, as the index resolved it.
  defp written_type(ctx, id) do
    ctx.index
    |> Index.references_from(id, [:writes_type])
    |> Enum.map(fn %{to: "data_type:" <> type} -> type end)
    |> Enum.uniq()
    |> case do
      [type] -> type
      _ -> nil
    end
  end

  # --- expressions -------------------------------------------------------------------

  defp expr(nil, _path, _env), do: nil

  defp expr(value, path, env) when is_map(value) do
    pointer = Source.pointer(path)

    with {:ok, %{ast: ast}} <- Expression.parse(value, schema: env.schema, path: path),
         {:ok, %{ir: ir, diagnostics: diags}} <- Compiler.compile(ast, %{env | path: path}) do
      if ir,
        do: %Expr{path: pointer, ir: ir},
        else: %Expr{path: pointer, constructs: Residue.constructs(diags)}
    else
      _ -> %Expr{path: pointer, constructs: ["parse_failed"]}
    end
  end

  defp expr(value, path, _env) when is_binary(value),
    do: %Expr{path: Source.pointer(path), ir: IR.node(:literal, [value], "text")}

  defp expr(value, path, _env) when is_number(value),
    do: %Expr{path: Source.pointer(path), ir: IR.node(:literal, [value], "number")}

  defp expr(value, path, _env) when is_boolean(value),
    do: %Expr{path: Source.pointer(path), ir: IR.node(:literal, [value], "boolean")}

  defp expr(_value, path, _env), do: %Expr{path: Source.pointer(path), constructs: ["malformed"]}

  defp exprs_of(args) do
    Enum.flat_map(args, fn
      {_k, %Expr{} = e} -> [e]
      {_k, list} when is_list(list) -> Enum.flat_map(list, &nested_exprs/1)
      _ -> []
    end)
  end

  defp nested_exprs(%Change{value: value}), do: [value]
  defp nested_exprs(%{value: value}), do: [value]
  defp nested_exprs(_), do: []

  defp expr_residue(id, exprs) do
    case for(%Expr{ir: nil} = e <- exprs, do: e) do
      [] ->
        []

      failed ->
        [
          Residue.entry(id, :uncompiled_expression, %{
            expressions: length(failed),
            constructs: failed |> Enum.flat_map(& &1.constructs) |> Enum.uniq() |> Enum.sort()
          })
        ]
    end
  end

  # --- cycles and diagnostics ---------------------------------------------------------

  # Call cycles among backend workflows; the ID is the plan's cycle task ID
  # (`cycle:` and the members' escaped symbol parts).
  defp cycles(index, backend) do
    for %{workflows: members} = cycle <- Index.cycles(index),
        ids = Enum.map(members, &symbol_bubble_id(index, &1)),
        Enum.all?(ids, &Map.has_key?(backend, &1)) do
      %{
        id: "cycle:" <> Enum.map_join(members, "+", &symbol_part/1),
        workflows: members,
        bubble_ids: ids,
        synchronous: cycle.synchronous
      }
    end
  end

  defp symbol_bubble_id(index, id) do
    case Index.symbol(index, id) do
      %{bubble_id: bubble_id} -> bubble_id
      nil -> nil
    end
  end

  defp symbol_part(id), do: id |> String.split(":", parts: 2) |> List.last()

  defp workflow_diagnostics(%Workflow{} = w) do
    subject = %{workflow: w.bubble_id}

    bypass =
      if w.ignores_privacy?,
        do: [
          Diagnostic.new(
            :workflow_privacy_bypass,
            w.path,
            "backend workflow runs ignoring privacy rules in Bubble; it is lowered with " <>
              "authorization bypassed (authorize?: false) for every data access",
            subject: subject,
            details: %{exposed: w.exposed?, auth: Atom.to_string(w.auth)}
          )
        ],
        else: []

    residue =
      for %{subject: s, reason: reason, detail: detail} <- Workflow.residue(w) do
        path = if s == w.id, do: w.path, else: step_path(w, s)

        Diagnostic.new(
          :workflow_residue,
          path,
          "#{s} is not lowered (#{reason}); it is left for agent work",
          subject: subject,
          details: %{subject: s, reason: Atom.to_string(reason), detail: detail}
        )
      end

    action_privacy =
      for %Step{op: op} = s <- w.steps,
          op in [:schedule, :schedule_list],
          s.args[:privacy_option] == true,
          do:
            Diagnostic.new(
              :workflow_action_privacy_option,
              s.path,
              "the scheduling action's ignore-privacy option is not a bypass; " <>
                "the scheduled workflow's own setting decides",
              subject: subject
            )

    bypass ++ residue ++ action_privacy
  end

  defp step_path(w, subject) do
    Enum.find_value(w.steps, w.path, &(&1.id == subject && &1.path))
  end

  # --- helpers ------------------------------------------------------------------------

  defp data_type_key(value) when is_binary(value) do
    case Type.reference(value) do
      {:data_type, key} -> key
      _ -> nil
    end
  end

  defp data_type_key(_), do: nil

  defp ordered(map) when is_map(map) do
    entries = Enum.to_list(map)

    if Enum.all?(entries, fn {k, _} -> match?({_, ""}, Integer.parse(k)) end),
      do: Enum.sort_by(entries, fn {k, _} -> String.to_integer(k) end),
      else: Enum.sort_by(entries, &elem(&1, 0))
  end

  defp ordered(list) when is_list(list),
    do: list |> Enum.with_index() |> Enum.map(fn {v, i} -> {i, v} end)

  defp ordered(_), do: []

  defp map(value) when is_map(value), do: value
  defp map(_), do: %{}

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_), do: nil

  defp type_text(type) when is_binary(type), do: type
  defp type_text(_), do: nil

  @doc false
  # The action classes of `BubbleEx.Index.WorkflowAnalysis`, for tests.
  def action_class(type), do: WorkflowAnalysis.action_class(type)
end
