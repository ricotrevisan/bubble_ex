defmodule BubbleEx.Plan.Diff do
  @moduledoc """
  What changed between two `BubbleEx.Plan`s of the same app, and which tasks
  need re-verifying (WTF-367). From `BubbleEx.Plan.diff/2`:

      {:ok, old} = ".wtf/plan.json" |> File.read!() |> Jason.decode()
      {:ok, diff} = BubbleEx.Plan.diff(old, new_plan)
      for %{needs_reverify: true} = t <- diff.tasks, do: t.task

  It only reports. Nothing here writes or regenerates code: code the owner
  owns is never touched, a Bubble change only marks the tasks covering it
  (WTF-359 Q1).

  ## Classification

  Each task of either plan gets one `status`:

    * `:unchanged` - in both, same `source_sha256`
    * `:changed` - in both, another `source_sha256`. `reasons` say what
      differs: `:symbols` (a covered symbol was added, removed or changed;
      see `changes`), `:residue`, `:decisions` (its `decisions_sha256`: an
      effective decision, or a decision record naming a covered symbol or
      its resolved state), `:subjects`, or `:source` when only something
      else it hashes did (the named styles of a style task)
    * `:added` - only in the new plan
    * `:removed` - only in the old plan

  ## Propagation

  A task in both plans `needs_reverify` when it changed, or when it depends
  on a task that changed, was added or was removed, along a `depends_on`
  edge of any kind but `:generate` and `:early`. Those only order work: a
  generator group is regenerated from the Model, and the tasks using a
  changed symbol changed themselves, since a symbol's digest includes what
  its references point to; `early` puts surfaces after auth and style
  residue without using them. That includes
  non-blocking `:coordinate` edges (the callee is in the caller's
  `rerun_after`). It is transitive, and a subtask that needs re-verifying
  makes its parent need it too (a subtask is done with its parent). Edges
  of the new plan are followed, and those of the old plan for a removed
  task. `via` lists the tasks that need re-verifying (or were added or
  removed) it depends on, with the edge `kind` (`:subtask` for a subtask);
  a task flagged only by propagation has reason `:dependency`.
  Added and removed tasks were never verified against the new snapshot, so
  `needs_reverify` is false for them.

  ## Changes

  A changed task's `changes` is a stack-neutral diff of the symbols it
  covers: `%{added: ids, removed: ids, changed: ids}`, symbol IDs
  (`BubbleEx.Index.Symbol`: kind plus Bubble IDs), sorted. It names nothing
  else: no display names, expression text or values. For other tasks it is
  nil.

  ## Content key

  `content_changed` is true when the plans' content digests were made
  differently (`inputs.content`: another algorithm or key, or one plan
  without them). Every task then changes (reason `:content`): a lost or
  rotated key re-verifies everything rather than nothing.

  `tasks` follow the new plan's order, then removed tasks in the old plan's
  order. `counts` has one count per status and `needs_reverify`.
  """

  alias BubbleEx.{CanonicalJson, Error, Plan}

  @enforce_keys [:from, :to, :tasks, :counts]
  defstruct [:from, :to, content_changed: false, tasks: [], counts: %{}]

  @type status :: :unchanged | :changed | :added | :removed
  @type reason ::
          :symbols | :residue | :decisions | :subjects | :content | :source | :dependency
  @type entry :: %{
          task: String.t(),
          status: status(),
          needs_reverify: boolean(),
          reasons: [reason()],
          via: [%{task: String.t(), kind: atom() | String.t()}],
          changes: %{added: [String.t()], removed: [String.t()], changed: [String.t()]} | nil
        }
  @type t :: %__MODULE__{
          from: String.t() | nil,
          to: String.t() | nil,
          content_changed: boolean(),
          tasks: [entry()],
          counts: %{atom() => non_neg_integer()}
        }

  @edge_kinds ~w(generate early secrets decision reusable fragment acceptance plugin api calls
                 coordinate release)a
  @kind_atoms Map.new(@edge_kinds, &{Atom.to_string(&1), &1})
  @statuses [:unchanged, :changed, :added, :removed]

  # Edges that only order work: no re-verification flows along them.
  @ordering_only [:generate, :early]

  @doc "See the module documentation."
  @spec diff(Plan.t() | map(), Plan.t() | map()) :: {:ok, t()} | {:error, Error.t()}
  def diff(old, new) do
    with {:ok, old} <- read(old, "old"),
         {:ok, new} <- read(new, "new") do
      {:ok, compute(old, new)}
    end
  end

  # --- reading ------------------------------------------------------------------

  defp read(%Plan{} = plan, which), do: plan |> Plan.to_map() |> read(which)

  defp read(%{"schema_version" => version} = map, which) do
    cond do
      version != Plan.schema_version() ->
        error(
          "the #{which} plan has schema_version #{inspect(version)}; rebuild it with " <>
            "schema_version #{Plan.schema_version()} to compare"
        )

      not (is_list(map["tasks"]) and Enum.all?(map["tasks"], &task?/1)) ->
        error("the #{which} plan's tasks are malformed")

      not symbols?(map["symbols"]) ->
        error("the #{which} plan's symbols are malformed")

      true ->
        tasks = Enum.map(map["tasks"], &task/1)

        {:ok,
         %{
           sha256: map["plan_sha256"],
           content: get_in(map, ["inputs", "content"]),
           tasks: tasks,
           by_id: Map.new(tasks, &{&1.id, &1}),
           symbols: map["symbols"],
           children:
             Enum.group_by(
               for({id, %{"parent" => p}} <- map["symbols"], p != nil, do: {p, id}),
               &elem(&1, 0),
               &elem(&1, 1)
             )
         }}
    end
  end

  defp read(_, which), do: error("the #{which} plan must be a BubbleEx.Plan or its decoded JSON")

  defp task?(%{"id" => id, "depends_on" => deps, "subjects" => subjects})
       when is_binary(id) and is_list(deps) and is_list(subjects),
       do:
         Enum.all?(
           deps,
           &match?(%{"task" => t, "kind" => k} when is_binary(t) and is_binary(k), &1)
         )

  defp task?(_), do: false

  defp symbols?(symbols) when is_map(symbols),
    do: Enum.all?(symbols, &match?({id, %{"sha256" => _}} when is_binary(id), &1))

  defp symbols?(_), do: false

  defp task(map) do
    %{
      id: map["id"],
      parent: map["parent"],
      subjects: map["subjects"],
      deps: Enum.map(map["depends_on"], &{&1["task"], kind(&1["kind"])}),
      residue: map["residue"],
      decisions_sha256: map["decisions_sha256"],
      source_sha256: map["source_sha256"]
    }
  end

  defp kind(kind), do: Map.get(@kind_atoms, kind, kind)

  # --- comparing ----------------------------------------------------------------

  defp compute(old, new) do
    classified =
      Enum.map(new.tasks, fn t ->
        case old.by_id[t.id] do
          nil -> {t.id, :added, [], nil}
          o -> classify(o, t, old, new, old.content != new.content)
        end
      end)

    removed = for t <- old.tasks, not Map.has_key?(new.by_id, t.id), do: t.id
    status = Map.new(classified, fn {id, s, _, _} -> {id, s} end)

    seeds =
      MapSet.new(for({id, s, _, _} <- classified, s in [:changed, :added], do: id) ++ removed)

    upstream = upstream(old, new, MapSet.new(removed))
    flagged = propagate(seeds, upstream, status)

    upstream_of = &via(&1, upstream, MapSet.union(seeds, flagged))

    entries =
      Enum.map(classified, &entry(&1, flagged, upstream_of)) ++
        Enum.map(
          removed,
          &%{
            task: &1,
            status: :removed,
            needs_reverify: false,
            reasons: [],
            via: [],
            changes: nil
          }
        )

    %__MODULE__{
      from: old.sha256,
      to: new.sha256,
      content_changed: old.content != new.content,
      tasks: entries,
      counts: counts(entries)
    }
  end

  defp entry({id, s, reasons, changes}, flagged, upstream_of) do
    reverify = s == :changed or (s == :unchanged and MapSet.member?(flagged, id))

    %{
      task: id,
      status: s,
      needs_reverify: reverify,
      reasons: if(s == :unchanged and reverify, do: [:dependency], else: reasons),
      via: if(reverify, do: upstream_of.(id), else: []),
      changes: changes
    }
  end

  # The flagged, added or removed tasks `id` depends on.
  defp via(id, upstream, marked) do
    for(
      {up, kind} <- Map.get(upstream, id, []),
      MapSet.member?(marked, up),
      do: %{task: up, kind: kind}
    )
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.task, to_string(&1.kind)})
  end

  defp classify(o, t, old, new, content_changed) do
    if o.source_sha256 == t.source_sha256 do
      {t.id, :unchanged, [], nil}
    else
      changes = changes(covered(old, o), covered(new, t), old.symbols, new.symbols)

      reasons =
        [
          {:symbols, changes != %{added: [], removed: [], changed: []}},
          {:residue, o.residue != t.residue},
          {:decisions, o.decisions_sha256 != t.decisions_sha256},
          {:subjects, o.subjects != t.subjects},
          {:content, content_changed}
        ]
        |> Enum.filter(&elem(&1, 1))
        |> Enum.map(&elem(&1, 0))

      {t.id, :changed, if(reasons == [], do: [:source], else: reasons), changes}
    end
  end

  # The symbols a task covers: its subjects in the table and their
  # descendants.
  defp covered(plan, task) do
    task.subjects
    |> Enum.filter(&Map.has_key?(plan.symbols, &1))
    |> Enum.flat_map(&[&1 | descendants(plan, &1)])
    |> MapSet.new()
  end

  defp descendants(plan, id) do
    plan.children
    |> Map.get(id, [])
    |> Enum.flat_map(&[&1 | descendants(plan, &1)])
  end

  defp changes(before, now, old_symbols, new_symbols) do
    %{
      added: now |> MapSet.difference(before) |> Enum.sort(),
      removed: before |> MapSet.difference(now) |> Enum.sort(),
      changed:
        before
        |> MapSet.intersection(now)
        |> Enum.filter(&(old_symbols[&1]["sha256"] != new_symbols[&1]["sha256"]))
        |> Enum.sort()
    }
  end

  # task => [{task it depends on (or its subtask), edge kind}]: the new
  # plan's edges and subtasks, plus the old plan's edges to removed tasks.
  defp upstream(old, new, removed) do
    new_edges =
      for t <- new.tasks,
          {to, kind} <- t.deps,
          kind not in @ordering_only,
          do: {t.id, {to, kind}}

    subtasks = for t <- new.tasks, t.parent != nil, do: {t.parent, {t.id, :subtask}}

    old_edges =
      for t <- old.tasks,
          Map.has_key?(new.by_id, t.id),
          {to, kind} <- t.deps,
          kind not in @ordering_only,
          MapSet.member?(removed, to),
          do: {t.id, {to, kind}}

    Enum.group_by(new_edges ++ subtasks ++ old_edges, &elem(&1, 0), &elem(&1, 1))
  end

  # Tasks in both plans reachable from a seed against the upstream edges.
  defp propagate(seeds, upstream, status) do
    downstream =
      for {task, ups} <- upstream, {up, _kind} <- ups, reduce: %{} do
        acc -> Map.update(acc, up, [task], &[task | &1])
      end

    walk(MapSet.to_list(seeds), downstream, status, MapSet.new())
  end

  defp walk([], _downstream, _status, seen), do: seen

  defp walk([id | rest], downstream, status, seen) do
    next =
      for d <- Map.get(downstream, id, []),
          Map.get(status, d) in [:changed, :unchanged],
          not MapSet.member?(seen, d),
          uniq: true,
          do: d

    walk(next ++ rest, downstream, status, Enum.into(next, seen))
  end

  defp counts(entries) do
    by_status = Enum.frequencies_by(entries, & &1.status)

    @statuses
    |> Map.new(&{&1, Map.get(by_status, &1, 0)})
    |> Map.put(:needs_reverify, Enum.count(entries, & &1.needs_reverify))
  end

  # --- serialization ------------------------------------------------------------

  @doc "JSON form: string keys and JSON primitives."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = diff) do
    %{
      "from" => diff.from,
      "to" => diff.to,
      "content_changed" => diff.content_changed,
      "tasks" => Enum.map(diff.tasks, &json/1),
      "counts" => json(diff.counts)
    }
  end

  @doc "Canonical JSON text of `to_map/1`."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = diff), do: diff |> to_map() |> CanonicalJson.encode()

  defp json(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), json(v)} end)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(value) when value in [true, false, nil], do: value
  defp json(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json(value), do: value

  defp error(message), do: {:error, Error.new(:invalid_input, message)}
end
