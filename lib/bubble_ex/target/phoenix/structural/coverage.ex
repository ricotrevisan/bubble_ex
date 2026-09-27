defmodule BubbleEx.Target.Phoenix.Structural.Coverage do
  @moduledoc """
  Symbol accounting for the structural pack
  (`BubbleEx.Target.Phoenix.Structural`, WTF-386): every Bubble definition
  of a category, from the `BubbleEx.Model` (data types, fields, option sets
  and values) or the `BubbleEx.Index` (pages, reusables, workflows, API
  Connector calls), is put in exactly one bucket. Nothing here is
  recomputed: each bucket reads what the generator, the plan or the owner's
  decisions already say.

  | bucket | meaning | read from |
  |--------|---------|-----------|
  | `generated` | the generator emitted it | data types, fields, option sets and values: a resource, attribute, relationship, enum or enum value of the `BubbleEx.Target.Ash.Project` whose `source` is its Bubble ID **and**, with rendered files, the module and name in the rendered source (read from the AST); pages and reusables: `.wtf/surfaces.json` of the rendered files; workflows: a **native** workflow (its whole body, and its callees', generated) of the `BubbleEx.Target.Ash.Workflows.Spec` (backend) or the `BubbleEx.Target.Elixir.FrontendWorkflows.Spec` (pages and reusables); API calls: a call of the `BubbleEx.Target.ApiClients.Spec` |
  | `decision` | an applied owner decision replaced or removed it | fields: a derived calculation, count aggregate or `has_many` standing for the field (`derive_*` decisions), rendered like a field; workflows: a closed `delete_workflows` or plugin `drop` task of the plan |
  | `residue` | not emitted, and an **open** plan task that is not a generator node carries residue whose subject is the symbol itself or one of its own parts (a workflow's actions): agent work. Never for pages and reusables: the generator emits every surface | the plan's tasks and their `BubbleEx.Plan.Residue` |
  | `diagnosed` | the generator left it out and said why | a `:ash_malformed_omitted` or `:ash_duplicate_enum_value` diagnostic of the Project; a workflow on no page or reusable (`no_surface`) |
  | `excluded` | not part of the app to migrate | deleted in Bubble; mobile views and their workflows (the plan excludes them) |
  | `uncovered` | none of the above: a structural failure | why: `not_emitted` (its generator did not emit it), `not_rendered` (in the Project, not in the rendered source) |

  A generator node of the plan (`generate:*`) or an `:auto` task accounts
  for nothing: they say the generator will emit the symbol, which is
  what is checked. `residue` is accounted for, **not done**. A parity
  exception does not account for a symbol: structural checks accept no
  difference (decision D4 on WTF-358).

  The fields and values of a malformed data type or option set (kept raw
  by the Model) cannot be listed: `counts/1` reports how many such parents
  there are (`unreadable_parents`).
  """

  alias BubbleEx.Index
  alias BubbleEx.Index.Symbol
  alias BubbleEx.Model
  alias BubbleEx.Plan
  alias BubbleEx.Target.ApiClients.Spec, as: ApiSpec
  alias BubbleEx.Target.Ash.Workflows.Spec, as: WorkflowSpec
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec, as: FrontendSpec

  @categories [
    :data_types,
    :fields,
    :option_sets,
    :option_values,
    :pages,
    :reusables,
    :workflows,
    :api_calls
  ]
  @buckets [:generated, :decision, :residue, :diagnosed, :excluded, :uncovered]
  @declaring [:attribute, :belongs_to, :has_many, :many_to_many, :calculate, :count]

  @typedoc "One accounted symbol: its index symbol ID, bucket, why, and Bubble-ID subjects."
  @type entry :: %{id: String.t(), bucket: atom(), why: atom() | nil, subjects: map()}

  @doc "The categories, in report order."
  @spec categories() :: [atom()]
  def categories, do: @categories

  @doc "The buckets, in report order."
  @spec buckets() :: [atom()]
  def buckets, do: @buckets

  @doc """
  Accounts every symbol of every category. `inputs` is the map given to
  `BubbleEx.Target.Phoenix.Structural.run/2`: `model`, `index`, `plan`,
  `project`, and optionally `files`, `workflows`, `frontend_workflows`
  and `api_clients`. The
  result has one entry list per category and `:unreadable`, the malformed
  parents whose members cannot be listed.
  """
  @spec account(map()) :: map()
  def account(inputs) do
    plan = plan_facts(inputs.plan)
    files = Map.get(inputs, :files)
    ctx = %{project: inputs.project, rendered: rendered(files, inputs.project)}

    %{
      data_types: data_types(inputs.model, ctx),
      fields: fields(inputs.model, ctx),
      option_sets: option_sets(inputs.model, ctx),
      option_values: option_values(inputs.model, ctx),
      pages: surfaces(inputs.index, :page, surfaces(files)),
      reusables: surfaces(inputs.index, :reusable, surfaces(files)),
      workflows:
        workflows(
          inputs.index,
          Map.get(inputs, :workflows),
          Map.get(inputs, :frontend_workflows),
          plan
        ),
      api_calls: api_calls(inputs.index, Map.get(inputs, :api_clients), plan),
      unreadable: %{
        fields: Enum.count(inputs.model.data_types, &(not is_nil(&1.raw))),
        option_values: Enum.count(inputs.model.option_sets, &(not is_nil(&1.raw)))
      }
    }
  end

  @doc """
  Counts per category: every bucket (zero included), `total`, `reasons`
  (`bucket:why` frequencies outside `generated`) and, for fields and
  option values, `unreadable_parents`. Counts only: no names or IDs.
  """
  @spec counts(map()) :: map()
  def counts(accounted) do
    unreadable = Map.get(accounted, :unreadable, %{})

    Map.new(@categories, fn category ->
      entries = Map.get(accounted, category, [])
      buckets = Map.new(@buckets, &{Atom.to_string(&1), 0})

      counts =
        entries
        |> Enum.frequencies_by(&Atom.to_string(&1.bucket))
        |> then(&Map.merge(buckets, &1))

      reasons =
        entries
        |> Enum.reject(&(&1.bucket == :generated or is_nil(&1.why)))
        |> Enum.frequencies_by(&"#{&1.bucket}:#{&1.why}")

      counts = Map.merge(counts, %{"total" => length(entries), "reasons" => reasons})

      counts =
        if Map.has_key?(unreadable, category),
          do: Map.put(counts, "unreadable_parents", unreadable[category]),
          else: counts

      {Atom.to_string(category), counts}
    end)
  end

  # --- the rendered source --------------------------------------------------------

  # Module name -> the names it declares (attributes, relationships,
  # calculations, aggregates) and its enum values, from the AST of the
  # rendered lib/ files; nil without files.
  defp rendered(files, _project) when is_map(files) do
    namespace =
      with json when is_binary(json) <- files[".wtf/generated.json"],
           {:ok, %{"module" => module}} <- Jason.decode(json) do
        module
      end

    modules =
      for {path, source} <- files,
          String.starts_with?(path, "lib/") and Path.extname(path) == ".ex",
          {:ok, ast} <- [Code.string_to_quoted(source, emit_warnings: false)],
          {name, declared} <- modules(ast),
          into: %{},
          do: {name, declared}

    %{namespace: namespace, modules: modules}
  end

  defp rendered(_files, _project), do: nil

  defp modules(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, parts}, [do: body]]} = node, acc ->
          {node, [{Enum.map_join(parts, ".", &to_string/1), declared(body)} | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp declared(body) do
    {_, acc} =
      Macro.prewalk(body, %{names: MapSet.new(), values: MapSet.new()}, fn
        {fun, _, [name | _]} = node, acc when fun in @declaring and is_atom(name) ->
          {node, %{acc | names: MapSet.put(acc.names, Atom.to_string(name))}}

        {:use, _, [{:__aliases__, _, [:Ash, :Type, :Enum]}, opts]} = node, acc
        when is_list(opts) ->
          values = opts |> Keyword.get(:values, []) |> Enum.map(&enum_value/1)
          {node, %{acc | values: MapSet.union(acc.values, MapSet.new(values))}}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp enum_value({value, _opts}), do: to_string(value)
  defp enum_value(value), do: to_string(value)

  # A Project module (relative name) as rendered, or `:unchecked` without
  # rendered files.
  defp module(%{rendered: nil}, _relative), do: :unchecked

  defp module(%{rendered: %{namespace: ns, modules: modules}}, relative),
    do: Map.get(modules, "#{ns}.#{relative}")

  # --- data model -------------------------------------------------------------------

  defp data_types(%Model{} = model, ctx) do
    resources = Map.new(ctx.project.resources, &{get_in(&1.source, [:type]), &1})

    for type <- model.data_types do
      subjects = %{type: type.id}
      id = Symbol.id(:data_type, type.id)
      resource = resources[type.id]

      cond do
        type.deleted -> entry(id, :excluded, :deleted, subjects)
        resource && module(ctx, resource.module) -> entry(id, :generated, nil, subjects)
        resource -> entry(id, :uncovered, :not_rendered, subjects)
        diagnosed?(ctx.project, subjects) -> entry(id, :diagnosed, :malformed, subjects)
        true -> entry(id, :uncovered, :not_emitted, subjects)
      end
    end
  end

  defp fields(%Model{} = model, ctx) do
    {stored, derived} = field_sources(ctx.project)

    for type <- model.data_types,
        is_nil(type.raw),
        field <- type.system_fields ++ type.fields do
      subjects = %{type: type.id, field: field.id}
      id = Symbol.id(:field, [type.id, field.id])
      key = {type.id, field.id}

      cond do
        type.deleted -> entry(id, :excluded, :type_deleted, subjects)
        field.deleted -> entry(id, :excluded, :deleted, subjects)
        items = stored[key] -> rendered_entry(id, :generated, nil, items, ctx, subjects)
        items = derived[key] -> rendered_entry(id, :decision, :derived, items, ctx, subjects)
        diagnosed?(ctx.project, subjects) -> entry(id, :diagnosed, :malformed, subjects)
        true -> entry(id, :uncovered, :not_emitted, subjects)
      end
    end
  end

  # Every Project item standing for the field is declared in its rendered
  # resource module.
  defp rendered_entry(id, bucket, why, items, ctx, subjects) do
    if Enum.all?(items, fn {module, name} -> declares?(module(ctx, module), name) end),
      do: entry(id, bucket, why, subjects),
      else: entry(id, :uncovered, :not_rendered, subjects)
  end

  defp declares?(:unchecked, _name), do: true
  defp declares?(nil, _name), do: false
  defp declares?(%{names: names}, name), do: MapSet.member?(names, name)

  # {type, field} -> [{resource module, name}] of stored attributes and
  # belongs_to relationships, and of what a decision derives in their
  # place (calculations, aggregates, has_many, many_to_many).
  defp field_sources(project) do
    stored =
      for r <- project.resources,
          item <- r.attributes ++ Enum.filter(r.relationships, &(&1.kind == :belongs_to)),
          key = source_key(item.source),
          key != nil,
          do: {key, {r.module, item.name}}

    derived =
      for r <- project.resources,
          item <-
            Enum.filter(r.calculations, &(&1.kind == :derived)) ++
              r.aggregates ++
              Enum.filter(r.relationships, &(&1.kind in [:has_many, :many_to_many])),
          key = source_key(item.source),
          key != nil,
          do: {key, {r.module, item.name}}

    {Enum.group_by(stored, &elem(&1, 0), &elem(&1, 1)),
     Enum.group_by(derived, &elem(&1, 0), &elem(&1, 1))}
  end

  defp source_key(%{type: type, field: field}), do: {type, field}
  defp source_key(_), do: nil

  defp option_sets(%Model{} = model, ctx) do
    enums = Map.new(ctx.project.enums, &{&1.source.option_set, &1})

    for set <- model.option_sets do
      subjects = %{option_set: set.id}
      id = Symbol.id(:option_set, set.id)
      enum = enums[set.id]

      cond do
        set.deleted -> entry(id, :excluded, :deleted, subjects)
        enum && module(ctx, enum.module) -> entry(id, :generated, nil, subjects)
        enum -> entry(id, :uncovered, :not_rendered, subjects)
        diagnosed?(ctx.project, subjects) -> entry(id, :diagnosed, :malformed, subjects)
        true -> entry(id, :uncovered, :not_emitted, subjects)
      end
    end
  end

  defp option_values(%Model{} = model, ctx) do
    generated =
      for enum <- ctx.project.enums,
          v <- enum.values,
          into: %{},
          do: {{v.source.option_set, v.source.value}, {enum.module, v.value}}

    duplicates =
      for %{code: :ash_duplicate_enum_value, subject: %{option_set: set}, details: details} <-
            ctx.project.diagnostics,
          into: MapSet.new(),
          do: {set, details[:value]}

    known = %{generated: generated, duplicates: duplicates, ctx: ctx}

    for set <- model.option_sets, is_nil(set.raw), value <- set.values do
      id = Symbol.id(:option_value, [set.id, value.key || value.id])
      option_value(id, set, value, known)
    end
  end

  defp option_value(id, set, value, known) do
    subjects = %{option_set: set.id}
    key = {set.id, value.id}

    cond do
      set.deleted -> entry(id, :excluded, :option_set_deleted, subjects)
      value.deleted -> entry(id, :excluded, :deleted, subjects)
      emitted = known.generated[key] -> value_entry(id, emitted, known.ctx, subjects)
      MapSet.member?(known.duplicates, key) -> entry(id, :diagnosed, :duplicate_key, subjects)
      diagnosed?(known.ctx.project, subjects) -> entry(id, :diagnosed, :malformed, subjects)
      true -> entry(id, :uncovered, :not_emitted, subjects)
    end
  end

  defp value_entry(id, {module, value}, ctx, subjects) do
    case module(ctx, module) do
      :unchecked -> entry(id, :generated, nil, subjects)
      %{values: values} -> rendered_value(id, value in values, subjects)
      nil -> entry(id, :uncovered, :not_rendered, subjects)
    end
  end

  defp rendered_value(id, true, subjects), do: entry(id, :generated, nil, subjects)
  defp rendered_value(id, false, subjects), do: entry(id, :uncovered, :not_rendered, subjects)

  # A Project diagnostic saying the definition was left out.
  defp diagnosed?(project, subjects) do
    Enum.any?(project.diagnostics, fn d ->
      d.code == :ash_malformed_omitted and d.subject == subjects
    end)
  end

  # --- surfaces -----------------------------------------------------------------------

  defp surfaces(%Index{} = index, kind, rendered) do
    section = if kind == :page, do: "pages", else: "reusables"
    emitted = Map.get(rendered, section, %{})
    key = if kind == :page, do: :page, else: :element

    for symbol <- Index.symbols(index, kind) do
      subjects = %{key => symbol.bubble_id}

      cond do
        kind == :page and symbol.attrs[:section] == "mobile_views" ->
          entry(symbol.id, :excluded, :mobile_view, subjects)

        Map.has_key?(emitted, symbol.bubble_id) ->
          entry(symbol.id, :generated, nil, subjects)

        # The generator emits every surface, residue or not: a missing
        # one is never excused by a task's residue.
        true ->
          entry(symbol.id, :uncovered, :not_emitted, subjects)
      end
    end
  end

  # The rendered `.wtf/surfaces.json` (pages and reusables by Bubble ID),
  # or none when the frontend was not rendered.
  defp surfaces(files) when is_map(files) do
    with json when is_binary(json) <- files[".wtf/surfaces.json"],
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      map
    else
      _ -> %{}
    end
  end

  defp surfaces(_files), do: %{}

  # --- workflows ------------------------------------------------------------------------

  defp workflows(%Index{} = index, spec, frontend, plan) do
    surfaces =
      for s <- index.symbols,
          (s.kind == :page and s.attrs[:section] != "mobile_views") or s.kind == :reusable,
          into: MapSet.new(),
          do: s.id

    mobile =
      for s <- Index.symbols(index, :page),
          s.attrs[:section] == "mobile_views",
          into: MapSet.new(),
          do: s.id

    actions = Map.merge(workflow_actions(spec), frontend_actions(frontend))
    own = own_subjects(index)
    known = %{surfaces: surfaces, mobile: mobile, actions: actions, plan: plan, own: own}
    Enum.map(Index.symbols(index, :workflow), &workflow(&1, known))
  end

  defp workflow(symbol, known) do
    subjects = %{workflow: symbol.bubble_id}

    cond do
      why = Map.get(known.plan.removed, symbol.id) ->
        entry(symbol.id, :decision, why, subjects)

      symbol.attrs[:backend] == true ->
        lowered_workflow(symbol, subjects, known, :not_emitted)

      MapSet.member?(known.mobile, symbol.parent) ->
        entry(symbol.id, :excluded, :mobile_view, subjects)

      not MapSet.member?(known.surfaces, symbol.parent) ->
        entry(symbol.id, :diagnosed, :no_surface, subjects)

      true ->
        lowered_workflow(symbol, subjects, known, :not_emitted)
    end
  end

  # A workflow a Spec lowered (backend: `Target.Ash.Workflows`; page and
  # reusable: `Target.Elixir.FrontendWorkflows`) is generated when native
  # (its whole body and its callees'); otherwise the plan must hold its
  # residue, or, when only its callees block it, theirs. One no Spec
  # lowered is uncovered (`missing`) unless the plan holds its residue.
  defp lowered_workflow(symbol, subjects, known, missing) do
    case Map.fetch(known.actions, symbol.bubble_id) do
      {:ok, %{native?: true}} ->
        entry(symbol.id, :generated, nil, subjects)

      {:ok, _} ->
        not_native(symbol.id, subjects, known, MapSet.new([symbol.id]))

      :error ->
        planned(symbol.id, own(known, symbol.id), subjects, known.plan, missing)
    end
  end

  # A workflow's own subjects: itself and its actions.
  defp own(known, id), do: [id | Map.get(known.own, id, [])]

  defp own_subjects(index) do
    for %{kind: :action, parent: "workflow:" <> _ = parent, id: id} <- index.symbols,
        reduce: %{} do
      acc -> Map.update(acc, parent, [id], &[id | &1])
    end
  end

  defp not_native(id, subjects, known, seen) do
    case planned(id, own(known, id), subjects, known.plan, :not_native) do
      %{bucket: :residue} = entry ->
        entry

      uncovered ->
        blocked = Map.get(known.actions, bubble_id(id), %{}) |> Map.get(:blocked_by, [])

        if blocked != [] and Enum.all?(blocked, &callee_accounted?(&1, known, seen)),
          do: entry(id, :residue, :blocked_by_callee, subjects),
          else: uncovered
    end
  end

  # A callee blocking a workflow carries residue in an open task, or is
  # itself only blocked by such callees (cycles count as unaccounted).
  defp callee_accounted?("workflow:" <> _ = callee, known, seen) do
    if MapSet.member?(seen, callee),
      do: Enum.any?(own(known, callee), &Map.has_key?(known.plan.reasons, &1)),
      else:
        match?(
          %{bucket: :residue},
          not_native(callee, %{}, known, MapSet.put(seen, callee))
        )
  end

  defp callee_accounted?(_subject, _known, _seen), do: false

  defp bubble_id("workflow:" <> id), do: id

  # Bubble workflow ID -> whether it is native, and what blocks it.
  defp workflow_actions(%WorkflowSpec{} = spec),
    do:
      Map.new(
        WorkflowSpec.actions(spec),
        &{&1.workflow,
         %{native?: WorkflowSpec.native?(&1), blocked_by: Map.get(&1, :blocked_by, [])}}
      )

  defp workflow_actions(_), do: %{}

  defp frontend_actions(%FrontendSpec{} = spec),
    do:
      Map.new(FrontendSpec.workflows(spec), fn w ->
        blocked = Map.get(w, :blocked_by, [])
        {w.workflow, %{native?: blocked == [] and w.residue == [], blocked_by: blocked}}
      end)

  defp frontend_actions(_), do: %{}

  # --- API calls ------------------------------------------------------------------------

  defp api_calls(%Index{} = index, spec, plan) do
    generated =
      case spec do
        %ApiSpec{} -> for g <- spec.groups, c <- g.calls, into: MapSet.new(), do: c.subject
        _ -> MapSet.new()
      end

    for symbol <- Index.symbols(index, :api_call) do
      if MapSet.member?(generated, symbol.id),
        do: entry(symbol.id, :generated, nil, %{}),
        else: planned(symbol.id, [symbol.id], %{}, plan, :not_emitted)
    end
  end

  # --- the plan ------------------------------------------------------------------------

  # A symbol no generator emitted is `residue` when an open plan task that
  # is not a generator node carries residue whose subject is the symbol
  # itself or one of its own parts (`own`: a workflow's actions), else
  # `uncovered` for `why`. Residue elsewhere in a covering task (another
  # element of a page, another workflow of a folder) excuses nothing.
  defp planned(id, own, subjects, plan, why) do
    case Enum.find_value(own, &Map.get(plan.reasons, &1)) do
      nil -> entry(id, :uncovered, why, subjects)
      reason -> entry(id, :residue, reason, subjects)
    end
  end

  # Residue subjects of the open tasks that are not generator nodes, nor
  # review, release or owner-decision tasks, with their first reason;
  # workflows removed by closed decision tasks.
  defp plan_facts(%Plan{tasks: tasks}) do
    ignored = [:generate, :acceptance, :delivery, :cutover, :data, :replay, :decision]
    open = Enum.filter(tasks, &(&1.status == :open and &1.kind not in ignored))
    residue = open |> Enum.flat_map(& &1.residue) |> Enum.sort_by(& &1.reason)

    removed =
      for %{status: :closed, kind: kind, subjects: subjects} <- tasks,
          kind in [:delete_workflows, :plugin],
          id <- subjects,
          String.starts_with?(id, "workflow:"),
          into: %{},
          do: {id, if(kind == :plugin, do: :plugin_drop, else: :delete_workflows)}

    %{
      reasons: residue |> Enum.reverse() |> Map.new(&{&1.subject, &1.reason}),
      removed: removed
    }
  end

  defp entry(id, bucket, why, subjects),
    do: %{id: id, bucket: bucket, why: why, subjects: subjects}
end
