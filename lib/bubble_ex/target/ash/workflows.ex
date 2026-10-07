defmodule BubbleEx.Target.Ash.Workflows do
  @moduledoc """
  Binds lowered backend workflows (`BubbleEx.Workflows.Backend`) to Ash
  and Oban (WTF-373): names, argument types and Elixir source for every
  value, as plain data (`BubbleEx.Target.Ash.Workflows.Spec`) that
  `BubbleEx.Target.Phoenix` prints.

      {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
      {:ok, project} = BubbleEx.Target.Ash.map(model)
      {:ok, spec} = BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "Acme")
      {:ok, files} = BubbleEx.Target.Phoenix.render(project, name: "Acme", workflows: spec)

  ## Mapping

  | Bubble | Ash / Oban |
  |--------|------------|
  | backend folder | a resource `Workflows.<Folder>` without a data layer, listed in the app's domain |
  | backend workflow (any kind) | a generic action on its folder's resource; the arguments are its parameters (a thing is its Bubble ID, loaded in the body; a list of things a list of IDs) |
  | "Schedule API workflow" (and on a list) | an Oban job of the generated `Workflows.Scheduler` worker (`max_attempts: 1`: Bubble does not retry), `scheduled_at` the scheduled date |
  | "Trigger a custom event" | a direct call of the callee's action in the same process |
  | database trigger | an Ash change on the data type's resource inserting a scheduler job in the same transaction, with the record's ID and its values before the change |
  | exposed API workflow | `/api/1.1/wf/<name>` through the generated `WorkflowApiController` |
  | call cycle | a depth guard: a scheduled job carries its chain depth and a direct call its call depth; beyond the configured limits the step fails |

  Values are compiled by `BubbleEx.Target.Elixir` against `project`; an
  IR that does not compile there, or reads a context input a backend
  workflow does not have (an element's value, a URL parameter), makes its
  step residue (`:uncompiled_expression`, constructs prefixed `elixir:`).

  ## Privacy

  Every data access in a generated body passes the workflow's actor and
  `authorize?`: `false` **only** for a workflow whose own "ignore privacy
  rules" setting is on (`privacy_bypasses`, each with a
  `:workflow_privacy_bypass` warning); a custom event uses its caller's
  (`:inherit`, `true` when run on its own); everything else is `true`.

  **What that is worth depends on the project's privacy mode.**

    * `privacy: :omit` - `BubbleEx.Target.Phoenix`'s default:
      no resource has an authorizer, so `authorize?` changes nothing and
      the actor restricts nothing. Any caller of a workflow can read and
      write any record, including records of other users whose IDs it
      passes. So the workflow API (`/api/1.1/wf/<name>`) is **not served**
      until the owner opts in (`serve_workflow_api: true`, see the
      generated `Workflows.Runtime`), and every exposed workflow gets a
      `:workflow_endpoint_not_served` warning. Scheduled jobs and database
      triggers are internal and run.
    * `privacy: :unverified` - the generated policies (WTF-356) authorize
      reads only: no policy authorizes `create`, `update` or `destroy`
      (see `BubbleEx.Target.Ash`, "writes by workflows"), so every
      generated write with `authorize?: true` is forbidden.
    * `privacy: :enforced` - the same read policies, enforced (WTF-423):
      reads follow the compiled privacy rules for the workflow's actor.
      Writes follow Rico's option A: the generated runtime marks its data
      steps (`%{private: %{bubble_workflow_write: true}}` in the action context)
      and the `WorkflowWrite` policy authorizes them, so the workflow's
      conditions guard its writes, as in Bubble; writes are not checked
      against the privacy rules. The workflow API stays off until the
      owner opts in (`serve_workflow_api: true`), with a
      `:workflow_endpoint_not_served` info per exposed workflow.

  ## Coverage

  `coverage/1` (`BubbleEx.Target.Ash.Workflows.Spec.coverage/1`) measures
  generated code: a workflow is **native** when it has no residue, neither
  from `BubbleEx.Workflows.Backend` nor from this binding, so its whole
  body is generated; a step likewise. Entry points are always generated.
  """

  alias BubbleEx.{Diagnostic, Error}
  alias BubbleEx.Model.Type
  alias BubbleEx.Plan.Residue
  alias BubbleEx.Target.Ash.{Naming, Project, Resource}
  alias BubbleEx.Expression.IR
  alias BubbleEx.Target.Ash.Workflows.Spec
  alias BubbleEx.Target.Elixir, as: ElixirTarget
  alias BubbleEx.Workflows.Backend
  alias BubbleEx.Workflows.Backend.{Step, Workflow}
  alias BubbleEx.Workflows.Lowering.{Change, Expr}

  @names_version 1

  # Function names a generated body module must not define: keywords,
  # special forms and every Kernel function or macro.
  @reserved Enum.uniq(
              ~w(do end fn when and or not in true false nil catch rescue after else) ++
                Enum.map(Kernel.__info__(:functions) ++ Kernel.__info__(:macros), fn {f, _} ->
                  Atom.to_string(f)
                end) ++
                Enum.map(Kernel.SpecialForms.__info__(:macros), fn {f, _} ->
                  Atom.to_string(f)
                end)
            )

  @page_data %{"Current Date/Time" => :now, "AppVersion" => :app_version}

  @doc """
  Binds `backend` to `project` (`BubbleEx.Target.Ash.map/3` of the same
  Model).

  ## Options

    * `:namespace` - the root module (required: the Elixir source names
      the generated enum and runtime modules)
    * `:names` - a name map from an earlier run (`Spec.names`): its names
      are kept for the same Bubble IDs
  """
  @spec map(Backend.t(), Project.t(), keyword()) :: {:ok, Spec.t()} | {:error, Error.t()}
  def map(backend, project, opts \\ [])

  def map(%Backend{} = backend, %Project{} = project, opts) when is_list(opts) do
    with {:ok, namespace} <- namespace(opts) do
      locked = locked(Keyword.get(opts, :names))
      lookup = lookup(project)
      dropped = Project.dropped(project)
      # Workflows an owner dropped (WTF-422) are not bound; calls to them
      # are residue (`step/2`).
      backend = %{
        backend
        | workflows:
            Enum.reject(backend.workflows, &MapSet.member?(dropped.workflows, &1.bubble_id))
      }

      ctx = %{
        namespace: namespace,
        runtime: namespace <> ".Bubble.Runtime",
        project: project,
        lookup: lookup,
        dropped: dropped,
        workflows: Map.new(backend.workflows, &{&1.id, &1})
      }

      {modules, names} = folder_names(backend.workflows, locked)
      {actions, names} = action_names(backend.workflows, modules, locked, names)

      bound = backend.workflows |> Enum.map(&action(&1, modules, actions, ctx)) |> block()

      resources =
        bound
        |> Enum.group_by(& &1.module)
        |> Enum.map(fn {module, actions} ->
          %{
            module: module,
            folder: hd(actions).folder,
            actions: Enum.sort_by(actions, & &1.name)
          }
        end)
        |> Enum.sort_by(& &1.module)

      diagnostics =
        (backend.diagnostics ++
           Enum.flat_map(bound, & &1.diagnostics) ++
           endpoint_diagnostics(bound, project) ++
           sensitive_trigger_diagnostics(triggers(bound, lookup), project))
        |> Diagnostic.normalize()

      {:ok,
       %Spec{
         namespace: namespace,
         resources: resources,
         triggers: triggers(bound, lookup),
         stamps: stamps(project),
         cycles: backend.cycles,
         privacy_bypasses: for(a <- bound, a.authorize == false, do: a.workflow) |> Enum.sort(),
         names: names,
         diagnostics: diagnostics
       }}
    end
  end

  def map(_backend, _project, _opts),
    do:
      {:error,
       Error.new(
         :invalid_input,
         "expected a BubbleEx.Workflows.Backend, a BubbleEx.Target.Ash.Project and options"
       )}

  @doc "Every action of a spec, sorted by Bubble ID. See `Spec.actions/1`."
  defdelegate actions(spec), to: Spec

  @doc "Every residue entry of a spec, sorted. See `Spec.residue/1`."
  defdelegate residue(spec), to: Spec

  @doc "Whether an action has no residue. See `Spec.native?/1`."
  defdelegate native?(action), to: Spec

  @doc "Generated-code coverage. See `Spec.coverage/1`."
  defdelegate coverage(spec), to: Spec

  # --- blocking --------------------------------------------------------------------

  # A workflow whose body has residue, or that calls or schedules one that
  # does (transitively, cycles included), must not run any step: its
  # generated body fails before step 1. `blocked_by` lists why: its own
  # residue subjects and the blocked (or unknown) workflows it reaches
  # directly, sorted.
  defp block(actions) do
    by_id = Map.new(actions, &{&1.workflow, &1})
    own = for a <- actions, own_residue(a) != [], into: MapSet.new(), do: a.workflow
    blocked = fixpoint(own, actions, by_id)

    Enum.map(actions, fn a ->
      callees =
        for id <- callees(a),
            not Map.has_key?(by_id, id) or MapSet.member?(blocked, id),
            do: "workflow:" <> to_string(id)

      subjects = own_residue(a) |> Enum.map(& &1.subject)
      Map.put(a, :blocked_by, Enum.sort(Enum.uniq(subjects ++ callees)))
    end)
  end

  defp fixpoint(blocked, actions, by_id) do
    next =
      for a <- actions,
          MapSet.member?(blocked, a.workflow) or
            Enum.any?(callees(a), &(not Map.has_key?(by_id, &1) or MapSet.member?(blocked, &1))),
          into: MapSet.new(),
          do: a.workflow

    if next == blocked, do: blocked, else: fixpoint(next, actions, by_id)
  end

  defp own_residue(a), do: a.residue ++ Enum.flat_map(a.steps, & &1.residue)

  defp callees(a) do
    for %{op: op, args: %{workflow: id}} <- a.steps,
        op in [:call, :schedule, :schedule_list],
        uniq: true,
        do: id
  end

  defp not_served_reason(:omit),
    do:
      "with privacy: :omit no resource has authorization, so any caller could read and " <>
        "write any record through it. Add policies, then set serve_workflow_api: true"

  defp not_served_reason(:enforced),
    do:
      "the workflow API is opt-in (serve_workflow_api: true). With privacy: :enforced its " <>
        "reads follow the privacy rules for the caller, and its writes are guarded only by " <>
        "the workflow's own conditions, as in Bubble"

  # Exposed workflows: with `privacy: :omit` (no authorization at all) the
  # workflow API is not served until the owner turns it on; an endpoint
  # name used twice serves the workflow with the lower Bubble ID.
  defp endpoint_diagnostics(actions, project) do
    exposed = actions |> Enum.filter(& &1.exposed) |> Enum.sort_by(& &1.workflow)

    disabled =
      for a <- exposed, project.privacy in [:omit, :enforced] do
        Diagnostic.new(
          :workflow_endpoint_not_served,
          "",
          "exposed as /api/1.1/wf/#{a.exposed.endpoint} in Bubble, but not served: " <>
            not_served_reason(project.privacy),
          target: :ash,
          subject: %{workflow: a.workflow},
          details: %{auth: Atom.to_string(a.exposed.auth), bypass: a.authorize == false}
        )
      end

    duplicates =
      exposed
      |> Enum.group_by(& &1.exposed.endpoint)
      |> Enum.flat_map(fn
        {_name, [_]} ->
          []

        {name, [kept | dropped]} ->
          for a <- dropped do
            Diagnostic.new(
              :workflow_endpoint_duplicate,
              "",
              "the endpoint name #{inspect(name)} is also used by #{kept.workflow}, which serves it",
              target: :ash,
              subject: %{workflow: a.workflow},
              details: %{served_by: kept.workflow}
            )
          end
      end)

    disabled ++ duplicates
  end

  # --- names ---------------------------------------------------------------------------

  defp namespace(opts) do
    case Keyword.get(opts, :namespace) do
      ns when is_binary(ns) ->
        if Regex.match?(~r/\A[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)*\z/, ns),
          do: {:ok, ns},
          else: {:error, Error.new(:invalid_input, "invalid namespace #{inspect(ns)}")}

      _ ->
        {:error, Error.new(:invalid_input, "the :namespace option is required")}
    end
  end

  defp locked(%{"version" => @names_version} = names) do
    actions =
      for {id, %{"resource" => r, "action" => a}} <- map_or_empty(names["actions"]),
          is_binary(r) and is_binary(a),
          Naming.valid?(:pascal, r) and Naming.valid?(:snake, a),
          into: %{},
          do: {id, {r, a}}

    %{folders: string_map(names["folders"]), actions: actions}
  end

  defp locked(_), do: %{folders: %{}, actions: %{}}

  defp string_map(map) when is_map(map),
    do: for({k, v} <- map, is_binary(v) and Naming.valid?(:pascal, v), into: %{}, do: {k, v})

  defp string_map(_), do: %{}

  defp map_or_empty(map) when is_map(map), do: map
  defp map_or_empty(_), do: %{}

  # Folder resource modules: `Workflows.<Folder>`, from the folder's
  # Bubble ID (the export has no folder names); `Unfiled` for none.
  defp folder_names(workflows, locked) do
    folders = workflows |> Enum.map(&(&1.folder || "")) |> Enum.uniq() |> Enum.sort()
    kept = Map.take(locked.folders, folders)
    used = kept |> Map.values() |> MapSet.new()

    {modules, _} =
      Enum.reduce(folders, {kept, used}, fn folder, {acc, used} ->
        if Map.has_key?(acc, folder), do: {acc, used}, else: claim_folder(folder, acc, used)
      end)

    names = %{
      "version" => @names_version,
      "folders" => Map.new(modules),
      "actions" => %{}
    }

    {modules, names}
  end

  defp claim_folder(folder, acc, used) do
    base =
      if folder == "",
        do: "Unfiled",
        else: String.slice("Folder" <> Naming.base(:pascal, nil, folder, "Workflows"), 0, 50)

    {name, used} = Naming.claim(base, used, :pascal, :module)
    {Map.put(acc, folder, name), used}
  end

  # Action names per resource from the workflow's Bubble name (snake case),
  # claimed in Bubble ID order; a locked name is kept.
  defp action_names(workflows, modules, locked, names) do
    {result, _used} =
      workflows
      |> Enum.sort_by(& &1.bubble_id)
      |> Enum.reduce({%{}, %{}}, fn w, {acc, used} ->
        module = Map.fetch!(modules, w.folder || "")
        taken = Map.get(used, module, MapSet.new(@reserved))

        {name, taken} = locked_or_claim(locked.actions[w.bubble_id], module, w, taken)

        {Map.put(acc, w.bubble_id, name), Map.put(used, module, taken)}
      end)

    actions =
      Map.new(result, fn {id, name} ->
        w = Enum.find(workflows, &(&1.bubble_id == id))
        {id, %{"resource" => Map.fetch!(modules, w.folder || ""), "action" => name}}
      end)

    {result, %{names | "actions" => actions}}
  end

  defp locked_or_claim({module, name}, module, w, taken) do
    if MapSet.member?(taken, name) and name not in @reserved,
      do: claim(w, taken),
      else: {name, MapSet.put(taken, name)}
  end

  defp locked_or_claim(_locked, _module, w, taken), do: claim(w, taken)

  defp claim(w, taken) do
    base = Naming.base(:snake, w.name, w.bubble_id, "workflow")
    base = if base in @reserved, do: base <> "_workflow", else: base
    Naming.claim(base, taken, :snake, :none)
  end

  # --- actions ---------------------------------------------------------------------------

  defp action(%Workflow{} = w, modules, names, ctx) do
    module = "Workflows." <> Map.fetch!(modules, w.folder || "")
    {arguments, arg_residue} = arguments(w, ctx)
    params = Map.new(arguments, &{&1.param, &1})
    bctx = Map.merge(ctx, %{workflow: w, params: params})

    {condition, cond_residue} = compile(w.condition, w.id, bctx)
    steps = Enum.map(w.steps, &step(&1, bctx))

    authorize =
      cond do
        w.ignores_privacy? -> false
        w.inherits_privacy? -> :inherit
        true -> true
      end

    residue = Residue.sort(w.residue ++ arg_residue ++ cond_residue ++ dropped_trigger(w, ctx))

    %{
      workflow: w.bubble_id,
      symbol: w.id,
      name: Map.fetch!(names, w.bubble_id),
      bubble_name: w.name,
      kind: w.kind,
      module: module,
      folder: w.folder,
      arguments: arguments,
      returns: Enum.map(w.returns, &%{return: &1.id, name: &1.name}),
      authorize: authorize,
      exposed:
        if(w.exposed? and is_binary(w.name),
          do: %{
            endpoint: w.name,
            auth: w.auth,
            method: w.method,
            return_200?: w.return_200_if_not_run?
          }
        ),
      trigger: w.trigger_type,
      trigger_fields: trigger_fields(w, ctx.lookup),
      scheduled?: :scheduled in w.invocation_modes,
      cycle: w.cycle,
      condition: condition,
      steps: steps,
      residue: residue,
      diagnostics: target_diagnostics(w, residue, steps)
    }
  end

  defp target_diagnostics(w, residue, steps) do
    own = MapSet.new(Workflow.residue(w))

    for entry <- residue ++ Enum.flat_map(steps, & &1.residue),
        not MapSet.member?(own, entry) do
      Diagnostic.new(
        :workflow_residue,
        w.path || "",
        "#{entry.subject} is not lowered (#{entry.reason}); it is left for agent work",
        subject: %{workflow: w.bubble_id},
        details: %{
          subject: entry.subject,
          reason: Atom.to_string(entry.reason),
          detail: entry.detail
        }
      )
    end
  end

  # Arguments from the parameters, named from their keys (snake case).
  defp arguments(%Workflow{} = w, ctx) do
    {args, _} =
      Enum.map_reduce(w.parameters, MapSet.new(~w(id)), fn p, used ->
        base = Naming.base(:snake, p.key, p.id, "parameter")
        {name, used} = Naming.claim(base, used, :snake, :none)
        {argument(p, name, ctx), used}
      end)

    {args, []}
  end

  defp argument(param, name, ctx) do
    {type, _} = Type.classify(param.type)
    list? = type.cardinality == :many

    {kind, ash, resource} = argument_type(type, ctx)

    %{
      name: name,
      param: param.id,
      key: param.key,
      kind: kind,
      type: if(list?, do: {:array, ash}, else: ash),
      resource: resource,
      list?: list?,
      optional?: param.optional?,
      in_url?: param.in_url?
    }
  end

  defp argument_type(%Type{kind: :ref, target: target}, ctx) do
    case ctx.lookup.types[target] do
      %{module: module} -> {:record, :string, module}
      nil -> {:id, :string, nil}
    end
  end

  defp argument_type(%Type{kind: :option, target: set}, ctx) do
    case ctx.lookup.enums[set] do
      %{module: module} -> {:value, {:module, module}, nil}
      nil -> {:value, :string, nil}
    end
  end

  defp argument_type(%Type{kind: :scalar, base: :date}, _ctx),
    do: {:date, :utc_datetime_usec, nil}

  defp argument_type(%Type{kind: :scalar, base: base}, _ctx), do: {:value, scalar(base), nil}
  defp argument_type(%Type{kind: :file_ref}, _ctx), do: {:value, :string, nil}
  defp argument_type(_type, _ctx), do: {:value, :term, nil}

  defp scalar(:text), do: :string
  defp scalar(:number), do: :float
  defp scalar(:boolean), do: :boolean
  defp scalar(_), do: :term

  # --- steps -----------------------------------------------------------------------------

  # A database trigger on a data type an owner dropped can never fire:
  # residue, never a silently unwired trigger.
  defp dropped_trigger(%Workflow{kind: :database_trigger, trigger_type: type} = w, ctx)
       when is_binary(type) do
    if MapSet.member?(ctx.dropped.types, type),
      do: [Residue.entry(w.id, :uses_dropped, %{symbol: "data_type:" <> type})],
      else: []
  end

  defp dropped_trigger(_w, _ctx), do: []

  defp step(%Step{} = s, ctx) do
    base = %{
      index: s.index,
      bubble_id: s.bubble_id,
      symbol: s.id,
      type: s.type,
      op: s.op,
      condition: nil,
      args: %{},
      residue: s.residue
    }

    dropped = dropped_callee(s, ctx)

    cond do
      # A call or schedule of a workflow an owner dropped (WTF-422): the
      # step is residue, so the caller refuses to run before step 1.
      dropped != nil ->
        entry = Residue.entry(s.id, :uses_dropped, %{symbol: "workflow:" <> dropped})
        %{base | residue: Residue.sort([entry | s.residue])}

      s.residue != [] ->
        base

      true ->
        bound_step(s, base, ctx)
    end
  end

  defp dropped_callee(%Step{op: op, args: %{workflow: id}}, ctx)
       when op in [:call, :schedule, :schedule_list] and is_binary(id) do
    if MapSet.member?(ctx.dropped.workflows, id), do: id
  end

  defp dropped_callee(_s, _ctx), do: nil

  defp bound_step(s, base, ctx) do
    {condition, cr} = compile(s.condition, s.id, ctx)
    {args, ar} = step_args(s.op, s.args, s.id, ctx)
    %{base | condition: condition, args: args, residue: Residue.sort(cr ++ ar)}
  end

  defp step_args(op, args, id, ctx)
       when op in [:create, :update, :update_current_user, :update_list] do
    {target, tr} = compile(args[:target], id, ctx)

    case resource_of(args.data_type, ctx) do
      nil ->
        {%{}, [unmapped(id, "data_type") | tr]}

      resource ->
        {changes, cr} = changes(args.changes, resource, id, ctx)
        {%{resource: resource.module, target: target, changes: changes}, tr ++ cr}
    end
  end

  defp step_args(op, args, id, ctx) when op in [:delete, :delete_list] do
    {target, tr} = compile(args.target, id, ctx)

    case resource_of(args.data_type, ctx) do
      nil -> {%{}, [unmapped(id, "data_type") | tr]}
      resource -> {%{resource: resource.module, target: target}, tr}
    end
  end

  defp step_args(op, args, id, ctx) when op in [:schedule, :schedule_list] do
    {at, r1} = compile(args.at, id, ctx)
    {list, r2} = compile(args[:list], id, ctx)
    {interval, r3} = compile(args[:interval], id, ctx)
    {params, r4} = values(args.params, :param, id, ctx)

    {%{
       workflow: callee(args.workflow),
       at: at,
       list: list,
       interval: interval,
       params: params
     }, r1 ++ r2 ++ r3 ++ r4}
  end

  defp step_args(:call, args, id, ctx) do
    {params, residue} = values(args.params, :param, id, ctx)
    {%{workflow: callee(args.workflow), params: params}, residue}
  end

  defp step_args(:terminate, args, id, ctx) do
    {returns, residue} = values(args.returns, :return, id, ctx)
    {%{returns: returns}, residue}
  end

  defp step_args(:return, %{values: values}, id, ctx) do
    {compiled, residue} =
      Enum.map_reduce(values, [], fn v, acc ->
        {value, r} = compile(v.value, id, ctx)
        {%{key: v.key, list?: v.list?, value: value}, acc ++ r}
      end)

    {%{values: compiled}, residue}
  end

  defp step_args(:return, args, id, ctx) do
    {text, r1} = compile(args.text, id, ctx)
    {content_type, r2} = compile(args.content_type, id, ctx)
    {%{text: text, content_type: content_type}, r1 ++ r2}
  end

  defp callee(id), do: id

  defp values(entries, key, id, ctx) do
    Enum.map_reduce(entries, [], fn entry, acc ->
      {value, r} = compile(entry.value, id, ctx)
      {%{key => Map.fetch!(entry, key), value: value}, acc ++ r}
    end)
  end

  defp changes(changes, resource, id, ctx) do
    fields = ctx.lookup.types[resource.source.type].fields

    Enum.map_reduce(changes, [], fn %Change{} = c, acc ->
      {change, residue} = change(c, fields[c.field], resource, id, ctx)
      {change, acc ++ residue}
    end)
    |> then(fn {changes, residue} -> {Enum.reject(changes, &is_nil/1), Enum.uniq(residue)} end)
  end

  @list_ops [:add, :remove, :add_list, :remove_list, :set_list, :clear_list]

  defp change(c, %{attribute: attribute, references: refs}, resource, id, ctx)
       when is_binary(attribute) do
    if c.op in @list_ops and not list_attribute?(resource, attribute) do
      {nil, [Residue.entry(id, :unsupported_option, %{options: ["changes"]})]}
    else
      {value, residue} = compile(c.value, id, ctx)
      {%{attribute: attribute, op: c.op, value: value, ref: ref_kind(refs)}, residue}
    end
  end

  defp change(_c, _field, _resource, id, _ctx), do: {nil, [unmapped(id, "field")]}

  defp list_attribute?(%Resource{attributes: attributes}, name),
    do: Enum.any?(attributes, &(&1.name == name and match?({:array, _}, &1.type)))

  defp ref_kind(%{cardinality: :one}), do: :one
  defp ref_kind(%{cardinality: :many}), do: :many
  defp ref_kind(_), do: nil

  defp resource_of(nil, _ctx), do: nil

  defp resource_of(type, ctx),
    do: Enum.find(ctx.project.resources, &(&1.source.type == type))

  defp unmapped(id, what),
    do: Residue.entry(id, :unresolved_reference, %{reference: what, target: "ash"})

  # --- expressions ---------------------------------------------------------------------

  defp compile(nil, _id, _ctx), do: {nil, []}

  # Already residue of the lowering.
  defp compile(%Expr{ir: nil}, _id, _ctx), do: {nil, []}

  defp compile(%Expr{ir: ir, path: path}, id, ctx) do
    {:ok, result} =
      ElixirTarget.compile(ir, ctx.project,
        runtime: ctx.runtime,
        namespace: ctx.namespace,
        subject: %{workflow: ctx.workflow.bubble_id},
        path: path,
        utc: true
      )

    case result do
      %{source: nil, diagnostics: diags} ->
        constructs =
          diags
          |> Enum.flat_map(&Map.get(&1.details, :constructs, []))
          |> Enum.map(&("elixir:" <> &1))
          |> Enum.uniq()
          |> Enum.sort()

        {nil,
         [
           Residue.entry(id, :uncompiled_expression, %{
             expressions: 1,
             constructs: if(constructs == [], do: ["elixir:uncompiled"], else: constructs)
           })
         ]}

      %{source: source, bindings: bindings, loads: loads} ->
        case bind_all(bindings, loads, ctx) do
          {:ok, bound} ->
            {%{source: String.trim(source), bindings: bound}, []}

          {:error, constructs} ->
            {nil,
             [
               Residue.entry(id, :uncompiled_expression, %{
                 expressions: 1,
                 constructs: constructs
               })
             ]}
        end
    end
  end

  defp bind_all(bindings, loads, ctx) do
    {bound, failed} =
      Enum.reduce(bindings, {[], []}, fn b, {ok, failed} ->
        case bind(b.input, ctx) do
          {:ok, bind} ->
            {[%{var: b.var, bind: bind, loads: Map.get(loads, b.var, [])} | ok], failed}

          {:error, construct} ->
            {ok, [construct | failed]}
        end
      end)

    if failed == [],
      do: {:ok, Enum.sort_by(bound, & &1.var)},
      else: {:error, failed |> Enum.uniq() |> Enum.sort()}
  end

  defp bind(:current_user, _ctx), do: {:ok, :actor}

  defp bind({:parameter, ref}, ctx) do
    event = ref["event_id"]
    param = ref["param_id"] || ref["param_key"]

    cond do
      event not in [nil, ctx.workflow.bubble_id] -> {:error, "elixir:parameter_of_other_workflow"}
      Map.has_key?(ctx.params, param) -> {:ok, {:param, param}}
      true -> {:error, "elixir:unresolved_parameter"}
    end
  end

  defp bind({:step_result, %{"action" => action}}, _ctx), do: {:ok, {:step, action}}

  defp bind({:trigger_thing, %{"state" => state}}, ctx) when state in ["now", "before"] do
    if ctx.workflow.kind == :database_trigger,
      do: {:ok, {:trigger, if(state == "now", do: :now, else: :before)}},
      else: {:error, "elixir:trigger_outside_trigger"}
  end

  defp bind({:page_data, %{"name" => name}}, _ctx) do
    case @page_data[name] do
      nil -> {:error, "elixir:unbound_input:page_data"}
      bind -> {:ok, bind}
    end
  end

  defp bind({kind, _ref}, _ctx) when is_atom(kind),
    do: {:error, "elixir:unbound_input:#{kind}"}

  defp bind(_input, _ctx), do: {:error, "elixir:unbound_input"}

  # --- lookups -------------------------------------------------------------------------

  defp lookup(%Project{} = project) do
    types =
      Map.new(project.resources, fn resource ->
        rels =
          for r <- resource.relationships, r.kind == :belongs_to, into: %{} do
            {r.source.field, r.name}
          end

        fields =
          for a <- resource.attributes, a.source[:field], into: %{} do
            {a.source.field,
             %{
               attribute: a.name,
               relationship: Map.get(rels, a.source.field),
               references: a.references
             }}
          end

        {resource.source.type, %{module: resource.module, fields: fields}}
      end)

    %{types: types, enums: Map.new(project.enums, &{&1.source.option_set, &1})}
  end

  defp triggers(actions, lookup) do
    actions
    |> Enum.filter(&(&1.kind == :database_trigger and is_binary(&1.trigger)))
    |> Enum.group_by(& &1.trigger)
    |> Enum.flat_map(fn {type, actions} ->
      case lookup.types[type] do
        nil ->
          []

        %{module: module} ->
          [
            %{
              resource: module,
              data_type: type,
              workflows: actions |> Enum.map(& &1.workflow) |> Enum.sort(),
              fields: actions |> Enum.flat_map(& &1.trigger_fields) |> Enum.uniq() |> Enum.sort()
            }
          ]
      end
    end)
    |> Enum.sort_by(& &1.resource)
  end

  @sensitive ~r/password|hashed|token|secret|confirm/i

  # A trigger that reads the email or authentication data of a record puts
  # it in the job's arguments (oban_jobs), where it stays until pruned.
  defp sensitive_trigger_diagnostics(triggers, project) do
    for t <- triggers,
        resource = Enum.find(project.resources, &(&1.module == t.resource)),
        a <- resource.attributes,
        a.name in t.fields,
        a.source[:field] == "email" or Regex.match?(@sensitive, a.name) do
      Diagnostic.new(
        :workflow_trigger_sensitive_field,
        "",
        "a database trigger on #{t.data_type} reads #{a.name}, so its jobs carry it " <>
          "(oban_jobs.args) until they are pruned",
        target: :ash,
        subject: %{type: t.data_type},
        details: %{attribute: a.name, workflows: t.workflows}
      )
    end
  end

  # The attributes a database-trigger workflow reads from "Thing now" or
  # "Thing before change": the first field of every field chain rooted at
  # the trigger's record in its compiled condition and steps (a reference
  # is its ID attribute, which relationship loads go through). The job
  # snapshots only these and the primary key, not the whole record.
  defp trigger_fields(%Workflow{kind: :database_trigger} = w, lookup) do
    [w.condition | Enum.flat_map(w.steps, &[&1.condition | nested(&1.args)])]
    |> Enum.flat_map(fn
      %Expr{ir: %IR{} = ir} -> trigger_reads(ir)
      _ -> []
    end)
    |> Enum.flat_map(fn {type, field} ->
      case get_in(lookup, [:types, type, :fields, field]) do
        %{attribute: attribute} when is_binary(attribute) -> [attribute]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp trigger_fields(_w, _lookup), do: []

  defp nested(%Expr{} = e), do: [e]
  defp nested(%_{} = struct), do: struct |> Map.from_struct() |> nested()
  defp nested(map) when is_map(map), do: map |> Map.values() |> Enum.flat_map(&nested/1)
  defp nested(list) when is_list(list), do: Enum.flat_map(list, &nested/1)
  defp nested(_), do: []

  defp trigger_reads(%IR{
         op: :field,
         args: [%IR{op: :input, args: [:trigger_thing, _]}, type, field]
       }),
       do: [{type, field}]

  defp trigger_reads(%IR{args: args}), do: Enum.flat_map(args, &trigger_reads/1)
  defp trigger_reads(list) when is_list(list), do: Enum.flat_map(list, &trigger_reads/1)
  defp trigger_reads(_), do: []

  # The attributes Bubble sets on its own when a workflow creates or
  # changes a record: Created Date, Modified Date and Created By.
  defp stamps(%Project{resources: resources}) do
    Map.new(resources, fn r ->
      find = fn field ->
        Enum.find_value(r.attributes, &(&1.source[:field] == field && &1.name))
      end

      {r.module,
       %{
         created: find.("Created Date"),
         modified: find.("Modified Date"),
         creator: find.("Created By")
       }}
    end)
  end
end
