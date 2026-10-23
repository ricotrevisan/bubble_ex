defmodule BubbleEx.Target.Phoenix.FrontendWorkflows do
  @moduledoc """
  Prints page and reusable-element workflows
  (`BubbleEx.Target.Elixir.FrontendWorkflows.Spec`, WTF-372) with the
  pages of `BubbleEx.Target.Phoenix.Pages`:

    * one **owned** `Workflows` module per page (`<Web>.<Page>Live.Workflows`)
      and per reusable element with workflows, custom states or tracked
      inputs (`<Web>.Reusables.<Name>.Workflows`), WTF-359 Q5: what the
      page lets a browser trigger (`__bubble__(:surface)`), each workflow's
      metadata (`__bubble__(:workflows)`: its function, condition, what
      blocks it, whether it touches stored data, its callees) and, for a
      page, the reusable-element instances it renders
      (`__bubble__(:instances)`); then one function per workflow, marked
      `# bubble:workflow <id>` with one `# bubble:step N <type>` per
      Bubble action (the plan's `step_order`). A workflow whose steps only
      show, hide, toggle, animate, focus or scroll to elements, clicked, with no
      condition, is a function returning `Phoenix.LiveView.JS` commands the
      element's `phx-click` calls; every other workflow is a function of
      the runtime's context, its steps private functions. A step bubble_ex
      could not lower is a `TODO(bubble:<id>)` step listed in `blocked`: the
      runtime refuses the workflow (and its callers) before any step runs
    * the **generated** runtime `<Web>.BubbleWorkflows` (see its
      moduledoc: event allowlist, data-access opt-in, unverified Bubble
      behavior)
    * an **owned** smoke test per native workflow (it and every workflow it
      calls or schedules generated whole), in
      `test/<app>_web/bubble_frontend_workflows_test.exs`: a clicked or
      input-changed workflow through its page's own event (a disconnected
      socket, `<Web>.BubbleWorkflows.socket/2`), any other through the
      runtime; each checks that it runs from a fresh page without raising.
      Like the backend's, they cannot fail on behavior, so they are tagged
      `bubble_smoke: "workflow:<id>"` (the plan's subject) and do not
      satisfy a `unit_test` check

  Only prints: it reads the spec and what the pages computed, never the
  Model or the lowering (see the boundary test).
  """

  alias BubbleEx.Target.Ash.Source
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Target.Phoenix.Templates

  @doc """
  The files of `spec` for the pages. `ctx` has `:web`, `:module`, `:app`
  and `:surfaces`: by surface Bubble ID, `%{kind, module, file, label,
  path, inputs, containers, instances}` from the pages (the Workflows
  module name and file, the page path, tracked inputs `element => {type,
  first value}`, each tracked input's containers, and a page's instances
  `[{scope, reusable Bubble ID}]`). Returns `%{owned, generated}`.
  """
  @spec files(Spec.t(), map()) :: %{owned: map(), generated: map()}
  def files(%Spec{} = spec, ctx) do
    modules =
      for {id, s} <- ctx.surfaces, s.module != nil, into: %{}, do: {id, s.module}

    ctx = Map.put(ctx, :modules, modules)

    owned =
      for {id, s} <- Enum.sort(ctx.surfaces), s.module != nil, into: %{} do
        {s.file, format(surface_module(id, s, spec, ctx))}
      end

    test = "test/#{ctx.app}_web/bubble_frontend_workflows_test.exs"

    assigns = %{
      web: ctx.web,
      module: ctx.module,
      app: ctx.app,
      join_topics: ctx.join_topics,
      enforced?: Map.get(ctx, :enforced?, false),
      api_data?: Spec.api_data?(spec),
      viewer?: Map.get(ctx, :viewer?, false),
      viewer_loads?: Map.get(ctx, :viewer_loads?, false)
    }

    %{
      owned: Map.put(owned, test, format(tests(spec, ctx))),
      generated:
        %{
          "lib/#{ctx.app}_web/bubble_workflows.ex" =>
            format(Templates.render("lib/web/bubble_workflows.ex", assigns)),
          # The page data (WTF-420).
          "lib/#{ctx.app}_web/bubble_data.ex" =>
            format(Templates.render("lib/web/bubble_data.ex", assigns)),
          "lib/#{ctx.app}/bubble/changes.ex" =>
            format(Templates.render("lib/app/bubble/changes.ex", assigns))
        }
        |> Map.merge(scripts_file(spec, ctx))
    }
  end

  # A script as the body of its function in the hook, every line indented
  # past the template's own, trailing spaces and repeated blank lines
  # dropped (so formatting it again changes nothing; no text spans lines,
  # `BubbleEx.Js`), its implicit globals declared first.
  defp script_body(%{source: source, implicit: implicit}) do
    lines = if implicit == [], do: [], else: ["let " <> Enum.join(implicit, ", ") <> ";"]

    (lines ++ String.split(source, ~r/\r\n|\r|\n/))
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.chunk_by(&(&1 == ""))
    |> Enum.flat_map(fn
      ["" | _] -> [""]
      lines -> Enum.map(lines, &("          " <> &1))
    end)
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  # The app author's page-only scripts and the publishers' hook (WTF-608),
  # when the pages have any.
  defp scripts_file(spec, ctx) do
    if Spec.scripts?(spec) do
      scripts =
        Enum.map(Spec.scripts(spec), fn s ->
          %{key: Jason.encode!(s.script), body: script_body(s)}
        end)

      elements =
        for {id, e} <- Enum.sort(spec.element_scripts) do
          %{key: Jason.encode!(id), scripts: Enum.map(e.scripts, &%{body: script_body(&1)})}
        end

      %{
        "lib/#{ctx.app}_web/components/bubble_scripts.ex" =>
          format(
            Templates.render("lib/web/components/bubble_scripts.ex", %{
              web: ctx.web,
              scripts: scripts,
              elements: elements,
              names: Jason.encode!(BubbleEx.Js.params())
            })
          )
      }
    else
      %{}
    end
  end

  @doc "Whether a surface of `spec` needs a Workflows module."
  @spec module?(Spec.t(), String.t()) :: boolean()
  def module?(%Spec{surfaces: surfaces} = spec, id) do
    case surfaces[id] do
      %{kind: :page} ->
        true

      %{workflows: w, states: s, inputs: i} = surface ->
        w != [] or s != [] or map_size(i) > 0 or Map.get(surface, :data, []) != [] or
          MapSet.member?(spec.data_index.roots, id)

      nil ->
        false
    end
  end

  # A repeating group whose cells hold instances, or `{outer, inner}` for
  # one rendered per cell of another (WTF-520).
  defp cells_key({outer, inner}), do: "{#{literal(outer)}, #{literal(inner)}}"
  defp cells_key(rg), do: literal(rg)

  # --- a surface's module -----------------------------------------------------------------

  defp surface_module(id, s, spec, ctx) do
    surface = spec.surfaces[id] || %{kind: s.kind, workflows: [], states: [], inputs: %{}}
    workflows = surface.workflows
    surface_map = surface_map(surface, s, spec)

    metas =
      Enum.map_join(workflows, ",\n", fn w ->
        "#{literal(w.workflow)} => #{meta_source(w)}"
      end)

    instances =
      for {scope, definition} <- Map.get(s, :instances, []),
          module = ctx.modules[definition],
          module != nil,
          do: "{#{literal(scope)}, #{module}}"

    # The instances rendered once per cell of a repeating group (WTF-494):
    # per repeating group, their scopes relative to the cell's, with their
    # nested instances'.
    cells =
      for {rg, entries} <- Map.get(s, :cells, []),
          listed =
            for(
              {scope, definition} <- entries,
              module = ctx.modules[definition],
              module != nil,
              do: "{#{literal(scope)}, #{module}}"
            ),
          listed != [],
          do: "{#{cells_key(rg)}, [#{Enum.join(listed, ", ")}]}"

    functions = Enum.map_join(workflows, "\n", &workflow_source(&1, s, spec, ctx))
    visible = visible_source(surface, s, spec)

    data = Map.get(surface, :data, [])
    data_functions = Enum.map_join(data, "\n", &data_source(&1, s, ctx))
    data_metas = Enum.map_join(data, ",\n", &data_meta(&1, s, ctx))

    uses_js? = Enum.any?(workflows, & &1.client?)

    queries? = queries?(data, workflows)

    """
    defmodule #{s.module} do
      @moduledoc #{literal(moduledoc(s))}

      alias #{ctx.module}.Workflows.Runtime, warn: false
      alias #{ctx.web}.BubbleWorkflows, warn: false
      alias #{ctx.web}.Bubble, warn: false
    #{if uses_js?, do: "  alias Phoenix.LiveView.JS\n", else: ""}#{if data != [] or queries?, do: "  alias #{ctx.web}.BubbleData, warn: false\n", else: ""}#{if queries?, do: "\n  require Ash.Query\n", else: ""}
      @surface #{surface_map}

      @workflows %{
    #{metas}
      }

      @instances [#{Enum.join(instances, ", ")}]

      @cells [#{Enum.join(cells, ", ")}]

      # The page data (WTF-420): the sources this surface loads, in order.
      @data [
    #{data_metas}
      ]

      @doc false
      def __bubble__(:surface), do: @surface
      def __bubble__(:workflows), do: @workflows
      def __bubble__(:instances), do: @instances
      def __bubble__(:cells), do: @cells
      def __bubble__(:data), do: @data

    #{functions}
    #{data_functions}#{visible}
    end
    """
  end

  # The visibility on the page of the reusable instances it renders whose
  # reusable element's workflows read it (WTF-605, `Spec`'s `visible`):
  # `__bubble_visible__(scope, ctx)`, by the instance's scope (listed in
  # `@instances`, from the page down), each level read in its host's
  # scope (the page's, or the instance holding it), the instance's own
  # visibility there and its host's. Nil for any other scope.
  defp visible_source(%{kind: :page}, s, spec) do
    chains =
      for {scope, _definition} <- Map.get(s, :instances, []),
          chain = scope_chain(scope),
          Enum.all?(chain, fn {_host, id} -> Map.has_key?(spec.visible, id) end),
          do: {scope, chain}

    if chains == [] do
      ""
    else
      levels =
        chains
        |> Enum.flat_map(fn {_scope, chain} -> chain end)
        |> Enum.uniq()
        |> Enum.with_index(1)

      names = Map.new(levels, fn {level, n} -> {level, "__visible_#{n}__"} end)

      clauses = Enum.map_join(chains, "\n", &visible_clause(&1, names))

      functions =
        Enum.map_join(levels, "\n", fn {{_host, id} = level, _n} ->
          visible_level(names[level], id, spec.visible[id].visible)
        end)

      """

        @doc \"\"\"
        Whether the reusable instance of `scope` is shown on the page
        (WTF-605): its own visibility and its hosts' up to the page,
        computed on the server, never taken from the browser. Nil for a
        scope the page does not compute.
        \"\"\"
        def __bubble_visible__(scope, ctx)
      #{clauses}
        def __bubble_visible__(_scope, _ctx), do: nil

      #{functions}
      """
    end
  end

  defp visible_source(_surface, _s, _spec), do: ""

  # A scope's clause: every level, in its host's scope.
  defp visible_clause({scope, chain}, names) do
    body =
      Enum.map_join(chain, " and\n      ", fn {host, _id} = level ->
        "#{names[level]}(BubbleWorkflows.host_ctx(ctx, #{literal(host)}))"
      end)

    "  def __bubble_visible__(#{literal(scope)}, ctx),\n    do:\n      #{body}\n"
  end

  # Instance `id`'s visibility on its host, a function of the host's
  # context.
  defp visible_level(name, id, value) do
    test =
      if value.source in ["true", "false"],
        do: value.source,
        else: "(#{value.source}) == true"

    """
      # The visibility of instance #{id} on its host
      defp #{name}(#{ctx_arg([value])}) do
      #{prelude([value])}  #{test}
      end
    """
  end

  # The instances of a scope from the page down (`Bubble.nest/2`'s
  # segments, `-` and `~` escaped), each with its host's scope.
  defp scope_chain(scope) do
    segments = String.split(scope, "-")

    segments
    |> Enum.with_index()
    |> Enum.map(fn {segment, i} ->
      host = segments |> Enum.take(i) |> Enum.join("-")
      {host, segment |> String.replace("~1", "-") |> String.replace("~0", "~")}
    end)
  end

  # What the page lets a browser trigger, and its first states and inputs.
  # The clicks and input changes of elements in a repeating group's cell
  # (WTF-520) are listed apart, with the repeating group: the browser's
  # event names the cell's scope, which the page accepts only for a cell
  # it read (`cell_lists`, the lists whose cells it keeps scopes for).
  defp surface_map(surface, s, spec) do
    {in_cells, wired} =
      surface.workflows
      |> Enum.filter(&Spec.wired?/1)
      |> Enum.split_with(&is_binary(Map.get(&1, :cell)))

    clicks =
      wired
      |> Enum.filter(&(&1.kind == :click and not &1.client? and is_binary(&1.element)))
      |> group(& &1.element)

    changes =
      wired
      |> Enum.filter(&(&1.kind == :input_change and is_binary(&1.element)))
      |> group(& &1.element)

    cell_clicks =
      in_cells
      |> Enum.filter(&(&1.kind == :click and not &1.client?))
      |> cell_group()

    cell_changes = in_cells |> Enum.filter(&(&1.kind == :input_change)) |> cell_group()
    cell_inputs = Map.get(s, :cell_inputs, %{})

    cell_lists =
      (Enum.map(in_cells, & &1.cell) ++ Enum.map(Map.values(cell_inputs), &elem(&1, 0)))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&{&1, Map.get(spec.data_index.nested_lists, &1)})

    intervals =
      for w <- wired, w.kind == :do_every, do: {w.workflow, interval_seconds(w.interval)}

    popups = popups(wired)

    states = for st <- surface.states, into: %{}, do: {{st.element, st.state}, st.default}

    """
    %{
    #{page_name(s)}  clicks: #{map_source(clicks)},
      changes: #{map_source(changes)},
      inputs: #{inputs_source(s.inputs)},
      loaded: #{source(for w <- wired, w.kind == :page_load, do: w.workflow)},
      conditions: #{source(for w <- wired, w.kind == :condition_true, do: {w.workflow, w.run_when})},
      intervals: #{intervals_source(intervals)},
      popups: #{popups_source(popups)},
      overlays: #{source(Map.get(s, :overlays, []))},
      states: #{states_source(states)},
      cell_clicks: #{cell_map_source(cell_clicks)},
      cell_changes: #{cell_map_source(cell_changes)},
      cell_inputs: #{cell_inputs_source(cell_inputs)},
      cell_lists: #{cell_lists_source(cell_lists)}#{page_width_source(surface, s)}#{publishers_source(surface)}
    }
    """
  end

  defp output_source(o),
    do:
      "{#{literal(o.name)}, #{literal(o.state)}, #{inspect(o.kind)}, #{o.list?}, " <>
        "#{o.resource || "nil"}}"

  # The surface's "Javascript to Bubble" publishers (WTF-608), listed only
  # when it has any: their suffix, the states each output sets (name,
  # state, kind, list?, the resource a thing is read as) and the event's
  # wired workflows.
  defp publishers_source(surface) do
    case Map.get(surface, :publishers, %{}) do
      none when none == %{} ->
        ""

      publishers ->
        wired = for w <- surface.workflows, Spec.wired?(w), into: MapSet.new(), do: w.workflow

        entries =
          Enum.map_join(Enum.sort(publishers), ", ", fn {element, p} ->
            outputs = Enum.map_join(p.outputs, ", ", &output_source/1)
            workflows = p.workflows |> Enum.filter(&MapSet.member?(wired, &1)) |> Enum.sort()

            "#{literal(element)} => %{suffix: #{literal(p.suffix)}, outputs: [#{outputs}], " <>
              "workflows: [#{Enum.map_join(workflows, ", ", &literal/1)}]}"
          end)

        ",\n  publishers: %{#{entries}}"
    end
  end

  # Whether the surface reads the viewport's width (WTF-520): a loaded
  # source or a wired workflow (a condition's included) binding it, or,
  # for a page, a binding of its templates or of a reusable element it
  # renders (`reads_width`: a visibility conditional, a text). Only then
  # does the page's hook report it, and the runtime read again on a
  # report; listed only when true.
  defp page_width_source(surface, s) do
    data = for d <- Map.get(surface, :data, []), d.residue == [], do: d
    wired = Enum.filter(surface.workflows, &Spec.wired?/1)

    if Map.get(s, :reads_width, false) or binds_page_width?(data) or binds_page_width?(wired),
      do: ",\n  page_width: true",
      else: ""
  end

  defp binds_page_width?(%{bind: :page_width}), do: true
  defp binds_page_width?(%_{} = struct), do: struct |> Map.from_struct() |> binds_page_width?()

  defp binds_page_width?(map) when is_map(map),
    do: Enum.any?(map, fn {_k, v} -> binds_page_width?(v) end)

  defp binds_page_width?(list) when is_list(list), do: Enum.any?(list, &binds_page_width?/1)

  defp binds_page_width?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> binds_page_width?()

  defp binds_page_width?(_term), do: false

  # Element => `{repeating group, workflow IDs}`.
  defp cell_group(workflows) do
    workflows
    |> Enum.group_by(&{&1.element, &1.cell}, & &1.workflow)
    |> Map.new(fn {{element, rg}, ids} -> {element, {rg, Enum.sort(ids)}} end)
  end

  # A Popup opened or closed (WTF-520), by the page's hook.
  defp popups(wired) do
    wired
    |> Enum.filter(&(&1.kind in [:popup_opened, :popup_closed] and is_binary(&1.element)))
    |> Enum.group_by(& &1.element)
    |> Map.new(fn {element, ws} ->
      {element,
       %{
         opened: for(w <- ws, w.kind == :popup_opened, do: w.workflow) |> Enum.sort(),
         closed: for(w <- ws, w.kind == :popup_closed, do: w.workflow) |> Enum.sort()
       }}
    end)
  end

  # A page's Bubble name: the first of its URL's path segments (WTF-508).
  defp page_name(%{kind: :page, name: name}) when is_binary(name) and name != "",
    do: "  name: #{literal(name)},\n"

  defp page_name(_surface), do: ""

  defp group(workflows, key) do
    workflows
    |> Enum.group_by(key, & &1.workflow)
    |> Map.new(fn {k, ids} -> {k, Enum.sort(ids)} end)
  end

  defp moduledoc(s) do
    what =
      if s.kind == :page,
        do: "the Bubble page #{s.label}",
        else: "the Bubble reusable element #{s.label}"

    "The workflows of #{what}. Scaffolded by bubble_ex (WTF-372); this file is yours: " <>
      "later generations never overwrite it. `__bubble__/1` is what a browser may trigger " <>
      "and what each workflow needs (see `BubbleWorkflows`); each workflow is marked " <>
      "`# bubble:workflow <id>` with one `# bubble:step N <type>` per Bubble action, and a " <>
      "`TODO(bubble:<id>)` step (listed in `blocked`) was not lowered: the workflow does not " <>
      "run until you implement it and remove it from `blocked`."
  end

  defp meta_source(w) do
    run = if w.client?, do: "nil", else: ":" <> w.fun

    condition =
      if w.kind == :condition_true and w.condition, do: ":#{w.fun}__condition", else: "nil"

    "%{run: #{run}, condition: #{condition}, blocked: #{source(Map.get(w, :blocked_by, []))}, " <>
      "data: #{w.data?}}"
  end

  # --- workflow functions -------------------------------------------------------------------

  defp workflow_source(%{client?: true} = w, _s, _spec, _ctx) do
    steps =
      Enum.map_join(w.steps, "", fn step ->
        "  # bubble:step #{step.index} #{marker(step.type)}\n" <>
          "  |> Bubble.#{client_op(step.op)}(#{scope_source(step.args.target.path, "scope")}, " <>
          "#{element_source(step.args.target.element)}#{animation_args(step)})\n"
      end)

    """
    # bubble:workflow #{marker(symbol_part(w.symbol))}
    @doc #{doc(w, "Runs in the browser: the element's `phx-click` calls it (no round trip).")}
    def #{w.fun}(js \\\\ %JS{}, scope) do
      js
    #{steps}end
    """
  end

  defp workflow_source(w, s, spec, ctx) do
    blocked? = w.residue != [] or Enum.any?(w.steps, &(&1.residue != []))
    event_todo = event_todo(w)

    condition =
      cond do
        w.kind == :condition_true -> "nil"
        w.condition -> "&#{w.fun}__condition/1"
        true -> "nil"
      end

    steps = Enum.map_join(w.steps, ", ", &"&#{w.fun}__step(#{&1.index}, &1)")

    note =
      cond do
        w.disabled? -> "Disabled in the Bubble editor: never triggered."
        blocked? -> "Not lowered completely (see `blocked`): the runtime does not run it."
        true -> nil
      end

    """
    # bubble:workflow #{marker(symbol_part(w.symbol))}
    @doc #{doc(w, note)}
    def #{w.fun}(ctx) do
    #{event_todo}  BubbleWorkflows.steps(ctx, #{condition}, [#{steps}])
    end
    #{condition_source(w, ctx)}#{Enum.map_join(w.steps, "", &step_source(&1, w, s, spec, ctx))}
    """
  end

  defp event_todo(%{residue: []}), do: ""

  defp event_todo(w) do
    reasons = w.residue |> Enum.map(&Atom.to_string(&1.reason)) |> Enum.uniq() |> Enum.join(", ")
    "  # TODO(bubble:#{comment(w.symbol)}) not lowered: #{reasons}\n"
  end

  # Whether a surface module reads a query: a page data source, or a
  # workflow's condition (WTF-564).
  defp queries?(data, workflows),
    do:
      Enum.any?(data, &Spec.reads_query?/1) or
        Enum.any?(workflows, &match?(%{condition: %{queries: [_ | _]}}, &1))

  defp condition_source(%{condition: nil}, _ctx), do: ""

  defp condition_source(w, ctx) do
    visibility = if w.kind == :condition_true, do: "@doc false\ndef", else: "defp"
    label = if w.kind == :condition_true, do: "Condition", else: "Only when"

    # A condition reading a search (WTF-564): its queries are read first,
    # as the condition is tested.
    {arg, body} =
      case w.condition do
        %{queries: [_ | _] = queries} = c ->
          {"ctx", "#{queries_source(queries, [c], ctx, nil, "", false)}  #{c.source}"}

        c ->
          {ctx_arg([c]), "#{prelude([c])}  #{c.source}"}
      end

    """

    # #{label}
    #{visibility} #{w.fun}__condition(#{arg}) do
    #{body}
    end
    """
  end

  defp step_source(%{residue: [_ | _]} = step, w, _s, _spec, _ctx) do
    reasons =
      step.residue |> Enum.map(&Atom.to_string(&1.reason)) |> Enum.uniq() |> Enum.join(", ")

    """

    # bubble:step #{step.index} #{marker(step.type || "unknown")}
    # TODO(bubble:#{comment(step.symbol)}) not lowered: #{reasons}
    defp #{w.fun}__step(#{step.index}, ctx),
      do: BubbleWorkflows.not_lowered(ctx, #{literal(step.bubble_id)}, #{literal(step.type || "")})
    """
  end

  defp step_source(step, w, s, spec, ctx) do
    call = op_source(step, s, spec, ctx)
    exprs = [step.condition | step_values(step)] |> Enum.reject(&is_nil/1)

    body =
      if step.condition,
        do: "if #{step.condition.source} do\n#{call}\nelse\nBubbleWorkflows.skip(ctx)\nend",
        else: call

    """

    # bubble:step #{step.index} #{marker(step.type)}
    defp #{w.fun}__step(#{step.index}, ctx) do
    #{prelude(exprs)}#{body}
    end
    """
  end

  defp step_values(step), do: Spec.step_values(step)

  defp op_source(%{op: op, args: args} = step, s, spec, ctx),
    do: op(op, args, literal(step.bubble_id), %{surface: s, spec: spec, ctx: ctx})

  defp op(op, args, _id, _env) when op in [:show, :hide, :toggle, :focus, :scroll_to],
    do:
      "BubbleWorkflows.element(ctx, #{literal(client_name(op))}, " <>
        "#{source(args.target.path)}, #{element_source(args.target.element)})"

  # An animation (WTF-603): the element's transition and motion, run by
  # the page's hook.
  defp op(:animate, args, _id, _env),
    do:
      "BubbleWorkflows.animate(ctx, #{source(args.target.path)}, " <>
        "#{element_source(args.target.element)}#{animation_args(%{op: :animate, args: args})})"

  defp op(:reset_group, args, _id, env),
    do: reset_source(args.target, env.surface, env.spec, env.ctx, Map.get(args, :clears, []))

  # "Display data" / "Display list" (WTF-492): kept per instance (and
  # cell), re-read as the current user when the page reads its data.
  defp op(op, args, id, env) when op in [:display_data, :display_list] do
    resource = if args.resource, do: "#{env.spec.namespace}.#{args.resource}", else: "nil"

    page_size = if args.list?, do: ", #{inspect(Map.get(args, :page_size))}", else: ""

    "BubbleWorkflows.display(ctx, #{id}, #{source(args.key.path)}, #{literal(args.key.element)}, " <>
      "#{args.cell?}, #{resource}, #{args.list?}, #{src(args.value)}#{page_size})"
  end

  defp op(:reset_inputs, args, _id, env),
    do: reset_source(args.within, env.surface, env.spec, env.ctx, [])

  defp op(:set_state, args, id, _env) do
    states =
      Enum.map_join(args.states, ", ", fn %{key: k, value: v} ->
        "{#{source(k.path)}, #{literal(k.element)}, #{literal(k.state)}, #{src(v)}}"
      end)

    "BubbleWorkflows.set_state(ctx, #{id}, [#{states}])"
  end

  defp op(:navigate, args, _id, env) do
    to = if args.page == :current, do: ":current", else: literal(page_path(args.page, env.ctx))
    params = Enum.map_join(args.params, ", ", fn p -> "{#{literal(p.key)}, #{src(p.value)}}" end)

    thing =
      case args do
        %{thing: nil} -> ""
        %{thing: value, untyped?: true} -> ", {:segment, #{src(value)}}"
        %{thing: value} -> ", #{src(value)}"
        _ -> ""
      end

    "BubbleWorkflows.navigate(ctx, #{to}, [#{params}], #{args.keep_params?}, " <>
      "#{args.replace?}, #{args.new_tab?}#{thing})"
  end

  defp op(:open_url, args, id, _env),
    do: "BubbleWorkflows.open_url(ctx, #{id}, #{src(args.url)}, #{args.new_tab?})"

  defp op(:refresh, _args, _id, _env), do: "BubbleWorkflows.refresh(ctx)"
  defp op(:log_out, _args, _id, _env), do: "BubbleWorkflows.log_out(ctx)"

  defp op(op, args, id, env) when op in [:call, :call_reusable] do
    path = if op == :call_reusable, do: [args.instance], else: []

    "BubbleWorkflows.call(ctx, #{id}, #{callee_module(args.callee, env.ctx)}, " <>
      "#{literal(args.callee.workflow)}, #{source(path)}, #{keyed(args.params, :param)})"
  end

  defp op(:schedule_custom, args, id, env),
    do:
      "BubbleWorkflows.schedule_custom(ctx, #{id}, #{callee_module(args.callee, env.ctx)}, " <>
        "#{literal(args.callee.workflow)}, [], #{src(args.delay)}, #{keyed(args.params, :param)})"

  # A page-only "Run javascript" (WTF-608): its inputs, computed here, go
  # to the page's scripts hook with the run's other browser steps.
  defp op(:run_js, args, id, _env) do
    params = Enum.map_join(args.params, ", ", fn p -> "{#{literal(p.name)}, #{src(p.value)}}" end)
    "BubbleWorkflows.script(ctx, #{id}, #{literal(args.script)}, [#{params}])"
  end

  defp op(:pause, args, id, _env),
    do: "BubbleWorkflows.pause(ctx, #{id}, #{src(args.length)})"

  defp op(:terminate, args, _id, _env),
    do: "BubbleWorkflows.terminate(ctx, #{keyed(args.returns, :return)})"

  defp op(:create, args, id, env),
    do:
      backend("Runtime.create(run, #{id}, #{resource(args, env.spec)}, #{changes(args.changes)})")

  defp op(:update, args, id, env),
    do:
      backend(
        "Runtime.update(run, #{id}, #{resource(args, env.spec)}, #{src(args.target)}, " <>
          "#{changes(args.changes)})"
      )

  defp op(:update_current_user, args, id, env),
    do:
      backend(
        "Runtime.update(run, #{id}, #{resource(args, env.spec)}, Runtime.actor(run, []), " <>
          "#{changes(args.changes)})"
      )

  defp op(:update_list, args, id, env),
    do:
      backend(
        "Runtime.update_list(run, #{id}, #{resource(args, env.spec)}, #{src(args.target)}, " <>
          "#{changes(args.changes)})"
      )

  defp op(:delete, args, id, _env), do: backend("Runtime.delete(run, #{id}, #{src(args.target)})")

  defp op(:delete_list, args, id, _env),
    do: backend("Runtime.delete_list(run, #{id}, #{src(args.target)})")

  defp op(:schedule, args, id, _env),
    do:
      backend(
        "Runtime.schedule(run, #{id}, #{literal(args.backend)}, #{src(args.at)}, " <>
          "#{keyed(args.params, :param)})"
      )

  defp op(:schedule_list, args, id, _env),
    do:
      backend(
        "Runtime.schedule_list(run, #{id}, #{literal(args.backend)}, #{src(args.at)}, " <>
          "#{src(args.list)}, #{src(args.interval)}, #{keyed(args.params, :param)})"
      )

  # An API Connector call (WTF-533): on the server, in the LiveView
  # process, through the backend workflow runtime; never data-gated.
  defp op(:api_call, args, id, env),
    do:
      "BubbleWorkflows.api(ctx, fn run -> " <>
        BubbleEx.Target.Phoenix.Workflows.api_call(args, id, env.spec.namespace, "run") <> " end)"

  # A step run on the backend workflow runtime (WTF-373).
  defp backend(call), do: "BubbleWorkflows.backend(ctx, fn run -> #{call} end)"

  # A whole instance or page resets from the page's first values; an
  # element's inputs are listed.
  # A reset group also clears what display steps showed in it (`clears`,
  # WTF-492); a reset instance everything shown in its scope.
  defp reset_source(nil, _s, _spec, _ctx, _clears), do: "BubbleWorkflows.reset(ctx, [], nil, [])"

  defp reset_source(%{path: path, element: :root}, _s, _spec, _ctx, :all),
    do: "BubbleWorkflows.reset(ctx, #{source(path)}, nil, [], :all)"

  defp reset_source(%{path: path, element: :root}, _s, _spec, _ctx, _clears),
    do: "BubbleWorkflows.reset(ctx, #{source(path)}, nil, [])"

  defp reset_source(%{path: [], element: element}, s, _spec, _ctx, clears) do
    within = for {input, containers} <- s.containers, element in containers, do: input
    within = if element in Map.keys(s.inputs), do: [element | within], else: within
    clears = if clears == [], do: "", else: ", #{source(Enum.sort(clears))}"

    "BubbleWorkflows.reset(ctx, [], #{literal(element)}, " <>
      "#{first_values(Enum.sort(Enum.uniq(within)), s.inputs)}#{clears})"
  end

  defp first_values(elements, inputs) do
    "[" <>
      Enum.map_join(elements |> Enum.sort(), ", ", fn e ->
        {_type, first} = inputs[e]
        "{#{literal(e)}, #{source(first)}}"
      end) <> "]"
  end

  defp callee_module(%{surface: surface}, ctx), do: ctx.modules[surface] || "nil"

  defp page_path(page, ctx) do
    case ctx.surfaces[page] do
      %{path: path} when is_binary(path) -> path
      _ -> "/"
    end
  end

  defp client_op(:scroll_to), do: "scroll_to"
  defp client_op(op), do: Atom.to_string(op)

  # An animation's transition (`:show`, `:hide` or nil: a callout) and
  # motion, after its element.
  defp animation_args(%{op: :animate, args: %{visibility: visibility, motion: motion}}),
    do: ", #{source(visibility)}, #{source(motion)}"

  defp animation_args(_step), do: ""

  defp client_name(:scroll_to), do: "scroll"
  defp client_name(op), do: Atom.to_string(op)

  defp element_source(:root), do: "nil"
  defp element_source(element), do: literal(element)

  # The scope of a target `path` below the variable `var`.
  defp scope_source([], var), do: var

  defp scope_source(path, var),
    do: Enum.reduce(path, var, fn id, acc -> "Bubble.nest(#{acc}, #{literal(id)})" end)

  defp resource(args, spec), do: "#{spec.namespace}.#{args.resource}"

  defp changes(changes) do
    "[" <>
      Enum.map_join(changes, ", ", fn c ->
        "{#{inspect(c.op)}, #{atom(c.attribute)}, #{change_value(c)}}"
      end) <> "]"
  end

  defp change_value(%{op: :clear_list}), do: "nil"
  defp change_value(%{ref: :one, value: v}), do: "Runtime.id(#{src(v)})"

  defp change_value(%{ref: :many, op: op, value: v}) when op in [:add, :remove],
    do: "Runtime.id(#{src(v)})"

  defp change_value(%{ref: :many, value: v}), do: "Runtime.ids(#{src(v)})"
  defp change_value(%{value: v}), do: src(v)

  defp keyed(entries, key) do
    "%{" <>
      Enum.map_join(entries, ", ", fn e -> "#{literal(Map.fetch!(e, key))} => #{src(e.value)}" end) <>
      "}"
  end

  defp src(nil), do: "nil"
  defp src(%{source: source}), do: "(" <> source <> ")"

  # The variables the expressions read, bound from the context (each once,
  # with the union of the relationship loads its uses need).
  defp prelude(exprs, cell_preloaded? \\ false, page_data? \\ false) do
    exprs
    |> Enum.flat_map(& &1.bindings)
    # What a source reads first (a query, an API Connector call) is bound
    # where it is read.
    |> Enum.reject(&match?(%{bind: {kind, _}} when kind in [:query, :api_data], &1))
    |> Enum.group_by(& &1.var)
    |> Enum.sort()
    |> Enum.map_join(fn {var, [b | _] = bs} ->
      loads = bs |> Enum.flat_map(& &1.loads) |> Enum.uniq() |> Enum.sort()

      "  #{var} = #{prelude_binding(b.bind, loads, cell_preloaded?, page_data?)}\n"
    end)
  end

  defp prelude_binding({:cell, _}, _loads, true, _page_data?), do: "ctx.cell"

  # The outer cell's thing (WTF-520): the loader loads what any part of a
  # source reads through it for every outer cell first (`outer_loads`).
  defp prelude_binding({:outer_cell, _}, _loads, _cell_preloaded?, true),
    do: "BubbleWorkflows.outer_cell(ctx)"

  defp prelude_binding(bind, loads, _cell_preloaded?, true),
    do: page_loaded(binding(bind, []), loads)

  defp prelude_binding(bind, loads, _cell_preloaded?, false), do: binding(bind, loads)

  defp ctx_arg(exprs),
    do: if(Enum.flat_map(exprs, & &1.bindings) == [], do: "_ctx", else: "ctx")

  defp binding(:actor, loads), do: "BubbleWorkflows.actor(ctx, #{loads_source(loads)})"

  # The instance's visibility on the page (WTF-605), which the page
  # computes (`__bubble_visible__/2`).
  defp binding({:instance_visible, _}, _loads), do: "BubbleWorkflows.instance_visible(ctx)"
  defp binding(:now, _loads), do: "ctx.now"
  defp binding(:page_width, _loads), do: "ctx.page_width"

  defp binding({:param, id}, loads),
    do: "BubbleWorkflows.param(ctx, #{literal(id)}, #{loads_source(loads)})"

  defp binding({:step, id}, loads),
    do: "BubbleWorkflows.step(ctx, #{literal(id)}, #{loads_source(loads)})"

  defp binding({:step_return, r}, loads),
    do:
      "BubbleWorkflows.step_return(ctx, #{literal(r.step)}, #{literal(r.return)}, " <>
        "#{r.resource || "nil"}, #{r.list?}, #{loads_source(loads)})"

  defp binding({:url, name}, _loads), do: "BubbleWorkflows.url(ctx, #{literal(name)})"

  defp binding({:url_value, u}, _loads),
    do: "BubbleWorkflows.url_value(ctx, #{url_source(u)}, #{literal(u.type)})"

  # A thing whose unique ID is in the URL, read through Ash as the actor.
  defp binding({:url_thing, u}, loads),
    do: "BubbleWorkflows.url_thing(ctx, #{url_source(u)}, #{u.resource}, #{loads_source(loads)})"

  defp binding({:state, k}, []),
    do:
      "BubbleWorkflows.state(ctx, #{source(k.path)}, #{literal(k.element)}, #{literal(k.state)})"

  defp binding({:state, k}, loads),
    do: "BubbleWorkflows.load(#{binding({:state, k}, [])}, #{loads_source(loads)}, ctx)"

  # A Dropdown of things (WTF-596) holds a record: what is read through it
  # is loaded as for the page's data.
  defp binding({:input, k}, loads),
    do: page_loaded("BubbleWorkflows.input(ctx, #{source(k.path)}, #{literal(k.element)})", loads)

  # An input in the workflow's cell (WTF-520): that cell's value.
  defp binding({:cell_input, k}, _loads),
    do: "BubbleWorkflows.cell_input(ctx, #{literal(k.element)})"

  # The page's data (WTF-420).
  defp binding({:data, k}, loads),
    do:
      page_loaded(
        "BubbleWorkflows.data(ctx, #{source(k.path)}, #{literal(k.element)})",
        loads
      )

  defp binding({:cell, _rg}, loads), do: page_loaded("ctx.cell", loads)
  defp binding({:cell_index, _rg}, _loads), do: "ctx.cell_index"

  defp binding({:cell_data, g}, loads),
    do: page_loaded("BubbleWorkflows.cell_data(ctx, #{literal(g)})", loads)

  # In a nested repeating group's cell (WTF-520): the outer cell's.
  defp binding({:outer_cell, _rg}, loads),
    do: page_loaded("BubbleWorkflows.outer_cell(ctx)", loads)

  defp binding({:outer_cell_index, _rg}, _loads), do: "BubbleWorkflows.outer_cell_index(ctx)"

  defp binding({:outer_cell_data, g}, loads),
    do: page_loaded("BubbleWorkflows.outer_cell_data(ctx, #{literal(g)})", loads)

  # Which part of the URL a typed read reads (`Spec.url/1`).
  defp url_source(%{path: nil, name: name}), do: "{:query, #{literal(name)}}"
  defp url_source(%{path: "segments"}), do: ":segments"
  defp url_source(%{path: "first"}), do: ":first"

  defp page_loaded(value, []), do: value

  defp page_loaded(value, loads),
    do: "BubbleData.load_value(#{value}, #{loads_source(loads)}, ctx)"

  # Relationship paths as names (strings), as the backend's printer:
  # `Runtime.load/3` turns them into existing atoms.
  defp loads_source(loads), do: source(loads)

  # --- page data (WTF-420) --------------------------------------------------------------------

  # A source's entry in `__bubble__(:data)`: its element, function (nil
  # when not loaded: `blocked` says why), how it reads, where a cell's
  # value goes, the relationships the page's bindings read through it
  # (`loads`, from the pages), its change topic (its resource's name), the
  # inputs it reads (`inputs`) and the page data it reads (`reads`, element
  # IDs): an input change reads again only the sources that read the input,
  # and those reading them, transitively (WTF-475).
  defp data_meta(d, s, ctx) do
    fun = if d.residue == [] and d.read != :displayed, do: ":" <> data_fun(d), else: "nil"

    loads = Map.get(Map.get(s, :loads, %{}), data_key_element(d), [])
    topic = if d.resource && d.residue == [], do: literal(d.resource), else: "nil"

    "%{element: #{literal(data_key_element(d))}, fun: #{fun}, read: #{data_read_kind(d.read)}, " <>
      "instance: #{data_instance(d)}, " <>
      "cell: #{if d.cell, do: literal(d.cell), else: "nil"}, " <>
      "#{outer_meta(d)}" <>
      "loads: #{source(loads)}, cell_loads: #{source(cell_loads(d.read))}, " <>
      "#{outer_loads_meta(d)}topic: #{topic}, " <>
      "inputs: #{source(data_inputs(d.read, ctx))}, reads: #{source(data_reads(d))}, " <>
      "deps: #{source(data_deps(d))}, " <>
      "blocked: #{source(Enum.uniq(Enum.map(d.residue, & &1.subject)))}" <>
      "#{display_meta(d)}#{data_default(d)}#{batch_meta(d, s)}#{query_topics(d)}" <>
      "#{cell_reads_meta(d)}}"
  end

  # A source in a nested repeating group's cell (WTF-520): the outer
  # repeating group, whose cells hold the inner one's.
  defp outer_meta(%{outer: outer}) when is_binary(outer), do: "outer: #{literal(outer)}, "
  defp outer_meta(_d), do: ""

  # A source whose searches read the cell are read for every cell together
  # (WTF-520): the loader collects each cell's search first, then reads
  # them in one query per round (`BubbleData.cell_read/4`).
  defp cell_reads_meta(%{residue: []} = d),
    do: if(Spec.cell_reads?(d), do: ", cell_reads: true", else: "")

  defp cell_reads_meta(_d), do: ""

  # The resources the queries a value reads first search (WTF-495): their
  # changes read it again, whatever its own type.
  defp query_topics(d) do
    case query_resources(d) do
      [] -> ""
      resources -> ", query_topics: #{source(resources)}"
    end
  end

  @doc """
  The resources (relative modules) the queries of page data source `d`
  search first (WTF-495), sorted: their changes read it again, whatever
  its own type, so they publish them (`BubbleEx.Target.Phoenix`).
  """
  @spec query_resources(map()) :: [String.t()]
  def query_resources(%{residue: [], read: read}) do
    queries =
      case read do
        {:value, v} -> Map.get(v, :queries, [])
        {:query, q} -> Map.get(q, :queries, [])
        # A conditional source (WTF-521): every branch's and condition's.
        {:switch, sw} -> Enum.flat_map(Spec.switch_reads(sw), &switch_queries/1)
        _ -> []
      end

    queries |> Enum.map(& &1.resource) |> Enum.uniq() |> Enum.sort()
  end

  def query_resources(_d), do: []

  defp switch_queries({:query, q}), do: [q | Map.get(q, :queries, [])]
  defp switch_queries({:value, v}), do: Map.get(v, :queries, [])

  # How a source is read for every cell of a repeating group together
  # (WTF-494): a reusable element's sources (its instances in cells) and a
  # page's sources in a cell. One that reads nothing of its scope is read
  # once (`shared`); what its value loads through what it reads is loaded
  # for every cell first (`preloads`).
  defp batch_meta(d, s) do
    shared = if s.kind == :reusable and Map.get(d, :shared?, false), do: ", shared: true"
    preloads = if s.kind == :reusable or d.cell != nil, do: preloads_meta(d)
    "#{shared}#{preloads}"
  end

  # The relationships a source's value loads through what it reads
  # (WTF-494): loaded for every cell together before it runs in each.
  defp preloads_meta(%{residue: []} = d) do
    preloads =
      d.read
      |> read_bindings()
      |> Enum.flat_map(fn
        %{loads: []} -> []
        %{bind: :actor, loads: loads} -> [{[:actor], loads}]
        %{bind: {:data, k}, loads: loads} -> [{[:data, k.path, k.element], loads}]
        %{bind: {:state, k}, loads: loads} -> [{[:state, k.path, k.element, k.state], loads}]
        %{bind: {:cell_data, g}, loads: loads} -> [{[:cell_data, g], loads}]
        %{bind: {:outer_cell_data, g}, loads: loads} -> [{[:outer_cell_data, g], loads}]
        _ -> []
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {what, loads} ->
        List.to_tuple(what ++ [loads |> Enum.concat() |> Enum.uniq() |> Enum.sort()])
      end)
      |> Enum.sort()

    if preloads == [], do: "", else: ", preloads: #{source(preloads)}"
  end

  defp preloads_meta(_d), do: ""

  # An element a "Display data" step sets (WTF-492): what the step showed
  # wins over its own source until a reset; with no source of its own
  # (`read: :displayed`), it shows only that.
  # A popup kept although workflows that do not run here may display data
  # in it while it is open (WTF-520) lists them (`not_run`, Bubble IDs).
  defp display_meta(%{displayed?: true, not_run: [_ | _] = ids} = d),
    do: ", display: %{page_size: #{inspect(d.page_size)}, not_run: #{inspect(ids)}}"

  defp display_meta(%{displayed?: true} = d),
    do: ", display: %{page_size: #{inspect(d.page_size)}}"

  defp display_meta(_d), do: ""

  # A reusable element property's default (WTF-493): read only where the
  # instance sets no value.
  defp data_default(%{kind: :param, element: e, holder: e}), do: ", default: true"
  defp data_default(_d), do: ""

  # What a source reading the viewport's width (`Current page width`)
  # names among its inputs: no element's Bubble ID has a space, so the
  # runtime reads it again when the width changes, as for an input.
  @page_width_input "Current Page Width"

  # The input elements a source's value or search constraints read (and
  # the viewport's width, `@page_width_input`).
  defp data_inputs(read, ctx) do
    read
    |> read_bindings()
    |> Enum.flat_map(fn
      %{bind: {:input, %{element: e}}} -> [e]
      %{bind: :page_width} -> [@page_width_input]
      _ -> []
    end)
    |> Kernel.++(api_inputs(read, ctx))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The API Connector calls a source makes (WTF-533), as its inputs: when
  # one ends, the page reads again only what reads it
  # (`BubbleData.api_done/3`, the same names).
  defp api_inputs({:value, v}, ctx),
    do: for(c <- Map.get(v, :calls, []), do: "API #{ctx.module}.#{c.module}.#{c.function}")

  defp api_inputs({:switch, sw}, ctx),
    do: sw |> Spec.switch_reads() |> Enum.flat_map(&api_inputs(&1, ctx))

  defp api_inputs(_read, _ctx), do: []

  defp read_bindings({:value, %{bindings: bindings} = v}),
    do:
      bindings ++
        Enum.flat_map(Map.get(v, :queries, []), &pin_bindings/1) ++
        Enum.flat_map(call_values(v), & &1.bindings)

  defp read_bindings({:query, q}),
    do: pin_bindings(q) ++ Enum.flat_map(Map.get(q, :queries, []), &pin_bindings/1)

  # A conditional source (WTF-521): what its conditions and branches read.
  defp read_bindings({:switch, sw}), do: Enum.flat_map(Spec.switch_reads(sw), &read_bindings/1)

  defp read_bindings(_), do: []

  defp pin_bindings(%{pins: pins}),
    do: for(%{value: %{bindings: bindings}} <- pins, b <- bindings, do: b)

  # The page data a source reads, as the elements it is kept under (an
  # instance's thing under its instance and its reusable element).
  defp data_reads(d) do
    d
    |> Map.get(:reads, [])
    |> Enum.flat_map(fn
      {:data, %{path: path, element: e}} -> [e | path]
      {_kind, e} when is_binary(e) -> [e]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # What a source reads of the page's data, as the loader finds who keeps
  # it (WTF-520): `{:data, path, element}` (kept under `element`, `path`
  # instances below the scope the source runs in: possibly a value
  # another surface computes, an instance's default), `{:cell, rg}` (a
  # repeating group's list, for its cells) or `{:cell_data, group}` (a
  # group's value per cell). The loader reads a source after those that
  # keep what it reads, across surfaces.
  #
  # In a nested repeating group's cell (WTF-520, `outer`), the inner list
  # is a value per outer cell (`{:cell_data, inner}`), and what the outer
  # cell holds is the outer list's and its cells'.
  defp data_deps(d) do
    outer = Map.get(d, :outer)

    d
    |> Map.get(:reads, [])
    |> Enum.flat_map(fn
      {:data, %{path: path, element: e}} ->
        [{:data, path, e}]

      {kind, rg} when kind in [:cell, :cell_index] and is_binary(outer) ->
        [{:cell_data, rg}]

      {kind, rg} when kind in [:cell, :cell_index, :outer_cell, :outer_cell_index] ->
        [{:cell, rg}]

      {kind, g} when kind in [:cell_data, :outer_cell_data] ->
        [{:cell_data, g}]

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp data_read_kind(:url_thing), do: ":url_thing"
  defp data_read_kind(:displayed), do: ":displayed"
  defp data_read_kind({:query, _}), do: ":query"
  # A value over queries (WTF-495) follows their type's changes too.
  defp data_read_kind({:value, %{queries: [_ | _]}}), do: ":query"

  defp data_read_kind({:switch, _} = read),
    do: if(Spec.reads_query?(%{read: read}), do: ":query", else: ":value")

  defp data_read_kind(_), do: ":value"

  defp data_instance(%{kind: :instance, element: element}), do: literal(element)
  defp data_instance(%{kind: :param, element: e, holder: h}) when e != h, do: literal(e)
  defp data_instance(_), do: "nil"

  # The relationships a cell's source reads through the cell's thing (its
  # value's, its searches' pins' and its calls' parameters': WTF-593, a
  # search read for every cell together pins what each cell's thing
  # holds), loaded for every cell at once.
  defp cell_loads(read) do
    for(%{bind: {:cell, _}, loads: paths} <- read_bindings(read), path <- paths, do: path)
    |> Enum.uniq()
  end

  # In a nested repeating group's cell (WTF-520): the relationships read
  # through the outer cell's thing, loaded for every outer cell at once.
  defp outer_loads_meta(%{residue: [], read: read}) do
    loads =
      for %{bind: {:outer_cell, _}, loads: paths} <- read_bindings(read),
          path <- paths,
          uniq: true,
          do: path

    if loads == [], do: "", else: "outer_loads: #{source(Enum.sort(loads))}, "
  end

  defp outer_loads_meta(_d), do: ""

  # Where a source's value is kept: an instance's under its scope and
  # reusable element (see `BubbleWorkflows.data/3`), the others under
  # their element.
  defp data_key_element(%{kind: :instance, holder: holder}) when is_binary(holder), do: holder
  defp data_key_element(%{kind: :param, key: %{element: key}}), do: key
  # A Dropdown's choices (WTF-596), beside its default under the element.
  defp data_key_element(%{kind: :choices, key: %{element: key}}), do: key
  defp data_key_element(d), do: d.element

  defp data_fun(%{kind: :param} = d), do: "data_" <> fun_part(d.element <> " " <> d.param)
  defp data_fun(%{kind: :choices} = d), do: "data_" <> fun_part(d.element <> " choices")
  defp data_fun(d), do: "data_" <> fun_part(d.element)

  # A property's value is marked with its element and property (WTF-493).
  defp data_marker(%{kind: :param, element: e, param: p}), do: marker(e) <> " " <> marker(p)
  defp data_marker(%{kind: :choices, element: e}), do: marker(e) <> " choices"
  defp data_marker(d), do: marker(d.element)

  defp fun_part(id) do
    id
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> then(&if(&1 == "", do: "x", else: &1))
    |> Kernel.<>("_" <> short_hash(id))
  end

  defp short_hash(id),
    do: :crypto.hash(:sha256, id) |> Base.encode16(case: :lower) |> binary_part(0, 8)

  defp data_source(%{residue: [_ | _]} = d, _s, _ctx) do
    reasons = d.residue |> Enum.map(&Atom.to_string(&1.reason)) |> Enum.uniq() |> Enum.join(", ")

    """
    # bubble:data #{data_marker(d)}
    # TODO(bubble:#{comment(d.symbol)}) not loaded: #{reasons}
    """
  end

  defp data_source(%{read: :displayed} = d, _s, _ctx) do
    """
    # bubble:data #{marker(d.element)}
    # Shown by a "Display data" step (no data source of its own): see BubbleData.
    """
  end

  # A conditional source (WTF-521): the conditions tested in order, the
  # last state first, and only the winning branch read (or the base), each
  # a function of its own.
  defp data_source(%{read: {:switch, sw}} = d, _s, ctx) do
    fun = data_fun(d)
    n = length(sw.cases)

    clauses =
      sw.cases
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {_case, i} ->
        "    #{fun}_when_#{i}(ctx) == true -> #{fun}_then_#{i}(ctx)\n"
      end)

    parts =
      sw.cases
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {c, i} ->
        data_part("#{fun}_when_#{i}", condition_body(c.when, ctx)) <>
          data_part("#{fun}_then_#{i}", read_body(c.then, d, ctx))
      end)

    """
    # bubble:data #{data_marker(d)}
    # Of #{n} conditional state#{if n == 1, do: "", else: "s"}, the last whose condition is yes wins, else the base (WTF-521).
    @doc false
    def #{fun}(ctx) do
      cond do
    #{clauses}    true -> #{fun}_else(ctx)
      end
    end
    #{parts}#{data_part("#{fun}_else", read_body(sw.else, d, ctx))}
    """
  end

  defp data_source(d, _s, ctx) do
    body =
      case d.read do
        :url_thing -> "BubbleData.url_thing(ctx, #{ctx.module}.#{d.resource})"
        read -> read_body(read, d, ctx)
      end

    arg = if String.contains?(body, "ctx"), do: "ctx", else: "_ctx"

    """
    # bubble:data #{data_marker(d)}
    @doc false
    def #{data_fun(d)}(#{arg}) do
      #{body}
    end
    """
  end

  defp data_part(name, body) do
    arg = if String.contains?(body, "ctx"), do: "ctx", else: "_ctx"

    """

    defp #{name}(#{arg}) do
      #{body}
    end
    """
  end

  # What a source's read evaluates to.
  defp read_body({:value, %{queries: [_ | _] = queries} = v}, d, ctx) do
    resource = if d.resource, do: "#{ctx.module}.#{d.resource}", else: "nil"

    "#{queries_source(queries, [v | call_values(v)], ctx, nil, calls_source(v, ctx))}BubbleData.records(ctx, #{resource}, (#{v.source}), #{d.list?}, #{inspect(d.page_size)})"
  end

  defp read_body({:value, v}, d, ctx) do
    resource = if d.resource, do: "#{ctx.module}.#{d.resource}", else: "nil"

    "#{prelude([v | call_values(v)], d.cell != nil, true)}#{calls_source(v, ctx)}BubbleData.records(ctx, #{resource}, (#{v.source}), #{d.list?}, #{inspect(d.page_size)})"
  end

  defp read_body({:query, q}, d, ctx), do: query_source(q, d, ctx)

  # A conditional state's condition: a value, yes only when it is yes.
  defp condition_body({:value, %{queries: [_ | _] = queries} = v}, ctx),
    do:
      "#{queries_source(queries, [v | call_values(v)], ctx, nil, calls_source(v, ctx))}(#{v.source})"

  defp condition_body({:value, v}, ctx),
    do: "#{prelude([v | call_values(v)], false, true)}#{calls_source(v, ctx)}(#{v.source})"

  # The API Connector calls a value reads first (WTF-533): each made with
  # its generated client through `BubbleData.api/4` (once per read of the
  # page's data for the same values), after the page values its
  # parameters read, before the queries and the value.
  defp call_values(v), do: for(c <- Map.get(v, :calls, []), p <- c.params, do: p.value)

  defp calls_source(v, ctx) do
    Enum.map_join(Map.get(v, :calls, []), "", fn c ->
      params =
        "%{" <> Enum.map_join(c.params, ", ", &"#{atom(&1.key)} => (#{&1.value.source})") <> "}"

      opts = if Map.get(c, :cache?, true), do: "", else: ", cache: false"

      "api_data_#{c.n} = BubbleData.api(ctx, #{ctx.module}.#{c.module}, #{atom(c.function)}, #{params}#{opts})\n"
    end)
  end

  defp query_source(%{queries: [_ | _] = queries} = q, d, ctx) do
    """
    #{queries_source(queries, [], ctx, q)}#{query_read(q, d.page_size, [], ctx)}
    """
  end

  defp query_source(q, d, ctx) do
    values = for %{value: %{bindings: _} = v} <- q.pins, do: v

    """
    #{prelude(values, false, true)}#{pins_source(q)}#{query_read(q, d.page_size, [], ctx)}
    """
  end

  # A query read: through `BubbleData.read/4`, or, read for every cell
  # together (WTF-520), through `BubbleData.cell_read/4`: in each cell the
  # query of that cell, and the query of every cell at once (its keys
  # compared with every cell's values), which the loader reads first.
  defp query_read(%{batch: batch} = q, page_size, loads, ctx) do
    vars = Enum.map(q.pins, & &1.var)
    pins = "%{" <> Enum.map_join(vars, ", ", &"#{&1}: #{&1}") <> "}"

    keys =
      "[" <>
        Enum.map_join(batch.keys, ", ", fn k ->
          "{:#{k.var}, #{atom(k.attr)}, #{key_kind(k, ctx)}, #{if k.unless, do: ":" <> k.unless, else: "nil"}}"
        end) <> "]"

    # Each cell's own record left out after the batch (WTF-593).
    excludes =
      "[" <>
        Enum.map_join(Map.get(batch, :excludes, []), ", ", fn x ->
          "{:#{x.var}, #{atom(x.attr)}, #{inspect(x.kind)}, #{if x.unless, do: ":" <> x.unless, else: "nil"}}"
        end) <> "]"

    # The batch reads no exclusion: its pins (and their empty guards) only
    # the cell's own query reads are not bound there.
    used = MapSet.new(filter_pins(batch.filter.expr) ++ List.wrap(Map.get(q, :listed)))

    batch_pins =
      "%{" <>
        Enum.map_join(vars, ", ", fn v ->
          if MapSet.member?(used, v), do: "#{v}: #{v}", else: "#{v}: _#{v}"
        end) <> "}"

    sort =
      "[" <>
        Enum.map_join(q.sort, ", ", fn {a, _dir} -> atom(a) end) <> "]"

    # The whole search: two that differ only in their sort, take, list or
    # exclusions (WTF-593: not in the batched filter) are never one.
    whole =
      case Map.get(batch, :excludes, []) do
        [] ->
          {q.resource, batch.filter, q.sort, q.take, Map.get(q, :listed), page_size, loads}

        excludes ->
          {q.resource, q.filter, excludes, q.sort, q.take, Map.get(q, :listed), page_size, loads}
      end

    ref =
      whole
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    """
    BubbleData.cell_read(
      ctx,
      %{
        ref: {__MODULE__, #{literal(binary_part(ref, 0, 12))}},
        pins: #{pins},
        keys: #{keys},
        excludes: #{excludes},
        void: [#{Enum.map_join(Map.get(batch, :void, []), ", ", fn {v, w} -> "{:#{v}, :#{w}}" end)}],
        sort: #{sort},
        take: #{take(q.take)},
        page_size: #{inspect(page_size)},
        loads: #{loads_source(loads)}
      },
      fn ->
        #{query_pipeline(q, ctx)}
      end,
      fn #{batch_pins} ->
        #{query_pipeline(%{q | filter: batch.filter}, ctx, :batch)}
      end
    )
    """
    |> String.trim_trailing()
  end

  defp query_read(q, page_size, loads, ctx) do
    read =
      "#{query_pipeline(q, ctx)}\n|> BubbleData.read(ctx, #{take(q.take)}, #{inspect(page_size)})"

    case loads do
      [] -> read
      l -> "BubbleData.load_value(#{read}, #{loads_source(l)}, ctx)"
    end
  end

  # The pins a filter reads.
  defp filter_pins({:pin, var}), do: [var]
  defp filter_pins(node) when is_tuple(node), do: node |> Tuple.to_list() |> filter_pins()
  defp filter_pins(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &filter_pins/1)
  defp filter_pins(_node), do: []

  # An option's key (WTF-589) names its option set's enum: a cell whose
  # value is not one of the set's reads its own query.
  defp key_kind(%{kind: :eq, enum: enum}, ctx) when is_binary(enum),
    do: "{:eq, #{ctx.module}.#{enum}}"

  defp key_kind(%{kind: kind}, _ctx), do: inspect(kind)

  # The queries a source reads first (WTF-495: searches under list
  # operators), in order, after the page values they all read; `values`
  # (and the source's own query `q`) read them as `query_<n>`.
  # A workflow's condition (`page_data?` false) binds the page values as
  # its steps do.
  defp queries_source(queries, values, ctx, q, calls \\ "", page_data? \\ true) do
    pinned = for x <- queries ++ List.wrap(q), %{value: %{bindings: _} = v} <- x.pins, do: v
    all = values ++ pinned

    page =
      Enum.map(all, fn v ->
        %{v | bindings: Enum.reject(v.bindings, &match?(%{bind: {:query, _}}, &1))}
      end)

    loads =
      for v <- all, %{bind: {:query, n}, loads: l} <- v.bindings, path <- l, reduce: %{} do
        acc -> Map.update(acc, n, [path], &Enum.uniq([path | &1]))
      end

    reads =
      Enum.map_join(queries, "", fn x ->
        n = Integer.to_string(x.n)
        read = query_read(x, nil, Enum.sort(Map.get(loads, n, [])), ctx)
        "#{pins_source(x)}query_#{n} = #{read}\n"
      end)

    "#{prelude(page, false, page_data?)}#{calls}#{reads}#{if q, do: pins_source(q), else: ""}"
  end

  defp pins_source(q) do
    Enum.map_join(q.pins, "", fn
      %{var: var, value: {:actor, path}} ->
        "#{var} = BubbleData.actor(ctx, #{source(path)}, #{source(q.actor_loads)})\n"

      # A list's things' IDs, each once, bounded (WTF-495).
      %{var: var, value: v, ref: :listed} ->
        "#{var} = BubbleData.listed_ids((#{v.source}))\n"

      %{var: var, value: v, ref: ref} ->
        "#{var} = BubbleData.pin((#{v.source}), #{inspect(ref)})\n"
    end)
  end

  defp query_pipeline(q, ctx, mode \\ :one) do
    sort =
      case q.sort do
        [] ->
          ""

        [:random] ->
          "\n|> BubbleData.random_sort()"

        sort ->
          "\n|> Ash.Query.sort([#{Enum.map_join(sort, ", ", fn {a, dir} -> "{#{atom(a)}, #{inspect(dir)}}" end)}])"
      end

    # A list's own records (WTF-495): read as the user may view them.
    listed =
      case Map.get(q, :listed) do
        var when is_binary(var) and mode == :batch -> "\n|> BubbleData.listed_batch(#{var})"
        var when is_binary(var) -> "\n|> BubbleData.listed(#{var})"
        _ -> ""
      end

    "#{ctx.module}.#{q.resource}\n|> Ash.Query.filter(#{Source.filter(q.filter)})#{sort}#{listed}"
  end

  defp take({kind, n}), do: "{#{inspect(kind)}, #{n}}"
  defp take(kind), do: inspect(kind)

  defp interval_seconds(%{source: source, bindings: []}), do: {:source, source}
  defp interval_seconds(_), do: nil

  defp intervals_source(intervals) do
    "[" <>
      Enum.map_join(intervals, ", ", fn
        {id, {:source, source}} -> "{#{literal(id)}, (#{source})}"
        {id, nil} -> "{#{literal(id)}, nil}"
      end) <> "]"
  end

  defp map_source(map) do
    "%{" <>
      Enum.map_join(Enum.sort(map), ", ", fn {k, ids} ->
        "#{literal(k)} => [#{Enum.map_join(ids, ", ", &literal/1)}]"
      end) <> "}"
  end

  defp popups_source(popups) do
    "%{" <>
      Enum.map_join(Enum.sort(popups), ", ", fn {e, %{opened: opened, closed: closed}} ->
        "#{literal(e)} => %{opened: [#{Enum.map_join(opened, ", ", &literal/1)}], " <>
          "closed: [#{Enum.map_join(closed, ", ", &literal/1)}]}"
      end) <> "}"
  end

  defp inputs_source(inputs) do
    "%{" <>
      Enum.map_join(Enum.sort(inputs), ", ", fn {e, {type, first}} ->
        "#{literal(e)} => {#{inspect(type)}, #{source(first)}}"
      end) <> "}"
  end

  defp cell_map_source(map) do
    "%{" <>
      Enum.map_join(Enum.sort(map), ", ", fn {e, {rg, ids}} ->
        "#{literal(e)} => {#{literal(rg)}, [#{Enum.map_join(ids, ", ", &literal/1)}]}"
      end) <> "}"
  end

  defp cell_inputs_source(inputs) do
    "%{" <>
      Enum.map_join(Enum.sort(inputs), ", ", fn {e, {rg, {type, first}}} ->
        "#{literal(e)} => {#{literal(rg)}, {#{inspect(type)}, #{source(first)}}}"
      end) <> "}"
  end

  defp cell_lists_source(lists) do
    "[" <>
      Enum.map_join(lists, ", ", fn
        {rg, nil} -> "{#{literal(rg)}, nil}"
        {rg, outer} -> "{#{literal(rg)}, #{literal(outer)}}"
      end) <> "]"
  end

  defp states_source(states) do
    "%{" <>
      Enum.map_join(Enum.sort(states), ", ", fn {{e, st}, default} ->
        "{#{literal(e)}, #{literal(st)}} => #{default || "nil"}"
      end) <> "}"
  end

  # --- tests --------------------------------------------------------------------------------

  defp tests(spec, ctx) do
    # The first page rendering each reusable element, with the scope.
    renders =
      ctx.surfaces
      |> Enum.sort()
      |> Enum.flat_map(fn {page, s} ->
        for {scope, definition} <- Map.get(s, :instances, []),
            s.kind == :page,
            do: {definition, {page, scope}}
      end)
      |> Enum.reverse()
      |> Map.new()

    tests =
      spec
      |> Spec.workflows()
      |> Enum.filter(&(Spec.native?(&1) and ctx.modules[&1.surface] != nil))
      |> Enum.map(&test_source(&1, spec, renders, ctx))

    """
    defmodule #{ctx.web}.BubbleFrontendWorkflowsTest do
      # One smoke test per native workflow scaffolded from Bubble (WTF-372:
      # it and every workflow it calls or schedules were lowered whole): it
      # runs from a fresh page without raising. A clicked or input-changed
      # workflow runs through its page's event (checked against the page's
      # own list), any other through #{ctx.web}.BubbleWorkflows. Data
      # access stays off (the default), so a workflow that reads or writes
      # stored data must refuse to start. They cannot fail on behavior, so
      # they are tagged `bubble_smoke: "workflow:<Bubble ID>"`, as the
      # backend workflows' smoke tests (WTF-373), not `bubble:`.
      # Scaffolded by bubble_ex; this file is yours.
      use #{ctx.module}.DataCase, async: true

      alias #{ctx.web}.BubbleWorkflows, warn: false
      alias #{ctx.web}.BubbleWorkflows.Ctx, warn: false

    #{Enum.join(tests, "\n")}
    end
    """
  end

  defp test_source(w, spec, renders, ctx) do
    module = ctx.modules[w.surface]
    name = "the Bubble workflow #{w.name || w.workflow} (bubble:#{w.workflow}) runs"
    {page, scope} = test_page(w, module, renders, ctx)
    input = w.element && get_in(ctx.surfaces, [w.surface, Access.key(:inputs), w.element])

    """
      @tag bubble_smoke: #{literal(w.symbol)}
      test #{literal(name)} do
    #{test_body(test_kind(w, page, input), w, %{module: module, page: page, scope: scope, input: input, spec: spec})}  end
    """
  end

  # The page (its Workflows module) and scope a workflow runs in.
  defp test_page(w, module, renders, ctx) do
    case {ctx.surfaces[w.surface], renders[w.surface]} do
      {%{kind: :page}, _} -> {module, ""}
      {_, {page, scope}} -> {ctx.modules[page], scope}
      _ -> {nil, ""}
    end
  end

  defp test_kind(%{client?: true}, _page, _input), do: :client
  defp test_kind(_w, nil, _input), do: :run

  defp test_kind(w, _page, input) do
    cond do
      not Spec.wired?(w) -> :run
      w.kind == :click -> :click
      w.kind == :input_change and input != nil -> :change
      true -> :run
    end
  end

  defp test_body(:client, w, t),
    do: "    assert %Phoenix.LiveView.JS{} = #{t.module}.#{w.fun}(\"\")\n"

  defp test_body(:click, w, t) do
    """
        socket = BubbleWorkflows.socket(#{t.page})

        assert {:noreply, %Phoenix.LiveView.Socket{}} =
                 BubbleWorkflows.handle_event(socket, #{t.page}, "bubble:click", %{
                   "scope" => #{literal(t.scope)},
                   "element" => #{literal(w.element)}
                 })
    """
  end

  defp test_body(:change, w, t) do
    """
        socket = BubbleWorkflows.socket(#{t.page})

        assert {:noreply, %Phoenix.LiveView.Socket{}} =
                 BubbleWorkflows.handle_event(socket, #{t.page}, "bubble:change", %{
                   "bubble" => %{
                     "scope" => #{literal(t.scope)},
                     "element" => #{literal(w.element)},
                     "value" => #{sample(t.input)}
                   }
                 })
    """
  end

  defp test_body(:run, w, t) do
    expected =
      if w.data?,
        do: "{{:error, {:data_access_disabled, _}}, %Ctx{}}",
        else: "{_status, %Ctx{}}"

    """
        ctx = %Ctx{module: #{t.module}, now: DateTime.utc_now()}

        assert #{expected} =
                 BubbleWorkflows.run(ctx, #{t.module}, #{literal(w.workflow)}, %{}, #{literal(t.scope)})
    """
  end

  # A value a browser could send for an input of `type`.
  defp sample({:number, _}), do: ~s("1")
  defp sample({:boolean, _}), do: ~s("true")
  # A Dropdown of things (WTF-596): no choice, which the page always takes.
  defp sample({:thing, _}), do: ~s("")
  defp sample(_input), do: ~s("text")

  # --- source helpers -----------------------------------------------------------------------

  defp doc(w, note) do
    text =
      "Bubble workflow #{w.name || "(unnamed)"} (bubble:#{w.workflow}), #{event_text(w)}." <>
        if(note, do: " " <> note, else: "")

    literal(text)
  end

  defp event_text(%{kind: :click, element: e}), do: "clicked element #{e}"
  defp event_text(%{kind: :input_change, element: e}), do: "changed input #{e}"
  defp event_text(%{kind: :page_load}), do: "page loaded"
  defp event_text(%{kind: :condition_true, run_when: r}), do: "condition true (#{r})"
  defp event_text(%{kind: :custom_event}), do: "custom event"
  defp event_text(%{kind: :do_every}), do: "do every N seconds"
  defp event_text(%{kind: :js_publish, element: e}), do: "published by element #{e}"
  defp event_text(%{kind: kind}), do: Atom.to_string(kind)

  # A string literal: `inspect/1`, never truncated.
  defp literal(value), do: source(to_string(value))

  defp source(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp atom(name) when is_atom(name), do: inspect(name)

  defp atom(name) do
    if Regex.match?(~r/\A[a-z_][A-Za-z0-9_]*[?!]?\z/, name),
      do: ":" <> name,
      else: ":" <> source(name)
  end

  # A `# bubble:workflow` / `# bubble:step` marker's word: printable ASCII
  # stays, every other byte (and `%`) is percent-encoded, so two IDs never
  # share a marker and a marker is one word.
  defp marker(text),
    do: text |> to_string() |> URI.encode(&(&1 in 0x21..0x7E and &1 != ?%))

  # Text for a `#` comment: one line.
  defp comment(text),
    do: text |> to_string() |> String.replace(~r/[\x00-\x1f\x7f\x{2028}\x{2029}]/u, " ")

  defp symbol_part(id), do: id |> String.split(":", parts: 2) |> List.last()

  defp format(source) do
    IO.iodata_to_binary([Code.format_string!(source), "\n"])
  end
end
