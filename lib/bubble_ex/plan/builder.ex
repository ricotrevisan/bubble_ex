defmodule BubbleEx.Plan.Builder do
  @moduledoc false

  # Derives the task graph of BubbleEx.Plan. See that module for the task
  # kinds and dependency rules; this one only computes them.

  alias BubbleEx.{CanonicalJson, Index}
  alias BubbleEx.Decision.Applied
  alias BubbleEx.Frontend.Normalized
  alias BubbleEx.Index.{Graph, Subject, Symbol}
  alias BubbleEx.Plan.{Criteria, Order, Residue, Task}

  # Generator groups, as full task IDs (the group names are plan IDs, not
  # data-model members).
  @generate [
    "generate:schema",
    "generate:option_sets",
    "generate:policies",
    "generate:styles",
    "generate:api_clients",
    "generate:routes",
    "generate:surfaces",
    "generate:workflow_entry_points"
  ]

  # generate:<a> depends on generate:<b>
  @generate_deps [
    {"generate:schema", ["generate:option_sets"]},
    {"generate:policies", ["generate:schema"]},
    {"generate:api_clients", ["generate:schema"]},
    {"generate:routes", ["generate:schema"]},
    {"generate:surfaces",
     ["generate:styles", "generate:routes", "generate:api_clients", "generate:policies"]},
    {"generate:workflow_entry_points", ["generate:policies", "generate:api_clients"]}
  ]

  @cutover ~w(rehearsal runbook communications freeze final_delta switch verify sign_off)

  @symbol_kinds Enum.map(Symbol.kinds(), &Atom.to_string/1)

  @spec run(map()) :: map()
  def run(input) do
    ctx =
      input
      |> scope()
      |> decisions()
      |> residue()
      |> workflows()

    tasks =
      (generate_tasks(ctx) ++
         decision_tasks(ctx) ++
         app_tasks(ctx) ++
         surface_tasks(ctx) ++
         workflow_tasks(ctx) ++ api_tasks(ctx) ++ plugin_tasks(ctx) ++ release_tasks(ctx))
      |> Map.new(&{&1.id, &1})
      |> statuses()

    {tasks, skipped} = Order.wire(tasks, edges(ctx, tasks))

    children = children(tasks)
    ordered = tasks |> Order.sort() |> Enum.map(&finish(&1, ctx, children))

    %{tasks: ordered, skipped: skipped, coverage: coverage(ctx, ordered)}
  end

  # --- scope ------------------------------------------------------------------

  # Pages (not mobile views) and reusables are surfaces. Every element
  # belongs to one surface, and to a fragment when it sits under a large
  # top-level container.
  defp scope(%{index: index} = ctx) do
    {pages, mobile} =
      index |> Index.symbols(:page) |> Enum.split_with(&(&1.attrs[:section] != "mobile_views"))

    surfaces = pages ++ Index.symbols(index, :reusable)

    trees =
      for surface <- surfaces,
          top <- Index.children(index, surface.id),
          top.kind == :element,
          do: {surface.id, top.id, [top.id | descendants(index, top.id, [:element])]}

    element_surface =
      for {surface, _top, ids} <- trees, id <- ids, into: %{}, do: {id, surface}

    fragments =
      for {surface, top, ids} <- trees,
          length(ids) > ctx.threshold,
          into: %{},
          do: {top, %{surface: surface, elements: ids}}

    fragment_of =
      for {frag, %{elements: ids}} <- fragments, id <- ids, into: %{}, do: {id, frag}

    Map.merge(ctx, %{
      surfaces: surfaces,
      surface_ids: MapSet.new(surfaces, & &1.id),
      mobile: mobile,
      element_surface: element_surface,
      surface_elements:
        element_surface
        |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
        |> Map.new(fn {k, v} -> {k, Enum.sort(v)} end),
      fragments: fragments,
      fragment_of: fragment_of
    })
  end

  defp descendants(index, id, kinds) do
    index
    |> Index.children(id)
    |> Enum.filter(&(&1.kind in kinds))
    |> Enum.flat_map(&[&1.id | descendants(index, &1.id, kinds)])
  end

  # --- decisions --------------------------------------------------------------

  # What accepted findings remove: workflows deleted outright, calling
  # actions dropped, and field writes dropped (an action whose every field
  # write is dropped goes too).
  defp decisions(%{index: index, applied: applied} = ctx) do
    touched = Map.new(applied, &{&1.key, touched(&1)})

    deleted = applied |> Enum.flat_map(&list(&1.proposal, :delete_workflows)) |> MapSet.new()
    dropped_calls = applied |> Enum.flat_map(&list(&1.proposal, :remove_calls)) |> MapSet.new()

    dropped_writes =
      applied
      |> Enum.flat_map(&list(&1.proposal, :remove_writes))
      |> MapSet.new(&{&1[:action], &1[:field]})

    removed_actions =
      for %{kind: :action} = a <- index.symbols,
          MapSet.member?(deleted, a.parent) or MapSet.member?(dropped_calls, a.id) or
            writes_dropped?(index, a.id, dropped_writes),
          into: MapSet.new(),
          do: a.id

    Map.merge(ctx, %{
      touched: touched,
      deleted_workflows: deleted,
      removed_actions: removed_actions
    })
  end

  defp writes_dropped?(index, action, dropped) do
    case Index.references_from(index, action, [:writes_field]) do
      [] -> false
      writes -> Enum.all?(writes, &MapSet.member?(dropped, {&1.from, &1.to}))
    end
  end

  defp list(proposal, key) do
    case Map.get(proposal, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # Every symbol an applied decision names: its subject and every symbol ID
  # in its proposal.
  defp touched(%Applied{subject: subject, proposal: proposal}),
    do: MapSet.new(Subject.symbol_ids(subject) ++ symbol_ids(proposal))

  defp symbol_ids(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [kind, _] when kind in @symbol_kinds -> [value]
      _ -> []
    end
  end

  defp symbol_ids(value) when is_map(value) and not is_struct(value),
    do: value |> Map.values() |> Enum.flat_map(&symbol_ids/1)

  defp symbol_ids(value) when is_list(value), do: Enum.flat_map(value, &symbol_ids/1)
  defp symbol_ids(_), do: []

  # --- residue ----------------------------------------------------------------

  defp residue(ctx) do
    removed = MapSet.union(ctx.removed_actions, ctx.deleted_workflows)

    by_subject =
      (Residue.index(ctx.index, ctx.model) ++
         Residue.frontend(ctx.frontend, ctx.index) ++ ctx.extra)
      |> Enum.reject(&MapSet.member?(removed, &1.subject))
      |> Enum.uniq()
      |> Residue.sort()
      |> Enum.group_by(& &1.subject)

    Map.put(ctx, :residue, by_subject)
  end

  defp residue_of(ctx, ids),
    do: ids |> Enum.flat_map(&Map.get(ctx.residue, &1, [])) |> Residue.sort()

  # --- workflows and cycles ---------------------------------------------------

  defp workflows(%{index: index} = ctx) do
    {kept, excluded} =
      index
      |> Index.symbols(:workflow)
      |> Enum.reject(&MapSet.member?(ctx.deleted_workflows, &1.id))
      |> Enum.split_with(
        &(&1.attrs[:backend] == true or MapSet.member?(ctx.surface_ids, &1.parent))
      )

    in_scope = MapSet.new(kept, & &1.id)

    cycles =
      for c <- index.cycles,
          members = Enum.filter(c.workflows, &MapSet.member?(in_scope, &1)),
          length(members) > 1,
          do: members

    cycle_of =
      for members <- cycles,
          id = cycle_id(members),
          w <- members,
          into: %{},
          do: {w, id}

    reusable_cycles = reusable_cycles(ctx)

    reusable_cycle_of =
      for members <- reusable_cycles, r <- members, into: %{}, do: {r, reusable_cycle_id(members)}

    Map.merge(ctx, %{
      workflows: kept,
      excluded_workflows: excluded,
      workflow_ids: in_scope,
      cycles: cycles,
      cycle_of: cycle_of,
      self_recursive: Enum.count(index.cycles, &match?([_], &1.workflows)),
      reusable_cycles: reusable_cycles,
      reusable_cycle_of: reusable_cycle_of
    })
  end

  defp cycle_id(members),
    do: "cycle:" <> Enum.map_join(members, "+", &bubble_id/1)

  defp reusable_cycle_id(members),
    do: "cycle:reusable/" <> Enum.map_join(members, "+", &bubble_id/1)

  # Reusables that contain instances of each other (more than one member).
  defp reusable_cycles(%{index: index} = ctx) do
    index
    |> Index.symbols(:reusable)
    |> Map.new(fn r -> {r.id, instanced(ctx, r.id)} end)
    |> Graph.cycles()
    |> Enum.filter(&match?([_, _ | _], &1))
  end

  # The reusables instanced by the elements of surface `id`.
  defp instanced(ctx, id) do
    for element <- Map.get(ctx.surface_elements, id, []),
        ref <- Index.references_from(ctx.index, element, [:instance_of]),
        MapSet.member?(ctx.surface_ids, ref.to),
        uniq: true,
        do: ref.to
  end

  defp bubble_id(symbol_id), do: symbol_id |> String.split(":", parts: 2) |> List.last()

  # --- task ids ---------------------------------------------------------------

  defp surface_task(ctx, surface_id) do
    case ctx.reusable_cycle_of do
      %{^surface_id => cycle} -> cycle
      _ -> surface_task_id(surface_id)
    end
  end

  defp surface_task_id("page:" <> id), do: "surface:page/" <> id
  defp surface_task_id("reusable:" <> id), do: "surface:reusable/" <> id

  defp acceptance_id("page:" <> id), do: "acceptance:page/" <> id
  defp acceptance_id("reusable:" <> id), do: "acceptance:reusable/" <> id

  defp workflow_parent(ctx, %Symbol{id: id} = w) do
    cond do
      cycle = ctx.cycle_of[id] -> cycle
      w.attrs[:backend] -> backend_id(w)
      true -> surface_task(ctx, w.parent)
    end
  end

  defp backend_id(%Symbol{attrs: attrs}), do: "backend:" <> (attrs[:folder] || "unfiled")

  # The task an element's work belongs to: its fragment, else its surface.
  defp element_task(ctx, element) do
    case ctx.fragment_of do
      %{^element => frag} -> "fragment:" <> bubble_id(frag)
      _ -> surface_task(ctx, ctx.element_surface[element])
    end
  end

  # --- tasks ------------------------------------------------------------------

  defp generate_tasks(%{index: index} = ctx) do
    subjects = %{
      "generate:schema" => ids(index, [:data_type, :field]),
      "generate:option_sets" => ids(index, [:option_set, :option_value, :option_attribute]),
      "generate:policies" => ids(index, [:privacy_rule]),
      "generate:styles" => style_subjects(ctx),
      "generate:api_clients" => ids(index, [:api_group, :api_call]),
      "generate:routes" => ctx.surfaces |> Enum.filter(&(&1.kind == :page)) |> Enum.map(& &1.id),
      "generate:surfaces" => Enum.map(ctx.surfaces, & &1.id),
      "generate:workflow_entry_points" => for(w <- ctx.workflows, w.attrs[:backend], do: w.id)
    }

    for group <- @generate do
      %Task{
        id: group,
        kind: :generate,
        actor: :generator,
        status: :auto,
        subjects: Enum.sort(subjects[group])
      }
    end
  end

  defp style_subjects(%{frontend: %Normalized{styles: styles}}),
    do: Enum.map(styles, &("style:" <> &1.map_key))

  defp style_subjects(ctx),
    do: ctx.residue |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "style:"))

  defp ids(index, kinds),
    do: for(s <- index.symbols, s.kind in kinds, do: s.id)

  # remove_writes / delete_workflows of applied findings (accepted, or
  # hints applied by default): generated nodes the decision closes.
  defp decision_tasks(ctx) do
    for %Applied{kind: :finding} = a <- ctx.applied,
        {kind, subjects} <- [
          remove_writes: a.proposal |> list(:remove_writes) |> Enum.map(& &1[:action]),
          delete_workflows: list(a.proposal, :delete_workflows) ++ list(a.proposal, :remove_calls)
        ],
        subjects != [] do
      %Task{
        id: "#{kind}:#{a.finding_id}",
        kind: kind,
        actor: :generator,
        status: :closed,
        closed_by: a.key,
        subjects: subjects |> Enum.uniq() |> Enum.sort()
      }
    end
  end

  defp app_tasks(ctx) do
    secrets = secret_subjects(ctx)
    styles = ctx.residue |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "style:"))

    auth =
      for w <- ctx.workflows,
          w.attrs[:event_type] in ["LoggedIn", "LoggedOut"] or
            Enum.any?(actions(ctx, w.id), &(&1.attrs[:type] in Residue.auth_actions())),
          do: w.id

    [
      %Task{id: "auth", kind: :auth, actor: :agent, subjects: auth},
      secrets != [] &&
        %Task{id: "setup:secrets", kind: :setup_secrets, actor: :owner, subjects: secrets},
      styles != [] &&
        %Task{
          id: "styles:residue",
          kind: :styles_residue,
          actor: :agent,
          subjects: styles,
          residue: residue_of(ctx, styles)
        }
    ]
    |> Enum.filter(& &1)
  end

  defp secret_subjects(ctx) do
    for group <- ctx.model.connectors,
        {id, params} <- [
          {Symbol.id(:api_group, group.id), group.parameters}
          | Enum.map(group.calls, &{Symbol.id(:api_call, [group.id, &1.id]), &1.parameters})
        ],
        Enum.any?(params, & &1.private),
        do: id
  end

  defp surface_tasks(ctx) do
    fragments =
      for {frag, %{surface: surface, elements: elements}} <- ctx.fragments do
        %Task{
          id: "fragment:" <> bubble_id(frag),
          kind: :fragment,
          actor: :agent,
          subjects: [frag],
          label: label(ctx, frag),
          batch: surface_task(ctx, surface),
          residue: residue_of(ctx, elements)
        }
      end

    surfaces =
      ctx.surfaces
      |> Enum.group_by(&surface_task(ctx, &1.id))
      |> Enum.map(fn {id, members} ->
        own = owned_elements(ctx, members)

        %Task{
          id: id,
          kind: if(String.starts_with?(id, "cycle:"), do: :cycle, else: :surface),
          actor: :agent,
          subjects: members |> Enum.map(& &1.id) |> Enum.sort(),
          label: members |> hd() |> Map.get(:name),
          batch: id,
          residue: residue_of(ctx, Enum.map(members, & &1.id) ++ own)
        }
      end)

    acceptance =
      for s <- ctx.surfaces do
        %Task{
          id: acceptance_id(s.id),
          kind: :acceptance,
          actor: :reviewer,
          subjects: [s.id],
          label: s.name
        }
      end

    fragments ++ surfaces ++ acceptance
  end

  # Elements of `surfaces` outside their fragments.
  defp owned_elements(ctx, surfaces) do
    for %{id: id} <- surfaces,
        element <- Map.get(ctx.surface_elements, id, []),
        not Map.has_key?(ctx.fragment_of, element),
        do: element
  end

  defp workflow_tasks(ctx) do
    subtasks =
      for w <- ctx.workflows do
        acts = actions(ctx, w.id)

        %Task{
          id: w.id,
          kind: :workflow,
          actor: :agent,
          parent: workflow_parent(ctx, w),
          subjects: [w.id],
          label: w.name,
          residue: residue_of(ctx, [w.id | Enum.map(acts, & &1.id)])
        }
      end

    backends =
      for w <- ctx.workflows,
          w.attrs[:backend],
          not Map.has_key?(ctx.cycle_of, w.id),
          uniq: true,
          do: backend_id(w)

    backend_tasks =
      for id <- backends do
        members = for w <- ctx.workflows, w.attrs[:backend], backend_id(w) == id, do: w.id
        %Task{id: id, kind: :backend, actor: :agent, subjects: Enum.sort(members), batch: id}
      end

    cycle_tasks =
      for members <- ctx.cycles do
        id = cycle_id(members)
        %Task{id: id, kind: :cycle, actor: :agent, subjects: members, batch: id}
      end

    subtasks ++ backend_tasks ++ cycle_tasks
  end

  # Actions of a workflow the decisions keep, in step order.
  defp actions(ctx, workflow) do
    ctx.index
    |> Index.children(workflow)
    |> Enum.filter(&(&1.kind == :action and not MapSet.member?(ctx.removed_actions, &1.id)))
    |> Enum.sort_by(&{&1.attrs[:index], &1.id})
  end

  # API groups with a call used by a kept workflow or a surface.
  defp api_tasks(ctx) do
    used = used_calls(ctx)

    ctx.model.connectors
    |> Enum.flat_map(fn group ->
      gid = Symbol.id(:api_group, group.id)

      calls =
        for c <- group.calls,
            id = Symbol.id(:api_call, [group.id, c.id]),
            Map.has_key?(used, id),
            uniq: true,
            do: id

      if calls == [],
        do: [],
        else: [api_group(group, gid) | Enum.map(calls, &api_call(ctx, gid, &1))]
    end)
  end

  defp api_group(group, gid),
    do: %Task{
      id: gid,
      kind: :api_group,
      actor: :agent,
      subjects: [gid],
      label: group.name,
      batch: gid
    }

  defp api_call(ctx, gid, id),
    do: %Task{
      id: id,
      kind: :api_call,
      actor: :agent,
      parent: gid,
      subjects: [id],
      label: label(ctx, id),
      residue: residue_of(ctx, [id])
    }

  # API call ID -> the tasks calling it (with the calling symbols).
  defp used_calls(ctx) do
    for {from, task} <- api_callers(ctx),
        ref <- Index.references_from(ctx.index, from, [:calls_api]),
        reduce: %{} do
      acc -> Map.update(acc, ref.to, [{task, from}], &[{task, from} | &1])
    end
  end

  # Symbols that can call an API (kept actions and in-scope elements and
  # surfaces), with the task they belong to.
  defp api_callers(ctx) do
    workflow_callers =
      for w <- ctx.workflows, a <- actions(ctx, w.id), do: {a.id, w.id}

    element_callers =
      for {element, _surface} <- ctx.element_surface, do: {element, element_task(ctx, element)}

    surface_callers = for s <- ctx.surfaces, do: {s.id, surface_task(ctx, s.id)}

    workflow_callers ++ element_callers ++ surface_callers
  end

  defp plugin_tasks(ctx) do
    ctx
    |> plugin_users()
    |> Enum.map(fn {plugin, users} ->
      %Task{
        id: "plugin:" <> plugin,
        kind: :plugin,
        actor: :agent,
        subjects: users |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
      }
    end)
  end

  # Plugin ID -> [{task, symbol}] of kept users (styles are the styles
  # residue task's).
  defp plugin_users(ctx) do
    for {subject, entries} <- ctx.residue,
        %{detail: %{plugin: plugin}, reason: reason} <- entries,
        reason != :plugin_style,
        task = subject_task(ctx, subject),
        reduce: %{} do
      acc -> Map.update(acc, plugin, [{task, subject}], &[{task, subject} | &1])
    end
  end

  # The task whose residue covers `subject`, or nil when out of scope.
  defp subject_task(ctx, "element:" <> _ = id),
    do: if(Map.has_key?(ctx.element_surface, id), do: element_task(ctx, id))

  defp subject_task(ctx, "workflow:" <> _ = id),
    do: if(MapSet.member?(ctx.workflow_ids, id), do: id)

  defp subject_task(ctx, "action:" <> _ = id) do
    case Index.symbol(ctx.index, id) do
      %{parent: parent} -> subject_task(ctx, parent)
      _ -> nil
    end
  end

  defp subject_task(_ctx, _id), do: nil

  defp release_tasks(ctx) do
    callers? = Enum.any?(ctx.workflows, & &1.attrs[:public])

    [
      %Task{id: "data:dry_run", kind: :data, actor: :loader},
      %Task{id: "data:full_load", kind: :data, actor: :loader},
      %Task{id: "replay:app", kind: :replay, actor: :harness},
      %Task{id: "delivery:staging", kind: :delivery, actor: :agent},
      callers? &&
        %Task{id: "delivery:callers", kind: :delivery, actor: :owner, subjects: public(ctx)},
      %Task{id: "delivery:production", kind: :delivery, actor: :owner}
    ]
    |> Enum.filter(& &1)
    |> Kernel.++(
      for step <- @cutover, do: %Task{id: "cutover:" <> step, kind: :cutover, actor: :owner}
    )
  end

  defp public(ctx), do: for(w <- ctx.workflows, w.attrs[:public], do: w.id)

  defp label(ctx, id) do
    case Index.symbol(ctx.index, id) do
      %{name: name} -> name
      _ -> nil
    end
  end

  # --- statuses ---------------------------------------------------------------

  @always_open ~w(auth setup_secrets styles_residue plugin acceptance data replay delivery cutover)a

  defp statuses(tasks) do
    children = tasks |> Map.values() |> Enum.filter(& &1.parent) |> Enum.group_by(& &1.parent)

    Map.new(tasks, fn {id, t} -> {id, %{t | status: status(t, Map.get(children, id, []))}} end)
  end

  # Generator and decision nodes are born :auto / :closed.
  defp status(%Task{status: status}, _) when status in [:auto, :closed], do: status

  defp status(%Task{kind: kind}, _) when kind in @always_open, do: :open

  defp status(%Task{residue: residue}, children) do
    if residue == [] and Enum.all?(children, &(&1.residue == [])), do: :auto, else: :open
  end

  # --- dependencies -----------------------------------------------------------

  # Candidate edges, highest priority first (a later edge that would close
  # a cycle between top-level tasks is skipped).
  defp edges(ctx, tasks) do
    Enum.concat([
      generate_edges(ctx, tasks),
      release_edges(tasks),
      early_edges(tasks),
      decision_edges(ctx, tasks),
      reusable_edges(ctx, tasks),
      fragment_edges(ctx, tasks),
      plugin_edges(ctx, tasks),
      api_edges(ctx, tasks),
      call_edges(ctx, tasks)
    ])
  end

  defp edge(from, to, kind, via \\ []), do: %{from: from, to: to, kind: kind, via: via}

  defp generate_edges(ctx, tasks) do
    chain =
      for {group, deps} <- @generate_deps,
          dep <- deps,
          do: edge(group, dep, :generate)

    entry =
      for t <- Map.values(tasks),
          t.parent == nil,
          target = generate_target(ctx, t),
          do: edge(t.id, target, :generate)

    chain ++ Enum.sort_by(entry, & &1.from)
  end

  defp generate_target(_ctx, %Task{kind: kind}) when kind in [:surface, :fragment, :plugin],
    do: "generate:surfaces"

  defp generate_target(_ctx, %Task{kind: :cycle, id: "cycle:reusable/" <> _}),
    do: "generate:surfaces"

  # A cycle of frontend workflows (custom events) lives in its surface.
  defp generate_target(ctx, %Task{kind: :cycle, subjects: subjects}) do
    if Enum.any?(subjects, &(Index.symbol(ctx.index, &1).attrs[:backend] == true)),
      do: "generate:workflow_entry_points",
      else: "generate:surfaces"
  end

  defp generate_target(_ctx, %Task{kind: kind}) when kind in [:backend, :cycle],
    do: "generate:workflow_entry_points"

  defp generate_target(_ctx, %Task{kind: kind}) when kind in [:api_group, :setup_secrets],
    do: "generate:api_clients"

  defp generate_target(_ctx, %Task{kind: :auth}), do: "generate:policies"
  defp generate_target(_ctx, %Task{kind: :styles_residue}), do: "generate:styles"

  defp generate_target(_ctx, %Task{kind: kind}) when kind in [:remove_writes, :delete_workflows],
    do: "generate:schema"

  defp generate_target(_ctx, %Task{id: "data:dry_run"}), do: "generate:schema"

  defp generate_target(_ctx, _task), do: nil

  # data -> replay -> delivery -> cutover, in a chain.
  defp release_edges(tasks) do
    has = &Map.has_key?(tasks, &1)

    implementation =
      for t <- Map.values(tasks),
          t.parent == nil,
          t.kind in [
            :acceptance,
            :backend,
            :cycle,
            :api_group,
            :auth,
            :styles_residue,
            :plugin,
            :setup_secrets
          ],
          do: edge("replay:app", t.id, :release)

    production =
      if has.("delivery:callers"),
        do: ["delivery:callers", "delivery:staging"],
        else: ["delivery:staging"]

    cutover = Enum.map(@cutover, &("cutover:" <> &1))

    [
      edge("data:full_load", "data:dry_run", :release),
      edge("replay:app", "data:full_load", :release)
      | Enum.sort_by(implementation, & &1.to)
    ] ++
      [edge("delivery:staging", "replay:app", :release)] ++
      if(has.("delivery:callers"),
        do: [edge("delivery:callers", "delivery:staging", :release)],
        else: []
      ) ++
      Enum.map(production, &edge("delivery:production", &1, :release)) ++
      [edge(hd(cutover), "delivery:production", :release)] ++
      (cutover
       |> Enum.chunk_every(2, 1, :discard)
       |> Enum.map(fn [a, b] -> edge(b, a, :release) end))
  end

  # Auth and style residue come before surfaces and workflow owners; API
  # groups with private values after the secrets.
  defp early_edges(tasks) do
    early = Enum.filter(["auth", "styles:residue"], &Map.has_key?(tasks, &1))

    owners =
      for t <- tasks |> Map.values() |> Enum.sort_by(& &1.id),
          t.parent == nil,
          t.kind in [:surface, :fragment, :backend, :cycle],
          e <- early,
          do: edge(t.id, e, :early)

    secrets =
      if Map.has_key?(tasks, "setup:secrets") do
        secret = MapSet.new(tasks["setup:secrets"].subjects)

        for t <- tasks |> Map.values() |> Enum.sort_by(& &1.id),
            t.kind == :api_group,
            Enum.any?([t.id | children_ids(tasks, t.id)], &MapSet.member?(secret, &1)),
            do: edge(t.id, "setup:secrets", :secrets)
      else
        []
      end

    owners ++ secrets
  end

  defp children_ids(tasks, id), do: for({cid, %Task{parent: ^id}} <- tasks, do: cid)

  # Parent ID -> sorted subtask IDs.
  defp children(tasks) do
    for {id, %Task{parent: parent}} <- tasks, parent != nil, reduce: %{} do
      acc -> Map.update(acc, parent, [id], &[id | &1])
    end
    |> Map.new(fn {k, v} -> {k, Enum.sort(v)} end)
  end

  # Workflows whose actions a decision removes wait for its node.
  defp decision_edges(ctx, tasks) do
    for t <- tasks |> Map.values() |> Enum.sort_by(& &1.id),
        t.kind in [:remove_writes, :delete_workflows],
        subject <- t.subjects,
        %{parent: workflow} <- [Index.symbol(ctx.index, subject)],
        Map.has_key?(tasks, workflow),
        do: edge(workflow, t.id, :decision, [subject])
  end

  # Reusables before consumers; acceptance after the surface, its fragments
  # and the acceptance of the reusables it uses.
  defp reusable_edges(ctx, _tasks) do
    instances =
      for {element, surface} <- Enum.sort(ctx.element_surface),
          ref <- Index.references_from(ctx.index, element, [:instance_of]),
          MapSet.member?(ctx.surface_ids, ref.to),
          do: {element, surface, ref.to}

    # Reusables that contain each other are built together: no edges
    # inside their group.
    instances =
      Enum.reject(instances, fn {_, surface, reusable} ->
        surface_task(ctx, surface) == surface_task(ctx, reusable)
      end)

    build =
      for {element, _surface, reusable} <- instances,
          target <- [surface_task(ctx, reusable), acceptance_id(reusable)],
          do: edge(element_task(ctx, element), target, :reusable, [element])

    accept =
      for {element, surface, reusable} <- instances,
          do: edge(acceptance_id(surface), acceptance_id(reusable), :acceptance, [element])

    build ++ accept
  end

  defp fragment_edges(ctx, tasks) do
    surface_fragments =
      for {frag, %{surface: surface}} <- Enum.sort(ctx.fragments) do
        f = "fragment:" <> bubble_id(frag)

        [
          edge(surface_task(ctx, surface), f, :fragment),
          edge(acceptance_id(surface), f, :acceptance)
        ]
      end

    acceptance =
      for s <- ctx.surfaces do
        edge(acceptance_id(s.id), surface_task(ctx, s.id), :acceptance)
      end

    # A surface's workflows in a workflow cycle task.
    cycles =
      for w <- ctx.workflows,
          cycle = ctx.cycle_of[w.id],
          not w.attrs[:backend],
          Map.has_key?(tasks, cycle),
          do: edge(acceptance_id(w.parent), cycle, :acceptance, [w.id])

    List.flatten(surface_fragments) ++ acceptance ++ Enum.sort_by(cycles, &{&1.from, &1.to})
  end

  defp plugin_edges(ctx, _tasks) do
    for {plugin, users} <- ctx |> plugin_users() |> Enum.sort(),
        {task, subject} <- Enum.sort(users),
        do: edge(task, "plugin:" <> plugin, :plugin, [subject])
  end

  defp api_edges(ctx, tasks) do
    for {call, callers} <- ctx |> used_calls() |> Enum.sort(),
        {task, from} <- Enum.sort(callers),
        group = api_group_of(call),
        Map.has_key?(tasks, group),
        do: edge(task, group, :api, [from])
  end

  defp api_group_of("api_call:" <> rest),
    do: Symbol.id(:api_group, rest |> String.split("/") |> hd() |> unescape())

  defp unescape(part), do: part |> String.replace("~1", "/") |> String.replace("~0", "~")

  # Callees before callers (inside a cycle task the edge orders nothing).
  defp call_edges(ctx, tasks) do
    for w <- ctx.workflows,
        a <- actions(ctx, w.id),
        ref <- Index.references_from(ctx.index, a.id, [:calls_workflow]),
        Map.has_key?(tasks, ref.to),
        ref.to != w.id,
        ctx.cycle_of[w.id] == nil or ctx.cycle_of[w.id] != ctx.cycle_of[ref.to],
        do: edge(w.id, ref.to, :calls, [a.id])
  end

  # --- finishing --------------------------------------------------------------

  defp finish(%Task{} = t, ctx, children) do
    covered = covered(ctx, t)
    decisions = effective(ctx, covered)
    coordinate = for %{kind: :coordinate, task: task} <- t.depends_on, do: task
    facts = ctx |> facts(t, children) |> Map.put(:coordinate, coordinate)

    %{
      t
      | decisions: Enum.map(decisions, & &1.key),
        criteria: Criteria.for_task(t, facts),
        source_sha256: source_sha256(ctx, t, covered, decisions)
    }
  end

  # The index symbols a task covers: its subjects and their descendants.
  defp covered(ctx, %Task{subjects: subjects}) do
    subjects
    |> Enum.filter(&Index.symbol(ctx.index, &1))
    |> Enum.flat_map(&[&1 | descendants(ctx.index, &1, Symbol.kinds())])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp effective(ctx, covered) do
    set = MapSet.new(covered)

    for a <- ctx.applied,
        not MapSet.disjoint?(ctx.touched[a.key], set),
        do: a
  end

  defp source_sha256(ctx, t, covered, decisions) do
    refs =
      covered
      |> Enum.flat_map(&Index.references_from(ctx.index, &1))
      |> Enum.map(&{&1.from, &1.kind, &1.to, &1.attrs})
      |> Enum.sort()
      |> Enum.map(fn {from, kind, to, attrs} ->
        %{from: from, kind: kind, to: to, attrs: attrs}
      end)

    %{
      kind: t.kind,
      subjects: t.subjects,
      content_sha256: Index.subject_sha256(ctx.index, covered),
      references: refs,
      residue: t.residue,
      decisions: Enum.map(decisions, &generation_inputs/1),
      styles: styles_input(ctx, t)
    }
    |> CanonicalJson.sha256()
  end

  @doc false
  def generation_inputs(%Applied{} = a) do
    %{
      key: a.key,
      transform: a.transform,
      automatic: a.automatic,
      target: a.target,
      params: a.params,
      proposal_sha256: a.proposal_sha256,
      basis_sha256: a.basis_sha256
    }
  end

  # Named styles are not index symbols: their normalized form stands in.
  defp styles_input(%{frontend: %Normalized{styles: styles}}, %Task{id: id})
       when id in ["generate:styles", "styles:residue"],
       do: Enum.map(styles, &Map.take(&1, [:map_key, :applies_to, :properties, :responsive]))

  defp styles_input(_ctx, _task), do: nil

  defp facts(ctx, %Task{kind: :surface, subjects: subjects} = t, children),
    do: %{
      elements: subjects ++ Enum.sort(owned_elements(ctx, symbols(ctx, subjects))),
      children: Map.get(children, t.id, [])
    }

  defp facts(
         ctx,
         %Task{kind: :cycle, id: "cycle:reusable/" <> _, subjects: subjects} = t,
         children
       ),
       do: %{
         elements: subjects ++ Enum.sort(owned_elements(ctx, symbols(ctx, subjects))),
         children: Map.get(children, t.id, [])
       }

  defp facts(ctx, %Task{kind: :fragment, subjects: [frag]}, _tasks),
    do: %{elements: Enum.sort(ctx.fragments[frag].elements)}

  defp facts(ctx, %Task{kind: :workflow, subjects: [w]}, _tasks) do
    symbol = Index.symbol(ctx.index, w)

    %{
      steps: ctx |> actions(w) |> Enum.map(& &1.attrs[:type]),
      backend: symbol.attrs[:backend] == true
    }
  end

  defp facts(ctx, %Task{kind: :acceptance, subjects: [s]}, _tasks) do
    elements = Map.get(ctx.surface_elements, s, [])
    %{elements: [s | elements], surface: surface_task(ctx, s)}
  end

  defp facts(_ctx, t, children), do: %{children: Map.get(children, t.id, [])}

  defp symbols(ctx, ids), do: Enum.map(ids, &Index.symbol(ctx.index, &1))

  # --- coverage ---------------------------------------------------------------

  defp coverage(ctx, tasks) do
    top = Enum.filter(tasks, &is_nil(&1.parent))
    residue = tasks |> Enum.flat_map(& &1.residue) |> Enum.uniq()
    with_residue = MapSet.new(residue, & &1.subject)
    elements = Map.keys(ctx.element_surface)
    kept_actions = for w <- ctx.workflows, a <- actions(ctx, w.id), do: a.id
    workflow_tasks = Enum.filter(tasks, &(&1.kind == :workflow))

    %{
      "top_level" => statuses_count(top),
      "tasks" =>
        tasks
        |> Enum.group_by(&Atom.to_string(&1.kind))
        |> Map.new(fn {k, ts} -> {k, statuses_count(ts)} end),
      "residue" => residue |> Enum.frequencies_by(&Atom.to_string(&1.reason)),
      "units" => %{
        "elements" => element_units(ctx, elements, with_residue),
        "actions" =>
          unit(kept_actions, with_residue) |> Map.put("removed", MapSet.size(ctx.removed_actions)),
        "workflows_frontend" =>
          workflow_tasks |> Enum.reject(&backend?(ctx, &1)) |> statuses_count(),
        "workflows_backend" =>
          workflow_tasks |> Enum.filter(&backend?(ctx, &1)) |> statuses_count(),
        "workflows_removed" => MapSet.size(ctx.deleted_workflows),
        "workflows_trigger_not_normalized" =>
          residue
          |> Enum.filter(&(&1.reason == :trigger_not_normalized))
          |> Enum.uniq_by(& &1.subject)
          |> length(),
        "api_calls" => api_units(ctx, tasks),
        "styles" => %{
          "total" => length(style_subjects(ctx)),
          "residue" => Enum.count(with_residue, &String.starts_with?(&1, "style:"))
        },
        "plugins" => Enum.count(tasks, &(&1.kind == :plugin)),
        "cycles" => %{
          "workflow" => length(ctx.cycles),
          "self_recursive" => ctx.self_recursive,
          "reusable" => length(ctx.reusable_cycles)
        }
      },
      "excluded" => %{
        "mobile_views" => length(ctx.mobile),
        "mobile_view_workflows" => length(ctx.excluded_workflows)
      }
    }
  end

  defp backend?(ctx, t), do: Index.symbol(ctx.index, t.id).attrs[:backend] == true

  defp statuses_count(tasks) do
    counts = Enum.frequencies_by(tasks, &Atom.to_string(&1.status))
    Map.merge(%{"total" => length(tasks), "auto" => 0, "open" => 0, "closed" => 0}, counts)
  end

  defp unit(ids, with_residue) do
    residue = Enum.count(ids, &MapSet.member?(with_residue, &1))
    %{"total" => length(ids), "generated" => length(ids) - residue, "residue" => residue}
  end

  # With a frontend, an element counts as generated only when it was
  # normalized and has no residue; one normalization never reached (inside
  # a runtime container) is `not_normalized`, whatever its residue. Without
  # one, `not_normalized` is nil and generated means no residue.
  defp element_units(%{frontend: nil}, elements, with_residue),
    do: elements |> unit(with_residue) |> Map.put("not_normalized", nil)

  defp element_units(%{frontend: frontend}, elements, with_residue) do
    present = Residue.normalized_ids(frontend)
    {normalized, missing} = Enum.split_with(elements, &MapSet.member?(present, bubble_id(&1)))
    residue = Enum.count(normalized, &MapSet.member?(with_residue, &1))

    %{
      "total" => length(elements),
      "generated" => length(normalized) - residue,
      "residue" => residue,
      "not_normalized" => length(missing),
      "not_normalized_with_residue" => Enum.count(missing, &MapSet.member?(with_residue, &1))
    }
  end

  defp api_units(ctx, tasks) do
    calls = ids(ctx.index, [:api_call])
    planned = Enum.filter(tasks, &(&1.kind == :api_call))

    %{
      "total" => length(calls),
      "referenced" => length(planned),
      "generated" => Enum.count(planned, &(&1.status == :auto)),
      "residue" => Enum.count(planned, &(&1.status == :open))
    }
  end
end
