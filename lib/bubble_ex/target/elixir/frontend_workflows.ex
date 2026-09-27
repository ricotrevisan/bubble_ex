defmodule BubbleEx.Target.Elixir.FrontendWorkflows do
  @moduledoc """
  Binds lowered page and reusable-element workflows
  (`BubbleEx.Workflows.Frontend`) to Phoenix LiveView (WTF-372): function
  names, Elixir source for every value, where each value the workflows
  read comes from, and what this target cannot run yet, as plain data
  (`BubbleEx.Target.Elixir.FrontendWorkflows.Spec`) that
  `BubbleEx.Target.Phoenix` prints with the pages.

      {:ok, lowered} = BubbleEx.Workflows.Frontend.build(app, model, index)
      {:ok, spec} =
        BubbleEx.Target.Elixir.FrontendWorkflows.map(lowered, project,
          namespace: "Acme",
          frontend: normalized
        )

      {:ok, files} =
        BubbleEx.Target.Phoenix.render(project,
          frontend: normalized,
          expressions: compiled,
          frontend_workflows: spec
        )

  ## Values

  Values compile with `BubbleEx.Target.Elixir` against `project`; each
  free variable is bound to what the generated page keeps:

  | Bubble | kept as |
  |--------|---------|
  | Current user | the LiveView's `current_user` |
  | Current date/time | the time the workflow started |
  | a custom event's parameter | its argument |
  | Result of step N | the step's result |
  | an element's custom state | the page's state map, per reusable-element instance |
  | an input's value | the page's input map, per instance: the page tracks every `Input` and `MultiLineInput` of text or number, `Checkbox` and text `Dropdown` it renders (not in a runtime container's template) |
  | a URL parameter (`Get data from page URL`) | the page's URL query, as text |

  Anything else (a page's or a cell's thing, a group's data, an element's
  built-in states such as `is visible`, other page data) is
  `:unavailable_input` residue: the generated pages do not load or track
  it (T5's rule: a mount loads no data).

  ## Residue added here

    * `:uncompiled_expression` (constructs prefixed `elixir:`) - an IR with
      no Elixir mapping, or two inputs of a step sharing a variable name
    * `:unavailable_input` - a value the page does not provide (above), or
      an input-changed event on an input the page does not track
    * `:target_not_rendered`, `:trigger_not_normalized`,
      `:trigger_in_runtime_template` - an element to show, hide, focus,
      reset or call into, or the element an event listens to, that the
      generated page does not render
    * `:backend_workflow` - scheduling an API workflow without the
      `:backend` option (the backend workflows' spec, WTF-373)
    * `:unsupported_event` (`detail.target` `"phoenix"`) - popup opened or
      closed, user logged in or out: no wiring yet
    * `:unresolved_reference` (`detail.target` `"ash"`) - a data type or
      field the Ash project does not map
    * `:unsupported_option` - a list change on a field that is not a list

  ## Coverage

  `coverage/1` (`Spec.coverage/1`) measures generated code.
  """

  alias BubbleEx.{Diagnostic, Error}
  alias BubbleEx.Frontend.Normalized
  alias BubbleEx.Model.Type
  alias BubbleEx.Plan.Residue
  alias BubbleEx.Target.Ash.{Naming, Project, Resource}
  alias BubbleEx.Target.Ash.Workflows.Spec, as: BackendSpec
  alias BubbleEx.Target.Elixir, as: ElixirTarget
  alias BubbleEx.Target.Elixir.FrontendWorkflows.{Data, Spec}
  alias BubbleEx.Workflows.Frontend
  alias BubbleEx.Workflows.Frontend.{Step, Workflow}
  alias BubbleEx.Workflows.Lowering.{Change, Expr}

  @client_ops [:show, :hide, :toggle, :focus, :scroll_to]
  # Steps that read or write stored data (a schedule inserts a job).
  @data_ops [
    :create,
    :update,
    :update_current_user,
    :delete,
    :update_list,
    :delete_list,
    :schedule,
    :schedule_list
  ]

  # Input element types whose value the page tracks, by value type, with
  # the normalized kind that renders them natively.
  @inputs %{
    "Input" => {~w(text number), :input},
    "MultiLineInput" => {~w(text), :multiline_input},
    "Checkbox" => {~w(boolean), :checkbox},
    "Dropdown" => {~w(text), :dropdown}
  }

  # Bindings that make an input's first value dynamic: the page would not
  # know it until the input changes.
  @dynamic_slots ~w(value checked choices)

  @unwired_events [:popup_opened, :popup_closed, :logged_in, :logged_out]

  @doc """
  Binds `lowered` to `project` (`BubbleEx.Target.Ash.map/3` of the same
  Model).

  ## Options

    * `:namespace` - the root module (required: the Elixir source names
      the generated enum and runtime modules)
    * `:frontend` - the normalized frontend the pages render (required:
      what it does not render cannot be wired)
    * `:backend` - the app's backend workflows bound to Ash
      (`BubbleEx.Target.Ash.Workflows.Spec`, WTF-373): a page scheduling
      one of them schedules its job; without it, scheduling is
      `:backend_workflow` residue
    * `:page_data` - the page data (`BubbleEx.PageData`, WTF-420): the
      page loads its data sources (`BubbleEx.Target.Elixir.FrontendWorkflows.Data`)
      and its workflows read what it loads; without it, they are
      `:unavailable_input` residue
  """
  @spec map(Frontend.t(), Project.t(), keyword()) :: {:ok, Spec.t()} | {:error, Error.t()}
  def map(lowered, project, opts \\ [])

  def map(%Frontend{} = lowered, %Project{} = project, opts) when is_list(opts) do
    with {:ok, namespace} <- namespace(opts),
         {:ok, frontend} <- frontend(opts) do
      present = Residue.normalized_ids(frontend)
      templates = Residue.runtime_template_ids(frontend)
      nodes = native_nodes(frontend)

      elements =
        Map.new(lowered.elements, fn {id, e} ->
          {id,
           %{
             surface: bubble(e.surface),
             instance_of: e.instance_of,
             root?: e.kind in [:page, :reusable]
           }}
        end)

      kinds =
        for {id, %{kind: kind}} <- lowered.elements,
            kind in [:page, :reusable],
            into: %{},
            do: {id, kind}

      ctx = %{
        backend: backend_actions(Keyword.get(opts, :backend)),
        namespace: namespace,
        runtime: namespace <> ".Bubble.Runtime",
        project: project,
        lookup: lookup(project),
        elements: elements,
        raw_elements: lowered.elements,
        present: present,
        templates: templates,
        nodes: nodes,
        custom_events:
          for(
            w <- lowered.workflows,
            w.kind == :custom_event,
            into: %{},
            do: {w.bubble_id, %{surface: bubble(w.surface), params: w.parameters}}
          )
      }

      inputs = inputs(lowered.elements, ctx)
      ctx = Map.put(ctx, :inputs, inputs)
      {states, state_diags} = states(lowered.states, ctx)
      ctx = Map.put(ctx, :states, states)
      ctx = Map.put(ctx, :view, %Spec{elements: elements, surfaces: surfaces_view(ctx)})

      # The page's data (WTF-420): its sources are bound against every
      # source that lowered, then only what loads is read by the rest.
      page_data = Keyword.get(opts, :page_data)
      optimistic = Data.index(page_data)

      data =
        Data.bind(page_data, set_data(ctx, optimistic), %{
          compile: &compile/3,
          bind: &bind/2
        })

      ctx = set_data(ctx, Data.wired_index(data))

      bound =
        lowered.workflows
        |> Enum.group_by(&bubble(&1.surface))
        |> Map.new(fn {surface, ws} ->
          {surface, ws |> names() |> Enum.map(fn {w, fun} -> workflow(w, fun, surface, ctx) end)}
        end)
        |> block(ctx.backend)

      surfaces =
        Map.new(kinds, fn {id, kind} ->
          workflows = bound |> Map.get(id, []) |> Enum.sort_by(& &1.workflow)

          {id,
           %{
             kind: kind,
             workflows: Enum.map(workflows, &Map.delete(&1, :diagnostics)),
             states: Enum.filter(states, &(elements[&1.element].surface == id)),
             inputs: Map.get(inputs, id, %{}),
             data: Map.get(data, id, [])
           }}
        end)

      diagnostics =
        (lowered.diagnostics ++
           state_diags ++
           Enum.flat_map(Map.values(bound), &Enum.flat_map(&1, fn w -> w.diagnostics end)) ++
           data_diagnostics(data, page_data))
        |> Diagnostic.normalize()

      {:ok,
       %Spec{
         namespace: namespace,
         surfaces: surfaces,
         elements: elements,
         diagnostics: diagnostics,
         data_index: ctx.data
       }}
    end
  end

  def map(_lowered, _project, _opts),
    do:
      {:error,
       Error.new(
         :invalid_input,
         "expected a BubbleEx.Workflows.Frontend, a BubbleEx.Target.Ash.Project and options"
       )}

  @doc "Generated-code coverage. See `Spec.coverage/1`."
  defdelegate coverage(spec), to: Spec

  @doc "Generated-code coverage of the page data (WTF-420). See `Spec.data_coverage/1`."
  defdelegate data_coverage(spec), to: Spec

  @doc "Every residue entry of a spec, sorted. See `Spec.residue/1`."
  defdelegate residue(spec), to: Spec

  # --- options -------------------------------------------------------------------------

  # The backend workflows by Bubble ID, with whether each runs
  # (`BubbleEx.Target.Ash.Workflows.Spec.native?/1`), or nil.
  defp backend_actions(%BackendSpec{} = spec),
    do: spec |> BackendSpec.actions() |> Map.new(&{&1.workflow, BackendSpec.native?(&1)})

  defp backend_actions(_), do: nil

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

  defp frontend(opts) do
    case Keyword.get(opts, :frontend) do
      %Normalized{} = frontend -> {:ok, frontend}
      _ -> {:error, Error.new(:invalid_input, "the :frontend option (a Normalized) is required")}
    end
  end

  # --- names ---------------------------------------------------------------------------

  # A function per workflow, `wf_<name>` (snake case), claimed in Bubble ID
  # order within its surface's module.
  defp names(workflows) do
    {named, _} =
      workflows
      |> Enum.sort_by(& &1.bubble_id)
      |> Enum.map_reduce(MapSet.new(), fn w, used ->
        base = "wf_" <> Naming.base(:snake, w.name, w.bubble_id, "workflow")
        {name, used} = Naming.claim(base, used, :snake, :none)
        {{w, name}, used}
      end)

    named
  end

  # --- inputs and states -------------------------------------------------------------------

  # The inputs a page tracks: rendered natively (not a placeholder, not in
  # a runtime template), of a tracked value type, with a static first value.
  defp inputs(elements, ctx) do
    for {id, %{kind: :element, type: type, value: value, instance_of: nil} = e} <- elements,
        {values, kind} <- [Map.get(@inputs, type, {[], nil})],
        value in values,
        rendered?(id, ctx),
        native_input?(ctx.nodes[id], kind),
        reduce: %{} do
      acc ->
        Map.update(
          acc,
          bubble(e.surface),
          %{id => String.to_existing_atom(value)},
          &Map.put(&1, id, String.to_existing_atom(value))
        )
    end
  end

  # The states with their defaults as Elixir literals (a default that is not
  # a constant, or does not fit the state's type, starts empty and is
  # diagnosed).
  defp states(states, ctx) do
    {kept, diags} =
      Enum.map_reduce(states, [], fn s, diags ->
        case default(s, ctx) do
          {:ok, source} ->
            {%{element: s.element, state: s.state, default: source}, diags}

          :error ->
            diag =
              Diagnostic.new(
                :frontend_workflow_residue,
                "",
                "element:#{s.element} #{s.state}: its default value is not lowered " <>
                  "(unsupported_option); the state starts empty",
                details: %{
                  subject: "element:" <> s.element,
                  reason: "unsupported_option",
                  detail: %{options: ["default_val"]}
                }
              )

            {%{element: s.element, state: s.state, default: nil}, [diag | diags]}
        end
      end)

    {Enum.filter(kept, &Map.has_key?(ctx.elements, &1.element)), Enum.reverse(diags)}
  end

  defp default(%{default: nil}, _ctx), do: {:ok, nil}
  defp default(%{default: %Expr{ir: nil}}, _ctx), do: :error

  defp default(%{default: %Expr{ir: ir}, type: type}, ctx) do
    with true <- fits?(ir, type),
         {:ok, %{source: source, bindings: []}} when is_binary(source) <-
           ElixirTarget.compile(ir, ctx.project, runtime: ctx.runtime, namespace: ctx.namespace) do
      {:ok, String.trim(source)}
    else
      _ -> :error
    end
  end

  # A literal default must have its state's scalar type (Bubble keeps a
  # date or an option as text in the definition; neither is read here).
  defp fits?(%{op: :literal, args: [v]}, type) do
    case Type.classify(type) do
      {%Type{kind: :scalar, base: :text, cardinality: :one}, _} -> is_binary(v)
      {%Type{kind: :scalar, base: :number, cardinality: :one}, _} -> is_number(v)
      {%Type{kind: :scalar, base: :boolean, cardinality: :one}, _} -> is_boolean(v)
      _ -> false
    end
  end

  defp fits?(%{op: op}, _type), do: op in [:option, :empty]

  # --- workflows -------------------------------------------------------------------------

  defp workflow(%Workflow{} = w, fun, surface, ctx) do
    bctx = Map.merge(ctx, %{workflow: w, surface: surface, subject: w.id})

    {condition, cr} = compile(w.condition, w.id, bctx)
    {interval, ir} = compile(w.interval, w.id, bctx)
    steps = Enum.map(w.steps, &step(&1, bctx))

    residue =
      Residue.sort(
        Enum.uniq(
          w.residue ++ cr ++ ir ++ interval_residue(w, interval, ir) ++ event_residue(w, ctx)
        )
      )

    native? = residue == [] and Enum.all?(steps, &(&1.residue == []))
    client? = native? and client?(w, steps)

    # Reading the page's data (WTF-420) reads stored data too.
    data? =
      Enum.any?(steps, &(&1.op in @data_ops)) or
        Enum.any?(
          [condition, interval | Enum.flat_map(steps, &[&1.condition | Spec.step_values(&1)])],
          &(loads?(&1) or reads_data?(&1))
        )

    %{
      workflow: w.bubble_id,
      symbol: w.id,
      name: w.name,
      surface: surface,
      kind: w.kind,
      element: w.element,
      run_when: w.run_when,
      interval: interval,
      disabled?: w.disabled?,
      client?: client?,
      fun: fun,
      params: Enum.map(w.parameters, &%{param: &1.id, key: &1.key}),
      condition: condition,
      steps: steps,
      residue: residue,
      data?: data?,
      callees: callees(steps),
      diagnostics: diagnostics(w, residue, steps)
    }
  end

  # A workflow run in the browser: clicked, no condition, element steps only.
  defp client?(%Workflow{kind: :click, condition: nil, disabled?: false}, [_ | _] = steps),
    do: Enum.all?(steps, &(&1.op in @client_ops and &1.condition == nil))

  defp client?(_w, _steps), do: false

  # "Do every" needs a constant interval.
  defp interval_residue(%Workflow{kind: :do_every} = w, interval, []) do
    if interval == nil or interval.bindings != [],
      do: [Residue.entry(w.id, :unsupported_option, %{options: ["interval"]})],
      else: []
  end

  defp interval_residue(_w, _interval, _residue), do: []

  # --- blocking --------------------------------------------------------------------

  # As the backend binding (`BubbleEx.Target.Ash.Workflows`): a workflow
  # whose body has residue, or that calls or schedules one that does
  # (transitively, cycles included), must not run any step. `blocked_by`
  # lists why: its own residue subjects and the blocked (or unknown)
  # workflows it reaches directly, sorted. `data?` becomes transitive too:
  # a workflow runs only with data access when one it calls does.
  defp block(bound, backend) do
    all = bound |> Map.values() |> List.flatten()
    by_key = Map.new(all, &{{&1.surface, &1.workflow}, &1})
    own = for w <- all, own_residue(w) != [], into: MapSet.new(), do: {w.surface, w.workflow}
    blocked = fixpoint(own, all, by_key, backend)
    data = for w <- all, w.data?, into: MapSet.new(), do: key(w)
    data = data_fixpoint(data, all)

    Map.new(bound, fn {surface, ws} ->
      {surface,
       Enum.map(ws, fn w ->
         callees =
           for callee <- all_callees(w),
               callee_blocked?(callee, by_key, backend, blocked),
               do: callee_subject(callee)

         subjects = Enum.map(own_residue(w), & &1.subject)

         w
         |> Map.put(:data?, MapSet.member?(data, key(w)))
         |> Map.put(:blocked_by, Enum.sort(Enum.uniq(subjects ++ callees)))
       end)}
    end)
  end

  defp key(w), do: {w.surface, w.workflow}

  defp fixpoint(blocked, all, by_key, backend) do
    next =
      for w <- all,
          MapSet.member?(blocked, key(w)) or
            Enum.any?(all_callees(w), &callee_blocked?(&1, by_key, backend, blocked)),
          into: MapSet.new(),
          do: key(w)

    if next == blocked, do: blocked, else: fixpoint(next, all, by_key, backend)
  end

  defp data_fixpoint(data, all) do
    next =
      for w <- all,
          MapSet.member?(data, key(w)) or
            Enum.any?(w.callees, &MapSet.member?(data, {&1.surface, &1.workflow})),
          into: MapSet.new(),
          do: key(w)

    if next == data, do: data, else: data_fixpoint(next, all)
  end

  # Frontend callees (`%{surface, workflow}`) and scheduled backend
  # workflows (`{:backend, id}`).
  defp all_callees(w) do
    backend =
      for %{op: op, args: %{backend: id}} <- w.steps,
          op in [:schedule, :schedule_list],
          uniq: true,
          do: {:backend, id}

    w.callees ++ backend
  end

  defp callee_blocked?({:backend, id}, _by_key, backend, _blocked),
    do: Map.get(backend || %{}, id) != true

  defp callee_blocked?(%{surface: s, workflow: id}, by_key, _backend, blocked),
    do: not Map.has_key?(by_key, {s, id}) or MapSet.member?(blocked, {s, id})

  defp callee_subject({:backend, id}), do: "workflow:" <> id
  defp callee_subject(%{workflow: id}), do: "workflow:" <> id

  defp own_residue(w), do: w.residue ++ Enum.flat_map(w.steps, & &1.residue)

  defp event_residue(%Workflow{kind: kind} = w, _ctx) when kind in @unwired_events,
    do: [
      Residue.entry(w.id, :unsupported_event, %{type: w.event_type, target: "phoenix"})
    ]

  defp event_residue(%Workflow{kind: kind, element: element} = w, ctx)
       when kind in [:click, :input_change] and is_binary(element) do
    cond do
      not Map.has_key?(ctx.elements, element) ->
        []

      not MapSet.member?(ctx.present, element) and not ctx.elements[element].root? ->
        [Residue.entry(w.id, :trigger_not_normalized, %{element: "element:" <> element})]

      Map.has_key?(ctx.templates, element) ->
        [
          Residue.entry(w.id, :trigger_in_runtime_template, %{
            element: "element:" <> element,
            container: "element:" <> ctx.templates[element]
          })
        ]

      kind == :input_change and not tracked?(element, ctx) ->
        [Residue.entry(w.id, :unavailable_input, %{inputs: ["input_value"]})]

      true ->
        []
    end
  end

  defp event_residue(_w, _ctx), do: []

  defp tracked?(element, ctx) do
    case ctx.elements[element] do
      %{surface: surface} -> Map.has_key?(Map.get(ctx.inputs, surface, %{}), element)
      nil -> false
    end
  end

  defp diagnostics(w, residue, steps) do
    own = MapSet.new(Workflow.residue(w))

    for entry <- residue ++ Enum.flat_map(steps, & &1.residue),
        not MapSet.member?(own, entry) do
      Diagnostic.new(
        :frontend_workflow_residue,
        w.path || "",
        "#{entry.subject} is not lowered for Phoenix (#{entry.reason}); it is left for agent work",
        subject: %{workflow: w.bubble_id},
        details: %{
          subject: entry.subject,
          reason: Atom.to_string(entry.reason),
          detail: entry.detail
        }
      )
    end
  end

  defp callees(steps) do
    steps
    |> Enum.flat_map(fn
      %{op: op, args: %{callee: callee}} when op in [:call, :call_reusable, :schedule_custom] ->
        [callee]

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  # --- steps -------------------------------------------------------------------------------

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

    if s.residue != [] do
      base
    else
      {condition, cr} = compile(s.condition, s.id, ctx)
      {args, ar} = args(s.op, s.args, s.id, ctx)
      step = %{base | condition: condition, args: args}
      residue = Residue.sort(Enum.uniq(cr ++ ar ++ collisions(step)))
      %{step | residue: residue}
    end
  end

  # Two inputs a step reads must not share a variable name.
  defp collisions(step) do
    clashing =
      [step.condition | Spec.step_values(step)]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(& &1.bindings)
      |> Enum.group_by(& &1.var, & &1.bind)
      |> Enum.any?(fn {_var, binds} -> length(Enum.uniq(binds)) > 1 end)

    if clashing,
      do: [
        Residue.entry(step.symbol, :uncompiled_expression, %{
          expressions: 1,
          constructs: ["elixir:variable_collision"]
        })
      ],
      else: []
  end

  defp loads?(nil), do: false
  defp loads?(%{bindings: bindings}), do: Enum.any?(bindings, &(&1.loads != []))

  defp reads_data?(nil), do: false

  defp reads_data?(%{bindings: bindings}),
    do: Enum.any?(bindings, &match?({kind, _} when kind in [:data, :cell, :cell_data], &1.bind))

  defp args(op, %{element: element}, id, ctx)
       when op in [:show, :hide, :toggle, :focus, :scroll_to, :reset_group] do
    case target(element, ctx) do
      {:ok, target} -> {%{target: target}, []}
      {:error, entry} -> {%{}, [entry.(id)]}
    end
  end

  defp args(:reset_inputs, %{within: nil}, _id, _ctx), do: {%{within: nil}, []}

  defp args(:reset_inputs, %{within: within}, id, ctx) do
    case target(within, ctx) do
      {:ok, target} -> {%{within: target}, []}
      {:error, entry} -> {%{}, [entry.(id)]}
    end
  end

  defp args(:set_state, %{element: element, states: states}, id, ctx) do
    el = ctx.elements[element]

    {bound, residue} =
      Enum.map_reduce(states, [], fn %{state: state, value: value}, acc ->
        {compiled, r} = compile(value, id, ctx)
        {%{key: Spec.state_key(element, el, state), value: compiled}, acc ++ r}
      end)

    {%{states: bound}, residue}
  end

  defp args(:navigate, args, id, ctx) do
    {params, residue} =
      Enum.map_reduce(args.params, [], fn %{key: key, value: value}, acc ->
        {compiled, r} = compile(value, id, ctx)
        {%{key: key, value: compiled}, acc ++ r}
      end)

    {%{
       page: args.page,
       params: params,
       keep_params?: args.keep_params?,
       replace?: args.replace?,
       new_tab?: args.new_tab?
     }, residue}
  end

  defp args(:open_url, args, id, ctx) do
    {url, residue} = compile(args.url, id, ctx)
    {%{url: url, new_tab?: args.new_tab?}, residue}
  end

  defp args(op, _args, _id, _ctx) when op in [:refresh, :log_out], do: {%{}, []}

  defp args(:call, args, id, ctx) do
    {params, residue} = values(args.params, :param, id, ctx)
    {%{callee: %{surface: ctx.surface, workflow: args.workflow}, params: params}, residue}
  end

  defp args(:call_reusable, args, id, ctx) do
    {params, residue} = values(args.params, :param, id, ctx)

    case ctx.elements[args.element] do
      %{instance_of: definition} when is_binary(definition) ->
        rendered =
          if rendered?(args.element, ctx),
            do: [],
            else: [
              Residue.entry(id, :target_not_rendered, %{element: "element:" <> args.element})
            ]

        {%{
           instance: args.element,
           callee: %{surface: definition, workflow: args.workflow},
           params: params
         }, residue ++ rendered}

      _ ->
        {%{}, [Residue.entry(id, :unresolved_reference, %{reference: "element"}) | residue]}
    end
  end

  defp args(:schedule_custom, args, id, ctx) do
    {params, r1} = values(args.params, :param, id, ctx)
    {delay, r2} = compile(args.delay, id, ctx)

    {%{callee: %{surface: ctx.surface, workflow: args.workflow}, delay: delay, params: params},
     r1 ++ r2}
  end

  defp args(op, args, id, %{backend: nil}) when op in [:schedule, :schedule_list],
    do: {%{}, [Residue.entry(id, :backend_workflow, %{workflow: "workflow:" <> args.workflow})]}

  defp args(op, args, id, ctx) when op in [:schedule, :schedule_list] do
    if Map.has_key?(ctx.backend, args.workflow) do
      {at, r1} = compile(args.at, id, ctx)
      {list, r2} = compile(args[:list], id, ctx)
      {interval, r3} = compile(args[:interval], id, ctx)
      {params, r4} = values(args.params, :param, id, ctx)

      {%{backend: args.workflow, at: at, list: list, interval: interval, params: params},
       r1 ++ r2 ++ r3 ++ r4}
    else
      {%{}, [Residue.entry(id, :unresolved_reference, %{reference: "workflow", target: "ash"})]}
    end
  end

  defp args(:terminate, args, id, ctx) do
    {returns, residue} = values(args.returns, :return, id, ctx)
    {%{returns: returns}, residue}
  end

  defp args(op, args, id, ctx) when op in [:create, :update, :update_list] do
    {target, tr} = compile(args[:target], id, ctx)

    case resource_of(args.data_type, ctx) do
      nil ->
        {%{}, [unmapped(id, "data_type") | tr]}

      resource ->
        {changes, cr} = changes(args.changes, resource, id, ctx)
        {Map.merge(resource_args(resource), %{target: target, changes: changes}), tr ++ cr}
    end
  end

  defp args(:update_current_user, args, id, ctx) do
    case Enum.find(ctx.project.resources, &(&1.source.type == "user")) do
      nil ->
        {%{}, [unmapped(id, "data_type")]}

      resource ->
        {changes, cr} = changes(args.changes, resource, id, ctx)
        {Map.merge(resource_args(resource), %{target: nil, changes: changes}), cr}
    end
  end

  defp args(op, args, id, ctx) when op in [:delete, :delete_list] do
    {target, tr} = compile(args.target, id, ctx)

    case resource_of(args.data_type, ctx) do
      nil -> {%{}, [unmapped(id, "data_type") | tr]}
      resource -> {Map.put(resource_args(resource), :target, target), tr}
    end
  end

  defp values(entries, key, id, ctx) do
    Enum.map_reduce(entries, [], fn entry, acc ->
      {value, r} = compile(entry.value, id, ctx)
      {%{key => Map.fetch!(entry, key), value: value}, acc ++ r}
    end)
  end

  # --- elements --------------------------------------------------------------------------

  # A target relative to the workflow's surface: its own element, an
  # instance's root, or the reusable element's own root.
  defp target(element, ctx) do
    case element && ctx.elements[element] do
      %{surface: surface} = el when surface == ctx.surface -> own_target(element, el, ctx)
      _ -> {:error, &Residue.entry(&1, :unresolved_reference, %{reference: "element"})}
    end
  end

  # The reusable element's own root (a page is no target).
  defp own_target(element, %{root?: true}, ctx) do
    if element == ctx.surface and Map.get(ctx.raw_elements[element] || %{}, :kind) == :reusable,
      do: {:ok, %{path: [], element: :root}},
      else: {:error, &Residue.entry(&1, :unresolved_reference, %{reference: "element"})}
  end

  defp own_target(element, el, ctx) do
    cond do
      not rendered?(element, ctx) ->
        {:error, &Residue.entry(&1, :target_not_rendered, %{element: "element:" <> element})}

      is_binary(el.instance_of) ->
        {:ok, %{path: [element], element: :root}}

      true ->
        {:ok, %{path: [], element: element}}
    end
  end

  defp native_input?(%Normalized.Node{kind: kind, placeholder?: false} = node, kind),
    do: not Enum.any?(@dynamic_slots, &Map.has_key?(node.bindings || %{}, &1))

  defp native_input?(_node, _kind), do: false

  # Every normalized node with a Bubble ID.
  defp native_nodes(%Normalized{} = frontend) do
    (frontend.pages ++ frontend.reusables)
    |> Enum.flat_map(&all_nodes/1)
    |> Enum.filter(&(&1.source && is_binary(&1.source.bubble_id)))
    |> Map.new(&{&1.source.bubble_id, &1})
  end

  defp all_nodes(%Normalized.Node{} = node),
    do: [node | Enum.flat_map(node.children, &all_nodes/1)]

  defp rendered?(element, ctx),
    do: MapSet.member?(ctx.present, element) and not Map.has_key?(ctx.templates, element)

  # --- data ------------------------------------------------------------------------------

  defp resource_args(%Resource{} = r), do: %{resource: r.module}

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
  defp resource_of(type, ctx), do: Enum.find(ctx.project.resources, &(&1.source.type == type))

  defp unmapped(id, what),
    do: Residue.entry(id, :unresolved_reference, %{reference: what, target: "ash"})

  defp lookup(%Project{} = project) do
    types =
      Map.new(project.resources, fn resource ->
        fields =
          for a <- resource.attributes, a.source[:field], into: %{} do
            {a.source.field, %{attribute: a.name, references: a.references}}
          end

        {resource.source.type, %{module: resource.module, fields: fields}}
      end)

    %{types: types}
  end

  # --- expressions -----------------------------------------------------------------------

  defp compile(nil, _id, _ctx), do: {nil, []}
  # Already residue of the lowering.
  defp compile(%Expr{ir: nil}, _id, _ctx), do: {nil, []}

  defp compile(%Expr{ir: ir, path: path}, id, ctx) do
    {:ok, result} =
      ElixirTarget.compile(ir, ctx.project,
        runtime: ctx.runtime,
        namespace: ctx.namespace,
        subject: if(ctx.workflow.bubble_id, do: %{workflow: ctx.workflow.bubble_id}, else: %{}),
        path: path
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

          {:error, inputs} ->
            {nil, [Residue.entry(id, :unavailable_input, %{inputs: inputs})]}
        end
    end
  end

  defp bind_all(bindings, loads, ctx) do
    {bound, failed} =
      Enum.reduce(bindings, {[], []}, fn b, {ok, failed} ->
        case bind(b.input, ctx) do
          {:ok, bind} ->
            {[%{var: b.var, bind: bind, loads: Map.get(loads, b.var, [])} | ok], failed}

          {:error, what} ->
            {ok, [what | failed]}
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
      event not in [nil, ctx.workflow.bubble_id] -> {:error, "parameter_of_other_workflow"}
      Enum.any?(ctx.workflow.parameters, &(&1.id == param)) -> {:ok, {:param, param}}
      true -> {:error, "unresolved_parameter"}
    end
  end

  defp bind({:step_result, %{"action" => action}}, _ctx), do: {:ok, {:step, action}}

  defp bind({:url_parameter, %{"name" => name}}, _ctx) when is_binary(name),
    do: {:ok, {:url, name}}

  defp bind({:page_data, %{"name" => "Current Date/Time"}}, _ctx), do: {:ok, :now}

  # The page's data (WTF-420): a page's or cell's thing, a group's data, a
  # repeating group's list.
  defp bind({:element_state, %{"state" => s}} = input, ctx)
       when s in ["get_group_data", "get_list_data"],
       do: Data.read(ctx.data, ctx.surface, Map.get(ctx, :cell), input)

  defp bind({kind, _ref} = input, ctx) when kind in [:page_thing, :cell_thing, :cell_index],
    do: Data.read(ctx.data, ctx.surface, Map.get(ctx, :cell), input)

  defp bind({:element_state, %{"element" => e, "state" => s}} = input, ctx)
       when is_binary(e) and is_binary(s) do
    case Spec.read(ctx.view, ctx.surface, input) do
      {kind, key} -> {:ok, {kind, key}}
      nil -> {:error, element_state_kind(s)}
    end
  end

  defp bind({kind, _ref}, _ctx) when is_atom(kind), do: {:error, Atom.to_string(kind)}
  defp bind(_input, _ctx), do: {:error, "unknown"}

  # Built-in element state names are Bubble's (no app IDs); a custom state
  # or a reusable element's parameter carries one, so it is named by kind.
  defp element_state_kind("custom." <> _), do: "element_state:custom"
  defp element_state_kind("param_" <> _), do: "element_state:param"

  defp element_state_kind(state) do
    if Regex.match?(~r/\A[a-z_]+\z/, state),
      do: "element_state:" <> state,
      else: "element_state"
  end

  defp set_data(ctx, index),
    do: ctx |> Map.put(:data, index) |> Map.update!(:view, &%{&1 | data_index: index})

  # A diagnostic per residue entry the binding added to a data source (the
  # lowering's have theirs).
  defp data_diagnostics(data, page_data) do
    own =
      case page_data do
        %{sources: sources} -> MapSet.new(Enum.flat_map(sources, & &1.residue))
        _ -> MapSet.new()
      end

    for {_surface, sources} <- data,
        source <- sources,
        entry <- source.residue,
        not MapSet.member?(own, entry) do
      Diagnostic.new(
        :page_data_residue,
        "",
        "#{entry.subject}'s data source is not lowered for Phoenix (#{entry.reason}); " <>
          "the page does not load it",
        details: %{
          subject: entry.subject,
          reason: Atom.to_string(entry.reason),
          detail: entry.detail
        }
      )
    end
  end

  defp surfaces_view(ctx) do
    states = Enum.group_by(ctx.states, &ctx.elements[&1.element].surface)
    ids = ctx.elements |> Map.values() |> Enum.map(& &1.surface) |> Enum.uniq()

    Map.new(ids, fn id ->
      {id, %{states: Map.get(states, id, []), inputs: Map.get(ctx.inputs, id, %{})}}
    end)
  end

  defp bubble(symbol_id),
    do:
      symbol_id
      |> String.split(":", parts: 2)
      |> List.last()
      |> String.replace("~1", "/")
      |> String.replace("~0", "~")
end
