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
  | Current date/time | the time the workflow started (Bubble computes it once per evaluation and never again on its own, replay 2026-10-19) |
  | Current page width | the browser's viewport width in CSS pixels without a vertical scrollbar (`document.documentElement.clientWidth`, as Bubble, replay 2026-10-19), as the page's hook reports it once connected (and again when it changes); empty before that |
  | a custom event's parameter | its argument |
  | Result of step N | the step's result |
  | an element's custom state | the page's state map, per reusable-element instance |
  | an input's value | the page's input map, per instance: the page tracks every `Input` and `MultiLineInput` of text or number, `Checkbox` and text `Dropdown` it renders (not in a runtime container's template), and a `Dropdown` of things whose choices it loads (WTF-596: its value one of them, or its default); in a repeating group's cell the page renders per cell (WTF-520), one with a static first value, per cell, read in that cell |
  | a URL parameter (`Get data from page URL`) | the page's URL query, read as its type (`Spec.url/1`); a thing by its unique ID, through Ash as the current user |
  | the URL's path (`path`, `path segments`) | the page's URL path, its first segment the page's name |

  With `:page_data`, a page's thing, a group's, instance's or repeating
  group's data and a cell's thing are what the page loads; an element a
  "Display data" / "Display list" step sets (WTF-492) holds what the step
  showed, re-read as the current user. Anything else (an element's
  built-in states such as `is hovered`, other page data) is
  `:unavailable_input` residue: the generated pages do not load or track
  it.

  With `:element_visibility`, an element's `is visible` (and `isn't
  visible`) in an "Only when" condition, a workflow's or a step's, or a
  "Do when" condition of a page, is the visibility the page computes for
  it (WTF-588), as an element's conditionals read it
  (`BubbleEx.Target.Elixir.Frontend.ElementVisibility`, WTF-578): folded
  from its conditionals and its ancestors' up to the page, and its
  conditions' inputs bound like the condition's own. The clicked or
  changed element is not taken as shown: the server does not check that
  the element of a browser's event is, so a click's own condition decides
  it too. The read stays `:unavailable_input` residue when the browser may
  change it (a step shows, hides, toggles or animates it or an ancestor
  on the way, in the browser or from the server; a breakpoint, a hover
  rule, an overlay, a repeating group's cell on the way), when a
  conditional on the way does not compile for a workflow (a repeating
  group's `is loading`, say).

  In a reusable element's workflow (WTF-605), the reusable element's own
  `is visible` is its instance's on the page (`{:instance_visible, _}`,
  which the page computes per instance from `Spec`'s `visible`), and an
  element of it is visible when its visibility below the reusable
  element and the instance's both are. Only when every instance's
  visibility decides on the server, on a page or in a reusable element
  whose instances all decide in turn, and no step shows or hides the
  reusable element itself; otherwise the reads stay `:unavailable_input`.

  ## Residue added here

    * `:uncompiled_expression` (constructs prefixed `elixir:`) - an IR with
      no Elixir mapping, or two inputs of a step sharing a variable name
    * `:unavailable_input` - a value the page does not provide (above), or
      an input-changed event on an input the page does not track
    * `:target_not_rendered`, `:trigger_not_normalized`,
      `:trigger_in_runtime_template` - an element to show, hide, focus,
      reset or call into, or the element an event listens to, that the
      generated page does not render (an instance whose own data source
      does not load, WTF-522, has no scope to call into); a click or an
      input change in a repeating group's cell is wired per cell when the
      page renders that cell's template (WTF-520, `cell_members/2`), and
      the workflow binds that cell's thing (`Spec` workflow `cell`)
    * `:backend_workflow` - scheduling an API workflow without the
      `:backend` option (the backend workflows' spec, WTF-373)
    * `:unsupported_event` (`detail.target` `"phoenix"`) - user logged in
      or out: no wiring yet; popup opened or closed on an element that is
      not a Popup of the workflow's surface (a reusable element that is
      itself a popup included)
    * `:unresolved_reference` (`detail.target` `"ash"`) - a data type or
      field the Ash project does not map
    * `:unsupported_option` - a list change on a field that is not a list
    * `:page_data_in_cell` (`detail.kind` `"display"`, `"list"`,
      `"instance"`) - a "Display data" step into a repeating group's cell
      from outside it, or a list or an instance there (a reusable instance
      in a cell is otherwise rendered per cell, WTF-494: `Spec.cells`; a
      repeating group in a cell, per outer cell, two levels, WTF-520)

  ## Coverage

  `coverage/1` (`Spec.coverage/1`) measures generated code.
  """

  alias BubbleEx.{Diagnostic, Error, PageData}
  alias BubbleEx.Expression.{IR, Tree}
  alias BubbleEx.Frontend.{Conditions, Normalized, Table}
  alias BubbleEx.Model.Type
  alias BubbleEx.Plan.Residue
  alias BubbleEx.Target.Ash.{Naming, Project, Resource}
  alias BubbleEx.Target.Ash.Workflows, as: BackendWorkflows
  alias BubbleEx.Target.Ash.Workflows.Spec, as: BackendSpec
  alias BubbleEx.Target.Elixir, as: ElixirTarget
  alias BubbleEx.Target.Elixir.Frontend.ElementVisibility
  alias BubbleEx.Target.Elixir.FrontendWorkflows.{Data, Spec}
  alias BubbleEx.Workflows.Frontend
  alias BubbleEx.Workflows.Frontend.{Step, Workflow}
  alias BubbleEx.Workflows.Lowering.{Change, Expr}

  @client_ops [:show, :hide, :toggle, :animate, :focus, :scroll_to]
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

  @unwired_events [:logged_in, :logged_out]

  # "A popup is opened / closed" (WTF-520): the page's hook reports a
  # Popup it opened or closed (`bubble:popup`).
  @popup_events [:popup_opened, :popup_closed]

  @display_ops [:display_data, :display_list]

  # Events that never fire as the page loads (WTF-520). A popup opened or
  # closed fires when a step opens or closes it, or the user closes it
  # (`start_roots/2`). Anything else may (a page load, a condition, a
  # plugin's event, a user logged in or out: the conservative reading).
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
    * `:element_visibility` - the index of the pages' and reusable
      elements' visibility
      (`BubbleEx.Target.Elixir.Frontend.visibility_index/3`, WTF-588): an
      "Only when" or "Do when" condition reads an element's `is visible`
      as the page computes it, in a reusable element through its
      instance's (WTF-605, see Values); without it, that read is
      `:unavailable_input` residue
    * `:api_clients` - the `BubbleEx.Target.ApiClients.Spec` the app
      renders (WTF-533): an API Connector step calls its generated client
      on the server, in the LiveView process (only the step's non-private
      parameters are values from the page; secrets come from
      `config/runtime.exs`); without it, or for a call it does not
      generate, the step is `:api_connector_action` residue
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
        api_calls: BackendWorkflows.api_calls(Keyword.get(opts, :api_clients)),
        dropped: dropped,
        namespace: namespace,
        runtime: namespace <> ".Bubble.Runtime",
        project: project,
        element_visibility: Keyword.get(opts, :element_visibility),
        lookup: lookup(project),
        elements: elements,
        raw_elements: lowered.elements,
        present: present,
        templates: templates,
        nodes: nodes,
        publishers: lowered.publishers,
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

      # Repeating groups in another's cell, rendered per outer cell
      # (WTF-520, depth 2), then the reusable instances in repeating group
      # cells (WTF-494), and the reusable elements each reusable element
      # nests outside its cells.
      ctx = Map.put(ctx, :nested_lists, nested_lists(frontend))

      # The repeating groups whose list holds option-set values: their
      # cells are keyed by the option's value (WTF-520).
      ctx =
        Map.put(ctx, :option_lists, option_lists(frontend, Keyword.get(opts, :page_data), ctx))

      # The page's own elements in those cells (WTF-520): the ones whose
      # clicks and input changes the page wires per cell.
      ctx = Map.put(ctx, :cell_members, cell_members(frontend, ctx.nested_lists))
      {in_cells, nested} = cell_structure(lowered.elements, ctx)

      ctx =
        ctx
        |> Map.put(:nested, nested)
        |> Map.put(:in_cells, in_cells)
        |> Map.put(:once, once_instances(in_cells, ctx))

      ctx = Map.put(ctx, :rendered_once, rendered_once(ctx.once, kinds))

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
      #
      # A Dropdown of things (WTF-596) is tracked when its choices load,
      # and its default value too when it has one.
      {choices, defaults} = choice_inputs(page_data, ctx)

      {ctx, data, bound} =
        bind_with_inputs(
          MapSet.union(initial_inputs(page_data, ctx), defaults),
          choices,
          lowered,
          page_data,
          ctx
        )

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
             cell_inputs: Map.get(ctx.cell_inputs, id, %{}),
             initial: ctx.initial |> Enum.filter(&(elements[&1].surface == id)) |> Enum.sort(),
             data: Map.get(data, id, []),
             publishers: publishers(id, workflows, ctx)
           }}
        end)

      diagnostics =
        (lowered.diagnostics ++
           state_diags ++
           Enum.flat_map(Map.values(bound), &Enum.flat_map(&1, fn w -> w.diagnostics end)) ++
           data_diagnostics(data, page_data) ++
           not_run_diagnostics(data))
        |> Diagnostic.normalize()

      spec = %Spec{
        namespace: namespace,
        surfaces: surfaces,
        elements: elements,
        diagnostics: diagnostics,
        data_index: ctx.data,
        cells: Data.cell_instances(in_cells, data, ctx.data, nested),
        visible: visible_instances(ctx, surfaces),
        element_scripts: lowered.element_scripts
      }

      {:ok, Spec.with_unset_sources(spec, page_data)}
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
  # first value is page data, WTF-520) and the Dropdowns of things
  # `choices` (WTF-596) tracked, until the initial content of every one of
  # them loads, and the choices of every such Dropdown (with its default,
  # when it has one): an input whose initial content does not load, or a
  # Dropdown whose choices do not, is not tracked (as before), and its
  # sources are left out.
  defp bind_with_inputs(initial, choices, lowered, page_data, base) do
    ctx =
      base
      |> Map.put(:initial, initial)
      |> Map.put(:choices, choices)
      |> Map.put(:inputs, inputs(lowered.elements, base, initial, choices))
      |> Map.put(:cell_inputs, cell_inputs(lowered.elements, base))

    ctx = Map.put(ctx, :view, %Spec{elements: ctx.elements, surfaces: surfaces_view(ctx)})

    {ctx, data, bound} =
      bind_data_and_workflows(
        displayed(lowered.workflows, page_data, ctx),
        lowered,
        with_inputs(page_data, initial, choices),
        ctx
      )

    loaded = fn kind ->
      for {_surface, sources} <- data,
          %{kind: ^kind, residue: []} = d <- sources,
          into: MapSet.new(),
          do: d.element
    end

    kept = MapSet.intersection(initial, loaded.(:input))
    kept_choices = MapSet.intersection(choices, loaded.(:choices))

    # A Dropdown whose default does not load is not tracked; nor is the
    # default of one whose choices do not.
    {defaults, dropdowns} = thing_sources(page_data)

    kept_choices =
      MapSet.reject(kept_choices, &(&1 in defaults and &1 not in kept))

    kept = MapSet.reject(kept, &(&1 in dropdowns and &1 not in kept_choices))

    if kept == initial and kept_choices == choices,
      do: {ctx, data, bound},
      else: bind_with_inputs(kept, kept_choices, lowered, page_data, base)
  end

  # The elements with a default or initial content (`:input`) and the
  # Dropdowns with choices (`:choices`).
  defp thing_sources(nil), do: {MapSet.new(), MapSet.new()}

  defp thing_sources(page_data) do
    by = fn kind ->
      for %{kind: ^kind, element: e} <- page_data.sources, into: MapSet.new(), do: e
    end

    {by.(:input), by.(:choices)}
  end

  # The elements with a data source of their own, or nil without page data.
  defp own_elements(nil), do: nil

  defp own_elements(page_data),
    do:
      for(
        s <- page_data.sources,
        s.kind not in [:param, :choices],
        into: MapSet.new(),
        do: s.element
      )

  # The page data with the initial contents of the inputs `initial` only,
  # and the choices of the Dropdowns `choices` only.
  defp with_inputs(nil, _initial, _choices), do: nil

  defp with_inputs(page_data, initial, choices) do
    sources =
      Enum.reject(page_data.sources, fn s ->
        (s.kind == :input and not MapSet.member?(initial, s.element)) or
          (s.kind == :choices and not MapSet.member?(choices, s.element))
      end)

    %{page_data | sources: sources}
  end

  # The Dropdowns of things a page could track (WTF-596): rendered with
  # their choices from the page's data (`variant: :dynamic`), outside a
  # repeating group's cell, whose choices lowered (`BubbleEx.PageData`'s
  # `:choices` sources) and, when they have a default value, whose default
  # lowered too (`:input`): `{dropdowns, those with a default}`.
  defp choice_inputs(nil, _ctx), do: {MapSet.new(), MapSet.new()}

  defp choice_inputs(page_data, ctx) do
    by_kind =
      Enum.group_by(
        page_data.sources,
        &{&1.kind, &1.element},
        &(&1.residue == [])
      )

    dropdowns =
      for %{kind: :choices, element: id, residue: [], cell: nil} <- page_data.sources,
          %{kind: :element, type: "Dropdown", value: value, instance_of: nil} <- [
            ctx.raw_elements[id]
          ],
          thing_type?(value),
          rendered?(id, ctx),
          match?(
            %Normalized.Node{kind: :dropdown, variant: :dynamic, placeholder?: false},
            ctx.nodes[id]
          ),
          Map.get(by_kind, {:input, id}, [true]) == [true],
          into: MapSet.new(),
          do: id

    {dropdowns, MapSet.filter(dropdowns, &Map.has_key?(by_kind, {:input, &1}))}
  end

  defp thing_type?(type) when is_binary(type),
    do: match?({%Type{kind: :ref, cardinality: :one}, _}, Type.classify(type))

  defp thing_type?(_type), do: false

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
    ctx = ctx |> Map.put(:displayed, displayed) |> Map.delete(:instance_visibility)

    {ctx, data} = bind_page_data(page_data, displayed, ctx)

    # What the page's data binds decides the instances' visibility
    # (WTF-605), which the workflows read.
    ctx = Map.put(ctx, :instance_visibility, instance_visibility(ctx))

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
      do: {ctx, not_run(data, displayed, %{all: all, runs: runs}), bound},
      else: bind_data_and_workflows(kept, lowered, page_data, ctx)
  end

  # Lists on each popup kept by `opened_with_data?/5` the workflows that do
  # not run here and may display data in it while it is open
  # (`display_not_run/2`): `not_run`, Bubble IDs.
  defp not_run(data, displayed, workflows) do
    lists =
      for {element, %{opened_with_data?: true} = holder} <- displayed,
          ids = display_not_run(holder, workflows),
          ids != [],
          into: %{},
          do: {element, Enum.sort(ids)}

    Map.new(data, fn {surface, sources} ->
      {surface,
       Enum.map(sources, fn d ->
         case d do
           %{displayed?: true, kind: kind, element: e}
           when kind != :param and is_map_key(lists, e) ->
             Map.put(d, :not_run, lists[e])

           d ->
             d
         end
       end)}
    end)
  end

  defp not_run_diagnostics(data) do
    for {_surface, sources} <- data,
        %{not_run: [_ | _] = ids, element: element} <- sources do
      Diagnostic.new(
        :frontend_workflow_residue,
        "",
        "element:#{element}: kept as page data, but workflows that do not run here may " <>
          "display data in it while it is open (#{Enum.join(ids, ", ")}): it may show older data",
        details: %{
          subject: "element:" <> element,
          reason: "display_not_run",
          detail: %{workflows: ids}
        }
      )
    end
  end

  # Binds the page data. An instance whose own data source does not load
  # while its reusable element's reads of its own thing do (WTF-522,
  # `Data.unloaded_instances/3`) is not rendered: its scope is not read,
  # so a default of its reusable element read from outside it (WTF-520)
  # is not read either, and the sources reading one are bound again
  # without it. That can only leave more unloaded, never less, so this
  # ends; an instance once unloaded stays so.
  defp bind_page_data(page_data, displayed, ctx) do
    data =
      Data.bind(page_data, set_data(ctx, Data.index(page_data, displayed)), %{
        compile: &compile/3,
        bind: &bind/2
      })

    wired = Data.wired_index(data)
    before = Map.get(ctx, :unloaded, %{})
    self_reads = if page_data, do: page_data.self_reads, else: MapSet.new()
    new = Map.drop(Data.unloaded_instances(data, wired, self_reads), Map.keys(before))
    unloaded = Map.merge(before, new)

    ctx =
      ctx
      |> Map.put(:once, Map.drop(ctx.once, Map.keys(unloaded)))
      |> Map.put(:unloaded, unloaded)

    # Bound again only when a source reads under a newly unloaded instance
    # (its default, a custom state): the rest binds the same.
    if map_size(new) == 0 or not reads_under?(data, new),
      do: {set_data(ctx, wired), data},
      else: bind_page_data(page_data, displayed, ctx)
  end

  defp reads_under?(data, instances) do
    Enum.any?(data, fn {_surface, list} ->
      Enum.any?(list, &under?(Map.get(&1, :read), instances))
    end)
  end

  # Whether a bound read names a key (`%{path: ...}`) below one of
  # `instances`.
  defp under?(%{path: path} = map, instances) when is_list(path),
    do:
      Enum.any?(path, &Map.has_key?(instances, &1)) or
        Enum.any?(Map.values(map), &under?(&1, instances))

  defp under?(%_{}, _instances), do: false

  defp under?(map, instances) when is_map(map),
    do: Enum.any?(Map.values(map), &under?(&1, instances))

  defp under?(list, instances) when is_list(list), do: Enum.any?(list, &under?(&1, instances))

  defp under?(tuple, instances) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> under?(instances)

  defp under?(_term, _instances), do: false

  # Whether the page keeps what display steps show in an element
  # faithfully (WTF-520). In a repeating group's cell, when a step that
  # runs sets it (WTF-492). Elsewhere, by the workflows that may start
  # each step (`roots`, `start_roots/2`): every one that may run as the
  # page loads (a page-load or condition-true workflow, a plugin's or
  # another event this target does not lower, a popup a page-load
  # workflow opens or closes, or the callers of the custom event holding
  # the step) runs whole and is triggered; every event-driven one (a
  # click, an input change, a "do every" tick, a popup only those open or
  # close, the popup's workflow itself) is triggered, whether the runtime
  # then runs it or refuses it with a notice. Before an event the element
  # shows nothing, as in Bubble (a click in a repeating group's cell the
  # page wires per cell is one, WTF-520, when it also runs whole:
  # `event_kept?/2`); an event the page never
  # triggers (a click in a table's row, a third level) would leave it
  # empty where Bubble shows data, so it is not kept. No step at all:
  # empty, kept. A popup always opened with its data is kept whatever its
  # roots (`opened_with_data?/5`).
  defp kept?(element, %{cell: cell}, _workflows, shown) when is_binary(cell),
    do: MapSet.member?(shown, element)

  defp kept?(_element, %{opened_with_data?: true}, _workflows, _shown), do: true

  defp kept?(_element, %{roots: roots}, %{all: all, runs: runs}, _shown) do
    Enum.all?(roots, fn
      {:load, symbol} -> wired?(runs[symbol])
      {:event, symbol} -> event_kept?(all[symbol], runs[symbol])
    end)
  end

  # An event the page triggers. In a repeating group's cell (WTF-520) it
  # must also run whole (`runs`): one the runtime refuses would leave the
  # element empty for good where Bubble fills it on the click, so the
  # element stays unloaded, loudly.
  defp event_kept?(%{cell: cell}, run) when is_binary(cell), do: wired?(run)
  defp event_kept?(w, _run), do: wired?(w)

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
          do:
            {id,
             %{surface: surface, cell: rg, holder: holder, outer: Map.get(ctx.nested_lists, rg)}}

    nested =
      for {_id, surface, holder, nil} <- instances,
          reduce: %{} do
        acc -> Map.update(acc, surface, [holder], &Enum.uniq([holder | &1]))
      end

    {in_cells, Map.new(nested, fn {k, v} -> {k, Enum.sort(v)} end)}
  end

  # The repeating groups the page renders once per cell of another
  # (WTF-520): inner => outer. Two levels only: an outer repeating group
  # outside any runtime container (a table's header and footer rows render
  # once), and an inner one in its cell's template, not inside another
  # runtime container there (a table, a plugin's). A repeating group in an
  # inner one's cell, or in a table's repeated row, is not one: its list
  # stays residue (`:page_data_in_cell`, `kind` `"list"`).
  defp nested_lists(%Normalized{} = frontend) do
    (frontend.pages ++ frontend.reusables)
    |> Enum.flat_map(&outer_lists/1)
    |> Map.new()
  end

  defp outer_lists(%Normalized.Node{} = node) do
    cond do
      Table.table?(node) -> Enum.flat_map(Table.once(node), &outer_lists/1)
      repeating?(node) -> Enum.flat_map(node.children, &inner_lists(&1, node.source.bubble_id))
      runtime_container?(node) -> []
      true -> Enum.flat_map(node.children, &outer_lists/1)
    end
  end

  defp inner_lists(%Normalized.Node{} = node, outer) do
    cond do
      Table.table?(node) -> []
      repeating?(node) -> [{node.source.bubble_id, outer}]
      runtime_container?(node) -> []
      true -> Enum.flat_map(node.children, &inner_lists(&1, outer))
    end
  end

  # The page's own elements in the cells of the repeating groups it
  # renders per cell (WTF-520): element => the repeating group whose cell
  # holds it. A repeating group outside any runtime container, or one
  # rendered per cell of another (`nested`, two levels); the element in
  # its cell's template, not inside another runtime container there (a
  # table, a plugin's, a repeating group not rendered per cell) nor inside
  # a reusable instance (its elements are its reusable element's).
  defp cell_members(%Normalized{} = frontend, nested) do
    (frontend.pages ++ frontend.reusables)
    |> Enum.flat_map(&outer_members(&1, nested))
    |> Map.new()
  end

  defp outer_members(%Normalized.Node{} = node, nested) do
    cond do
      Table.table?(node) ->
        Enum.flat_map(Table.once(node), &outer_members(&1, nested))

      repeating?(node) ->
        Enum.flat_map(node.children, &members(&1, node.source.bubble_id, nested))

      runtime_container?(node) ->
        []

      true ->
        Enum.flat_map(node.children, &outer_members(&1, nested))
    end
  end

  defp members(%Normalized.Node{} = node, rg, nested) do
    id = node.source && node.source.bubble_id

    cond do
      Table.table?(node) ->
        []

      repeating?(node) ->
        if Map.get(nested, id) == rg,
          do: Enum.flat_map(node.children, &members(&1, id, nested)),
          else: []

      runtime_container?(node) or node.kind == :reusable_instance ->
        []

      true ->
        own = if is_binary(id), do: [{id, rg}], else: []
        own ++ Enum.flat_map(node.children, &members(&1, rg, nested))
    end
  end

  # The repeating group whose cell holds a click's or an input change's
  # element when the page wires it per cell (WTF-520): one of
  # `cell_members/2` whose list loads (and, for one rendered per cell of
  # another, the outer list too), else nil. The page then renders the
  # element in every cell, and its event carries that cell's scope.
  defp cell_trigger(element, ctx) when is_binary(element) do
    with rg when is_binary(rg) <- Map.get(Map.get(ctx, :cell_members, %{}), element),
         %{surface: surface} <- ctx.elements[element],
         outer = Map.get(ctx.nested_lists, rg),
         true <- keyed_cells?(rg, outer, ctx),
         true <- Data.cells_loaded?(ctx.data, surface, rg, outer) do
      rg
    else
      _ -> nil
    end
  end

  defp cell_trigger(_element, _ctx), do: nil

  # Whether the cells of `rg` (and of its outer list) are keyed by what
  # they hold: a list of things (their unique IDs) or of options (the
  # option's value and its occurrence, `<Web>.Bubble.cell_scope/5`). A
  # list of texts, numbers or dates has cells by position only, which
  # could name another item once the list changes under a stale page: its
  # events stay unwired.
  defp keyed_cells?(rg, outer, ctx),
    do: Enum.all?(Enum.reject([rg, outer], &is_nil/1), &keyed_list?(&1, ctx))

  defp keyed_list?(rg, ctx),
    do:
      data_type?(raw_content(rg, ctx)) or
        MapSet.member?(Map.get(ctx, :option_lists, MapSet.new()), rg)

  defp raw_content(id, ctx), do: Map.get(ctx.raw_elements[id] || %{}, :content)

  # Every repeating group whose list holds option-set values (WTF-520):
  # option values are stable and unique within their set, so a cell is
  # keyed by its option, not its position. Both its type of content and
  # what its data source computes must be that option set: a source of
  # another type (a list of texts read into an option-typed list) would
  # put arbitrary text in the cells' scopes, so it stays keyed by
  # position (and refused).
  defp option_lists(%Normalized{} = frontend, %PageData{sources: sources}, ctx) do
    computed =
      for %{kind: :list, element: id, value: %{ir: %IR{type: type}}} <- sources,
          is_binary(id),
          into: %{},
          do: {id, type}

    (frontend.pages ++ frontend.reusables)
    |> Enum.flat_map(&repeating_ids/1)
    |> Enum.filter(fn id ->
      content = raw_content(id, ctx)
      option_type?(content) and Map.get(computed, id) == "list." <> content
    end)
    |> MapSet.new()
  end

  defp option_lists(_frontend, _page_data, _ctx), do: MapSet.new()

  defp repeating_ids(%Normalized.Node{} = node) do
    own = if repeating?(node), do: [node.source.bubble_id], else: []
    own ++ Enum.flat_map(node.children, &repeating_ids/1)
  end

  defp option_type?(type) when is_binary(type),
    do: match?({%Type{kind: :option, cardinality: :one}, _}, Type.classify(type))

  defp option_type?(_type), do: false

  # The cell a workflow's event runs in: a click or an input change of an
  # element the page wires per cell (WTF-520), else nil.
  defp event_cell(%Workflow{kind: kind, element: element}, ctx)
       when kind in [:click, :input_change] and is_binary(element) do
    if Map.has_key?(ctx.templates, element), do: cell_trigger(element, ctx)
  end

  defp event_cell(_w, _ctx), do: nil

  defp repeating?(%Normalized.Node{
         kind: :placeholder,
         runtime: %{"boundary" => "container", "repeats" => true},
         source: %{bubble_id: id}
       })
       when is_binary(id),
       do: true

  defp repeating?(_node), do: false

  defp runtime_container?(%Normalized.Node{kind: :placeholder, runtime: %{"boundary" => _}}),
    do: true

  defp runtime_container?(_node), do: false

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

  # The reusable elements rendered once somewhere (WTF-520): with an
  # instance rendered once on a page, or in a reusable element rendered
  # once somewhere. The others are rendered only in repeating group cells,
  # if at all.
  defp rendered_once(once, kinds) do
    by_surface =
      Enum.group_by(Map.values(once), & &1.surface, & &1.holder)

    pages = for {id, :page} <- kinds, do: id
    reach_once(pages, MapSet.new(), by_surface)
  end

  defp reach_once([], seen, _by_surface), do: seen

  defp reach_once([surface | rest], seen, by_surface) do
    new =
      by_surface |> Map.get(surface, []) |> Enum.uniq() |> Enum.reject(&MapSet.member?(seen, &1))

    reach_once(new ++ rest, Enum.into(new, seen), by_surface)
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
  #
  # A Dropdown of things whose choices the page loads (`choices`, WTF-596)
  # is tracked as `:thing`: its value is one of its choices (or its
  # default), which the browser names by unique ID.
  defp inputs(elements, ctx, initial, choices) do
    for {id, %{kind: :element, type: type, value: value, instance_of: nil} = e} <- elements,
        typed = input_type(id, type, value, ctx, initial, choices),
        typed != nil,
        reduce: %{} do
      acc -> Map.update(acc, bubble(e.surface), %{id => typed}, &Map.put(&1, id, typed))
    end
  end

  defp input_type(id, type, value, ctx, initial, choices) do
    {values, kind} = Map.get(@inputs, type, {[], nil})

    cond do
      MapSet.member?(choices, id) ->
        :thing

      value in values and rendered?(id, ctx) and
          (native_input?(ctx.nodes[id], kind) or MapSet.member?(initial, id)) ->
        String.to_existing_atom(value)

      true ->
        nil
    end
  end

  # The inputs a page tracks per cell (WTF-520): of a tracked value type,
  # rendered natively with a static first value, among the page's own
  # elements of a repeating group's cell (`cell_members/2`). By surface:
  # element => `%{type, cell}`. Each cell keeps its own value, under the
  # cell's scope; whether the list loads is the event's to check.
  defp cell_inputs(elements, ctx) do
    for {id, %{kind: :element, type: type, value: value, instance_of: nil} = e} <- elements,
        rg = Map.get(ctx.cell_members, id),
        is_binary(rg),
        keyed_cells?(rg, Map.get(ctx.nested_lists, rg), ctx),
        {values, kind} <- [Map.get(@inputs, type, {[], nil})],
        value in values,
        MapSet.member?(ctx.present, id),
        native_input?(ctx.nodes[id], kind),
        reduce: %{} do
      acc ->
        entry = %{type: String.to_existing_atom(value), cell: rg}
        Map.update(acc, bubble(e.surface), %{id => entry}, &Map.put(&1, id, entry))
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
    # A click or an input change in a repeating group's cell (WTF-520)
    # runs in that cell: "Current cell's" thing, index and groups (and an
    # outer cell's, two levels) are the cell's the browser's event names.
    cell = event_cell(w, ctx)
    bctx = Map.merge(ctx, %{workflow: w, surface: surface, subject: w.id, cell: cell})

    {condition, cr} = condition(w, bctx)
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

    # Reading the page's data (WTF-420) reads stored data too, and so
    # does a condition's search (WTF-564).
    data? =
      Enum.any?(steps, &(&1.op in @data_ops)) or queries?(condition) or
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
      cell: cell,
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

  # A workflow's condition ("Only when"). One that reads a search (WTF-564),
  # which the Elixir target does not compile, is compiled as a conditional
  # state's condition is in the page's data (`Data.condition/4`): each
  # search is an Ash query read as the event runs, as the current user
  # (what the user may find, as the page's searches), before the
  # condition is tested. Bubble tests the condition when the event fires,
  # so the search is read then. Not a "Do when condition is true"
  # workflow's: the page tests it again when its own data changes, not
  # when the search's records do, as Bubble would.
  defp condition(%Workflow{kind: :condition_true} = w, ctx),
    do: compile(visibility(w.condition, ctx), w.id, ctx)

  defp condition(%Workflow{condition: expr, id: id}, ctx) do
    expr = visibility(expr, ctx)

    with {nil, [_ | _] = residue} = uncompiled <- compile(expr, id, ctx),
         true <- Enum.any?(residue, &(&1.reason == :uncompiled_expression)) do
      case Data.condition(expr, id, ctx, %{compile: &compile/3, bind: &bind/2}) do
        {:ok, compiled} -> {compiled, []}
        {:error, residue} -> {nil, residue}
        :none -> uncompiled
      end
    else
      {_compiled, _residue} = compiled -> compiled
      false -> compile(expr, id, ctx)
    end
  end

  # An element's "is visible" in an "Only when" or "Do when" condition
  # (WTF-588): the visibility the page computes for it
  # (`ElementVisibility.inline/4`, as an element's conditionals read it,
  # WTF-578), with only the page held shown. A read the page cannot decide
  # stays, and is `:unavailable_input` residue as before.
  #
  # Not the clicked or changed element and what holds it: the server never
  # checks that the element of a browser's event is shown (a stale or
  # forged click, an input committed later), so its own condition must
  # decide that too.
  #
  # A reusable element's condition (WTF-605) reads an element of its own
  # through the instance it runs in: the element's visibility below the
  # reusable element, and the instance's on the host page, which the
  # page computes per instance (`instance_visibility/1`). Only when every
  # instance's decides on the server; else its reads stay.
  defp visibility(%Expr{ir: %IR{} = ir} = expr, ctx) do
    index = Map.get(ctx, :element_visibility)

    case ctx.raw_elements[ctx.surface] do
      %{kind: :page} when is_map(index) ->
        %{expr | ir: ElementVisibility.inline(ir, ctx.surface, MapSet.new(), index)}

      %{kind: :reusable} when is_map(index) ->
        if decided_reusable?(ctx.surface, ctx),
          do: %{expr | ir: ElementVisibility.inline_instance(ir, ctx.surface, index)},
          else: expr

      _ ->
        expr
    end
  end

  defp visibility(expr, _ctx), do: expr

  defp decided_reusable?(id, ctx),
    do: match?(%{reusables: %{^id => {:ok, _}}}, Map.get(ctx, :instance_visibility))

  # The visibility of each reusable-element instance on its host
  # (WTF-605): `instances` by Bubble ID (`%{definition, host, visible}`,
  # `visible` its compiled visibility there, bound like a condition of
  # the host's, or nil when it does not decide on the server), and
  # `reusables`, by reusable element: `{:ok, data?}` when every instance
  # of it decides, on a page or in a reusable element whose instances all
  # decide in turn, and nothing shows or hides the reusable element apart
  # from its instances (`ElementVisibility.own_visibility?/2`); `data?`
  # when deciding one reads the page's data. A reusable element with no
  # instance runs nowhere and is not decided.
  defp instance_visibility(ctx) do
    case Map.get(ctx, :element_visibility) do
      %{} = index ->
        instances =
          for {id, %{kind: :element, instance_of: definition}} <- ctx.raw_elements,
              is_binary(definition),
              %{surface: host} <- [ctx.elements[id]],
              into: %{},
              do:
                {id,
                 %{
                   definition: definition,
                   host: host,
                   visible: instance_value(id, host, index, ctx)
                 }}

        by_definition = Enum.group_by(Map.values(instances), & &1.definition)

        reusables = decide(by_definition, index, ctx)

        %{instances: instances, reusables: reusables}

      _ ->
        %{instances: %{}, reusables: %{}}
    end
  end

  # The instances whose visibility a workflow reads (`Spec`'s `visible`):
  # of the reusable elements whose workflows bind it, and of the reusable
  # elements holding those, up to the pages.
  defp visible_instances(ctx, surfaces) do
    case Map.get(ctx, :instance_visibility) do
      %{instances: instances} ->
        read =
          for {id, %{workflows: workflows}} <- surfaces,
              Enum.any?(workflows, &reads_instance?/1),
              into: MapSet.new(),
              do: id

        needed = hosts_up(read, Map.values(instances), MapSet.new())

        for {id, %{definition: definition, visible: %{} = visible} = i} <- instances,
            MapSet.member?(needed, definition),
            into: %{},
            do: {id, %{host: i.host, visible: visible}}

      _ ->
        %{}
    end
  end

  defp hosts_up(new, instances, acc) do
    acc = MapSet.union(acc, new)

    hosts =
      for %{definition: d, host: host} <- instances,
          MapSet.member?(new, d),
          not MapSet.member?(acc, host),
          into: MapSet.new(),
          do: host

    if MapSet.size(hosts) == 0, do: acc, else: hosts_up(hosts, instances, acc)
  end

  defp reads_instance?(w),
    do:
      [w.condition | Enum.map(w.steps, & &1.condition)]
      |> Enum.any?(fn
        %{bindings: bindings} -> Enum.any?(bindings, &match?({:instance_visible, _}, &1.bind))
        _ -> false
      end)

  defp instance_value(id, host, index, ctx) do
    hctx =
      Map.merge(ctx, %{surface: host, cell: nil, workflow: %{bubble_id: nil, parameters: []}})

    with {:ok, ir} <- ElementVisibility.instance(id, index),
         {%{} = value, []} <- compile(%Expr{path: "", ir: ir}, id, hctx) do
      value
    else
      _ -> nil
    end
  end

  # The decided reusable elements, a least fixpoint: one is decided once
  # every instance of it decides and is on a page or in a reusable element
  # already decided (a cycle never is). Each round is linear in the
  # instances.
  defp decide(by_definition, index, ctx) do
    candidates =
      for {id, %{kind: :reusable}} <- ctx.raw_elements,
          instances = Map.get(by_definition, id, []),
          instances != [],
          Enum.all?(instances, &is_map(&1.visible)),
          not ElementVisibility.own_visibility?(id, index),
          into: %{},
          do: {id, instances}

    decide_round(candidates, %{}, ctx)
  end

  defp decide_round(candidates, decided, ctx) do
    new =
      for {id, instances} <- candidates,
          not Map.has_key?(decided, id),
          hosts = Enum.map(instances, &host_decided(&1.host, decided, ctx)),
          Enum.all?(hosts, &match?({:ok, _}, &1)),
          into: %{} do
        data? =
          Enum.any?(hosts, &(&1 == {:ok, true})) or
            Enum.any?(instances, &(loads?(&1.visible) or reads_data?(&1.visible)))

        {id, {:ok, data?}}
      end

    if new == %{}, do: decided, else: decide_round(candidates, Map.merge(decided, new), ctx)
  end

  defp host_decided(host, decided, ctx) do
    case ctx.raw_elements[host] do
      %{kind: :page} -> {:ok, false}
      %{kind: :reusable} -> Map.get(decided, host, :error)
      _ -> :error
    end
  end

  defp queries?(%{queries: [_ | _]}), do: true
  defp queries?(_compiled), do: false

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

      unwired_template?(element, ctx) ->
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

  # A popup opened or closed (WTF-520): a Popup of the workflow's surface
  # the page renders, outside a runtime container's template. Bubble lists
  # only popups for these events; a reusable element that is itself a
  # popup is not wired (its instance is the overlay).
  defp event_residue(%Workflow{kind: kind, element: element} = w, ctx)
       when kind in @popup_events do
    cond do
      not popup?(element, bubble(w.surface), ctx) ->
        [Residue.entry(w.id, :unsupported_event, %{type: w.event_type, target: "phoenix"})]

      not MapSet.member?(ctx.present, element) ->
        [Residue.entry(w.id, :trigger_not_normalized, %{element: "element:" <> element})]

      Map.has_key?(ctx.templates, element) ->
        [
          Residue.entry(w.id, :trigger_in_runtime_template, %{
            element: "element:" <> element,
            container: "element:" <> ctx.templates[element]
          })
        ]

      true ->
        []
    end
  end

  # A "Javascript to Bubble" element's event (WTF-608): a publisher of the
  # workflow's surface outside a runtime container's template, whose
  # outputs the page can keep.
  defp event_residue(%Workflow{kind: :js_publish, element: element} = w, ctx) do
    publisher = ctx.publishers[element]

    cond do
      Map.has_key?(ctx.templates, element) ->
        [
          Residue.entry(w.id, :trigger_in_runtime_template, %{
            element: "element:" <> element,
            container: "element:" <> ctx.templates[element]
          })
        ]

      publisher == nil ->
        [Residue.entry(w.id, :unsupported_event, %{type: w.event_type, target: "phoenix"})]

      (bad = Enum.reject(publisher.outputs, &output_kind(&1.type, ctx))) != [] ->
        [
          Residue.entry(w.id, :unsupported_option, %{
            options: Enum.map(bad, &"#{&1.name} (#{&1.type || "untyped"})")
          })
        ]

      true ->
        []
    end
  end

  defp event_residue(_w, _ctx), do: []

  # The publishers of surface `id` (WTF-608): what the page's hook may
  # publish to, the states each output sets (with the kind of value and,
  # for a thing, the resource it is read as), and the event's workflows.
  defp publishers(id, workflows, ctx) do
    for {element, p} <- ctx.publishers,
        bubble(p.surface) == id,
        not Map.has_key?(ctx.templates, element),
        outputs = for(o <- p.outputs, kind = output_kind(o.type, ctx), do: {o, kind}),
        length(outputs) == length(p.outputs),
        into: %{} do
      {element,
       %{
         suffix: p.suffix,
         outputs:
           Enum.map(outputs, fn {o, {kind, list?, resource}} ->
             %{name: o.name, state: o.state, kind: kind, list?: list?, resource: resource}
           end),
         workflows: if(p.trigger?, do: published_workflows(workflows, element), else: [])
       }}
    end
  end

  defp published_workflows(workflows, element) do
    for w <- workflows,
        w.kind == :js_publish,
        w.element == element,
        not w.disabled?,
        do: w.workflow
  end

  # What a published output holds: `{kind, list?, resource}` for a text,
  # number, yes/no, date or a thing of a mapped type (or a list of one);
  # nil for anything else (an option, a file, an untyped state).
  defp output_kind(type, ctx) when is_binary(type) do
    item = Type.list_item(type)
    list? = item != nil
    item = item || type

    case {item, Type.reference(item)} do
      {basic, _} when basic in ~w(text number boolean date) ->
        {String.to_existing_atom(basic), list?, nil}

      {_, {:data_type, key}} ->
        thing_output(key, list?, ctx)

      {"user", _} ->
        thing_output("user", list?, ctx)

      _ ->
        nil
    end
  end

  defp output_kind(_type, _ctx), do: nil

  defp thing_output(key, list?, ctx) do
    case resource_of(key, ctx) do
      %{module: module} -> {:thing, list?, "#{ctx.namespace}.#{module}"}
      nil -> nil
    end
  end

  # An element of a runtime container's template the page does not wire:
  # in a repeating group's cell the page renders per cell (WTF-520) it is
  # wired in the cell's scope; in any other template, not.
  defp unwired_template?(element, ctx),
    do: Map.has_key?(ctx.templates, element) and cell_trigger(element, ctx) == nil

  # A Popup element (not a reusable element's root) of `surface`.
  defp popup?(element, surface, ctx) when is_binary(element) do
    match?(%{type: "Popup", kind: :element}, ctx.raw_elements[element]) and
      match?(%{surface: ^surface, root?: false}, ctx.elements[element])
  end

  defp popup?(_element, _surface, _ctx), do: false

  defp tracked?(element, ctx) do
    case ctx.elements[element] do
      %{surface: surface} ->
        Map.has_key?(Map.get(ctx.inputs, surface, %{}), element) or
          Map.has_key?(Map.get(ctx.cell_inputs, surface, %{}), element)

      nil ->
        false
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
      element: s.element,
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
    {condition, cr} = compile(visibility(s.condition, ctx), s.id, ctx)
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
    do:
      Enum.any?(
        bindings,
        &match?(
          {kind, _} when kind in [:data, :cell, :cell_data, :outer_cell, :outer_cell_data],
          &1.bind
        )
      ) or Enum.any?(bindings, &match?({:step_return, %{resource: r}} when r != nil, &1.bind)) or
        Enum.any?(bindings, &match?({:instance_visible, %{data?: true}}, &1.bind))

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

  # An animation (WTF-603) runs in the browser, as the element steps do:
  # a transition shows or hides the element as a show or hide step does,
  # with its motion. Only a known effect reaches here (an unknown one is
  # residue in the lowering).
  defp args(:animate, %{element: element, visibility: visibility, motion: motion}, id, ctx) do
    case target(element, ctx) do
      {:ok, target} -> {%{target: target, visibility: visibility, motion: motion}, []}
      {:error, entry} -> {%{}, [entry.(id)]}
    end
  end

  # The page's own sign-in forms are not wired: users sign in through
  # AshAuthentication's (magic link). Still auth residue here.
  @auth_types %{
    sign_up: "SignUp",
    log_in: "LogIn",
    send_password_reset: "SendPasswordResetEmail",
    reset_password: "ResetPassword"
  }

  defp args(op, _args, id, _ctx) when is_map_key(@auth_types, op),
    do:
      {%{},
       [Residue.entry(id, :auth_action, %{type: Map.fetch!(@auth_types, op), target: "phoenix"})]}

  defp args(:send_email, _args, id, _ctx),
    do: {%{}, [Residue.entry(id, :unsupported_action, %{type: "SendEmail", target: "phoenix"})]}

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
        # An instance the page does not render as its reusable element
        # (its own data source does not load, WTF-522) has no scope to
        # run the custom event in: it would read nothing of its thing.
        rendered =
          if rendered?(args.element, ctx) and
               not Map.has_key?(Map.get(ctx, :unloaded, %{}), args.element),
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

  defp args(:api_call, args, id, ctx),
    do: BackendWorkflows.api_step(args, id, ctx.api_calls, &compile(&1, &2, ctx))

  # Toolbox's "Run javascript" (WTF-608): its inputs computed on the
  # server, as the current user; the script runs in the browser.
  defp args(:run_js, args, id, ctx) do
    {params, residue} = values(args.params, :name, id, ctx)

    {%{
       script: args.script,
       source: args.source,
       implicit: args.implicit,
       params: params,
       async?: args.async?
     }, residue}
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
  defp displayed(workflows, page_data, ctx) do
    own = own_elements(page_data)
    starts = start_roots(workflows, ctx)

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

    set =
      set
      |> Map.drop(MapSet.to_list(popup_races(workflows, starts_callers(workflows), ctx)))
      |> Map.new(fn {element, holder} ->
        {element,
         Map.put(
           holder,
           :opened_with_data?,
           opened_with_data?(element, holder, workflows, page_data, ctx)
         )}
      end)

    if own == nil,
      do: set,
      else: Map.merge(never_shown(steps, own, ctx), set)
  end

  # A popup always opened with its data (WTF-520): what it shows does
  # not depend on which workflows may display data in it, so the page
  # keeps it even when some of them do not run here (`kept?/4`). Popups
  # are closed as the page loads, and what is inside one renders only
  # while it is open. When every workflow that may open it (a show or a
  # toggle) displays data in it after its last opening step, with only
  # client steps (show, hide, toggle, focus, scroll to) between and no
  # condition on the display; nothing else may open it (its conditions,
  # an action this target does not lower naming it or an element inside
  # it); and nothing outside it reads it or anything inside it, then what
  # it shows on opening is what the opening run displayed. A workflow
  # that does not run here and may display data in it while it is open
  # (a plugin's event, a refused condition-true workflow, ...) is listed
  # on its data (`not_run`, `display_not_run/2`): what it would show is
  # lost, and the popup may show older data meanwhile. Not in a repeating
  # group's cell (kept by the steps that run there).
  defp opened_with_data?(popup, holder, workflows, page_data, ctx) do
    active = Enum.reject(workflows, & &1.disabled?)
    openers = Enum.filter(active, &opens?(&1, popup))

    holder.cell == nil and match?(%{type: "Popup"}, ctx.raw_elements[popup]) and openers != [] and
      Enum.all?(openers, &opens_with_data?(&1, popup)) and
      not visibility_conditions?(ctx.nodes[popup]) and
      not Enum.any?(active, &unknown_step?(&1, popup, ctx)) and
      not read_outside?(popup, active, page_data, ctx)
  end

  defp opens?(w, popup),
    do:
      Enum.any?(
        w.steps,
        &(visibility_op(&1) in [:show, :toggle] and match?(%{element: ^popup}, &1.args))
      )

  @client_steps [:show, :hide, :toggle, :animate, :focus, :scroll_to]

  # What a step does to its element's visibility: a show, hide or toggle,
  # or an animation's transition (an entrance shows, an exit hides,
  # WTF-603); nil for anything else (a callout included).
  defp visibility_op(%Step{op: op}) when op in [:show, :hide, :toggle], do: op
  defp visibility_op(%Step{op: :animate, args: %{visibility: visibility}}), do: visibility
  defp visibility_op(_step), do: nil

  # Whether a workflow that opens `popup` displays data in it after its
  # last opening step, with only client steps between (no data step, no
  # terminate, nothing that may end the run or change what it reads) and
  # no condition on the display.
  defp opens_with_data?(w, popup) do
    after_open =
      w.steps
      |> Enum.reverse()
      |> Enum.take_while(
        &(not (visibility_op(&1) in [:show, :toggle] and match?(%{element: ^popup}, &1.args)))
      )
      |> Enum.reverse()

    rest = Enum.drop_while(after_open, &(&1.op in @client_steps))
    match?([%Step{op: :display_data, args: %{element: ^popup}, condition: nil} | _], rest)
  end

  # Steps this target does not run: an action that does not lower, or an
  # animation of an effect it does not know (WTF-603: which may show or
  # hide the element).
  defp unlowered?(%Step{op: nil}), do: true
  defp unlowered?(%Step{op: :animate, args: %{motion: nil}}), do: true
  defp unlowered?(_step), do: false

  # An action this target does not lower naming the popup (or an element
  # in it): it may open the popup, or change it, at any time.
  defp unknown_step?(w, popup, ctx),
    do:
      Enum.any?(
        w.steps,
        &(unlowered?(&1) and is_binary(&1.element) and within?(&1.element, popup, ctx))
      )

  # Whether anything outside `popup` names the popup or an element inside
  # it, other than as the target of a step: an element's binding or
  # property (not `current_parent`: the editor's static record of where
  # the element was, an ID or `<ID>.elements`, never an expression), a
  # page data source, a workflow's condition or a step's condition or
  # value. After a workflow's own display in the popup with no
  # condition (not in that display's own value), its steps may read the
  # popup itself (what it just displayed, in the same run), not the
  # elements inside it. A workflow
  # of an element inside the popup (a click, an input change) runs only
  # while it is open, and so does a custom event only those call (not
  # one anything schedules: it may run after the popup closes): not
  # outside. Nor is one the page never triggers (an event this target
  # does not lower or wire). The popup's own "is opened" workflow is
  # outside: which of it and the opening run reads first is not replayed
  # (`popup_races/3`).
  defp read_outside?(popup, workflows, page_data, ctx) do
    ids = for {id, _} <- ctx.raw_elements, within?(id, popup, ctx), do: ~s("#{id}")

    nodes_read?(popup, ids, ctx) or sources_read?(popup, ids, page_data, ctx) or
      workflows_read?(popup, ids, workflows, ctx)
  end

  defp names?(_term, []), do: false

  defp names?(term, ids),
    do: String.contains?(inspect(term, limit: :infinity, printable_limit: :infinity), ids)

  defp nodes_read?(popup, ids, ctx) do
    Enum.any?(ctx.nodes, fn {id, node} ->
      not within?(id, popup, ctx) and
        names?(
          {node.bindings, node.content, node.attributes, without_parent_record(node.unmapped)},
          ids
        )
    end)
  end

  defp sources_read?(_popup, _ids, nil, _ctx), do: false

  defp sources_read?(popup, ids, page_data, ctx),
    do:
      Enum.any?(page_data.sources, fn s ->
        not within?(s.element, popup, ctx) and names?(s.value, ids)
      end)

  defp workflows_read?(popup, ids, workflows, ctx) do
    inner = List.delete(ids, ~s("#{popup}"))
    by_id = Map.new(workflows, &{&1.bubble_id, &1})
    callers = starts_callers(workflows)
    ctx = Map.put(ctx, :scheduled, scheduled(workflows))

    Enum.any?(workflows, fn w ->
      {before, later} = split_at_display(w.steps, popup)

      not while_open?(w, popup, by_id, callers, MapSet.new(), ctx) and
        (names?(w.condition, ids) or names?(reads(before), ids) or names?(reads(later), inner))
    end)
  end

  # An element's unmapped keys without the editor's `current_parent`
  # (on the element, or among its properties).
  defp without_parent_record(unmapped) do
    case Map.delete(unmapped, "current_parent") do
      %{"properties" => %{} = props} = rest ->
        Map.put(rest, "properties", Map.delete(props, "current_parent"))

      rest ->
        rest
    end
  end

  # The custom events a workflow schedules: they may run after the popup
  # closes, whoever schedules them.
  defp scheduled(workflows) do
    for w <- workflows,
        %Step{op: :schedule_custom, args: %{workflow: callee}} <- w.steps,
        is_binary(callee),
        into: MapSet.new(),
        do: callee
  end

  # Whether a workflow runs only while `popup` is open, or never here.
  defp while_open?(nil, _popup, _by_id, _callers, _seen, _ctx), do: true

  defp while_open?(%{kind: kind}, _popup, _by_id, _callers, _seen, _ctx)
       when kind == :unsupported or kind in @unwired_events,
       do: true

  defp while_open?(%{kind: kind, element: element}, popup, _by_id, _callers, _seen, ctx)
       when kind in [:click, :input_change] and is_binary(element),
       do: within?(element, popup, ctx)

  defp while_open?(%{kind: :custom_event, bubble_id: id}, popup, by_id, callers, seen, ctx) do
    cond do
      MapSet.member?(ctx.scheduled, id) ->
        false

      MapSet.member?(seen, id) ->
        true

      true ->
        seen = MapSet.put(seen, id)

        callers
        |> Map.get(id, [])
        |> Enum.all?(&while_open?(by_id[&1], popup, by_id, callers, seen, ctx))
    end
  end

  defp while_open?(_w, _popup, _by_id, _callers, _seen, _ctx), do: false

  # A workflow's steps up to its first display in `popup` with no
  # condition, that display included (its value is read before it shows),
  # and the steps after it.
  defp split_at_display(steps, popup) do
    {before, rest} =
      Enum.split_while(
        steps,
        &(not match?(%Step{op: :display_data, args: %{element: ^popup}, condition: nil}, &1))
      )

    case rest do
      [display | later] -> {before ++ [display], later}
      [] -> {before, []}
    end
  end

  # What steps read: their conditions and values, not their targets.
  defp reads(steps), do: Enum.map(steps, &{&1.condition, Map.delete(&1.args, :element)})

  # The workflows that do not run here and may display data in a popup
  # kept by `opened_with_data?/5` while it is open (WTF-520): its roots
  # neither triggered and run whole (`runs`), other than page-load
  # workflows, which run while every popup is closed. Their Bubble IDs,
  # sorted.
  defp display_not_run(%{roots: roots}, %{all: all, runs: runs}) do
    for {_mode, symbol} <- roots,
        is_binary(symbol),
        w = all[symbol],
        w != nil,
        w.kind != :page_load,
        not wired?(runs[symbol]),
        uniq: true,
        do: w.workflow
  end

  # Elements whose data a popup's own workflow may undo (WTF-520): a
  # workflow that opens a popup (or closes it), or one calling it, shows
  # data in an element that the popup's "is opened" (or "is closed")
  # workflow resets (the element or a group around it) or shows data in
  # too. Which runs last is not replayed (here the popup's, after the
  # page re-rendered): what the element shows then is not known, so it is
  # not kept, loudly. Replayed (2026-10-14): a workflow that shows the
  # popup and then displays data in it (the popup or an element inside
  # it) wins over a reset in the popup's "is opened" workflow; the page
  # keeps that display through the reset (`BubbleWorkflows.reset/5`,
  # `kept`), so it is no race. (The page keeps any display made after the
  # opening step so; an element outside the popup that such a reset
  # reaches stays unloaded here, so nothing reads what it keeps.)
  defp popup_races(workflows, callers, ctx) do
    active = Enum.reject(workflows, & &1.disabled?)
    by_id = Map.new(active, &{&1.bubble_id, &1})

    for %{kind: kind, element: popup} = w <- active,
        kind in @popup_events,
        is_binary(popup),
        resets = for(%Step{op: :reset_group, args: %{element: e}} <- w.steps, do: e),
        own = displays(w),
        opener <- openers(active, kind, popup, callers, by_id),
        shown <- displays(opener),
        shown in own or
          (Enum.any?(resets, &within?(shown, &1, ctx)) and
             not shown_after_opening?(kind, opener, popup, shown, ctx)),
        into: MapSet.new(),
        do: shown
  end

  # Whether `shown` is the popup or inside it, `opener` itself shows (or
  # toggles) `popup` and every step of it displaying data in `shown` comes
  # after that step: what the popup's "is opened" workflow resets then
  # shows the displayed value (replay 2026-10-14). An element outside the
  # popup, a display through a custom event that opens the popup, or one
  # before the popup opens, is not replayed: still a race.
  defp shown_after_opening?(:popup_opened, opener, popup, shown, ctx) do
    steps = Enum.with_index(opener.steps)

    opened =
      Enum.find_value(steps, fn {step, i} ->
        if visibility_op(step) in [:show, :toggle] and match?(%{element: ^popup}, step.args),
          do: i
      end)

    displayed =
      for {%Step{op: op, args: %{element: ^shown}}, i} <- steps, op in @display_ops, do: i

    within?(shown, popup, ctx) and opened != nil and displayed != [] and
      Enum.all?(displayed, &(&1 > opened))
  end

  defp shown_after_opening?(_kind, _opener, _popup, _shown, _ctx), do: false

  defp displays(w),
    do:
      for(%Step{op: op, args: %{element: e}} <- w.steps, op in @display_ops, is_binary(e), do: e)

  # The workflows whose steps open (close) the popup, and those calling
  # them, transitively.
  defp openers(active, kind, popup, callers, by_id) do
    ops = if kind == :popup_opened, do: [:show, :toggle], else: [:hide, :toggle]

    direct =
      for w <- active,
          Enum.any?(w.steps, &(visibility_op(&1) in ops and match?(%{element: ^popup}, &1.args))),
          do: w.bubble_id

    direct
    |> callers_of(callers, MapSet.new())
    |> Enum.flat_map(&List.wrap(by_id[&1]))
  end

  defp callers_of([], _callers, seen), do: MapSet.to_list(seen)

  defp callers_of([id | rest], callers, seen) do
    if MapSet.member?(seen, id),
      do: callers_of(rest, callers, seen),
      else: callers_of(Map.get(callers, id, []) ++ rest, callers, MapSet.put(seen, id))
  end

  # Whether element `id` is `group` or inside it.
  defp within?(id, group, ctx, depth \\ 0)
  defp within?(id, id, _ctx, _depth), do: true
  defp within?(_id, _group, _ctx, depth) when depth > 64, do: false

  defp within?(id, group, ctx, depth) do
    case ctx.raw_elements[id] do
      %{parent: parent} when is_binary(parent) -> within?(parent, group, ctx, depth + 1)
      _ -> false
    end
  end

  # Custom event => the workflows calling or scheduling it.
  defp starts_callers(workflows) do
    for w <- workflows,
        not w.disabled?,
        %Step{op: op, args: %{workflow: callee}} <- w.steps,
        op in [:call, :call_reusable, :schedule_custom],
        is_binary(callee),
        reduce: %{} do
      acc -> Map.update(acc, callee, [w.bubble_id], &[w.bubble_id | &1])
    end
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

    groups =
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

    Map.merge(groups, never_shown_instances(stepped, own, ctx))
  end

  # Reusable-element instances no step and no data source fill (WTF-520):
  # their reusable element's thing is nothing, as a group's no step fills,
  # when every instance of that reusable element is one, outside a
  # repeating group's cell, and no step inside it sets its own thing. Its
  # reads of its own thing then read nothing in each instance. A reusable
  # element with any other instance is left as it is: what it reads of
  # its own thing loads only from an instance's own source.
  defp never_shown_instances(stepped, own, ctx) do
    ctx.raw_elements
    |> Enum.filter(fn {_id, e} -> e.kind == :element and is_binary(e.instance_of) end)
    |> Enum.group_by(fn {_id, e} -> e.instance_of end)
    |> Enum.filter(fn {definition, instances} ->
      unfilled_reusable?(definition, instances, stepped, own, ctx)
    end)
    |> Enum.flat_map(&elem(&1, 1))
    |> Enum.flat_map(&unfilled_holder(&1, ctx))
    |> Map.new()
  end

  defp unfilled_reusable?(definition, instances, stepped, own, ctx) do
    content = Map.get(ctx.raw_elements[definition] || %{}, :content)

    is_binary(content) and content != "" and not MapSet.member?(stepped, definition) and
      Enum.all?(instances, fn {id, raw} ->
        not MapSet.member?(stepped, id) and not MapSet.member?(own, id) and
          cell_of(raw, ctx, 0) == nil
      end)
  end

  defp unfilled_holder({id, raw}, ctx) do
    with %{surface: surface} = el <- ctx.elements[id],
         true <- rendered?(id, ctx) do
      [{id, Map.put(holder(:display_data, id, el, raw, surface, nil, ctx), :roots, [])}]
    else
      _ -> []
    end
  end

  # For each workflow (Bubble ID), the workflows that may start it:
  # `{:event, symbol}` for a click, an input change or a "do every" tick,
  # `{:load, symbol}` for any other event (it may fire as the page loads);
  # for a custom event, those of every workflow calling or scheduling it
  # (none when nothing does, or only itself through a cycle). Disabled
  # workflows never run.
  #
  # A popup opened or closed (WTF-520) is started by the workflows whose
  # steps open it (show, toggle) or close it (hide, toggle), the user's
  # Escape included for a closed one (the workflow's own `{:event,
  # symbol}`: the page must trigger it). Popups are closed as the page
  # loads, so with only event-driven openers it never fires as the page
  # loads; with a page-load opener it does, and must run whole there too
  # (`{:load, symbol}`). A popup whose conditions set its visibility may be
  # opened by them, which the page does not follow (an overlay's
  # conditions are not rendered), and one an action this target does not
  # lower names may be opened or closed by it: `{:load, nil}`, never kept.
  defp start_roots(workflows, ctx) do
    by_id = Map.new(workflows, &{&1.bubble_id, &1})
    callers = starts_callers(workflows)

    toggles =
      for w <- workflows,
          not w.disabled?,
          %Step{args: %{element: element}} = step <- w.steps,
          op = visibility_op(step),
          op != nil,
          is_binary(element),
          kind <- toggled(op),
          reduce: %{} do
        acc -> Map.update(acc, {kind, element}, [w.bubble_id], &[w.bubble_id | &1])
      end

    # An action this target does not lower (an unknown animation, a
    # plugin's action, ...) naming a popup may open or close it, at any
    # time: what the popup's workflows set is never kept.
    unknown =
      for w <- workflows,
          not w.disabled?,
          %Step{element: element} = step <- w.steps,
          unlowered?(step),
          is_binary(element),
          into: MapSet.new(),
          do: element

    starts = %{
      by_id: by_id,
      callers: callers,
      toggles: toggles,
      unknown: MapSet.union(conditional_popups(workflows, ctx), unknown)
    }

    Map.new(workflows, fn w -> {w.bubble_id, roots_of(w, starts, MapSet.new())} end)
  end

  defp toggled(:show), do: [:popup_opened]
  defp toggled(:hide), do: [:popup_closed]
  defp toggled(:toggle), do: [:popup_opened, :popup_closed]

  # The popups with popup events whose conditions set their visibility.
  defp conditional_popups(workflows, ctx) do
    for %{kind: kind, element: element} <- workflows,
        kind in @popup_events,
        is_binary(element),
        visibility_conditions?(ctx.nodes[element]),
        into: MapSet.new(),
        do: element
  end

  defp visibility_conditions?(%Normalized.Node{bindings: %{"condition" => %{payload: payload}}}),
    do: Conditions.visibility(payload) != []

  defp visibility_conditions?(_node), do: false

  defp roots_of(nil, _starts, _seen), do: []
  defp roots_of(%{disabled?: true}, _starts, _seen), do: []

  defp roots_of(%{kind: kind, id: symbol}, _starts, _seen) when kind in @event_kinds,
    do: [{:event, symbol}]

  defp roots_of(%{kind: :custom_event, bubble_id: id}, starts, seen) do
    if MapSet.member?(seen, id) do
      []
    else
      seen = MapSet.put(seen, id)

      starts.callers
      |> Map.get(id, [])
      |> Enum.flat_map(&roots_of(starts.by_id[&1], starts, seen))
      |> Enum.uniq()
    end
  end

  defp roots_of(%{kind: kind, element: element, id: symbol, bubble_id: id}, starts, seen)
       when kind in @popup_events do
    if MapSet.member?(seen, id) do
      []
    else
      seen = MapSet.put(seen, id)

      from =
        starts.toggles
        |> Map.get({kind, element}, [])
        |> Enum.flat_map(&roots_of(starts.by_id[&1], starts, seen))

      own =
        cond do
          MapSet.member?(starts.unknown, element) -> [{:load, nil}]
          Enum.any?(from, &match?({:load, _}, &1)) -> [{:event, symbol}, {:load, symbol}]
          true -> [{:event, symbol}]
        end

      Enum.uniq(own ++ from)
    end
  end

  defp roots_of(%{id: symbol}, _starts, _seen), do: [{:load, symbol}]

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

  # An instance the page does not render (WTF-522) has no scope to keep
  # what the step shows in: before the step it would show nothing of its
  # own source, so it stays unrendered and the step is residue.
  defp display_place(_op, element, _el, nil, _w, _surface, ctx) do
    if rendered?(element, ctx) and not Map.has_key?(Map.get(ctx, :unloaded, %{}), element),
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
    param = ref["param_id"] || ref["param_key"] || ref["key"]

    cond do
      event not in [nil, ctx.workflow.bubble_id] -> {:error, "parameter_of_other_workflow"}
      Enum.any?(ctx.workflow.parameters, &(&1.id == param)) -> {:ok, {:param, param}}
      true -> {:error, "unresolved_parameter"}
    end
  end

  # A value the custom event a step triggered returned (WTF-520): a thing
  # is read as a record of its resource, through Ash as the current user.
  defp bind({:step_result, %{"action" => action, "return" => return} = ref}, ctx)
       when is_binary(return) do
    case returned(ref["type"], ctx) do
      {:ok, resource} ->
        list? = Type.list?(ref["type"])
        {:ok, {:step_return, %{step: action, return: return, resource: resource, list?: list?}}}

      :error ->
        {:error, "step_return"}
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

  # The viewport's width, as the browser reports it (WTF-520): a data
  # source or condition reading it is read again when it changes.
  defp bind({:page_data, %{"name" => "Current Page Width"}}, _ctx), do: {:ok, :page_width}

  # A query a page data source reads first (WTF-495, `Data`).
  defp bind({:query, %{"n" => n}}, _ctx) when is_binary(n), do: {:ok, {:query, n}}

  # An API Connector call a page data source reads first (WTF-533, `Data`).
  defp bind({:api_data, %{"n" => n}}, _ctx) when is_binary(n), do: {:ok, {:api_data, n}}

  # The page's data (WTF-420): a page's or cell's thing, a group's data, a
  # repeating group's list, a reusable element's property (WTF-493).
  defp bind({:element_state, %{"state" => s}} = input, ctx)
       when s in ["get_group_data", "get_list_data"],
       do: Data.read(ctx.data, ctx.surface, Map.get(ctx, :cell), input)

  defp bind({:element_state, %{"state" => "param_" <> _}} = input, ctx),
    do: Data.read(ctx.data, ctx.surface, Map.get(ctx, :cell), input)

  defp bind({kind, _ref} = input, ctx) when kind in [:page_thing, :cell_thing, :cell_index],
    do: Data.read(ctx.data, ctx.surface, Map.get(ctx, :cell), input)

  # A reusable element's own `is visible` as a condition of its workflow
  # reads it (WTF-605, `visibility/2`, `ElementVisibility.instance_read/1`):
  # its instance's, which the host page computes.
  defp bind(
         {:element_state, %{"element" => e, "state" => "is_visible", "instance" => true}},
         %{surface: e} = ctx
       ) do
    case Map.get(ctx, :instance_visibility) do
      %{reusables: %{^e => {:ok, data?}}} -> {:ok, {:instance_visible, %{data?: data?}}}
      _ -> {:error, "element_state:is_visible"}
    end
  end

  defp bind({:element_state, %{"element" => e, "state" => s}} = input, ctx)
       when is_binary(e) and is_binary(s) do
    case Spec.read(ctx.view, ctx.surface, input, Map.get(ctx, :cell)) do
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

  # The resource of a returned thing or list of things (nil for any other
  # value).
  defp returned(type, ctx) do
    case Type.reference(Type.list_item(type) || type) do
      {:data_type, id} ->
        case resource_of(id, ctx) do
          %{module: module} -> {:ok, "#{ctx.namespace}.#{module}"}
          nil -> :error
        end

      _ ->
        {:ok, nil}
    end
  end

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
    index =
      index
      |> Map.put(:instances, Map.get(ctx, :once, %{}))
      |> Map.put(:unloaded, Map.get(ctx, :unloaded, %{}))
      |> Map.put(:nested_lists, Map.get(ctx, :nested_lists, %{}))
      |> Map.put(:option_lists, Map.get(ctx, :option_lists, MapSet.new()))

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
      {id,
       %{
         states: Map.get(states, id, []),
         inputs: Map.get(ctx.inputs, id, %{}),
         cell_inputs: Map.get(ctx.cell_inputs, id, %{})
       }}
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
