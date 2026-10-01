defmodule BubbleEx.Target.Ash.Policies do
  @moduledoc false

  # Privacy rules to Ash policies (WTF-356), as data on each resource of a
  # mapped Project. Called by `BubbleEx.Target.Ash.map/3`; the semantics are
  # documented there ("Privacy rules").
  #
  # For a Bubble permission `p` of a data type with non-default rules R and
  # the `everyone` rule E (which applies to users no other rule matches), a
  # user holds `p` when
  #
  #     OR(c_r for r in R granting p)  or  (E grants p and not OR(c_r for r in R))
  #
  # which simplifies to `OR(c_r granting p) or not OR(c_r for r in R lacking
  # p)` when E grants p (and to `always` when no rule lacks it). Each c_r is
  # the rule's condition compiled fail-safe by `Target.Ash.Expressions`; the
  # negation is compiled by the same compiler, so its actor guards are kept
  # (it is false when the actor lacks what a condition reads). A condition
  # that does not compile grants nothing, and blocks E's grants it would
  # have to be negated for: never an allow.

  alias BubbleEx.{Diagnostic, Model}

  # `:read` is generated as a keyed action (`read_action/0`), not a default.
  @write_defaults [:destroy, create: :*, update: :*]
  alias BubbleEx.Expression.IR
  alias BubbleEx.Model.Type

  alias BubbleEx.Verify.Difference

  alias BubbleEx.Target.Ash.{
    Action,
    Attribute,
    Bypass,
    Calculation,
    Expr,
    Expressions,
    FieldPolicy,
    Naming,
    Policy,
    PolicyCheck,
    Project,
    Relationship,
    Resource,
    ResourcePrivacy
  }

  @doc false
  # Adds policies to every resource of `project`. Returns the project and
  # the policies' diagnostics (with the rules' expression diagnostics).
  @spec apply(Project.t(), Model.t()) :: {Project.t(), [Diagnostic.t()]}
  def apply(%Project{} = project, %Model{} = model) do
    project = member_rows(project)
    {:ok, compiled} = Expressions.privacy(model, project)
    by_rule = Map.new(compiled, &{{&1.type, &1.rule}, &1})
    types = Map.new(model.data_types, &{&1.id, &1})

    {resources, {diags, names}} =
      Enum.map_reduce(project.resources, {[], project.names}, fn resource, {diags, names} ->
        type = Map.fetch!(types, resource.source.type)
        entry = get_in(names, ["resources", type.id])
        {resource, entry, more} = resource(resource, type, by_rule, project, entry)
        {resource, {[more | diags], put_in(names, ["resources", type.id], entry)}}
      end)

    {resources, names} = gate(resources, names)
    joins = Enum.map(project.joins, &join_policies(&1, resources))
    {resources, joins} = search_field_policies(resources, joins)

    expression_diags =
      Enum.flat_map(compiled, & &1.diagnostics) ++ aggregate_diags(resources, types)

    actor_loads =
      resources
      |> Enum.flat_map(& &1.calculations)
      |> Enum.flat_map(& &1.expr.actor_loads)
      |> Enum.uniq()
      |> Enum.sort()

    project = %{
      project
      | resources: resources,
        joins: joins,
        names: names,
        actor_loads: actor_loads
    }

    diags = [unverified(project) | Enum.reverse(diags)] ++ expression_diags
    {project, List.flatten(diags)}
  end

  @doc false
  # `privacy: :enforced` (WTF-423, Rico's option A): the policies of
  # `apply/2`, plus one policy per default write action authorizing the
  # writes of the generated workflow runtime (`:workflow_write`). Other
  # writes stay forbidden. The "not verified" warning becomes the warning
  # that writes are not checked against the privacy rules.
  @spec enforce(Project.t(), [Diagnostic.t()], Model.t()) :: {Project.t(), [Diagnostic.t()]}
  def enforce(%Project{} = project, diags, %Model{} = model) do
    resources =
      Enum.map(project.resources, &(&1 |> workflow_writes() |> attachments() |> view_search()))

    {resources, joins} =
      search_field_policies(resources, Enum.map(project.joins, &workflow_writes/1))

    project = %{project | resources: resources, joins: joins}

    diags = Enum.reject(diags, &(&1.code == :ash_policies_unverified))
    {project, writes_unchecked(project) ++ view_search_diags(project, model) ++ diags}
  end

  # WTF-457: a search's filter or sort is code, which field policies do
  # not guard. With enforced policies, the fields some users may not view
  # (and the gated relationships) are restricted in reads like Bubble's
  # non-filterable fields (`view_search_fields`, checked by
  # `<namespace>.Privacy.SearchFields`): a read whose filter or sort names
  # one returns only the records where the actor may view it. Bubble
  # evaluates such a constraint against the stored value for every user
  # who may search by the field: stricter than Bubble by the owner's
  # decision (`BubbleEx.Verify.Difference`, `hidden_field_constraint_matches`).
  defp view_search(%Resource{privacy: %ResourcePrivacy{} = p, field_policies: [_ | _]} = r) do
    fields =
      for %FieldPolicy{checks: checks, fields: names} <- r.field_policies,
          not visible_to_all?(checks),
          name <- names,
          into: %{},
          do: {name, [checks]}

    gated = for %Relationship{gate: gate} = rel <- r.relationships, gate != nil, do: rel

    # A gated relationship, its join rows relationship (a many_to_many),
    # and its private ungated twin (`*_for_privacy`, `gate/2`), which
    # reaches the same records: restricted by the relationship's checks.
    # The twins are named before `through/2`, so a derived field or count
    # reading through one (`gate/2` rewrote its path) is restricted too.
    relationships =
      for rel <- gated,
          groups = [view_checks(rel, r)],
          related <- [rel | twins_of(rel, r.privacy_relationships)],
          name <- [related.name | List.wrap(join_name(related))],
          into: %{},
          do: {name, groups}

    own = Map.merge(fields, relationships)
    %{r | privacy: %{p | view_search_fields: through(own, r)}}
  end

  defp view_search(resource), do: resource

  defp path(nil), do: ""
  defp path(type), do: type.path <> "/privacy_role"

  defp twins_of(rel, privacy_relationships),
    do: Enum.filter(privacy_relationships, &(&1.kind == rel.kind and &1.source == rel.source))

  defp join_name(%Relationship{kind: :many_to_many, join_relationship: name}), do: name
  defp join_name(_rel), do: nil

  defp visible_to_all?(checks),
    do: Enum.any?(checks, &match?(%PolicyCheck{kind: :authorize_if, test: :always}, &1))

  # A gated relationship follows its ID attribute's checks (a belongs_to)
  # or those of the list it replaces; with neither, nobody may follow it.
  defp view_checks(%Relationship{kind: :belongs_to} = rel, resource) do
    Enum.find_value(resource.field_policies, [], fn fp ->
      if rel.source_attribute in fp.fields, do: fp.checks
    end)
  end

  defp view_checks(rel, resource), do: Map.get(resource.privacy.relationship_checks, rel.name, [])

  defp view_search_diags(%Project{} = project, %Model{} = model) do
    types = Map.new(model.data_types, &{&1.id, &1})

    for %Resource{privacy: %ResourcePrivacy{view_search_fields: vsf}} = r <- project.resources,
        map_size(vsf) > 0 do
      names = vsf |> Map.keys() |> Enum.sort()
      type = r.source[:type]

      Diagnostic.new(
        :ash_policy_hidden_search_stricter_than_bubble,
        path(types[type]),
        "#{type}: some users may not view #{Enum.join(names, ", ")}; a :read or :search " <>
          "whose filter or sort names one returns only the records where the actor may view " <>
          "it (<namespace>.Privacy.SearchFields), where Bubble matches the stored value for " <>
          "every user who may search by it (stricter than Bubble by design)",
        target: :ash,
        subject: %{type: type},
        details: %{
          fields: names,
          flags: Enum.map(Difference.flags(:search_constraints), &Atom.to_string/1)
        }
      )
    end
  end

  defp workflow_writes(%Resource{policies: []} = resource), do: resource

  defp workflow_writes(%Resource{} = resource) do
    writes =
      for action <- ~w(create update destroy) do
        %Policy{
          action: action,
          permission: :workflow_write,
          description:
            "Writes by the generated workflow runtime: the workflow's conditions guard them, " <>
              "as in Bubble (not checked against the privacy rules)",
          checks: [
            %PolicyCheck{
              kind: :authorize_if,
              test: :workflow_write,
              source: %{decision: "WTF-423"}
            }
          ]
        }
      end

    %{resource | policies: resource.policies ++ writes}
  end

  # Bubble's "view attached files" as a keyed read action, `:attachments`,
  # on a resource with file fields: the generated app reads the record a
  # private file is attached to through it (by primary key), with the
  # actor, to decide whether to serve the file. Its policy is the
  # permission's checks.
  defp attachments(%Resource{privacy: %ResourcePrivacy{file_fields: [_ | _]} = p} = r) do
    action = %Action{
      type: :read,
      name: "attachments",
      description:
        "Bubble's \"view attached files\": the record, by primary key, when the user may " <>
          "open the files attached to it"
    }

    policies = [
      %Policy{
        action: "attachments",
        permission: :keyed,
        description: "Attached files are reached through their record's primary key",
        checks: [%PolicyCheck{kind: :authorize_if, test: :keyed}]
      },
      %Policy{
        action: "attachments",
        permission: :view_attachments,
        description: "The user may view the files attached to the record",
        checks: p.attachments
      }
    ]

    %{r | extra_actions: r.extra_actions ++ [action], policies: r.policies ++ policies}
  end

  defp attachments(resource), do: resource

  defp writes_unchecked(%Project{resources: []}), do: []

  defp writes_unchecked(%Project{}) do
    [
      Diagnostic.new(
        :ash_writes_not_policy_checked,
        "",
        "privacy: :enforced - reads follow the compiled privacy rules; writes are not checked " <>
          "against them: a write the generated workflow runtime makes is authorized (its " <>
          "conditions guard it, as in Bubble), any other write is forbidden",
        target: :ash
      )
    ]
  end

  # Ash field policies do not apply to aggregates (count, min, max, sum,
  # list, first, ...) over a field: diagnosed wherever some field is not
  # visible to everyone, since a policy cannot tell an aggregate from a read.
  defp aggregate_diags(resources, types) do
    for resource <- resources,
        hidden =
          for(
            fp <- resource.field_policies,
            fp.checks != [
              %PolicyCheck{kind: :authorize_if, test: :always, source: %{default: true}}
            ],
            f <- fp.fields,
            do: f
          ),
        hidden != [] do
      type = Map.fetch!(types, resource.source.type)

      Diagnostic.new(
        :ash_policy_aggregates_unguarded,
        type.path,
        "#{type.id}: Ash field policies do not cover aggregates; an aggregate over " <>
          "#{Enum.join(hidden, ", ")} reads values some users may not view",
        target: :ash,
        subject: %{type: type.id},
        details: %{fields: hidden}
      )
    end
  end

  # --- gated relationships -----------------------------------------------------------

  # Ash field policies do not cover relationships: a `belongs_to` whose ID
  # attribute some users may not view would still load, filter and sort the
  # record it names. Such a relationship gets a `filter` requiring the
  # checks that authorize its ID attribute (`gate`), and a private ungated
  # twin that only the privacy calculations and the actor loads read
  # through (they must see the real reference, or they would depend on
  # themselves). Every relationship path in the calculations and actor
  # loads is rewritten to the twins.
  #
  # A field derived by an owner decision reads through twins as well, of
  # gated and ungated relationships alike: public relationships are
  # unsortable, and a derived field must sort.
  defp gate(resources, names) do
    needed = derived_paths(resources)

    {resources, {names, twins}} =
      Enum.map_reduce(resources, {names, %{}}, fn resource, {names, twins} ->
        entry = get_in(names, ["resources", resource.source.type])
        {resource, entry, twins} = gate_resource(resource, entry, twins, needed)
        {resource, {put_in(names, ["resources", resource.source.type], entry), twins}}
      end)

    modules = Map.new(resources, &{&1.module, &1})

    # A field derived by an owner decision reads through the twins too: it
    # stands for a stored copy, which the related record's visibility did
    # not hide, and its own field policy guards it like that copy.
    resources =
      Enum.map(resources, fn resource ->
        calculations =
          Enum.map(resource.calculations, fn calc ->
            %{calc | expr: rewrite_expr(calc.expr, modules, twins)}
          end)

        # A derived count reads through the twins too.
        aggregates =
          Enum.map(resource.aggregates, fn agg ->
            %{agg | path: rewrite_path(agg.path, resource.module, modules, twins)}
          end)

        %{resource | calculations: calculations, aggregates: aggregates}
      end)

    {resources, names}
  end

  # `{module, relationship}` pairs the derived calculations and aggregates
  # read through.
  defp derived_paths(resources) do
    modules = Map.new(resources, &{&1.module, &1})

    for resource <- resources,
        path <-
          Enum.flat_map(
            for(%Calculation{kind: :derived} = c <- resource.calculations, do: c.expr.expr),
            &expr_paths/1
          ) ++ Enum.map(resource.aggregates, & &1.path),
        pair <- walk_path(path, resource.module, modules),
        into: MapSet.new(),
        do: pair
  end

  # Relationship paths (lists of names) an expression reads through.
  defp expr_paths({:ref, rels, _attribute}), do: [rels]
  defp expr_paths({:call, _name, args}), do: Enum.flat_map(args, &expr_paths/1)
  defp expr_paths({:op, _op, l, r}), do: expr_paths(l) ++ expr_paths(r)
  defp expr_paths({bool, nodes}) when bool in [:and, :or], do: Enum.flat_map(nodes, &expr_paths/1)
  defp expr_paths({:not, node}), do: expr_paths(node)
  defp expr_paths(_node), do: []

  defp walk_path([], _module, _modules), do: []

  defp walk_path([name | rest], module, modules) do
    case modules[module] && Enum.find(modules[module].relationships, &(&1.name == name)) do
      nil -> []
      rel -> [{module, name} | walk_path(rest, rel.destination, modules)]
    end
  end

  defp gate_resource(%Resource{} = resource, entry, twins, needed) do
    checks = for fp <- resource.field_policies, f <- fp.fields, into: %{}, do: {f, fp.checks}

    used =
      MapSet.new(
        Enum.map(resource.attributes, & &1.name) ++
          Enum.map(resource.relationships ++ resource.privacy_relationships, & &1.name) ++
          join_relationships(resource) ++
          Enum.map(resource.calculations, & &1.name) ++
          Enum.map(resource.aggregates, & &1.name) ++
          Map.values(Map.get(entry, "privacy_relationships", %{}))
      )

    {relationships, {privacy, entry, _used, twins}} =
      Enum.map_reduce(resource.relationships, {[], entry, used, twins}, fn rel, acc ->
        case {gate_of(relationship_checks(rel, checks, resource)),
              MapSet.member?(needed, {resource.module, rel.name})} do
          {nil, false} -> {rel, acc}
          {gate, _} -> twin(rel, gate, resource, acc)
        end
      end)

    unsortable = &%{&1 | sortable?: false}
    resource = twin_search_fields(resource, relationships, privacy)

    # The private twins stay sortable: `sort_input` cannot name a private
    # relationship, and a derived field (a public calculation guarded by
    # its own field policy) reads through them and must sort.
    # (the twins, then the join rows relationships `member_rows/1` added)
    resource = %{
      resource
      | relationships: Enum.map(relationships, unsortable),
        privacy_relationships: Enum.reverse(privacy) ++ resource.privacy_relationships
    }

    {resource, entry, twins}
  end

  # A private twin is restricted in searches like the relationship it
  # mirrors.
  defp twin_search_fields(
         %Resource{privacy: %ResourcePrivacy{search_fields: sf} = p} = r,
         rels,
         twins
       )
       when map_size(sf) > 0 do
    sf =
      Enum.reduce(twins, sf, fn twin, sf ->
        case Enum.find(rels, &(&1.kind == twin.kind and &1.source == twin.source)) do
          %{name: name} when is_map_key(sf, name) -> Map.put(sf, twin.name, sf[name])
          _ -> sf
        end
      end)

    %{r | privacy: %{p | search_fields: sf}}
  end

  defp twin_search_fields(resource, _rels, _twins), do: resource

  defp twin(rel, gate, resource, {privacy, entry, used, twins}) do
    field = rel.source.field

    {name, used, entry} =
      case get_in(entry, ["privacy_relationships", field]) do
        nil ->
          {name, used} = Naming.claim(rel.name <> "_for_privacy", used, :snake, :attribute)

          entry =
            Map.update(
              entry,
              "privacy_relationships",
              %{field => name},
              &Map.put(&1, field, name)
            )

          {name, used, entry}

        name ->
          {name, used, entry}
      end

    twin = %{rel | name: name, public?: false, gate: nil}

    # A many_to_many twin has its own relationship to the join rows.
    {twin, used} =
      case rel do
        %Relationship{kind: :many_to_many} ->
          {join, used} = Naming.claim(name <> "_join", used, :snake, :attribute)
          {%{twin | join_relationship: join}, used}

        _ ->
          {twin, used}
      end

    twins = Map.put(twins, {resource.module, rel.name}, name)
    {%{rel | gate: gate}, {[twin | privacy], entry, used, twins}}
  end

  defp join_relationships(resource) do
    for %Relationship{join_relationship: name} <- resource.relationships, name, do: name
  end

  # A belongs_to follows its ID attribute's checks; a derived has_many and
  # a many_to_many through a join follow those of the list they replace.
  defp relationship_checks(%Relationship{kind: kind} = rel, _checks, resource)
       when kind in [:has_many, :many_to_many],
       do: Map.get(resource.privacy.relationship_checks, rel.name, [])

  defp relationship_checks(rel, checks, _resource), do: Map.get(checks, rel.source_attribute, [])

  # Who may follow a relationship: those its ID attribute's checks
  # authorize. nil: everyone.
  defp gate_of(checks) do
    always? = Enum.any?(checks, &match?(%PolicyCheck{kind: :authorize_if, test: :always}, &1))
    calcs = for %PolicyCheck{kind: :authorize_if, test: {:calculation, c}} <- checks, do: c

    cond do
      always? -> nil
      calcs == [] -> :never
      true -> {:visible_if, calcs}
    end
  end

  defp rewrite_expr(expr, modules, twins) do
    user = actor_module(modules)

    %{
      expr
      | expr: rewrite_node(expr.expr, expr.resource, user, modules, twins),
        actor_loads:
          Enum.map(expr.actor_loads, &rewrite_path(&1, user, modules, twins))
          |> Enum.uniq()
          |> Enum.sort()
    }
  end

  defp actor_module(modules) do
    Enum.find_value(modules, fn {module, r} -> if r.source.type == "user", do: module end)
  end

  defp rewrite_node({:ref, rels, last}, module, _user, modules, twins) do
    path = rewrite_path(rels ++ [last], module, modules, twins)
    {init, [last]} = Enum.split(path, -1)
    {:ref, init, last}
  end

  defp rewrite_node({:actor, path}, _module, user, modules, twins),
    do: {:actor, rewrite_path(path, user, modules, twins)}

  defp rewrite_node({:op, op, l, r}, module, user, modules, twins),
    do:
      {:op, op, rewrite_node(l, module, user, modules, twins),
       rewrite_node(r, module, user, modules, twins)}

  defp rewrite_node({bool, nodes}, module, user, modules, twins) when bool in [:and, :or],
    do: {bool, Enum.map(nodes, &rewrite_node(&1, module, user, modules, twins))}

  defp rewrite_node({:not, node}, module, user, modules, twins),
    do: {:not, rewrite_node(node, module, user, modules, twins)}

  defp rewrite_node({:call, name, args}, module, user, modules, twins),
    do: {:call, name, Enum.map(args, &rewrite_node(&1, module, user, modules, twins))}

  defp rewrite_node(other, _module, _user, _modules, _twins), do: other

  # A path of relationship names (then possibly an attribute) from
  # `module`: each gated relationship is replaced by its twin.
  defp rewrite_path([], _module, _modules, _twins), do: []

  defp rewrite_path([name | rest], module, modules, twins) do
    case modules[module] && Enum.find(modules[module].relationships, &(&1.name == name)) do
      nil ->
        [name | rest]

      rel ->
        [
          Map.get(twins, {module, name}, name)
          | rewrite_path(rest, rel.destination, modules, twins)
        ]
    end
  end

  # --- join resources (WTF-352 cut 3) -----------------------------------------------

  # For every list normalized to a join, a private has_many on the
  # member's resource to the join rows naming it as member
  # (`<owner>_<list>_rows`, in `privacy_relationships` with source `%{type,
  # list: %{type, field}}`): a rule testing the current user's normalized
  # list reads it (`exists(rows, <owner column> == ^actor(:id))`,
  # `BubbleEx.Target.Ash.Expressions`). Named in the member's attribute
  # scope, not locked: only generated calculations use it.
  defp member_rows(%Project{joins: []} = project), do: project

  defp member_rows(%Project{} = project) do
    by_type = Map.new(project.resources, &{&1.source.type, &1})

    rows =
      for j <- project.joins, side <- j.join.sides do
        member = if side.owner == :left, do: j.join.right, else: j.join.left
        {member.type, %{join: j, side: side, column: member.column}}
      end

    resources =
      Enum.map(project.resources, fn r ->
        entry = get_in(project.names, ["resources", r.source.type]) || %{}

        rows
        |> Enum.filter(&(elem(&1, 0) == r.source.type))
        |> Enum.reduce(r, fn {_type, row}, r ->
          owner = Map.fetch!(by_type, row.side.type)

          used =
            MapSet.union(
              used_names(r, entry),
              MapSet.new(Map.values(Map.get(entry, "privacy_relationships", %{})))
            )

          base =
            Naming.base(
              :snake,
              Naming.underscore(owner.module) <> " " <> row.side.relationship,
              nil,
              "join"
            ) <> "_rows"

          {name, _used} = Naming.claim(base, used, :snake, :attribute)

          rel = %Relationship{
            kind: :has_many,
            name: name,
            destination: row.join.module,
            source_attribute: Enum.find(r.attributes, & &1.primary_key?).name,
            destination_attribute: row.column,
            public?: false,
            membership: row.side.marker,
            source: %{type: r.source.type, list: %{type: row.side.type, field: row.side.field}}
          }

          %{r | privacy_relationships: r.privacy_relationships ++ [rel]}
        end)
      end)

    %{project | resources: resources}
  end

  # A join resource's rows are the members of the lists it replaces
  # (`normalize_list_to_join`, `membership_policy`). A row reveals that its
  # owner's list holds its member, so it is readable only by an actor who
  # may view that list on that owner: the checks of the list field (its
  # many_to_many's `relationship_checks`, read through the join's private
  # belongs_to to the owner). For a join both mirrored lists share, the
  # actor must be able to view both (a row stands for both lists, and
  # Bubble may have shown only one): never wider than Bubble, possibly
  # narrower. Its `:read` is keyed like every resource's: rows are reached
  # through a relationship (the many_to_many, or the owner's join
  # relationship), never listed. No policy authorizes writes.
  defp join_policies(%Resource{join: join} = r, resources) do
    by_type = Map.new(resources, &{&1.source.type, &1})
    source = %{join: join.id}
    used = MapSet.new(Enum.map(r.attributes, & &1.name) ++ Enum.map(r.relationships, & &1.name))

    # Per list: who may view it on its owner (a condition on the join row),
    # as a private calculation `privacy_<list>` when it is neither always
    # nor never.
    {sides, used} =
      Enum.map_reduce(join.sides, used, &side_calculation(&1, &2, r, by_type, source))

    # A row is readable when it is a member of a list the actor may view
    # on its owner: its membership column holds a position (not null) or a
    # true flag, and that list's grants
    # hold. Each list's membership column (its position) reads only for
    # those who may view that list.
    visible =
      for {side, node, calc} <- sides, node != :never do
        member = member_node(side.marker)
        if node == :always, do: member, else: {:and, [member, {:ref, [], calc.name}]}
      end

    {row_checks, row_calcs} =
      case visible do
        [] ->
          {[deny()], []}

        nodes ->
          {name, _used} = Naming.claim("privacy_visible", used, :snake, :attribute)

          calc = %Calculation{
            name: name,
            source: source,
            description:
              "The row is a member of a list the actor may view on its owner record " <>
                "(its membership column holds a position, or a true flag)",
            expr: %Expr{
              resource: r.module,
              source: source,
              expr: if(match?([_], nodes), do: hd(nodes), else: {:or, nodes})
            }
          }

          {[%PolicyCheck{kind: :authorize_if, test: {:calculation, name}, source: source}],
           [calc]}
      end

    field_policies =
      for {side, node, calc} <- sides,
          do: %FieldPolicy{fields: [side.marker.column], checks: side_checks(node, calc, source)}

    %{
      r
      | actions: @write_defaults,
        extra_actions: [read_action()],
        calculations: for({_, _, %Calculation{} = c} <- sides, do: c) ++ row_calcs,
        relationships: Enum.map(r.relationships, &%{&1 | public?: false}),
        field_policies: field_policies,
        policies:
          [
            keyed_policy(),
            %Policy{
              action: "read",
              permission: :view,
              description:
                "Rows of the lists this join replaces: a member of a list the actor may view " <>
                  "on its owner",
              checks: row_checks
            }
          ] ++ Enum.flat_map(sides, &side_policies(&1, by_type, source))
    }
  end

  # Rows read through one list's relationships (the owner's join
  # relationships, through which its many_to_many loads, and the member's
  # rows relationship) are that list's rows: readable only when the actor
  # may view that list on the owner, even if another list sharing the
  # table shows the row.
  defp side_policies({side, node, calc}, by_type, source) do
    owner = Map.fetch!(by_type, side.type)

    member_type =
      Enum.find_value(owner.relationships, fn rel ->
        if rel.kind == :many_to_many and rel.source.field == side.field, do: rel.destination
      end)

    member = Enum.find(Map.values(by_type), &(&1.module == member_type))

    paths =
      for rel <- owner.relationships ++ owner.privacy_relationships,
          rel.kind == :many_to_many,
          rel.source[:field] == side.field,
          do: {owner.module, rel.join_relationship}

    paths =
      paths ++
        for rel <- member.privacy_relationships,
            rel.source[:list] == %{type: side.type, field: side.field},
            do: {member.module, rel.name}

    checks = side_checks(node, calc, source)

    for {module, rel} <- Enum.sort(paths) do
      %Policy{
        action: "read",
        accessing_from: {module, rel},
        permission: :view,
        description:
          "Rows of #{side.type}.#{side.field} read through #{rel}: the actor may view the list",
        checks: checks
      }
    end
  end

  defp side_checks(:always, _calc, _source),
    do: [%PolicyCheck{kind: :authorize_if, test: :always, source: %{default: true}}]

  defp side_checks(:never, _calc, _source), do: [deny()]

  defp side_checks(_node, calc, source),
    do: [%PolicyCheck{kind: :authorize_if, test: {:calculation, calc.name}, source: source}]

  # Who may view one list on the row's owner: `{side, node, calc}` with
  # a private calculation `privacy_<list>` unless the node is `:always` or
  # `:never`.
  defp side_calculation(side, used, r, by_type, source) do
    join = r.join
    owner = Map.fetch!(by_type, side.type)
    checks = Map.get(owner.privacy.relationship_checks, side.relationship, [])
    rel = if side.owner == :left, do: join.left.relationship, else: join.right.relationship

    case side_condition(gate_of(checks), rel) do
      node when node in [:always, :never] ->
        {{side, node, nil}, used}

      node ->
        {name, used} = Naming.claim("privacy_" <> side.relationship, used, :snake, :attribute)

        calc = %Calculation{
          name: name,
          source: Map.put(source, :list, %{type: side.type, field: side.field}),
          description:
            "The actor may view #{side.type}.#{side.field} (the list) on the row's owner record",
          expr: %Expr{resource: r.module, source: source, expr: node}
        }

        {{side, node, calc}, used}
    end
  end

  defp member_node(%{column: c, kind: :position}), do: {:not, {:call, "is_nil", [{:ref, [], c}]}}
  defp member_node(%{column: c, kind: :flag}), do: {:op, "==", {:ref, [], c}, {:value, true}}

  defp side_condition(nil, _rel), do: :always
  defp side_condition(:never, _rel), do: :never

  defp side_condition({:visible_if, calcs}, rel) do
    case Enum.map(calcs, &{:ref, [rel], &1}) do
      [one] -> one
      many -> {:or, many}
    end
  end

  # --- one resource ----------------------------------------------------------------

  defp resource(resource, type, by_rule, project, entry) do
    fields = fields(resource)

    case type.privacy do
      :present -> rules(resource, type, fields, by_rule, project, entry)
      :none -> fixed(resource, type, fields, :public_default, entry)
      :unavailable -> fixed(resource, type, fields, :unavailable, entry)
    end
  end

  # Non-key attributes by Bubble field ID, in attribute order, then the
  # fields derived by an owner decision (calculations, aggregates and
  # has_many relationships): a derived field is guarded like the field it
  # replaces (a has_many, which has no field policy, through its gate).
  defp fields(resource) do
    attributes =
      for a <- resource.attributes, not a.primary_key?, a.source[:field], do: {a.source.field, a}

    derived =
      for %Calculation{kind: :derived} = c <- resource.calculations, do: {c.source.field, c}

    aggregates = for g <- resource.aggregates, do: {g.source.field, g}

    has_many =
      for %Relationship{kind: kind} = r <- resource.relationships,
          kind in [:has_many, :many_to_many],
          do: {r.source.field, r}

    attributes ++ derived ++ aggregates ++ has_many
  end

  # Field policies for the fields, and the checks of the derived has_many
  # relationships (`privacy.relationship_checks`).
  defp split_checks(field_checks) do
    {rels, fields} = Enum.split_with(field_checks, &match?({%Relationship{}, _}, &1))

    {field_policies(Enum.map(fields, fn {f, checks} -> {f.name, checks} end)),
     Map.new(rels, fn {r, checks} -> {r.name, checks} end)}
  end

  # What auto-binding may write: stored attributes only.
  defp stored_fields(fields), do: Enum.filter(fields, &match?({_, %Attribute{}}, &1))

  defp file_fields(type, fields) do
    files =
      for f <- type.system_fields ++ type.fields,
          match?(%Type{kind: :file_ref}, f.type),
          into: MapSet.new(),
          do: f.id

    for {id, a} <- fields, MapSet.member?(files, id), do: a.name
  end

  # Bubble's public defaults (a type listed without rules), or no access at
  # all when the source does not include the rules.
  defp fixed(resource, type, fields, source, entry) do
    {kind, check_source} =
      if source == :public_default, do: {:authorize_if, %{default: true}}, else: {:forbid_if, %{}}

    checks = [%PolicyCheck{kind: kind, test: :always, source: check_source}]

    {field_policies, relationship_checks} =
      split_checks(Enum.map(fields, fn {_id, a} -> {a, checks} end))

    privacy = %ResourcePrivacy{
      source: source,
      attachments: checks,
      file_fields: file_fields(type, fields),
      data_api: %{exposed: type.exposed_api, create: [], modify: [], delete: []},
      relationship_checks: relationship_checks
    }

    resource = %{
      resource
      | actions: @write_defaults,
        extra_actions: [read_action(), search_action()],
        policies: [keyed_policy(), read_policy(checks), search_policy(checks)],
        field_policies: field_policies,
        privacy: privacy
    }

    diags =
      if source == :unavailable,
        do: [
          Diagnostic.new(
            :ash_privacy_rules_unavailable,
            type.path,
            "the source does not include #{type.id}'s privacy rules; every read is denied",
            target: :ash,
            subject: %{type: type.id}
          )
        ],
        else: []

    {resource, entry, diags ++ data_api(type, privacy)}
  end

  defp rules(resource, type, fields, by_rule, project, entry) do
    field_names = Map.new(fields, fn {id, a} -> {id, a.name} end)
    {default, others} = Enum.split_with(type.rules, & &1.default?)
    default = List.first(default)

    compiled =
      for r <- others,
          match?(%{expr: %{}}, by_rule[{type.id, r.id}]),
          into: MapSet.new(),
          do: r.id

    ctx = %{
      type: type,
      resource: resource,
      project: project,
      default: default,
      others: others,
      compiled: compiled,
      by_rule: by_rule,
      fields: field_names,
      entry: entry,
      used: used_names(resource, entry),
      calculations: %{},
      order: [],
      negated: [],
      blocked: [],
      diags: []
    }

    view_any = fn perms -> perms.view_all == true or visible_fields(perms, ctx) != [] end
    {read, ctx} = checks(ctx, :view, view_any)
    {search, ctx} = checks(ctx, :search_for, &(&1.search_for == true))

    {field_checks, ctx} =
      Enum.map_reduce(fields, ctx, fn {id, a}, ctx ->
        {checks, ctx} =
          checks(ctx, {:view_field, id}, &(&1.view_all == true or id in visible_fields(&1, ctx)))

        {{a, checks}, ctx}
      end)

    {field_policies, relationship_checks} = split_checks(field_checks)
    {search_fields, ctx} = search_fields(ctx, fields, resource)

    {auto_bind, ctx} = auto_binding(ctx, stored_fields(fields))
    {attachments, ctx} = checks(ctx, :view_attachments, &(&1.view_attachments == true))

    {api, ctx} =
      Enum.map_reduce(
        [create: :create_via_api, modify: :modify_via_api, delete: :delete_via_api],
        ctx,
        fn {key, flag}, ctx ->
          {checks, ctx} = checks(ctx, flag, &(Map.get(&1, flag) == true))
          {{key, checks}, ctx}
        end
      )

    denied = for r <- others, not MapSet.member?(compiled, r.id), do: r.id

    stricter =
      for r <- others,
          MapSet.member?(compiled, r.id),
          Difference.affected?(by_rule[{type.id, r.id}].ir),
          do: r.id

    everyone = stricter_everyone(default, others, fields)

    privacy = %ResourcePrivacy{
      source: :rules,
      compiled_rules: for(r <- others, MapSet.member?(compiled, r.id), do: r.id),
      denied_rules: denied,
      stricter_rules: stricter ++ everyone,
      stricter_flags:
        Map.new(stricter, &{&1, Difference.rule_flags(by_rule[{type.id, &1}].ir)})
        |> Map.merge(Map.new(everyone, &{&1, Difference.everyone_flags()})),
      attachments: attachments,
      file_fields: file_fields(type, fields),
      data_api: Map.new(api) |> Map.put(:exposed, type.exposed_api),
      relationship_checks: relationship_checks,
      search_fields: search_fields
    }

    resource = %{
      resource
      | actions: @write_defaults,
        extra_actions: [read_action(), search_action()] ++ auto_bind.actions,
        calculations:
          resource.calculations ++
            (ctx.order |> Enum.reverse() |> Enum.map(&Map.fetch!(ctx.calculations, &1))),
        policies:
          [keyed_policy(), read_policy(read), search_policy(search)] ++ auto_bind.policies,
        field_policies: field_policies,
        privacy: privacy
    }

    diags =
      Enum.reverse(ctx.diags) ++
        default_diags(ctx) ++
        denied_rules(type, denied, ctx) ++
        stricter_rules(type, stricter, ctx) ++
        field_list_diags(type, others ++ List.wrap(default), ctx) ++
        search_fields_diag(type, search_fields) ++
        binding_dropped(type, others ++ List.wrap(default), fields) ++
        attachments_diag(type, privacy) ++
        data_api(type, privacy)

    {resource, ctx.entry, diags}
  end

  # The names a privacy calculation may not take: the resource's attributes
  # and relationships, and the locked calculation names.
  defp used_names(resource, entry) do
    MapSet.new(
      Enum.map(resource.attributes, & &1.name) ++
        Enum.map(resource.relationships ++ resource.privacy_relationships, & &1.name) ++
        join_relationships(resource) ++
        Enum.map(resource.calculations, & &1.name) ++
        Enum.map(resource.aggregates, & &1.name) ++
        Map.values(Map.get(entry, "privacy_rules", %{})) ++
        Map.values(Map.get(entry, "columns", %{}))
    )
  end

  defp visible_fields(perms, ctx),
    do: for(f <- perms.view_fields || [], Map.has_key?(ctx.fields, f), do: f)

  defp binding_fields(perms, ctx),
    do: for(f <- perms.binding_fields || [], Map.has_key?(ctx.fields, f), do: f)

  # --- fields users may not search by -------------------------------------------------

  # Bubble's non-filterable fields: for each field some rule lists (and the
  # project maps), who may use it in a search: a rule they match finds the
  # record (`search_for`) and does not list the field (the same union as
  # every permission, the everyone rule included). `%{name => groups}`:
  # every group of checks must authorize, for the attribute (or derived
  # field) and for what reads through it: the `belongs_to` of a reference,
  # its private twin (`gate/2`), and a derived field or count whose path
  # starts at a restricted field. A field every user may search by is not
  # listed.
  defp search_fields(ctx, fields, resource) do
    rules = ctx.others ++ List.wrap(ctx.default)

    listed =
      for %{permissions: %{} = p} <- rules,
          f <- p.non_filterable_fields || [],
          Map.has_key?(ctx.fields, f),
          into: MapSet.new(),
          do: f

    {own, ctx} =
      fields
      |> Enum.filter(fn {id, _} -> MapSet.member?(listed, id) end)
      |> Enum.map_reduce(ctx, fn {id, item}, ctx ->
        {checks, ctx} = checks(ctx, {:filter_field, id}, &filterable?(&1, id))
        {{item.name, checks}, ctx}
      end)

    own = for {name, checks} <- own, not always?(checks), into: %{}, do: {name, [checks]}
    {through(own, resource), ctx}
  end

  defp filterable?(perms, id),
    do: perms.search_for == true and id not in (perms.non_filterable_fields || [])

  defp always?([%PolicyCheck{kind: :authorize_if, test: :always}]), do: true
  defp always?(_checks), do: false

  defp through(own, _resource) when map_size(own) == 0, do: own

  defp through(own, resource) do
    restricted =
      for %Relationship{kind: :belongs_to} = r <- resource.relationships,
          Map.has_key?(own, r.source_attribute),
          into: own,
          do: {r.name, own[r.source_attribute]}

    derived =
      for(
        %Calculation{kind: :derived} = c <- resource.calculations,
        do: {c.name, expr_heads(c.expr.expr)}
      ) ++ for(g <- resource.aggregates, do: {g.name, Enum.take(g.path, 1)})

    Enum.reduce(derived, restricted, fn {name, heads}, acc ->
      case heads |> Enum.flat_map(&Map.get(restricted, &1, [])) |> Enum.uniq() do
        [] -> acc
        groups -> Map.update(acc, name, groups, &Enum.uniq(&1 ++ groups))
      end
    end)
  end

  # The names an expression reads first: a relationship, or an attribute
  # of the resource itself.
  defp expr_heads({:ref, [], attribute}), do: [attribute]
  defp expr_heads({:ref, [rel | _], _attribute}), do: [rel]
  defp expr_heads({:call, _name, args}), do: Enum.flat_map(args, &expr_heads/1)
  defp expr_heads({:op, _op, l, r}), do: expr_heads(l) ++ expr_heads(r)
  defp expr_heads({bool, nodes}) when bool in [:and, :or], do: Enum.flat_map(nodes, &expr_heads/1)
  defp expr_heads({:not, node}), do: expr_heads(node)
  defp expr_heads(_node), do: []

  defp search_fields_diag(_type, search_fields) when map_size(search_fields) == 0, do: []

  defp search_fields_diag(type, search_fields) do
    names = search_fields |> Map.keys() |> Enum.sort()

    [
      Diagnostic.new(
        :ash_policy_search_fields_restricted,
        type.path <> "/privacy_role",
        "#{type.id}: some users may not search by #{Enum.join(names, ", ")}; a :read or " <>
          ":search whose filter or sort names one returns only the records where the actor " <>
          "may (<namespace>.Privacy.SearchFields), but aggregates over them are not guarded",
        target: :ash,
        subject: %{type: type.id},
        details: %{fields: names}
      )
    ]
  end

  # The resources (and joins) a read could reach a restricted field from,
  # through their relationships: each gets a policy on its read actions
  # (`authorize_if <namespace>.Privacy.SearchFields`).
  defp search_field_policies(resources, joins) do
    all = resources ++ joins

    restricted =
      for r <- resources,
          r.privacy && (r.privacy.search_fields != %{} or r.privacy.view_search_fields != %{}),
          do: r.module

    edges =
      Map.new(all, fn r ->
        {r.module, Enum.map(r.relationships ++ r.privacy_relationships, & &1.destination)}
      end)

    reach = reaching(MapSet.new(restricted), edges)
    add = &if(MapSet.member?(reach, &1.module), do: add_search_fields_policies(&1), else: &1)
    {Enum.map(resources, add), Enum.map(joins, add)}
  end

  defp reaching(set, edges) do
    more =
      for {module, destinations} <- edges,
          not MapSet.member?(set, module),
          Enum.any?(destinations, &MapSet.member?(set, &1)),
          into: set,
          do: module

    if MapSet.size(more) == MapSet.size(set), do: set, else: reaching(more, edges)
  end

  # Idempotent (`enforce/2` runs it again with the fields some users may
  # not view); `:attachments` reads by primary key only.
  defp add_search_fields_policies(%Resource{} = r) do
    guarded = [
      "attachments" | for(%Policy{permission: :search_fields, action: a} <- r.policies, do: a)
    ]

    actions =
      for %Action{type: :read, name: name} <- r.extra_actions, name not in guarded, do: name

    policies =
      for action <- actions do
        %Policy{
          action: action,
          permission: :search_fields,
          description:
            "A filter or sort naming a field some users may not search by returns only the " <>
              "records where the actor may",
          checks: [%PolicyCheck{kind: :authorize_if, test: :search_fields}]
        }
      end

    %{r | policies: r.policies ++ policies}
  end

  # --- grants ------------------------------------------------------------------------

  # The checks granting a permission: `holds` tells whether a rule's
  # permissions grant it.
  defp checks(ctx, permission, holds) do
    holds = fn rule -> rule.permissions != nil and holds.(rule.permissions) end
    granting = for r <- ctx.others, holds.(r), MapSet.member?(ctx.compiled, r.id), do: r
    lacking = for r <- ctx.others, not holds.(r), do: r

    case default_grant(ctx, permission, holds, lacking) do
      {:always, ctx} ->
        {[%PolicyCheck{kind: :authorize_if, test: :always, source: %{default: true}}], ctx}

      {default, ctx} ->
        {rule_checks, ctx} = Enum.map_reduce(granting, ctx, &rule_check/2)
        checks = rule_checks ++ List.wrap(default)
        if checks == [], do: {[deny()], ctx}, else: {checks, ctx}
    end
  end

  # The everyone rule's part: nothing, `:always`, or a check that no rule
  # lacking the permission holds.
  defp default_grant(%{default: nil} = ctx, _permission, _holds, _lacking), do: {nil, ctx}

  defp default_grant(ctx, permission, holds, lacking) do
    cond do
      not holds.(ctx.default) -> {nil, ctx}
      lacking == [] -> {:always, ctx}
      true -> except(ctx, permission, lacking)
    end
  end

  defp deny, do: %PolicyCheck{kind: :forbid_if, test: :always, source: %{}}

  defp rule_check(rule, ctx) do
    {name, ctx} = rule_calculation(rule, ctx)

    {%PolicyCheck{kind: :authorize_if, test: {:calculation, name}, source: %{rules: [rule.id]}},
     ctx}
  end

  defp rule_calculation(rule, ctx) do
    key = {:rule, rule.id}

    case ctx.calculations do
      %{^key => calc} ->
        {calc.name, ctx}

      _ ->
        {name, ctx} = claim_rule_name(rule, ctx)
        %{expr: expr} = Map.fetch!(ctx.by_rule, {ctx.type.id, rule.id})

        calc = %Calculation{
          name: name,
          expr: expr,
          source: %{type: ctx.type.id, rule: rule.id},
          description: "Bubble privacy rule #{rule_label(rule)}: its condition holds"
        }

        {name, add_calculation(ctx, key, calc)}
    end
  end

  # Rule calculation names are kept in the name map (`privacy_rules`), so a
  # rule renamed in Bubble does not rename code.
  defp claim_rule_name(rule, ctx) do
    case get_in(ctx.entry, ["privacy_rules", rule.id]) do
      nil ->
        base = Naming.base(:snake, "privacy rule " <> (rule.name || rule.id), nil, "privacy_rule")
        {name, used} = Naming.claim(base, ctx.used, :snake, :attribute)

        entry =
          Map.update(ctx.entry, "privacy_rules", %{rule.id => name}, &Map.put(&1, rule.id, name))

        {name, %{ctx | used: used, entry: entry}}

      name ->
        {name, ctx}
    end
  end

  # "No rule in `lacking` matches": the `everyone` rule's grant of a
  # permission some rules lack. Compiled as one negated condition, so the
  # compiler keeps its actor guards.
  defp except(ctx, permission, lacking) do
    ids = Enum.map(lacking, & &1.id)
    key = {:except, ids}
    blocked = Enum.reject(ids, &MapSet.member?(ctx.compiled, &1))

    cond do
      blocked != [] ->
        {nil, blocked_default(ctx, permission, blocked)}

      Map.has_key?(ctx.calculations, key) ->
        {except_check(ctx.calculations[key].name, ids), negated(ctx, permission, ids)}

      true ->
        compile_except(ctx, permission, key, lacking)
    end
  end

  defp compile_except(ctx, permission, {:except, ids} = key, lacking) do
    irs = Enum.map(lacking, &Map.fetch!(ctx.by_rule, {ctx.type.id, &1.id}).ir)
    any = if match?([_], irs), do: hd(irs), else: IR.node(:or, irs, "boolean")
    subject = %{type: ctx.type.id}

    # The compiled conditions are fail-safe for the actor, not for record
    # values whose Bubble emptiness semantics are unverified ("is no" on an
    # empty field, empty-is-empty, dangling references): negating them could
    # grant where Bubble would not. So the negation also requires every
    # record-side value the conditions read to be non-empty, and can only
    # under-grant.
    guards = Expressions.record_guards(irs)

    negation = IR.node(:and, [IR.node(:not, [any], "boolean") | guards], "boolean")

    {:ok, result} =
      Expressions.filter(negation, ctx.project,
        resource: ctx.type.id,
        source: Map.put(subject, :except_rules, ids),
        subject: subject,
        path: ctx.type.path <> "/privacy_role"
      )

    case result do
      %{expr: nil, diagnostics: diags} ->
        ctx = %{ctx | diags: Enum.reverse(diags) ++ ctx.diags}
        {nil, blocked_default(ctx, permission, ids)}

      %{expr: expr} ->
        {name, used} = Naming.claim("privacy_everyone_else", ctx.used, :snake, :attribute)

        calc = %Calculation{
          name: name,
          expr: expr,
          source: Map.put(subject, :except_rules, ids),
          description:
            "The Bubble \"everyone else\" rule applies: none of the rules " <>
              Enum.join(ids, ", ") <> " holds"
        }

        ctx = add_calculation(%{ctx | used: used}, key, calc)
        {except_check(name, ids), negated(ctx, permission, ids)}
    end
  end

  defp except_check(name, ids),
    do: %PolicyCheck{
      kind: :authorize_if,
      test: {:calculation, name},
      source: %{default: true, except_rules: ids}
    }

  defp add_calculation(ctx, key, calc),
    do: %{ctx | calculations: Map.put(ctx.calculations, key, calc), order: [key | ctx.order]}

  defp negated(ctx, permission, ids),
    do: %{ctx | negated: [{permission_key(permission), ids} | ctx.negated]}

  defp blocked_default(ctx, permission, blocked),
    do: %{ctx | blocked: [{permission_key(permission), blocked} | ctx.blocked]}

  # One diagnostic per type for the everyone rule's negated grants, and one
  # for its denied ones.
  defp default_diags(ctx) do
    path = ctx.type.path <> "/privacy_role/everyone"
    subject = %{type: ctx.type.id, rule: "everyone"}

    negated =
      if ctx.negated == [] do
        []
      else
        entries = Enum.reverse(ctx.negated)

        [
          Diagnostic.new(
            :ash_policy_default_rule_negated,
            path,
            "#{ctx.type.id}: the everyone rule grants #{length(entries)} permission(s) only " <>
              "when some other rules do not hold; that negation denies when the actor lacks " <>
              "a value a condition reads (e.g. logged out) or a record value it reads is empty " <>
              "(stricter than Bubble by design: Bubble's everyone rule reaches every user)",
            target: :ash,
            subject: subject,
            details: %{
              permissions: Enum.map(entries, &elem(&1, 0)),
              except_rules: entries |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
            }
          )
        ]
      end

    blocked =
      if ctx.blocked == [] do
        []
      else
        entries = Enum.reverse(ctx.blocked)
        rules = entries |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

        [
          Diagnostic.new(
            :ash_policy_default_grant_denied,
            path,
            "#{ctx.type.id}: #{length(entries)} grant(s) of the everyone rule are denied: they " <>
              "apply only when #{Enum.join(rules, ", ")} does not hold, which does not compile",
            target: :ash,
            subject: subject,
            details: %{permissions: Enum.map(entries, &elem(&1, 0)), blocking_rules: rules}
          )
        ]
      end

    negated ++ blocked
  end

  defp permission_key({:view_field, field}), do: "view_field:" <> field
  defp permission_key({:bind_field, field}), do: "bind_field:" <> field
  defp permission_key({:filter_field, field}), do: "filter_field:" <> field
  defp permission_key(permission), do: Atom.to_string(permission)

  defp rule_label(%{name: nil, id: id}), do: inspect(id)
  defp rule_label(%{name: name, id: id}), do: "#{inspect(name)} (#{id})"

  # --- auto-binding --------------------------------------------------------------------

  # An `:auto_bind` update accepting every field some rule lets users
  # auto-bind: one policy for the action (some auto-binding grant holds)
  # and one per field (a grant naming that field holds when it changes).
  defp auto_binding(ctx, fields) do
    rules = ctx.others ++ List.wrap(ctx.default)

    bindable =
      for {id, a} <- fields, Enum.any?(rules, &binds?(&1.permissions, id, ctx)), do: {id, a.name}

    if bindable == [] do
      {%{actions: [], policies: []}, ctx}
    else
      {base, ctx} =
        checks(ctx, :auto_binding, &(&1.auto_binding == true and binding_fields(&1, ctx) != []))

      {per_field, ctx} =
        Enum.map_reduce(bindable, ctx, fn {id, name}, ctx ->
          {checks, ctx} = checks(ctx, {:bind_field, id}, &binds?(&1, id, ctx))

          policy = %Policy{
            action: "auto_bind",
            changing: [name],
            permission: :auto_binding,
            description:
              "Auto-binding changes #{name}: a rule letting the user auto-bind it holds",
            checks: checks
          }

          {policy, ctx}
        end)

      action = %Action{
        type: :update,
        name: "auto_bind",
        accept: Enum.map(bindable, &elem(&1, 1)),
        description: "Bubble auto-binding: an input writes one field of the record"
      }

      base_policy = %Policy{
        action: "auto_bind",
        permission: :auto_binding,
        description: "Auto-binding: a rule letting the user auto-bind some field holds",
        checks: base
      }

      {%{actions: [action], policies: [base_policy | per_field]}, ctx}
    end
  end

  defp binds?(nil, _id, _ctx), do: false
  defp binds?(perms, id, ctx), do: perms.auto_binding == true and id in binding_fields(perms, ctx)

  # --- policies ------------------------------------------------------------------------

  defp read_action,
    do: %Action{
      type: :read,
      name: "read",
      primary?: true,
      keyed?: true,
      description:
        "Direct view: records reached by primary key (Ash.get, relationship loads); " <>
          "an authorized read or aggregate that does not select by primary key is forbidden"
    }

  defp search_action,
    do: %Action{
      type: :read,
      name: "search",
      description: "Bubble \"Do a search for\": the records the user may find in searches"
    }

  # Two policies on :read (both must pass): the key requirement, kept apart
  # from the grants so Ash's SAT solving stays small.
  defp keyed_policy,
    do: %Policy{
      action: "read",
      permission: :keyed,
      description:
        "Direct view reaches records by primary key or through a relationship, never by listing",
      checks: [%PolicyCheck{kind: :authorize_if, test: :keyed}]
    }

  defp read_policy(checks),
    do: %Policy{
      action: "read",
      permission: :view,
      checks: checks,
      description:
        "Direct view (by ID, or through a reference): the user may view some field of the record"
    }

  defp search_policy(checks),
    do: %Policy{
      action: "search",
      permission: :search_for,
      description: "Searches: the user may find the record in searches",
      checks: checks
    }

  # Fields with the same checks share a field policy, in attribute order.
  defp field_policies(field_checks) do
    field_checks
    |> Enum.chunk_by(&elem(&1, 1))
    |> Enum.map(fn [{_, checks} | _] = group -> {checks, Enum.map(group, &elem(&1, 0))} end)
    |> Enum.reduce([], fn {checks, names}, acc ->
      case Enum.find_index(acc, &(&1.checks == checks)) do
        nil -> [%FieldPolicy{fields: names, checks: checks} | acc]
        i -> List.update_at(acc, i, &%{&1 | fields: &1.fields ++ names})
      end
    end)
    |> Enum.reverse()
  end

  # --- diagnostics -----------------------------------------------------------------------

  defp unverified(%Project{resources: []}), do: []

  defp unverified(%Project{}) do
    Diagnostic.new(
      :ash_policies_unverified,
      "",
      "the generated policies are not verified against Bubble (WTF-384/385); " <>
        "do not ship them to users",
      target: :ash
    )
  end

  # The everyone rule's reach is stricter than Bubble's when some rule
  # lacks a view, search or field it grants: Bubble's everyone rule
  # reaches every user, the policy only the users none of those rules
  # matches (`everyone_exclusive`, WTF-467). Otherwise it is `always`.
  defp stricter_everyone(%{permissions: %{} = p}, others, fields) do
    perms = Enum.map(others, & &1.permissions)

    if Difference.everyone_narrowed?(p, perms, Enum.map(fields, &elem(&1, 0))),
      do: ["everyone"],
      else: []
  end

  defp stricter_everyone(_default, _others, _fields), do: []

  defp stricter_rules(type, stricter, ctx) do
    rules = Map.new(ctx.others, &{&1.id, &1})

    for id <- stricter do
      rule = Map.fetch!(rules, id)
      flags = Difference.rule_flags(ctx.by_rule[{type.id, id}].ir)

      Diagnostic.new(
        :ash_policy_stricter_than_bubble,
        rule.path,
        "#{type.id}: privacy rule #{rule_label(rule)} #{stricter_reason(flags)}, Bubble may " <>
          "grant and the policy denies (stricter than Bubble by design)",
        target: :ash,
        subject: %{type: type.id, rule: id},
        details: %{flags: Enum.map(flags, &Atom.to_string/1)}
      )
    end
  end

  defp stricter_reason(flags) do
    actor = :actor_empty_denies in flags
    yes_no = :empty_yes_no_is_no in flags

    cond do
      actor and yes_no ->
        "reads the current user and compares a yes/no; where the user is logged out or " <>
          "lacks a value it reads, or the yes/no is empty"

      yes_no ->
        "compares a yes/no; where it is empty (Bubble reads it as no)"

      true ->
        "reads the current user; where the user is logged out or lacks a value it reads"
    end
  end

  defp denied_rules(type, denied, ctx) do
    rules = Map.new(ctx.others, &{&1.id, &1})

    for id <- denied do
      rule = Map.fetch!(rules, id)

      Diagnostic.new(
        :ash_policy_rule_denied,
        rule.path,
        "#{type.id}: privacy rule #{rule_label(rule)} has no compiled condition; it grants nothing",
        target: :ash,
        subject: %{type: type.id, rule: id},
        details: %{granted: granted(rule.permissions)}
      )
    end
  end

  defp granted(nil), do: []

  defp granted(perms) do
    for flag <-
          ~w(view_all search_for view_attachments auto_binding create_via_api modify_via_api delete_via_api)a,
        Map.get(perms, flag) == true,
        do: Atom.to_string(flag)
  end

  defp field_list_diags(type, rules, ctx) do
    for rule <- rules,
        rule.permissions,
        missing =
          Enum.uniq(
            for f <-
                  (rule.permissions.view_fields || []) ++ (rule.permissions.binding_fields || []),
                not Map.has_key?(ctx.fields, f),
                do: f
          ),
        missing != [] do
      Diagnostic.new(
        :ash_policy_field_unmapped,
        rule.path <> "/permissions",
        "#{type.id}: privacy rule #{rule_label(rule)} lists fields the project does not map " <>
          "(#{Enum.join(missing, ", ")}); they are ignored",
        target: :ash,
        subject: %{type: type.id, rule: rule.id},
        details: %{fields: missing}
      )
    end
  end

  # Fields a rule lets users auto-bind that a decision no longer stores
  # (derived, or a list normalized to a join): not auto-bindable.
  defp binding_dropped(type, rules, fields) do
    derived =
      for {id, item} <- fields, not match?(%Attribute{}, item), into: %{}, do: {id, item.name}

    dropped =
      for rule <- rules,
          perms = rule.permissions,
          perms != nil and perms.auto_binding == true,
          f <- perms.binding_fields || [],
          Map.has_key?(derived, f),
          uniq: true,
          do: f

    if dropped == [] do
      []
    else
      [
        Diagnostic.new(
          :ash_policy_auto_binding_dropped,
          type.path <> "/privacy_role",
          "#{type.id}: privacy rules let users auto-bind #{Enum.join(Enum.sort(dropped), ", ")}, " <>
            "which an owner decision no longer stores (derived, or a list normalized to a " <>
            "join); the :auto_bind action does not accept them",
          target: :ash,
          subject: %{type: type.id},
          details: %{
            fields: Enum.sort(dropped),
            names: Enum.map(Enum.sort(dropped), &derived[&1])
          }
        )
      ]
    end
  end

  defp attachments_diag(_type, %ResourcePrivacy{file_fields: []}), do: []

  defp attachments_diag(_type, %ResourcePrivacy{
         attachments: [%{kind: :authorize_if, test: :always}]
       }),
       do: []

  defp attachments_diag(type, privacy) do
    [
      Diagnostic.new(
        :ash_policy_attachments_unenforced,
        type.path <> "/privacy_role",
        "#{type.id}: \"view attached files\" is not granted to everyone, and Ash cannot " <>
          "enforce it on file fields (#{Enum.join(privacy.file_fields, ", ")}): the file store must",
        target: :ash,
        subject: %{type: type.id},
        details: %{fields: privacy.file_fields}
      )
    ]
  end

  defp data_api(%{exposed_api: true} = type, _privacy) do
    [
      Diagnostic.new(
        :ash_policy_data_api_unmapped,
        type.path <> "/exposed_api",
        "#{type.id} is exposed through Bubble's Data API; no API actions are generated " <>
          "(the Data API is out of scope unless requested)",
        target: :ash,
        subject: %{type: type.id}
      )
    ]
  end

  defp data_api(_type, _privacy), do: []

  # --- workflows ignoring privacy rules ------------------------------------------------

  @doc false
  # Workflows that run ignoring privacy rules (`BubbleEx.Index`), as
  # bypass requirements with diagnostics.
  @spec bypasses(BubbleEx.Index.t()) :: {[Bypass.t()], [Diagnostic.t()]}
  def bypasses(%BubbleEx.Index{} = index) do
    symbols = Map.new(index.symbols, &{&1.id, &1})

    workflows =
      for %{kind: :workflow, attrs: %{runs_ignoring_privacy_rules: true}} = s <- index.symbols,
          do: s

    reads =
      for r <- index.references,
          r.attrs[:ignore_privacy_rules] == true,
          r.kind in [:reads_type, :reads_field],
          workflow = owner(r.from, symbols),
          type = type_of(r.to),
          uniq: true,
          do: {workflow, type}

    bypasses =
      for s <- Enum.sort_by(workflows, & &1.bubble_id) do
        %Bypass{
          workflow: s.bubble_id,
          own: s.attrs[:ignore_privacy_rules] == true,
          types: for({w, t} <- reads, w == s.id, do: t) |> Enum.uniq() |> Enum.sort()
        }
      end

    paths = Map.new(workflows, &{&1.bubble_id, &1.path})

    diags =
      for b <- bypasses do
        Diagnostic.new(
          :ash_policy_bypass_required,
          paths[b.workflow] || "",
          "workflow #{b.workflow} runs ignoring privacy rules; lowered, its reads need an " <>
            "explicit authorization bypass (authorize?: false)",
          target: :ash,
          subject: %{workflow: b.workflow},
          details: %{own: b.own, types: b.types}
        )
      end

    {bypasses, diags}
  end

  defp owner(id, symbols) do
    case symbols[id] do
      %{kind: :workflow} -> id
      %{parent: parent} when is_binary(parent) -> owner(parent, symbols)
      _ -> nil
    end
  end

  defp type_of("data_type:" <> type), do: type
  defp type_of("field:" <> rest), do: rest |> String.split("/") |> hd()
  defp type_of(_), do: nil
end
