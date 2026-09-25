defmodule BubbleEx.Target.Ash.Expressions do
  @moduledoc """
  Compiles expression IR (`BubbleEx.Expression.IR`) to `Ash.Expr` filters
  described as data (`BubbleEx.Target.Ash.Expr`), against a mapped
  `BubbleEx.Target.Ash.Project` whose names it uses. The first consumer is
  privacy rules (WTF-356): `privacy/2` compiles every rule condition of a
  Model.

      {:ok, project} = BubbleEx.Target.Ash.map(model)
      {:ok, [%{type: "task", rule: "owner_", expr: %Expr{} = expr, diagnostics: []} | _]} =
        BubbleEx.Target.Ash.Expressions.privacy(model, project)

      BubbleEx.Target.Ash.Source.expr(expr)
      #=> "expr(creator_id == ^actor(:id))"

  ## Mapping

  | IR | `Ash.Expr` |
  |----|-----------|
  | `This Thing` (the rule's record, a search's item) | its primary key: `id` |
  | `This Thing's a's b` | `a.b` through `belongs_to` relationships; a record-valued last step is its `<name>_id` attribute |
  | `Current User` | `^actor(:id)` |
  | `Current User's a's b` | `^actor([:a, :b])`; `a` goes in `actor_loads` |
  | option value | its stored key (the enum value), checked against the generated enum |
  | literal | the literal |
  | `x is y` | `x == y` when either side cannot be empty (a literal, an option, the record's ID) or is read from the actor; otherwise (two record-side values) `is_not_distinct_from(x, y)` |
  | `x is not y` | `x != y` when neither side can be empty; otherwise `is_distinct_from(x, y)`, with `not is_nil(a)` for every actor-side operand `a` |
  | `x is empty` | a reference with a `belongs_to`: `not exists(rel, true)` (a dangling ID is empty; there are no foreign keys), `is_nil(^actor([..., :rel]))` on the actor side; otherwise `is_nil(x)`, also `x == ""` for text and `x == []` for a list |
  | `>`, `<`, `>=`, `<=` | the operator |
  | `and`, `or`, `not` | the operator |
  | a yes/no value used as a condition | `x == true` |
  | `logged in` | `not is_nil(^actor(:id))` |
  | `list contains item` | `item in list` (lists of things are `{:array, :string}` of IDs, WTF-338) |
  | `list doesn't contain item` | `is_nil(list) or is_nil(item) or not (item in list)` (an empty list contains nothing); an actor-side item must not be empty and an actor-side list needs a logged-in actor |
  | `not x` for a yes/no value | `is_distinct_from(x, true)` (empty is not yes), guarded like `is not` on the actor side |
  | `text contains string` | `contains(text, string)` |
  | `+`, `-`, `*`, `/` on numbers | the operator |
  | a context input (element value, parameter, …) | `^arg(:name)`, listed in `arguments`, where allowed (`inputs: :arguments`); unsupported in privacy rules |

  ## Empty values and the actor

  A filter never matches because the actor is logged out or lacks a value
  it reads (fail-safe): every atomic comparison with an actor-side operand
  is false when that operand is empty, in either polarity. Empty is
  Bubble's emptiness, as `is empty` tests it: nil, `""` for text, `[]` for
  a list. For lists this is a deliberate choice over Bubble's "an empty
  list doesn't contain X": an actor with an empty (or no) list is denied
  `doesn't contain` / `is not contained by`, since a privacy grant must
  not follow from the actor lacking data. `not`, `is no`
  and `is not` are pushed down to the atoms (De Morgan), so a guard is
  never negated; `a is b` between yes/no values of which one is a
  condition reading the actor is expanded to `(a and b) or (not a and not
  b)` (a stored yes/no side is `== true` / `== false`: empty is neither).
  A condition reading the actor used as any other value is rejected. The
  one exception is `is empty` on an actor-side value, which tests the
  emptiness itself: it only requires a logged-in actor. Between two record-side values, `is` keeps
  what we take to be Bubble's rule, that an empty value equals an empty
  value; that rule is **not verified against Bubble** (pending the replay
  tests of WTF-384/385), and neither is Bubble's treatment of a dangling
  reference compared with `is` (here it is its stored ID). An empty list
  contains nothing.

  `actor_loads` lists the relationships the `^actor(...)` templates read
  through. The actor must be loaded with them freshly for each request or
  LiveView mount: a stale actor struct would evaluate against old values.

  ## Diagnostics

  Anything else (a path through a list of things, a field of a context
  input, list algebra, counts, fallbacks, text operators other than
  lowercase, searches inside a filter) is not compiled: the result has
  `expr: nil` and an `:ash_expr_unsupported` diagnostic (stage
  `{:target, :ash}`) listing each construct in `details.constructs`. A
  field, type or option value the Project does not map gives
  `:ash_expr_unmapped_reference`. Each diagnostic points at the IR node
  that failed (`IR.path`), one per code and node.
  """

  alias BubbleEx.{Diagnostic, Error, Model}
  alias BubbleEx.Model.Type
  alias BubbleEx.Expression.{Compiler, Env, IR, Schema}
  alias BubbleEx.Target.Ash.{Expr, Project}

  @type result :: %{expr: Expr.t() | nil, diagnostics: [Diagnostic.t()]}
  @type option ::
          {:resource, String.t()}
          | {:source, map()}
          | {:subject, Diagnostic.subject()}
          | {:path, String.t() | list()}
          | {:inputs, :arguments | :unsupported}

  @compare %{gt: ">", lt: "<", gte: ">=", lte: "<="}
  @arithmetic %{add: "+", sub: "-", mul: "*", div: "/"}
  # IR ops whose yes/no value may be empty (not predicates).
  @boolean_values [:field, :input, :option_attribute, :option_label, :external_field, :fallback]

  @doc """
  Compiles the condition of every privacy rule in `model` against
  `project` (`BubbleEx.Target.Ash.map/3` of the same Model). Returns one
  entry per rule with a condition, in Model order: `%{type, rule, expr,
  diagnostics}`, where `diagnostics` holds the expression's typing and IR
  diagnostics (stage `:model`) and the target's. Rules of deleted or
  unmapped types are included with `expr: nil` and a diagnostic.
  """
  @spec privacy(Model.t(), Project.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def privacy(%Model{} = model, %Project{} = project) do
    lookup = lookup(project)
    {:ok, Enum.flat_map(model.data_types, &type_rules(&1, model, lookup))}
  end

  def privacy(_model, _project),
    do: {:error, Error.new(:invalid_input, "expected a BubbleEx.Model and its Ash project")}

  defp type_rules(type, model, lookup) do
    for rule <- type.rules, rule.condition do
      subject = %{type: type.id, rule: rule.id}
      path = Diagnostic.pointer(rule.path) <> "/condition"

      env =
        Env.new(model,
          this_type: Schema.thing_type(type.id),
          this_binder: :rule_record,
          subject: subject,
          path: pointer_segments(path)
        )

      {:ok, compiled} = Compiler.compile(rule.condition, env)

      %{expr: expr, diagnostics: diags} =
        case compiled.ir do
          nil ->
            %{expr: nil, diagnostics: []}

          ir ->
            do_filter(ir, lookup,
              resource: type.id,
              source: subject,
              subject: subject,
              path: path,
              inputs: :unsupported
            )
        end

      %{
        type: type.id,
        rule: rule.id,
        expr: expr,
        diagnostics: Diagnostic.normalize(compiled.diagnostics ++ diags)
      }
    end
  end

  @doc """
  Compiles a boolean IR expression to a filter on the resource of data
  type `resource` (whose record `This Thing` is).

  ## Options

    * `:resource` - the data type ID the filter selects (required)
    * `:source` - stored in `Expr.source`
    * `:subject` / `:path` - diagnostic subject and pointer
    * `:inputs` - `:arguments` to read context inputs as `^arg(...)`, or
      `:unsupported` (default)
  """
  @spec filter(IR.t(), Project.t(), [option()]) :: {:ok, result()} | {:error, Error.t()}
  def filter(%IR{} = ir, %Project{} = project, opts) when is_list(opts) do
    if Keyword.has_key?(opts, :resource),
      do: {:ok, do_filter(ir, lookup(project), opts)},
      else: {:error, Error.new(:invalid_input, "the :resource option is required")}
  end

  def filter(_ir, _project, _opts), do: invalid()

  @doc """
  Compiles a search (`:search`, possibly under `:sort`) to a filter on the
  searched resource, with its sort. Context inputs become arguments.
  """
  @spec search(IR.t(), Project.t(), [option()]) :: {:ok, result()} | {:error, Error.t()}
  def search(ir, project, opts \\ [])

  def search(%IR{} = ir, %Project{} = project, opts) when is_list(opts) do
    lookup = lookup(project)

    case unsort(ir) do
      {%IR{op: :search, args: [type, pred]}, sort} ->
        opts = Keyword.merge([inputs: :arguments], Keyword.put(opts, :resource, type))
        pred = pred || IR.node(:literal, [true], "boolean")
        result = do_filter(pred, lookup, opts)
        {:ok, sort_result(result, sort, type, lookup, opts)}

      _ ->
        {:error, Error.new(:invalid_input, "expected a :search IR node (optionally under :sort)")}
    end
  end

  def search(_ir, _project, _opts), do: invalid()

  defp invalid,
    do:
      {:error,
       Error.new(:invalid_input, "expected an IR node, a BubbleEx.Target.Ash.Project and options")}

  defp unsort(%IR{op: :sort, args: [inner, field, desc]}),
    do: {inner, [{field, if(desc, do: :desc, else: :asc)}]}

  defp unsort(ir), do: {ir, []}

  defp sort_result(%{expr: nil} = result, _sort, _type, _lookup, _opts), do: result

  defp sort_result(%{expr: expr} = result, sort, type, lookup, opts) do
    fields = get_in(lookup, [:types, type, :fields]) || %{}

    case Enum.map(sort, fn {field, dir} -> {get_in(fields, [field, :attribute]), dir} end) do
      mapped when mapped != [] and is_nil(elem(hd(mapped), 0)) ->
        st = state(lookup, opts)
        {:error, st} = unmapped(st, {"the sort field", elem(hd(sort), 0)})
        %{expr: nil, diagnostics: result.diagnostics ++ diagnostics(st, opts)}

      mapped ->
        %{result | expr: %{expr | sort: mapped}}
    end
  end

  # --- the Project's names ---------------------------------------------------------

  defp lookup(%Project{} = project) do
    types =
      Map.new(project.resources, fn resource ->
        rels = Map.new(resource.relationships, &{&1.source.field, &1.name})
        pk = Enum.find(resource.attributes, & &1.primary_key?)

        fields =
          for a <- resource.attributes, a.source[:field], into: %{} do
            {a.source.field,
             %{
               attribute: a.name,
               relationship: Map.get(rels, a.source.field),
               references: a.references
             }}
          end

        {resource.source.type, %{module: resource.module, pk: pk && pk.name, fields: fields}}
      end)

    enums =
      Map.new(project.enums, &{&1.source.option_set, MapSet.new(&1.values, fn v -> v.value end)})

    %{types: types, enums: enums}
  end

  # --- compiling -----------------------------------------------------------------------

  defp state(lookup, opts) do
    %{
      lookup: lookup,
      resource: Keyword.fetch!(opts, :resource),
      inputs: Keyword.get(opts, :inputs, :unsupported),
      loads: MapSet.new(),
      args: %{},
      at: path_text(Keyword.get(opts, :path, "")),
      unsupported: [],
      unmapped: []
    }
  end

  defp path_text(path) when is_list(path), do: Diagnostic.pointer(path)
  defp path_text(path), do: path

  defp do_filter(ir, lookup, opts) do
    st = state(lookup, opts)

    {node, st} =
      case get_in(lookup, [:types, st.resource]) do
        nil -> unmapped(st, {"the data type", st.resource})
        _ -> pred(ir, st)
      end

    diags = diagnostics(st, opts)

    if node == :error or diags != [] do
      %{expr: nil, diagnostics: diags}
    else
      expr = %Expr{
        resource: lookup.types[st.resource].module,
        source: Keyword.get(opts, :source, %{}),
        expr: node,
        actor_loads: st.loads |> MapSet.to_list() |> Enum.sort(),
        arguments:
          st.args
          |> Enum.map(fn {{kind, ref}, {name, type}} ->
            %{name: name, input: {kind, ref}, type: type}
          end)
          |> Enum.sort_by(& &1.name)
      }

      %{expr: expr, diagnostics: []}
    end
  end

  # Every node is compiled `within` its source path, so diagnostics point at
  # the part that does not compile.
  defp pred(ir, st), do: pred(ir, st, true)
  defp pred(%IR{} = ir, st, positive), do: within(ir, st, &pred_(&1, &2, positive))
  defp value(%IR{} = ir, st), do: within(ir, st, &value_/2)

  defp within(ir, st, fun) do
    outer = st.at
    {node, st} = fun.(ir, %{st | at: ir.path || outer})
    {node, %{st | at: outer}}
  end

  # A condition, compiled for `positive` or negated polarity. Negation is
  # pushed down to the atomic comparisons (De Morgan), so an actor guard is
  # never negated: an atom that reads an empty actor-side value is false in
  # either polarity (fail-safe).
  defp pred_(%IR{op: op, args: args}, st, positive) when op in [:and, :or] do
    {nodes, st} = Enum.map_reduce(args, st, &pred(&1, &2, positive))
    {all_ok({if(positive, do: op, else: dual(op)), nodes}, nodes), st}
  end

  defp pred_(%IR{op: :not, args: [x]}, st, positive), do: pred(x, st, not positive)

  defp pred_(%IR{op: :literal, args: [b]}, st, positive) when is_boolean(b),
    do: {{:value, b == positive}, st}

  defp pred_(%IR{op: op, args: [l, r]}, st, positive) when op in [:eq, :neq] do
    cond do
      match?(%IR{op: :empty}, l) -> pred(empty_check(op, r), st, positive)
      match?(%IR{op: :empty}, r) -> pred(empty_check(op, l), st, positive)
      condition_is_literal?(l, r) -> pred(r, st, literal_polarity(op, l, positive))
      condition_is_literal?(r, l) -> pred(l, st, literal_polarity(op, r, positive))
      boolean_equality?(l, r) -> boolean_equality(op, l, r, st, positive)
      true -> atom(%IR{op: op, args: [l, r]}, st, positive)
    end
  end

  defp pred_(ir, st, positive), do: atom(ir, st, positive)

  defp dual(:and), do: :or
  defp dual(:or), do: :and

  # `a is b` between yes/no conditions that read the actor: (a and b) or
  # (not a and not b), each side compiled with its own guards.
  # A condition (not a stored yes/no value) and a literal yes/no: `c is yes`
  # is `c`, `c is no` is `not c`.
  defp condition_is_literal?(%IR{op: :literal, args: [b]}, other) when is_boolean(b),
    do: condition?(other)

  defp condition_is_literal?(_literal, _other), do: false

  defp literal_polarity(op, %IR{args: [b]}, positive), do: op == :eq == b == positive

  defp condition?(%IR{op: op, type: "boolean"}), do: op not in @boolean_values and op != :literal
  defp condition?(_ir), do: false

  # Two yes/no sides, one a condition, reading the actor: expanded so that
  # each side keeps its own guards (a stored yes/no side is `== true` /
  # `== false`: empty is neither).
  defp boolean_equality?(l, r),
    do: (condition?(l) or condition?(r)) and (reads_actor?(l) or reads_actor?(r))

  defp boolean_equality(op, l, r, st, positive) do
    {[lp, ln, rp, rn], st} =
      Enum.map_reduce([{l, true}, {l, false}, {r, true}, {r, false}], st, fn {ir, pol}, st ->
        side(ir, st, pol)
      end)

    node =
      if op == :eq == positive,
        do: {:or, [{:and, [lp, rp]}, {:and, [ln, rn]}]},
        else: {:or, [{:and, [lp, rn]}, {:and, [ln, rp]}]}

    {all_ok(node, [lp, ln, rp, rn]), st}
  end

  defp side(ir, st, pol) do
    if condition?(ir),
      do: pred(ir, st, pol),
      else: atom(IR.node(:eq, [ir, IR.node(:literal, [pol], "boolean")], "boolean"), st, true)
  end

  # An atomic condition: its core for the requested polarity, guarded so
  # that every actor-side operand must be non-empty.
  defp atom(ir, st, positive) do
    case atom_(ir, st) do
      {{pos, neg, operands}, st} ->
        {guard(if(positive, do: pos, else: neg), operands), st}

      {:error, st} ->
        {:error, st}
    end
  end

  defp atom_(%IR{op: op, args: [l, r]}, st) when op in [:eq, :neq] do
    {[a, b], st} = values([l, r], st)
    eq = eq_node(a, b, st)
    neq = neq_node(a, b, st)
    operands = [{a, l.type}, {b, r.type}]
    {all_ok(if(op == :eq, do: {eq, neq, operands}, else: {neq, eq, operands}), [a, b]), st}
  end

  defp atom_(%IR{op: op, args: [l, r]}, st) when is_map_key(@compare, op) do
    {[a, b], st} = values([l, r], st)
    node = {:op, Map.fetch!(@compare, op), a, b}
    {all_ok({node, {:not, node}, [{a, l.type}, {b, r.type}]}, [a, b]), st}
  end

  # A reference is empty when the record it names is gone too (there are no
  # foreign keys, so a deleted record's ID stays behind): check the
  # relationship, not the ID attribute. On the actor side it tests the
  # actor's own value, so only a logged-in actor is required.
  defp atom_(%IR{op: :is_empty, args: [x]}, st) do
    {node, st} = empty(x, st)
    logged_in = if reads_actor?(x), do: [{actor_id(st), "user"}], else: []
    {all_ok({node, negate(node), logged_in}, [node]), st}
  end

  defp atom_(%IR{op: :logged_in}, st) do
    missing = {:call, "is_nil", [actor_id(st)]}
    {{{:not, missing}, missing, []}, st}
  end

  # `list contains item` is `item in list`. Its negation: an empty list (and
  # an empty record-side item) contains nothing, so it matches; `not (x in
  # list)` alone would be NULL.
  defp atom_(%IR{op: :member, args: [list, item]}, st) do
    if list_type?(list.type) do
      {[l, i], st} = values([list, item], st)

      nil_item =
        if nonnull?(i, st) or actor?(i), do: [], else: [{:call, "is_nil", [i]}]

      member = {:op, "in", i, l}
      absent = {:or, [{:call, "is_nil", [l]} | nil_item] ++ [{:not, member}]}
      {all_ok({member, absent, [{l, list.type}, {i, item.type}]}, [l, i]), st}
    else
      unsupported(st, {"contains on a value that is not a list", nil})
    end
  end

  defp atom_(%IR{op: :text_contains, args: [text, part]}, st) do
    {[t, p], st} = values([text, part], st)
    contains = {:call, "contains", [t, p]}
    absent = {:or, [{:call, "is_nil", [t]}, {:not, contains}]}
    {all_ok({contains, absent, [{t, text.type}, {p, part.type}]}, [t, p]), st}
  end

  # A yes/no value: `x == true`; negated, empty is not yes.
  defp atom_(%IR{op: op} = ir, st) when op in @boolean_values do
    {v, st} = value(ir, st)
    yes = {:op, "==", v, {:value, true}}
    {all_ok({yes, {:call, "is_distinct_from", [v, {:value, true}]}, [{v, ir.type}]}, [v]), st}
  end

  defp atom_(%IR{op: op}, st), do: unsupported(st, {"the condition #{inspect(op)}", nil})

  defp empty(%IR{op: :field} = x, st) do
    case {classify(x.type), path(x, [], st, :relationship)} do
      {%Type{kind: :ref, cardinality: :one}, {{:related, rels, rel}, st}} ->
        {{:not, {:call, "exists", [{:ref, rels, rel}, {:value, true}]}}, st}

      {%Type{kind: :ref, cardinality: :one}, {{:actor_related, path}, st}} ->
        {{:call, "is_nil", [{:actor, path}]}, %{st | loads: MapSet.put(st.loads, path)}}

      _ ->
        empty_value(x, st)
    end
  end

  defp empty(x, st), do: empty_value(x, st)

  defp empty_value(x, st) do
    {node, st} = value(x, st)

    check =
      case classify(x.type) do
        %Type{cardinality: :many} ->
          &{:or, [{:call, "is_nil", [&1]}, {:op, "==", &1, {:value, []}}]}

        %Type{kind: :scalar, base: :text} ->
          &{:or, [{:call, "is_nil", [&1]}, {:op, "==", &1, {:value, ""}}]}

        _ ->
          &{:call, "is_nil", [&1]}
      end

    {ok(node, check), st}
  end

  defp actor_id(st), do: {:actor, [st.lookup.types["user"].pk]}

  defp negate(:error), do: :error
  defp negate({:not, node}), do: node
  defp negate(node), do: {:not, node}

  defp empty_check(:eq, x), do: IR.node(:is_empty, [x], "boolean")
  defp empty_check(:neq, x), do: IR.node(:not, [IR.node(:is_empty, [x], "boolean")], "boolean")

  # `is` / `is not`. A side that cannot be empty (a literal, an option, the
  # record's own ID) or that is read from the actor makes `==`, which is
  # false when a side is empty. Only between two record-side values does
  # Bubble's "empty is empty" (not verified against Bubble; WTF-384/385)
  # give `is_not_distinct_from`.
  defp eq_node(a, b, st) do
    if nonnull?(a, st) or nonnull?(b, st) or actor?(a) or actor?(b),
      do: {:op, "==", a, b},
      else: {:call, "is_not_distinct_from", [a, b]}
  end

  defp neq_node(a, b, st) do
    if nonnull?(a, st) and nonnull?(b, st),
      do: {:op, "!=", a, b},
      else: {:call, "is_distinct_from", [a, b]}
  end

  # `node`, required to have every actor-side operand non-empty in Bubble's
  # sense (as `is empty`): not nil, and not `""` for text or `[]` for a
  # list. `operands` are `{node, bubble_type}`. A core that is already NULL
  # (so false) for a nil operand (`==`, `in`, ordering) needs only the text
  # and list checks.
  @null_false ["==", "in", ">", "<", ">=", "<="]
  defp guard(:error, _operands), do: :error

  defp guard(node, operands) do
    null_false = match?({:op, op, _, _} when op in @null_false, node)

    checks =
      for {operand, type} <- operands,
          operand != :error,
          actor?(operand),
          check <- empty_checks(operand, type, null_false),
          uniq: true,
          do: check

    if checks == [], do: node, else: {:and, checks ++ [node]}
  end

  defp empty_checks(operand, type, null_false) do
    nil_check = if null_false, do: [], else: [{:not, {:call, "is_nil", [operand]}}]

    case classify(type) do
      %Type{cardinality: :many} -> nil_check ++ [{:op, "!=", operand, {:value, []}}]
      %Type{kind: :scalar, base: :text} -> nil_check ++ [{:op, "!=", operand, {:value, ""}}]
      _ -> nil_check
    end
  end

  # Whether a compiled value, or an IR subtree, reads the actor.
  defp actor?({:actor, _}), do: true
  defp actor?({:op, _, l, r}), do: actor?(l) or actor?(r)
  defp actor?({:call, _, args}), do: Enum.any?(args, &actor?/1)
  defp actor?({op, nodes}) when op in [:and, :or], do: Enum.any?(nodes, &actor?/1)
  defp actor?({:not, node}), do: actor?(node)
  defp actor?(_), do: false

  defp reads_actor?(%IR{op: op}) when op in [:current_user, :logged_in], do: true
  defp reads_actor?(%IR{args: args}), do: Enum.any?(args, &reads_actor?/1)
  defp reads_actor?(list) when is_list(list), do: Enum.any?(list, &reads_actor?/1)
  defp reads_actor?(_), do: false

  defp nonnull?({:value, v}, _st), do: not is_nil(v)
  defp nonnull?({:ref, [], attr}, st), do: attr == st.lookup.types[st.resource].pk
  defp nonnull?(_, _st), do: false

  defp values(irs, st), do: Enum.map_reduce(irs, st, &value/2)

  # --- values ---------------------------------------------------------------------

  defp value_(%IR{op: :literal, args: [v]}, st), do: {{:value, v}, st}
  defp value_(%IR{op: :empty}, st), do: {{:value, nil}, st}

  defp value_(%IR{op: :option, args: [set, value_id, key]}, st) do
    case Map.get(st.lookup.enums, set) do
      nil ->
        unmapped(st, {"the option set", set})

      keys ->
        if is_binary(key) and MapSet.member?(keys, key),
          do: {{:value, key}, st},
          else: unmapped(st, {"the option", "#{set}.#{value_id}"})
    end
  end

  defp value_(%IR{op: :this, args: [binder]} = ir, st)
       when binder in [:rule_record, :filter_item],
       do: path(ir, [], st)

  defp value_(%IR{op: :current_user} = ir, st), do: path(ir, [], st)
  defp value_(%IR{op: :field} = ir, st), do: path(ir, [], st)

  defp value_(%IR{op: :input, args: [kind, ref], type: type}, %{inputs: :arguments} = st) do
    case Map.get(st.args, {kind, ref}) do
      {name, _} ->
        {{:arg, name}, st}

      nil ->
        name = argument_name(kind, ref, st.args)
        {{:arg, name}, %{st | args: Map.put(st.args, {kind, ref}, {name, type})}}
    end
  end

  defp value_(%IR{op: :input, args: [kind, _]}, st),
    do: unsupported(st, {"the context input #{kind}", nil})

  defp value_(%IR{op: op, args: [l, r], type: "number"}, st) when is_map_key(@arithmetic, op) do
    {[a, b], st} = values([l, r], st)
    {all_ok({:op, Map.fetch!(@arithmetic, op), a, b}, [a, b]), st}
  end

  defp value_(%IR{op: :lowercase, args: [x]}, st) do
    {node, st} = value(x, st)
    {ok(node, &{:call, "string_downcase", [&1]}), st}
  end

  # A condition used as a value (compared with another value that reads no
  # actor). One that reads the actor has no guard that survives being used
  # as a value, so it is rejected.
  defp value_(%IR{op: op, type: "boolean"} = ir, st) when op not in @boolean_values do
    if reads_actor?(ir),
      do: unsupported(st, {"a condition reading the current user used as a value", nil}),
      else: pred(ir, st)
  end

  defp value_(%IR{op: op}, st), do: unsupported(st, {"the value #{inspect(op)}", nil})

  # A field chain down to its base: `steps` are `{data_type, field}` from
  # the base outwards.
  # With `mode` `:relationship`, a last step that is a `belongs_to` gives
  # the relationship (`{:related, rels, rel}` / `{:actor_related, path}`).
  defp path(ir, steps, st, mode \\ :attribute)

  defp path(%IR{op: :field, args: [base, type, field]}, steps, st, mode),
    do: path(base, [{type, field} | steps], st, mode)

  defp path(%IR{op: :this, args: [binder]}, steps, st, mode)
       when binder in [:rule_record, :filter_item] do
    case resolve(steps, st.resource, st) do
      {:ok, [], nil} ->
        {{:ref, [], st.lookup.types[st.resource].pk}, st}

      {:ok, rels, %{relationship: rel}} when mode == :relationship and is_binary(rel) ->
        {{:related, rels, rel}, st}

      {:ok, rels, info} ->
        {{:ref, rels, info.attribute}, st}

      {:error, what} ->
        classify(st, what)
    end
  end

  defp path(%IR{op: :current_user}, steps, st, mode) do
    case resolve(steps, "user", st) do
      {:ok, [], nil} ->
        {{:actor, [st.lookup.types["user"].pk]}, st}

      {:ok, rels, %{relationship: rel}} when mode == :relationship and is_binary(rel) ->
        {{:actor_related, rels ++ [rel]}, st}

      {:ok, rels, info} ->
        st = if rels == [], do: st, else: %{st | loads: MapSet.put(st.loads, rels)}
        {{:actor, rels ++ [info.attribute]}, st}

      {:error, what} ->
        classify(st, what)
    end
  end

  defp path(%IR{op: op}, _steps, st, _mode), do: unsupported(st, {"a field of #{op}", nil})

  # Relationship names for every step but the last, and the last step's
  # attribute. The chain's first step must be on `type`.
  defp resolve([], type, st) do
    if Map.has_key?(st.lookup.types, type),
      do: {:ok, [], nil},
      else: {:error, {:unmapped, {"the data type", type}}}
  end

  defp resolve(steps, _type, st) do
    {init, [{last_type, last_field}]} = Enum.split(steps, -1)

    with {:ok, rels} <- relationships(init, st),
         {:ok, info} <- field_info(last_type, last_field, st) do
      {:ok, rels, info}
    end
  end

  defp relationships(steps, st) do
    Enum.reduce_while(steps, {:ok, []}, fn {type, field}, {:ok, rels} ->
      case field_info(type, field, st) do
        {:ok, %{relationship: rel}} when is_binary(rel) ->
          {:cont, {:ok, rels ++ [rel]}}

        {:ok, %{references: %{cardinality: :many}}} ->
          {:halt,
           {:error, {:unsupported, {"a path through a list of things", "#{type}.#{field}"}}}}

        {:ok, _} ->
          {:halt, {:error, {:unsupported, {"a path through a value", "#{type}.#{field}"}}}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp field_info(type, field, st) do
    case get_in(st.lookup, [:types, type, :fields, field]) do
      nil -> {:error, {:unmapped, {"the field", "#{type}.#{field}"}}}
      info -> {:ok, info}
    end
  end

  defp classify(st, {:unmapped, what}), do: unmapped(st, what)
  defp classify(st, {:unsupported, what}), do: unsupported(st, what)

  defp list_type?(type), do: match?(%Type{cardinality: :many}, classify(type))

  # IR types are Bubble descriptors; the Model classifies them.
  defp classify(type) when is_binary(type), do: type |> Type.classify() |> elem(0)
  defp classify(_type), do: nil

  # Argument names from the input kind and its Bubble IDs, deterministic;
  # a clash gets a numeric suffix.
  defp argument_name(kind, ref, taken) do
    base =
      [
        Atom.to_string(kind)
        | for({_, v} <- Enum.sort(ref), is_binary(v) or is_number(v), do: to_string(v))
      ]
      |> Enum.join("_")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, "_")
      |> String.trim("_")

    names = taken |> Map.values() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}_#{n}"
    end)
    |> Enum.find(&(not MapSet.member?(names, &1)))
  end

  # --- results and diagnostics ------------------------------------------------------

  defp ok(:error, _fun), do: :error
  defp ok(node, fun), do: fun.(node)

  defp all_ok(node, parts), do: if(Enum.member?(parts, :error), do: :error, else: node)

  defp unsupported(st, what), do: {:error, %{st | unsupported: [{what, st.at} | st.unsupported]}}
  defp unmapped(st, what), do: {:error, %{st | unmapped: [{what, st.at} | st.unmapped]}}

  # One diagnostic per code and source path (the IR node's that failed, else
  # the expression's).
  defp diagnostics(st, opts) do
    subject = Keyword.get(opts, :subject, %{})

    [
      {:ash_expr_unsupported, st.unsupported, "has no Ash.Expr mapping"},
      {:ash_expr_unmapped_reference, st.unmapped, "is not mapped by the Ash project"}
    ]
    |> Enum.flat_map(fn {code, entries, why} ->
      entries
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
      |> Enum.sort()
      |> Enum.map(fn {path, whats} ->
        whats = whats |> Enum.uniq() |> Enum.sort()
        text = Enum.map_join(whats, "; ", &describe/1)

        diagnostic(code, path || "", "#{text} #{why}; the expression is not compiled",
          target: :ash,
          subject: subject,
          details: %{
            constructs: whats |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
            at: for({_, at} <- whats, at != nil, do: at)
          }
        )
      end)
    end)
  end

  # A construct is `{kind, at}`: `kind` names what it is and holds no Bubble
  # IDs (reports count it); `at` names the Bubble IDs involved, or nil.
  defp describe({kind, nil}), do: kind
  defp describe({kind, at}), do: "#{kind} #{inspect(at)}"

  defp diagnostic(:ash_expr_unsupported, path, message, opts),
    do: Diagnostic.new(:ash_expr_unsupported, path, message, opts)

  defp diagnostic(:ash_expr_unmapped_reference, path, message, opts),
    do: Diagnostic.new(:ash_expr_unmapped_reference, path, message, opts)

  defp pointer_segments(""), do: []

  defp pointer_segments("/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
  end
end
