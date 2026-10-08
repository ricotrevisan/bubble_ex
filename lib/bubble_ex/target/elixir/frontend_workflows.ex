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
  | a URL parameter (`Get data from page URL`) | the page's URL query, read as its type (`Spec.url/1`); a thing by its unique ID, through Ash as the current user |
  | the URL's path (`path`, `path segments`) | the page's URL path, its first segment the page's name |

  With `:page_data`, a page's thing, a group's, instance's or repeating
  group's data and a cell's thing are what the page loads; an element a
  "Display data" / "Display list" step sets (WTF-492) holds what the step
  showed, re-read as the current user. Anything else (an element's
  built-in states such as `is visible`, other page data) is
  `:unavailable_input` residue: the generated pages do not load or track
  it.

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
    * `:page_data_in_cell` (`detail.kind` `"display"`, `"list"`,
      `"instance"`) - a "Display data" step into a repeating group's cell
      from outside it, or a list or an instance there (a reusable instance
      in a cell is otherwise rendered per cell, WTF-494: `Spec.cells`)

  ## Coverage

  `coverage/1` (`Spec.coverage/1`) measures generated code.
  """

  alias BubbleEx.{Diagnostic, Error}
  alias BubbleEx.Expression.Tree
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

  @display_ops [:display_data, :display_list]

  # Events that never fire as the page loads (WTF-520). Anything else may
  # (a page load, a condition, a plugin's event, a popup opened or closed,
  # a user logged in or out: the conservative reading).
  @event_kinds [:click, :input_change, :do_every]

  # Elements holding data that "Display data" or "Display list" sets.
  @never_holders ~w(Group Popup FloatingGroup GroupFocus RepeatingGroup)
  @group_holders ~w(Group Popup FloatingGroup GroupFocus CustomElement)

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
      dropped = Project.dropped(project)
      lowered = without_dropped(lowered, dropped)
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
        dropped: dropped,
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

      {states, state_diags} = states(lowered.states, ctx)
      ctx = Map.put(ctx, :states, states)

      # Reusable instances in repeating group cells (WTF-494), and the
      # reusable elements each reusable element nests outside its cells.
      {in_cells, nested} = cell_structure(lowered.elements, ctx)

      ctx =
        ctx
        |> Map.put(:nested, nested)
        |> Map.put(:in_cells, in_cells)
        |> Map.put(:once, once_instances(in_cells, ctx))

      # The page's data (WTF-420): its sources are bound against every
      # source that lowered, then only what loads is read by the rest.
      page_data = Keyword.get(opts, :page_data)

      # The inputs whose first value is page data (WTF-520): tracked when
      # their initial content loads. What "Display data" steps show
      # (WTF-492): the elements they set, held as page data (with no
      # source of their own, read from what the step showed), and those no
      # step sets (WTF-520). One a step may set as the page loads only when
      # every workflow that may do so runs whole (`kept?/4`): the others
      # stay unloaded, loudly.
      {ctx, data, bound} =
        bind_with_inputs(initial_inputs(page_data, ctx), lowered, page_data, ctx)

      inputs = ctx.inputs

      surfaces =
        Map.new(kinds, fn {id, kind} ->
          workflows = bound |> Map.get(id, []) |> Enum.sort_by(& &1.workflow)

          {id,
           %{
             kind: kind,
             workflows: Enum.map(workflows, &Map.delete(&1, :diagnostics)),
             states: Enum.filter(states, &(elements[&1.element].surface == id)),
             inputs: Map.get(inputs, id, %{}),
             initial: ctx.initial |> Enum.filter(&(elements[&1].surface == id)) |> Enum.sort(),
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
         data_index: ctx.data,
         cells: Data.cell_instances(in_cells, data, ctx.data, nested)
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

  # Binds the page data and the workflows with the inputs `initial` (whose
  # first value is page data, WTF-520) tracked, until the initial content
  # of every one of them loads: an input whose initial content does not
  # load is not tracked (as before), and its source is left out.
  defp bind_with_inputs(initial, lowered, page_data, base) do
    ctx =
      base
      |> Map.put(:initial, initial)
      |> Map.put(:inputs, inputs(lowered.elements, base, initial))

    ctx = Map.put(ctx, :view, %Spec{elements: ctx.elements, surfaces: surfaces_view(ctx)})

    {ctx, data, bound} =
      bind_data_and_workflows(
        displayed(lowered.workflows, own_elements(page_data), ctx),
        lowered,
        with_inputs(page_data, initial),
        ctx
      )

    loaded =
      for {_surface, sources} <- data,
          %{kind: :input, residue: []} = d <- sources,
          into: MapSet.new(),
          do: d.element

    kept = MapSet.intersection(initial, loaded)

    if kept == initial,
      do: {ctx, data, bound},
      else: bind_with_inputs(kept, lowered, page_data, base)
  end

  # The elements with a data source of their own, or nil without page data.
  defp own_elements(nil), do: nil

  defp own_elements(page_data),
    do: for(s <- page_data.sources, s.kind != :param, into: MapSet.new(), do: s.element)

  # The page data with the initial contents of the inputs `initial` only.
  defp with_inputs(nil, _initial), do: nil

  defp with_inputs(page_data, initial) do
    sources =
      Enum.reject(page_data.sources, fn s ->
        s.kind == :input and not MapSet.member?(initial, s.element)
      end)

    %{page_data | sources: sources}
  end

  # The inputs a page could track with page data as their first value: an
  # input rendered natively whose only dynamic part is its initial content,
  # which lowered (`BubbleEx.PageData`'s `:input` sources).
  defp initial_inputs(nil, _ctx), do: MapSet.new()

  defp initial_inputs(page_data, ctx) do
    for %{kind: :input, element: id, residue: []} <- page_data.sources,
        %{kind: :element, type: type, value: value, instance_of: nil} <- [
          ctx.raw_elements[id]
        ],
        {values, kind} <- [Map.get(@inputs, type, {[], nil})],
        value in values,
        rendered?(id, ctx),
        initial_input?(ctx.nodes[id], kind),
        into: MapSet.new(),
        do: id
  end

  # Binds the page data and the workflows with the elements `displayed`
  # holds, until the page keeps every one of them faithfully (`kept?/4`).
  defp bind_data_and_workflows(displayed, lowered, page_data, ctx) do
    ctx = Map.put(ctx, :displayed, displayed)

    data =
      Data.bind(page_data, set_data(ctx, Data.index(page_data, displayed)), %{
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

    all = for {_surface, ws} <- bound, w <- ws, into: %{}, do: {w.symbol, w}
    runs = Map.filter(all, fn {_symbol, w} -> Spec.native?(w) and not w.disabled? end)

    shown =
      for w <- Map.values(runs),
          %{op: op, residue: []} = step <- w.steps,
          op in @display_ops,
          into: MapSet.new(),
          do: step_element(step, w)

    kept =
      Map.filter(displayed, fn {element, holder} ->
        kept?(element, holder, %{all: all, runs: runs}, shown)
      end)

    if map_size(kept) == map_size(displayed),
      do: {ctx, data, bound},
      else: bind_data_and_workflows(kept, lowered, page_data, ctx)
  end

  # Whether the page keeps what display steps show in an element
  # faithfully (WTF-520). In a repeating group's cell, when a step that
  # runs sets it (WTF-492). Elsewhere, by the workflows that may start
  # each step (`roots`, `start_roots/1`): every one that may run as the
  # page loads (a page-load or condition-true workflow, a popup opened or
  # closed, a plugin's or another event this target does not lower, or
  # the callers of the custom event holding the step) runs whole and is
  # triggered; every event-driven one (a click, an input change, a "do
  # every" tick) is triggered, whether the runtime then runs it or
  # refuses it with a notice. Before an event the element shows nothing,
  # as in Bubble; an event the page never triggers (a click in a
  # repeating group's cell, not wired yet) would leave it empty where
  # Bubble shows data, so it is not kept. No step at all: empty, kept.
  defp kept?(element, %{cell: cell}, _workflows, shown) when is_binary(cell),
    do: MapSet.member?(shown, element)

  defp kept?(_element, %{roots: roots}, %{all: all, runs: runs}, _shown) do
    Enum.all?(roots, fn
      {:load, symbol} -> wired?(runs[symbol])
      {:event, symbol} -> wired?(all[symbol])
    end)
  end

  defp wired?(nil), do: false
  defp wired?(w), do: Spec.wired?(w)

  # The reusable instances in a repeating group's cell of their surface
  # (instance => `%{surface, cell, holder}`), and for each reusable element
  # the reusable elements of its instances outside its cells.
  defp cell_structure(elements, ctx) do
    instances =
      for {id, %{kind: :element, instance_of: holder} = e} <- elements,
          is_binary(holder),
          do: {id, bubble(e.surface), holder, cell_of(e, ctx, 0)}

    in_cells =
      for {id, surface, holder, rg} <- instances,
          rg != nil,
          into: %{},
          do: {id, %{surface: surface, cell: rg, holder: holder}}

    nested =
      for {_id, surface, holder, nil} <- instances,
          reduce: %{} do
        acc -> Map.update(acc, surface, [holder], &Enum.uniq([holder | &1]))
      end

    {in_cells, Map.new(nested, fn {k, v} -> {k, Enum.sort(v)} end)}
  end

  # The reusable instances each rendered once, in one scope (WTF-520): not
  # in a repeating group's cell nor another runtime template. Instance =>
  # `%{surface, holder}`; their properties' defaults may be read from
  # outside them by the page's data (`Spec.data_read/4`).
  defp once_instances(in_cells, ctx) do
    for {id, %{kind: :element, instance_of: holder} = e} <- ctx.raw_elements,
        is_binary(holder),
        not Map.has_key?(in_cells, id),
        rendered?(id, ctx),
        into: %{},
        do: {id, %{surface: bubble(e.surface), holder: holder}}
  end

  # The element a bound display step sets: the instance for an instance's
  # thing.
  defp step_element(%{args: %{key: %{path: [instance]}}}, _w), do: instance
  defp step_element(%{args: %{key: %{element: element}}}, _w), do: element

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
  # a runtime template), of a tracked value type, with a static first value
  # or (`initial`, WTF-520) one the page's data gives.
  defp inputs(elements, ctx, initial) do
    for {id, %{kind: :element, type: type, value: value, instance_of: nil} = e} <- elements,
        {values, kind} <- [Map.get(@inputs, type, {[], nil})],
        value in values,
        rendered?(id, ctx),
        native_input?(ctx.nodes[id], kind) or MapSet.member?(initial, id),
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

    dropped = dropped_target(s, ctx.dropped)

    cond do
      # A step calling, scheduling or navigating to what an owner dropped
      # (WTF-422): residue, so the workflow refuses to run before step 1.
      dropped != nil ->
        entry = Residue.entry(s.id, :uses_dropped, %{symbol: dropped})
        %{base | residue: Residue.sort([entry | s.residue])}

      s.residue != [] ->
        base

      true ->
        bound_step(s, base, ctx)
    end
  end

  defp dropped_target(%Step{op: :navigate, args: %{page: page}}, dropped) when is_binary(page),
    do: if(MapSet.member?(dropped.pages, page), do: "page:" <> page)

  defp dropped_target(%Step{op: op, args: %{workflow: w}}, dropped)
       when op in [:call, :call_reusable, :schedule_custom, :schedule, :schedule_list] and
              is_binary(w),
       do: if(MapSet.member?(dropped.workflows, w), do: "workflow:" <> w)

  defp dropped_target(_step, _dropped), do: nil

  # The page workflows, elements and element states the owner's drops
  # remove (WTF-422): a dropped page's, and every dropped workflow.
  defp without_dropped(lowered, %{pages: pages, workflows: workflows}) do
    if MapSet.size(pages) == 0 and MapSet.size(workflows) == 0 do
      lowered
    else
      page? = fn surface -> MapSet.member?(pages, bubble(surface)) end

      elements = Map.reject(lowered.elements, fn {_id, e} -> page?.(e.surface) end)

      %{
        lowered
        | workflows:
            Enum.reject(
              lowered.workflows,
              &(page?.(&1.surface) or MapSet.member?(workflows, &1.bubble_id))
            ),
          elements: elements,
          states: Enum.filter(lowered.states, &Map.has_key?(elements, &1.element))
      }
    end
  end

  defp bound_step(s, base, ctx) do
    {condition, cr} = compile(s.condition, s.id, ctx)
    {args, ar} = args(s.op, s.args, s.id, ctx)
    step = %{base | condition: condition, args: args}
    residue = Residue.sort(Enum.uniq(cr ++ ar ++ collisions(step)))
    %{step | residue: residue}
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
       when op in [:show, :hide, :toggle, :focus, :scroll_to] do
    case target(element, ctx) do
      {:ok, target} -> {%{target: target}, []}
      {:error, entry} -> {%{}, [entry.(id)]}
    end
  end

  # "Display data" / "Display list" (WTF-492): what the element shows,
  # kept by the page per instance (and cell) and re-read as the current
  # user whenever the page reads its data, never shown as the workflow
  # read it.
  defp args(op, %{element: element} = args, id, ctx) when op in @display_ops do
    case display_holder(op, args, ctx.workflow, ctx.surface, ctx) do
      {:ok, holder} ->
        {value, residue} = compile(args.value, id, ctx)
        resource = Data.resource_of_type(holder.type, ctx)

        unmapped =
          if resource == nil and data_type?(holder.type),
            do: [unmapped(id, "data_type")],
            else: []

        key =
          if holder.kind == :instance,
            do: %{path: [element], element: holder.holder},
            else: %{path: [], element: element}

        {%{
           key: key,
           cell?: holder.cell != nil,
           list?: op == :display_list,
           page_size: holder.page_size,
           resource: resource,
           value: value
         }, residue ++ unmapped}

      {:error, entry} ->
        {%{}, [entry.(id)]}
    end
  end

  defp args(:reset_group, %{element: element}, id, ctx) do
    case target(element, ctx) do
      {:ok, target} -> {%{target: target, clears: clears(element, target, ctx)}, []}
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

    {thing, thing_residue} = navigate_thing(args, id, ctx)

    {%{
       page: args.page,
       params: params,
       thing: thing,
       untyped?: Map.get(args, :untyped?, false),
       keep_params?: args.keep_params?,
       replace?: args.replace?,
       new_tab?: args.new_tab?
     }, residue ++ thing_residue}
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

  defp args(:pause, args, id, ctx) do
    {length, residue} = compile(args.length, id, ctx)
    {%{length: length}, residue}
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

  # The data sent to a page (WTF-378): the path segment after the page's
  # own (every page's route takes one, `/index/:bubble_thing` for the
  # index page). To a page with a type of content it is bound only when
  # the page loads its thing; otherwise the step is residue. To a page
  # with none (`untyped?`, WTF-466) Bubble appends it all the same, and the
  # page ignores it. The current page (WTF-454) is a page workflow's own
  # page; a reusable element's is known at run time only, where the
  # runtime decides.
  defp navigate_thing(%{thing: nil}, _id, _ctx), do: {nil, []}
  defp navigate_thing(%{thing: thing, untyped?: true}, id, ctx), do: compile(thing, id, ctx)

  defp navigate_thing(%{thing: thing, page: :current}, id, ctx) do
    case ctx.raw_elements[ctx.surface] do
      %{kind: :page} -> navigate_thing(%{thing: thing, page: ctx.surface}, id, ctx)
      _ -> compile(thing, id, ctx)
    end
  end

  defp navigate_thing(%{thing: thing, page: page}, id, ctx) do
    case ctx.data.elements[page] do
      %{kind: :page_thing} -> compile(thing, id, ctx)
      _ -> {nil, [Residue.entry(id, :unsupported_option, %{options: ["data_to_send"]})]}
    end
  end

  defp navigate_thing(_args, _id, _ctx), do: {nil, []}

  defp values(entries, key, id, ctx) do
    Enum.map_reduce(entries, [], fn entry, acc ->
      {value, r} = compile(entry.value, id, ctx)
      {%{key => Map.fetch!(entry, key), value: value}, acc ++ r}
    end)
  end

  # --- displayed data (WTF-492) ------------------------------------------------------------

  # The elements "Display data" steps set, by Bubble ID: `%{kind, surface,
  # cell, holder, type, page_size, roots}` (page data holders, see
  # `Data.index/2`; `roots`, the workflows that may start the steps, see
  # `kept?/4`). Only an element the page renders that holds that kind of
  # data. With page data (`own`, the elements with a source of their own,
  # a conditional one included: `BubbleEx.PageData`), also the elements
  # no step sets, which show nothing (WTF-520): a group, popup, floating
  # group, group focus or repeating group with a type of content and no
  # data source, outside a repeating group's cell.
  defp displayed(workflows, own, ctx) do
    starts = start_roots(workflows)

    steps =
      for w <- workflows,
          not w.disabled?,
          %Step{op: op, args: %{element: element}} = step <- w.steps,
          op in @display_ops,
          is_binary(element),
          do: {element, w, step}

    set =
      steps
      |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))
      |> Enum.reduce(%{}, fn {element, ws}, acc ->
        case shown_holder(element, ws, starts, ctx) do
          {:ok, holder} -> Map.put(acc, element, holder)
          :error -> acc
        end
      end)

    if own == nil,
      do: set,
      else: Map.merge(never_shown(steps, own, ctx), set)
  end

  # The holder of an element display steps set: in a repeating group's
  # cell, from the steps that lowered (WTF-492); elsewhere from any step,
  # with the workflows that may run it as the page loads.
  defp shown_holder(element, ws, starts, ctx) do
    holders =
      for {w, %Step{op: op, args: args} = step} <- ws,
          display_target?(op, element, bubble(w.surface), ctx),
          {:ok, holder} <- [display_holder(op, args, w, bubble(w.surface), ctx)],
          do: {holder, step, w}

    case holders do
      [] ->
        :error

      [{%{cell: cell}, _, _} | _] when is_binary(cell) ->
        lowered_holder(holders)

      [{holder, _, _} | _] ->
        roots =
          holders
          |> Enum.flat_map(fn {_, _, w} -> Map.get(starts, w.bubble_id, []) end)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, Map.put(holder, :roots, roots)}
    end
  end

  defp lowered_holder(holders) do
    case for({holder, %Step{residue: []}, _w} <- holders, do: holder) do
      [holder | _] -> {:ok, Map.put(holder, :roots, [])}
      [] -> :error
    end
  end

  # Whether a display step's element holds that kind of data (a step
  # naming another element sets nothing).
  defp display_target?(:display_list, element, _surface, ctx),
    do: match?(%{type: "RepeatingGroup"}, ctx.raw_elements[element])

  defp display_target?(:display_data, surface, surface, _ctx), do: true

  defp display_target?(:display_data, element, _surface, ctx),
    do: match?(%{type: type} when type in @group_holders, ctx.raw_elements[element])

  # Elements that hold data no step ever sets: they show nothing.
  defp never_shown(steps, own, ctx) do
    stepped = MapSet.new(steps, &elem(&1, 0))

    for {id, %{kind: :element, type: type, content: content} = raw} <- ctx.raw_elements,
        type in @never_holders,
        is_binary(content) and content != "",
        not MapSet.member?(stepped, id),
        not MapSet.member?(own, id),
        %{surface: surface, instance_of: nil} = el <- [ctx.elements[id]],
        cell_of(raw, ctx, 0) == nil,
        rendered?(id, ctx),
        op = if(type == "RepeatingGroup", do: :display_list, else: :display_data),
        into: %{},
        do: {id, Map.put(holder(op, id, el, raw, surface, nil, ctx), :roots, [])}
  end

  # For each workflow (Bubble ID), the workflows that may start it:
  # `{:event, symbol}` for a click, an input change or a "do every" tick,
  # `{:load, symbol}` for any other event (it may fire as the page loads);
  # for a custom event, those of every workflow calling or scheduling it
  # (none when nothing does, or only itself through a cycle). Disabled
  # workflows never run.
  defp start_roots(workflows) do
    by_id = Map.new(workflows, &{&1.bubble_id, &1})

    callers =
      for w <- workflows,
          not w.disabled?,
          %Step{op: op, args: %{workflow: callee}} <- w.steps,
          op in [:call, :call_reusable, :schedule_custom],
          is_binary(callee),
          reduce: %{} do
        acc -> Map.update(acc, callee, [w.bubble_id], &[w.bubble_id | &1])
      end

    Map.new(workflows, fn w -> {w.bubble_id, roots_of(w, by_id, callers, MapSet.new())} end)
  end

  defp roots_of(%{disabled?: true}, _by_id, _callers, _seen), do: []

  defp roots_of(%{kind: kind, id: symbol}, _by_id, _callers, _seen) when kind in @event_kinds,
    do: [{:event, symbol}]

  defp roots_of(%{kind: :custom_event, bubble_id: id}, by_id, callers, seen) do
    if MapSet.member?(seen, id) do
      []
    else
      seen = MapSet.put(seen, id)

      callers
      |> Map.get(id, [])
      |> Enum.flat_map(&roots_of(by_id[&1], by_id, callers, seen))
      |> Enum.uniq()
    end
  end

  defp roots_of(%{id: symbol}, _by_id, _callers, _seen), do: [{:load, symbol}]

  # What a display step's element holds, or why the page cannot keep it:
  # a group (popup, floating group, group focus) holds a thing, a
  # reusable-element instance its reusable element's thing (as does the
  # reusable element itself, seen from inside), a repeating group a list.
  # In a repeating group's cell only a group, from a workflow of the same
  # cell (per cell).
  defp display_holder(op, %{element: element, cell: cell}, w, surface, ctx) do
    raw = ctx.raw_elements[element]
    el = ctx.elements[element]

    with :ok <- display_element(raw, el, surface),
         :ok <- display_place(op, element, el, cell, w, surface, ctx) do
      {:ok, holder(op, element, el, raw, surface, cell, ctx)}
    end
  end

  defp display_element(raw, %{surface: surface}, surface) when raw != nil, do: :ok

  defp display_element(_raw, _el, _surface),
    do: {:error, &Residue.entry(&1, :unresolved_reference, %{reference: "element"})}

  # A cell's elements render in its template, per cell (when the page
  # loads the list): only a group there, set from the same cell.
  defp display_place(op, _element, el, cell, _w, _surface, _ctx)
       when is_binary(cell) and (op == :display_list or is_binary(el.instance_of)),
       do:
         {:error,
          &Residue.entry(&1, :page_data_in_cell, %{
            kind: if(op == :display_list, do: "list", else: "instance")
          })}

  defp display_place(_op, _element, _el, cell, w, _surface, ctx) when is_binary(cell) do
    if trigger_cell(w, ctx) == cell,
      do: :ok,
      else: {:error, &Residue.entry(&1, :page_data_in_cell, %{kind: "display"})}
  end

  defp display_place(_op, surface, _el, nil, _w, surface, _ctx), do: :ok

  defp display_place(_op, element, _el, nil, _w, _surface, ctx) do
    if rendered?(element, ctx),
      do: :ok,
      else: {:error, &Residue.entry(&1, :target_not_rendered, %{element: "element:" <> element})}
  end

  defp holder(:display_list, _element, _el, raw, surface, cell, _ctx),
    do: %{
      kind: :list,
      surface: surface,
      cell: cell,
      holder: nil,
      type: raw.content && Type.listed(raw.content),
      page_size: Map.get(raw, :page_size)
    }

  # A thing has no page: a group's or instance's page size is nil.
  defp holder(:display_data, _element, %{instance_of: definition}, _raw, surface, cell, ctx)
       when is_binary(definition) do
    content = Map.get(ctx.raw_elements[definition] || %{}, :content)

    %{
      kind: :instance,
      surface: surface,
      cell: cell,
      holder: definition,
      type: content,
      page_size: nil
    }
  end

  defp holder(:display_data, _element, _el, raw, surface, cell, _ctx),
    do: %{
      kind: :group,
      surface: surface,
      cell: cell,
      holder: nil,
      type: raw.content,
      page_size: nil
    }

  # The repeating group whose cell holds a workflow's triggering element
  # (in its surface), or nil.
  defp trigger_cell(%{element: element}, ctx) when is_binary(element),
    do: cell_of(ctx.raw_elements[element], ctx, 0)

  defp trigger_cell(_w, _ctx), do: nil

  defp cell_of(nil, _ctx, _depth), do: nil
  defp cell_of(_el, _ctx, depth) when depth > 256, do: nil

  defp cell_of(%{parent: parent}, ctx, depth) do
    case ctx.raw_elements[parent] do
      %{kind: :element} = p -> Tree.cell_holder(p, parent) || cell_of(p, ctx, depth + 1)
      _ -> nil
    end
  end

  # The data a reset clears: what display steps showed in the element and
  # the elements inside it (in its surface, not inside a reusable
  # instance, whose own scope a reset of the instance clears).
  defp clears(_element, %{element: :root}, _ctx), do: :all

  defp clears(element, _target, ctx) do
    for {e, holder} <- Enum.sort(ctx.displayed),
        holder.kind != :instance,
        holder.surface == ctx.surface,
        e == element or inside?(e, element, ctx, 0),
        do: e
  end

  defp inside?(_e, _outer, _ctx, depth) when depth > 256, do: false

  defp inside?(e, outer, ctx, depth) do
    case ctx.raw_elements[e] do
      %{parent: ^outer} ->
        true

      %{parent: parent, kind: :element} when is_binary(parent) ->
        inside?(parent, outer, ctx, depth + 1)

      _ ->
        false
    end
  end

  defp data_type?(type) when is_binary(type),
    do: match?({%Type{kind: :ref}, _}, Type.classify(type))

  defp data_type?(_type), do: false

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

  # A native input whose initial content is its only dynamic part.
  defp initial_input?(%Normalized.Node{kind: kind, placeholder?: false} = node, kind) do
    bindings = node.bindings || %{}

    Map.has_key?(bindings, "value") and
      not Enum.any?(~w(checked choices), &Map.has_key?(bindings, &1))
  end

  defp initial_input?(_node, _kind), do: false

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

  # A URL input (`Spec.url/1`): a thing is read by its unique ID through
  # Ash, as the current user.
  defp bind({:url_parameter, ref}, ctx) do
    case Spec.url(ref) do
      {:ok, {:url_value, %{type: type} = url}} -> url_bind(url, Type.reference(type), ctx)
      {:ok, read} -> {:ok, read}
      :error -> {:error, "url_parameter"}
    end
  end

  defp bind({:page_data, %{"name" => "Current Date/Time"}}, _ctx), do: {:ok, :now}

  # A query a page data source reads first (WTF-495, `Data`).
  defp bind({:query, %{"n" => n}}, _ctx) when is_binary(n), do: {:ok, {:query, n}}

  # The page's data (WTF-420): a page's or cell's thing, a group's data, a
  # repeating group's list, a reusable element's property (WTF-493).
  defp bind({:element_state, %{"state" => s}} = input, ctx)
       when s in ["get_group_data", "get_list_data"],
       do: Data.read(ctx.data, ctx.surface, Map.get(ctx, :cell), input)

  defp bind({:element_state, %{"state" => "param_" <> _}} = input, ctx),
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

  defp url_bind(url, {:data_type, id}, ctx) do
    case resource_of(id, ctx) do
      %{module: module} ->
        {:ok, {:url_thing, Map.put(url, :resource, "#{ctx.namespace}.#{module}")}}

      nil ->
        {:error, "url_parameter"}
    end
  end

  defp url_bind(url, _reference, _ctx), do: {:ok, {:url_value, url}}

  # Built-in element state names are Bubble's (no app IDs); a custom state
  # or a reusable element's parameter carries one, so it is named by kind.
  defp element_state_kind("custom." <> _), do: "element_state:custom"
  defp element_state_kind("param_" <> _), do: "element_state:param"

  defp element_state_kind(state) do
    if Regex.match?(~r/\A[a-z_]+\z/, state),
      do: "element_state:" <> state,
      else: "element_state"
  end

  defp set_data(ctx, index) do
    index = Map.put(index, :instances, Map.get(ctx, :once, %{}))
    ctx |> Map.put(:data, index) |> Map.update!(:view, &%{&1 | data_index: index})
  end

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
