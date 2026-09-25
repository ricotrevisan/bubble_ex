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

  alias BubbleEx.Target.Ash.{
    Action,
    Bypass,
    Calculation,
    Expressions,
    FieldPolicy,
    Naming,
    Policy,
    PolicyCheck,
    Project,
    Resource,
    ResourcePrivacy
  }

  @doc false
  # Adds policies to every resource of `project`. Returns the project and
  # the policies' diagnostics (with the rules' expression diagnostics).
  @spec apply(Project.t(), Model.t()) :: {Project.t(), [Diagnostic.t()]}
  def apply(%Project{} = project, %Model{} = model) do
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
    expression_diags = Enum.flat_map(compiled, & &1.diagnostics)

    actor_loads =
      resources
      |> Enum.flat_map(& &1.calculations)
      |> Enum.flat_map(& &1.expr.actor_loads)
      |> Enum.uniq()
      |> Enum.sort()

    project = %{project | resources: resources, names: names, actor_loads: actor_loads}
    diags = [unverified(project) | Enum.reverse(diags)] ++ expression_diags
    {project, List.flatten(diags)}
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
  defp gate(resources, names) do
    {resources, {names, twins}} =
      Enum.map_reduce(resources, {names, %{}}, fn resource, {names, twins} ->
        entry = get_in(names, ["resources", resource.source.type])
        {resource, entry, twins} = gate_resource(resource, entry, twins)
        {resource, {put_in(names, ["resources", resource.source.type], entry), twins}}
      end)

    modules = Map.new(resources, &{&1.module, &1})

    resources =
      Enum.map(resources, fn resource ->
        calculations =
          Enum.map(resource.calculations, fn calc ->
            %{calc | expr: rewrite_expr(calc.expr, modules, twins)}
          end)

        %{resource | calculations: calculations}
      end)

    {resources, names}
  end

  defp gate_resource(%Resource{} = resource, entry, twins) do
    checks = for fp <- resource.field_policies, f <- fp.fields, into: %{}, do: {f, fp.checks}

    used =
      MapSet.new(
        Enum.map(resource.attributes, & &1.name) ++
          Enum.map(resource.relationships, & &1.name) ++
          Enum.map(resource.calculations, & &1.name) ++
          Map.values(Map.get(entry, "privacy_relationships", %{}))
      )

    {relationships, {privacy, entry, _used, twins}} =
      Enum.map_reduce(resource.relationships, {[], entry, used, twins}, fn rel, acc ->
        case gate_of(Map.get(checks, rel.source_attribute, [])) do
          nil -> {rel, acc}
          gate -> twin(rel, gate, resource, acc)
        end
      end)

    resource = %{
      resource
      | relationships: relationships,
        privacy_relationships: Enum.reverse(privacy)
    }

    {resource, entry, twins}
  end

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
    twins = Map.put(twins, {resource.module, rel.name}, name)
    {%{rel | gate: gate}, {[twin | privacy], entry, used, twins}}
  end

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

  # --- one resource ----------------------------------------------------------------

  defp resource(resource, type, by_rule, project, entry) do
    fields = fields(resource)

    case type.privacy do
      :present -> rules(resource, type, fields, by_rule, project, entry)
      :none -> fixed(resource, type, fields, :public_default, entry)
      :unavailable -> fixed(resource, type, fields, :unavailable, entry)
    end
  end

  # Non-key attributes by Bubble field ID, in attribute order.
  defp fields(resource) do
    for a <- resource.attributes, not a.primary_key?, a.source[:field], do: {a.source.field, a}
  end

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

    privacy = %ResourcePrivacy{
      source: source,
      attachments: checks,
      file_fields: file_fields(type, fields),
      data_api: %{exposed: type.exposed_api, create: [], modify: [], delete: []}
    }

    resource = %{
      resource
      | actions: @write_defaults,
        extra_actions: [read_action(), search_action()],
        policies: [read_policy(checks), search_policy(checks)],
        field_policies: field_policies(Enum.map(fields, fn {_id, a} -> {a.name, checks} end)),
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

        {{a.name, checks}, ctx}
      end)

    {auto_bind, ctx} = auto_binding(ctx, fields)
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

    privacy = %ResourcePrivacy{
      source: :rules,
      compiled_rules: for(r <- others, MapSet.member?(compiled, r.id), do: r.id),
      denied_rules: denied,
      attachments: attachments,
      file_fields: file_fields(type, fields),
      data_api: Map.new(api) |> Map.put(:exposed, type.exposed_api)
    }

    resource = %{
      resource
      | actions: @write_defaults,
        extra_actions: [read_action(), search_action()] ++ auto_bind.actions,
        calculations: ctx.order |> Enum.reverse() |> Enum.map(&Map.fetch!(ctx.calculations, &1)),
        policies: [read_policy(read), search_policy(search)] ++ auto_bind.policies,
        field_policies: field_policies(field_checks),
        privacy: privacy
    }

    diags =
      Enum.reverse(ctx.diags) ++
        default_diags(ctx) ++
        denied_rules(type, denied, ctx) ++
        field_list_diags(type, others ++ List.wrap(default), ctx) ++
        attachments_diag(type, privacy) ++
        data_api(type, privacy)

    {resource, ctx.entry, diags}
  end

  # The names a privacy calculation may not take: the resource's attributes
  # and relationships, and the locked calculation names.
  defp used_names(resource, entry) do
    MapSet.new(
      Enum.map(resource.attributes, & &1.name) ++
        Enum.map(resource.relationships, & &1.name) ++
        Map.values(Map.get(entry, "privacy_rules", %{}))
    )
  end

  defp visible_fields(perms, ctx),
    do: for(f <- perms.view_fields || [], Map.has_key?(ctx.fields, f), do: f)

  defp binding_fields(perms, ctx),
    do: for(f <- perms.binding_fields || [], Map.has_key?(ctx.fields, f), do: f)

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
    guards =
      irs
      |> Enum.flat_map(&record_values/1)
      |> Enum.uniq()
      |> Enum.map(&IR.node(:not, [IR.node(:is_empty, [&1], "boolean")], "boolean"))

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

  # The outermost field chains read from the rule's record (`This Thing's
  # a's b`), not from the actor.
  defp record_values(%IR{op: :field, args: [base | _]} = ir) do
    if record_based?(base), do: [strip_path(ir)], else: []
  end

  defp record_values(%IR{args: args}), do: Enum.flat_map(args, &record_values/1)
  defp record_values(list) when is_list(list), do: Enum.flat_map(list, &record_values/1)
  defp record_values(_), do: []

  defp record_based?(%IR{op: :this, args: [binder]}), do: binder in [:rule_record, :filter_item]
  defp record_based?(%IR{op: :field, args: [base | _]}), do: record_based?(base)
  defp record_based?(_), do: false

  # Source paths differ between occurrences of the same chain.
  defp strip_path(%IR{args: args} = ir),
    do: %{ir | path: nil, args: Enum.map(args, &strip_path/1)}

  defp strip_path(other), do: other

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
              "a value a condition reads (e.g. logged out) or a record value it reads is empty",
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
          "an authorized read that does not select by primary key returns nothing"
    }

  defp search_action,
    do: %Action{
      type: :read,
      name: "search",
      description: "Bubble \"Do a search for\": the records the user may find in searches"
    }

  defp read_policy(checks),
    do: %Policy{
      action: "read",
      permission: :view,
      description:
        "Direct view (by ID, or through a reference): the user may view some field of the record",
      checks: checks
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
