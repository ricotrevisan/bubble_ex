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
  | `generated` | the generator emitted it | data types, fields, option sets and values: a resource, attribute, `belongs_to`, enum or enum value of the `BubbleEx.Target.Ash.Project` whose `source` is its Bubble ID; pages and reusables: `.wtf/surfaces.json` of the rendered files; backend workflows: a **native** action of the `BubbleEx.Target.Ash.Workflows.Spec` (its whole body, and its callees', generated); API calls: a call of the `BubbleEx.Target.ApiClients.Spec` |
  | `decision` | an applied owner decision replaced or removed it | fields: a derived calculation, count aggregate or `has_many` standing for the field (`derive_*` decisions); workflows: a closed `delete_workflows` or plugin `drop` task of the plan |
  | `residue` | the generator cannot lower it: agent work | backend workflows that are not native; pages, reusables, workflows and API calls whose plan task is open with residue (`BubbleEx.Plan.Residue`), API calls in the client Spec's residue |
  | `task` | not generated, but a plan task covers it and its criteria verify it: agent work | the plan's tasks (frontend workflows have no generator yet, so they are all here or in `residue`) |
  | `diagnosed` | the generator left it out and said why | a `:ash_malformed_omitted` or `:ash_duplicate_enum_value` diagnostic of the Project |
  | `excluded` | not part of the app to migrate | deleted in Bubble; mobile views and their workflows (the plan excludes them) |
  | `uncovered` | none of the above: a structural failure | |

  `task` and `residue` are accounted for, **not done**: the plan's
  criteria (and later replay) verify that work. A parity exception does
  not account for a symbol: structural checks accept no difference
  (decision D4 on WTF-358).
  """

  alias BubbleEx.Index
  alias BubbleEx.Index.Symbol
  alias BubbleEx.Model
  alias BubbleEx.Plan
  alias BubbleEx.Target.ApiClients.Spec, as: ApiSpec
  alias BubbleEx.Target.Ash.Project
  alias BubbleEx.Target.Ash.Workflows.Spec, as: WorkflowSpec

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
  @buckets ~w(generated decision residue task diagnosed excluded uncovered)a

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
  `project`, and optionally `files`, `workflows` and `api_clients`.
  """
  @spec account(map()) :: %{atom() => [entry()]}
  def account(inputs) do
    plan = plan_facts(inputs.plan)
    surfaces = surfaces(Map.get(inputs, :files))

    %{
      data_types: data_types(inputs.model, inputs.project),
      fields: fields(inputs.model, inputs.project),
      option_sets: option_sets(inputs.model, inputs.project),
      option_values: option_values(inputs.model, inputs.project),
      pages: surfaces(inputs.index, :page, surfaces, plan),
      reusables: surfaces(inputs.index, :reusable, surfaces, plan),
      workflows: workflows(inputs.index, Map.get(inputs, :workflows), plan),
      api_calls: api_calls(inputs.index, Map.get(inputs, :api_clients), plan)
    }
  end

  @doc """
  Counts per category: every bucket (zero included), `total`, and
  `reasons` (`why` frequencies of the entries outside `generated`).
  Counts only: no names or IDs.
  """
  @spec counts(%{atom() => [entry()]}) :: map()
  def counts(accounted) do
    Map.new(accounted, fn {category, entries} ->
      buckets = Map.new(@buckets, &{Atom.to_string(&1), 0})

      counts =
        entries
        |> Enum.frequencies_by(&Atom.to_string(&1.bucket))
        |> then(&Map.merge(buckets, &1))

      reasons =
        entries
        |> Enum.reject(&(&1.bucket == :generated or is_nil(&1.why)))
        |> Enum.frequencies_by(&"#{&1.bucket}:#{&1.why}")

      {Atom.to_string(category),
       Map.merge(counts, %{"total" => length(entries), "reasons" => reasons})}
    end)
  end

  # --- data model -------------------------------------------------------------------

  defp data_types(%Model{} = model, %Project{} = project) do
    generated = MapSet.new(project.resources, &get_in(&1.source, [:type]))

    for type <- model.data_types do
      subjects = %{type: type.id}
      id = Symbol.id(:data_type, type.id)

      cond do
        type.deleted -> entry(id, :excluded, :deleted, subjects)
        MapSet.member?(generated, type.id) -> entry(id, :generated, nil, subjects)
        diagnosed?(project, subjects) -> entry(id, :diagnosed, :malformed, subjects)
        true -> entry(id, :uncovered, nil, subjects)
      end
    end
  end

  defp fields(%Model{} = model, %Project{} = project) do
    {stored, derived} = field_sources(project)

    for type <- model.data_types,
        is_nil(type.raw),
        field <- type.system_fields ++ type.fields do
      subjects = %{type: type.id, field: field.id}
      id = Symbol.id(:field, [type.id, field.id])
      key = {type.id, field.id}

      cond do
        type.deleted -> entry(id, :excluded, :type_deleted, subjects)
        field.deleted -> entry(id, :excluded, :deleted, subjects)
        MapSet.member?(stored, key) -> entry(id, :generated, nil, subjects)
        MapSet.member?(derived, key) -> entry(id, :decision, :derived, subjects)
        diagnosed?(project, subjects) -> entry(id, :diagnosed, :malformed, subjects)
        true -> entry(id, :uncovered, nil, subjects)
      end
    end
  end

  # {type, field} of stored attributes and belongs_to relationships, and of
  # what a decision derives in their place (calculations, aggregates,
  # has_many).
  defp field_sources(project) do
    stored =
      for r <- project.resources,
          item <-
            r.attributes ++ Enum.filter(r.relationships, &(&1.kind == :belongs_to)),
          key = source_key(item.source),
          key != nil,
          into: MapSet.new(),
          do: key

    derived =
      for r <- project.resources,
          item <-
            Enum.filter(r.calculations, &(&1.kind == :derived)) ++
              r.aggregates ++ Enum.filter(r.relationships, &(&1.kind == :has_many)),
          key = source_key(item.source),
          key != nil,
          into: MapSet.new(),
          do: key

    {stored, derived}
  end

  defp source_key(%{type: type, field: field}), do: {type, field}
  defp source_key(_), do: nil

  defp option_sets(%Model{} = model, %Project{} = project) do
    generated = MapSet.new(project.enums, & &1.source.option_set)

    for set <- model.option_sets do
      subjects = %{option_set: set.id}
      id = Symbol.id(:option_set, set.id)

      cond do
        set.deleted -> entry(id, :excluded, :deleted, subjects)
        MapSet.member?(generated, set.id) -> entry(id, :generated, nil, subjects)
        diagnosed?(project, subjects) -> entry(id, :diagnosed, :malformed, subjects)
        true -> entry(id, :uncovered, nil, subjects)
      end
    end
  end

  defp option_values(%Model{} = model, %Project{} = project) do
    generated =
      for enum <- project.enums,
          v <- enum.values,
          into: MapSet.new(),
          do: {v.source.option_set, v.source.value}

    duplicates =
      for %{code: :ash_duplicate_enum_value, subject: %{option_set: set}, details: details} <-
            project.diagnostics,
          into: MapSet.new(),
          do: {set, details[:value]}

    known = %{generated: generated, duplicates: duplicates, project: project}

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
      MapSet.member?(known.generated, key) -> entry(id, :generated, nil, subjects)
      MapSet.member?(known.duplicates, key) -> entry(id, :diagnosed, :duplicate_key, subjects)
      not is_nil(value.raw) -> diagnosed_or_uncovered(known.project, id, subjects)
      true -> entry(id, :uncovered, nil, subjects)
    end
  end

  defp diagnosed_or_uncovered(project, id, subjects) do
    if diagnosed?(project, subjects),
      do: entry(id, :diagnosed, :malformed, subjects),
      else: entry(id, :uncovered, nil, subjects)
  end

  # A Project diagnostic saying the definition was left out.
  defp diagnosed?(project, subjects) do
    Enum.any?(project.diagnostics, fn d ->
      d.code == :ash_malformed_omitted and d.subject == subjects
    end)
  end

  # --- surfaces -----------------------------------------------------------------------

  defp surfaces(%Index{} = index, kind, rendered, plan) do
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

        true ->
          planned(symbol.id, subjects, plan)
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

  defp workflows(%Index{} = index, spec, plan) do
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

    known = %{surfaces: surfaces, mobile: mobile, actions: workflow_actions(spec), plan: plan}
    Enum.map(Index.symbols(index, :workflow), &workflow(&1, known))
  end

  defp workflow(symbol, known) do
    subjects = %{workflow: symbol.bubble_id}

    cond do
      why = Map.get(known.plan.removed, symbol.id) ->
        entry(symbol.id, :decision, why, subjects)

      symbol.attrs[:backend] == true ->
        backend_workflow(symbol, subjects, known)

      MapSet.member?(known.mobile, symbol.parent) ->
        entry(symbol.id, :excluded, :mobile_view, subjects)

      not MapSet.member?(known.surfaces, symbol.parent) ->
        entry(symbol.id, :excluded, :no_surface, subjects)

      true ->
        planned(symbol.id, subjects, known.plan)
    end
  end

  # A backend workflow the Spec lowered is generated when native (its
  # whole body and its callees'), else residue.
  defp backend_workflow(symbol, subjects, known) do
    case Map.fetch(known.actions, symbol.bubble_id) do
      {:ok, true} -> entry(symbol.id, :generated, nil, subjects)
      {:ok, false} -> entry(symbol.id, :residue, :not_native, subjects)
      :error -> planned(symbol.id, subjects, known.plan)
    end
  end

  # Bubble workflow ID -> whether its action is native.
  defp workflow_actions(%WorkflowSpec{} = spec),
    do: Map.new(WorkflowSpec.actions(spec), &{&1.workflow, WorkflowSpec.native?(&1)})

  defp workflow_actions(_), do: %{}

  # --- API calls ------------------------------------------------------------------------

  defp api_calls(%Index{} = index, spec, plan) do
    {generated, residue} = api_spec(spec)

    for symbol <- Index.symbols(index, :api_call) do
      subjects = %{}

      cond do
        MapSet.member?(generated, symbol.id) -> entry(symbol.id, :generated, nil, subjects)
        MapSet.member?(residue, symbol.id) -> entry(symbol.id, :residue, :not_generated, subjects)
        true -> planned(symbol.id, subjects, plan)
      end
    end
  end

  defp api_spec(%ApiSpec{} = spec) do
    generated = for g <- spec.groups, c <- g.calls, into: MapSet.new(), do: c.subject

    residue =
      for r <- spec.residue, into: MapSet.new(), do: Symbol.id(:api_call, [r.group, r.call])

    {generated, residue}
  end

  defp api_spec(_), do: {MapSet.new(), MapSet.new()}

  # --- the plan ------------------------------------------------------------------------

  # What the plan says about a symbol: `residue` when a task covering it is
  # open with residue (or residue names it), `task` when a task covers it,
  # else `uncovered`.
  defp planned(id, subjects, plan) do
    tasks = Map.get(plan.covering, id, [])

    cond do
      MapSet.member?(plan.residue, id) or
          Enum.any?(tasks, &(&1.status == :open and &1.residue != [])) ->
        entry(id, :residue, residue_reason(id, tasks, plan), subjects)

      tasks != [] ->
        entry(id, :task, tasks |> hd() |> Map.get(:kind), subjects)

      true ->
        entry(id, :uncovered, nil, subjects)
    end
  end

  defp residue_reason(id, tasks, plan) do
    Map.get(plan.reasons, id) ||
      tasks
      |> Enum.flat_map(& &1.residue)
      |> Enum.map(& &1.reason)
      |> Enum.min(fn -> nil end)
  end

  # Symbol -> covering tasks (acceptance, delivery and cutover tasks cover
  # nothing: they review or release what others build; generator nodes
  # come last); residue subjects and their first reason; workflows removed
  # by closed decision tasks.
  defp plan_facts(%Plan{tasks: tasks}) do
    ignored = [:acceptance, :delivery, :cutover, :data, :replay, :decision]

    covering =
      tasks
      |> Enum.reject(&(&1.kind in ignored))
      |> Enum.sort_by(&if(&1.kind == :generate, do: 1, else: 0))
      |> Enum.flat_map(fn t -> Enum.map(t.subjects, &{&1, t}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    residue = tasks |> Enum.flat_map(& &1.residue) |> Enum.sort_by(& &1.reason)

    removed =
      for %{status: :closed, kind: kind, subjects: subjects} <- tasks,
          kind in [:delete_workflows, :plugin],
          id <- subjects,
          String.starts_with?(id, "workflow:"),
          into: %{},
          do: {id, if(kind == :plugin, do: :plugin_drop, else: :delete_workflows)}

    %{
      covering: covering,
      residue: MapSet.new(residue, & &1.subject),
      reasons: residue |> Enum.reverse() |> Map.new(&{&1.subject, &1.reason}),
      removed: removed
    }
  end

  defp entry(id, bucket, why, subjects),
    do: %{id: id, bucket: bucket, why: why, subjects: subjects}
end
