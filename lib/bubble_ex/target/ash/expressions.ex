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
  | `x is not y` | `x != y` when neither side can be empty; otherwise `is_distinct_from(x, y)`, with `not is_nil(a)` for every actor-side operand `a`. Between yes/no values (not conditions) an empty one reads as no and the result is never NULL (WTF-471, as Bubble): `x is not no` is `is_not_distinct_from(x, true)`, `x is not yes` is `is_distinct_from(x, true)`, two such values differ when exactly one is yes |
  | `x is empty` | a reference with a `belongs_to`: `not exists(rel, true)` (a dangling ID is empty; there are no foreign keys), `is_nil(^actor([..., :rel]))` on the actor side; otherwise `is_nil(x)`, also `x == ""` for text and `x == []` for a list |
  | `>`, `<`, `>=`, `<=` | the operator |
  | `and`, `or`, `not` | the operator |
  | `x is y` / `x is not y` between yes/no values in a search (`search/3`; not in privacy rules) | an empty one reads as no, as in Bubble (WTF-529): `x is no` and `x is not yes` are `x == false or is_nil(x)` on an attribute (`is_distinct_from(x, true)` on another value), `x is yes` and `x is not no` are `x == true`; between two values `is_not_distinct_from(a, true) == is_not_distinct_from(b, true)` (`!=` for `is not`) |
  | a yes/no value used as a condition | `x == true`; negated, `is_distinct_from(x, true)` (in a search, as `x is no`) |
  | `logged in` | `not is_nil(^actor(:id))` |
  | `list contains item` | `item in list` (lists of things are `{:array, :string}` of IDs, WTF-338) |
  | `list contains item`, `list is empty` on a list an owner decision derives as a `has_many` or normalizes to a join (`many_to_many`) | `exists(list, id == item)` (a record-side item read as `parent(...)`), `not exists(list, true)`; the list has no other use as a value |
  | `Current User's list contains item` on a list normalized to a join, the item being the record or a record it references | `exists(<item>.<rows>, <owner column> == ^actor(:id))` through the member's private rows relationship to the join (with `privacy: :unverified`); its `doesn't contain` does not compile (the rule is denied) |
  | `list doesn't contain item` | `is_nil(list) or is_nil(item) or not (item in list)` (an empty list contains nothing); an actor-side item must not be empty and an actor-side list needs a logged-in actor |
  | `not x` for a yes/no value | `is_distinct_from(x, true)` (empty is not yes), guarded like `is not` on the actor side |
  | `text contains string` | `contains(text, string)` |
  | `text contains keyword(s)` (Bubble's keyword match), in a search on a text field, its words an input or a literal | `fragment("coalesce(cardinality(?::text[]) > 0 AND ? ILIKE ALL (?::text[]), false)", patterns, text, patterns)`: the words (`BubbleEx.Target.Keywords`: split on whitespace, at most 32 words of the first 256 characters) computed in Elixir, each an `ILIKE` substring pattern with `\`, `%` and `_` escaped; an input's patterns are an argument of their own (`keywords: true` in `arguments`, the caller computes them from the input's value). No words or an empty text matches nothing; `doesn't contain` is `is_nil(text) or not fragment(...)`. A conservative reading, **not verified against Bubble** (whole words or substrings, every word or any, stemming, a minimum word length, Unicode case folding); not compiled in privacy rules (PostgreSQL only, which a policy evaluated in Elixir cannot run) |
  | `+`, `-`, `*`, `/` on numbers | the operator |
  | `x defaulting to d` | `if(<x is empty>, d, x)`, emptiness as `is empty` tests it (nil, `""`, `[]`, a reference whose record is gone); `(x defaulting to d)'s a` is the chain over `x` when it is not empty, else over `d`; `(x defaulting to d) is empty` is both empty |
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
  condition is expanded to `(a and b) or (not a and not
  b)` (a stored yes/no side is `== true` / `== false`: empty is neither;
  in a search, `is no` holds on an empty one, WTF-529).
  A condition reading the actor used as any other value is rejected; any
  other condition used as a value is `if(c, true, false)`, never NULL. The
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
  input, list algebra, counts, text operators other than
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
  # `contains keyword(s)` (`:text_contains_words`): the text (the second
  # `?`) matches every pattern of the bound list (the first and third,
  # `BubbleEx.Target.Keywords.patterns/1`, computed in Elixir: nothing is
  # split per row); no pattern, or an empty text, is false, never NULL.
  # Ash splits a fragment on every `?` (a literal one would be `\\?`):
  # this SQL has none but the placeholders.
  @keywords_sql "coalesce(cardinality(?::text[]) > 0 AND ? ILIKE ALL (?::text[]), false)"

  # IR ops whose yes/no value may be empty (not predicates).
  @boolean_values [:field, :input, :option_attribute, :option_label, :external_field, :fallback]

  @doc """
  Compiles the condition of every privacy rule in `model` against
  `project` (`BubbleEx.Target.Ash.map/3` of the same Model). Returns one
  entry per rule with a condition, in Model order: `%{type, rule, expr,
  ir, diagnostics}`, where `ir` is the compiled `BubbleEx.Expression.IR`
  (nil when it does not compile) and `diagnostics` holds the expression's
  typing and IR diagnostics (stage `:model`) and the target's. Rules of deleted or
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
        ir: compiled.ir,
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

  # The sort field of Bubble's random sort.
  @random_sort "_random_sorting"

  @doc """
  Compiles a search (`:search`, possibly under `:sort`, nested for several
  keys, the outermost first) to a filter on the searched resource, with
  its sort. Context inputs become arguments.
  Bubble's random sort (`_random_sorting`) becomes `sort: [:random]`; any
  other sort field that maps to no attribute leaves the search uncompiled.
  """
  @spec search(IR.t(), Project.t(), [option()]) :: {:ok, result()} | {:error, Error.t()}
  def search(ir, project, opts \\ [])

  def search(%IR{} = ir, %Project{} = project, opts) when is_list(opts) do
    lookup = lookup(project)

    case unsort(ir) do
      {%IR{op: :search, args: [type, pred]}, sort} ->
        opts =
          Keyword.merge(
            [inputs: :arguments, search?: true, empty_yes_no_is_no: true],
            Keyword.put(opts, :resource, type)
          )

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

  # Nested sorts are one sort by several keys, the outermost first (a sort
  # keeps the order of what it sorts among equal keys). A random sort
  # orders everything: the keys inside it are dropped. Bubble sorts things
  # with empty values last in both directions (replay 2026-10-07: `:sorted`
  # of things; PostgreSQL's own order puts them first descending).
  defp unsort(%IR{op: :sort, args: [inner, field, desc]}) do
    key = {field, if(desc, do: :desc_nils_last, else: :asc_nils_last)}

    case {field, unsort(inner)} do
      {@random_sort, {search, _inner_keys}} -> {search, [key]}
      {_, {search, keys}} -> {search, [key | keys]}
    end
  end

  defp unsort(ir), do: {ir, []}

  defp sort_result(%{expr: nil} = result, _sort, _type, _lookup, _opts), do: result

  # Bubble's random sort (WTF-452): no field, an order that changes on
  # every read (`BubbleEx.Target.Ash.Expr`'s `:random`).
  defp sort_result(%{expr: expr} = result, [{@random_sort, _dir}], _type, _lookup, _opts),
    do: %{result | expr: %{expr | sort: [:random]}}

  defp sort_result(%{expr: expr} = result, sort, type, lookup, opts) do
    fields = get_in(lookup, [:types, type, :fields]) || %{}

    mapped =
      Enum.map(sort, fn {field, dir} -> {field, get_in(fields, [field, :attribute]), dir} end)

    case Enum.find(mapped, fn {_field, attribute, _dir} -> is_nil(attribute) end) do
      {field, nil, _dir} ->
        st = state(lookup, opts)
        {:error, st} = unmapped(st, {"the sort field", field})
        %{expr: nil, diagnostics: result.diagnostics ++ diagnostics(st, opts)}

      nil ->
        %{result | expr: %{expr | sort: Enum.map(mapped, fn {_f, a, dir} -> {a, dir} end)}}
    end
  end

  # --- the Project's names ---------------------------------------------------------

  defp lookup(%Project{} = project) do
    modules = Map.new(project.resources, &{&1.module, &1.source.type})
    # A field referencing what an owner dropped holds IDs no longer mapped:
    # unreadable, so a rule reading it denies (WTF-422).
    dangling = Project.dangling(project)

    types =
      Map.new(project.resources, fn resource ->
        belongs_to = Enum.filter(resource.relationships, &(&1.kind == :belongs_to))
        rels = Map.new(belongs_to, &{&1.source.field, &1.name})
        pk = Enum.find(resource.attributes, & &1.primary_key?)

        fields =
          for a <- resource.attributes,
              a.source[:field],
              not MapSet.member?(dangling, {resource.source.type, a.source.field}),
              into: %{} do
            {a.source.field,
             %{
               attribute: a.name,
               relationship: Map.get(rels, a.source.field),
               references: a.references
             }}
          end

        # A field derived by an owner decision is read as its calculation
        # or aggregate.
        fields =
          for c <- resource.calculations, c.kind == :derived, into: fields do
            {c.source.field, %{attribute: c.name, relationship: nil, references: nil}}
          end

        fields =
          for g <- resource.aggregates, into: fields do
            {g.source.field, %{attribute: g.name, relationship: nil, references: nil}}
          end

        # A list derived as a has_many, or normalized to a join (a
        # many_to_many), is tested through it (membership, emptiness); it
        # has no value.
        # A current user's list normalized to a join is tested through the
        # member's private rows relationship (`actor_list`).
        fields =
          for %{kind: kind} = r <- resource.relationships,
              kind in [:has_many, :many_to_many],
              into: fields,
              do: {r.source.field, list_entry(resource, r, pk, modules)}

        # The member's rows of a join: `{owner type, list field}` => the
        # private has_many to the join (BubbleEx.Target.Ash.Policies).
        rows =
          for %{source: %{list: %{type: t, field: f}}} = r <- resource.privacy_relationships,
              into: %{},
              do: {{t, f}, r.name}

        {resource.source.type,
         %{module: resource.module, pk: pk && pk.name, fields: fields, rows: rows}}
      end)

    enums =
      Map.new(project.enums, &{&1.source.option_set, MapSet.new(&1.values, fn v -> v.value end)})

    %{types: types, enums: enums}
  end

  # A list the relationship `r` replaces: tested through it; a
  # many_to_many also through the member's rows when it is the current
  # user's (`actor_list`).
  defp list_entry(resource, r, pk, modules) do
    entry = %{attribute: nil, relationship: nil, references: nil, has_many: r.name}

    if r.kind == :many_to_many,
      do:
        Map.put(entry, :actor_list, %{
          key: {resource.source.type, r.source.field},
          owner_pk: pk && pk.name,
          owner_column: r.source_attribute_on_join_resource,
          member_type: Map.get(modules, r.destination)
        }),
      else: entry
  end

  # --- compiling -----------------------------------------------------------------------

  defp state(lookup, opts) do
    %{
      lookup: lookup,
      resource: Keyword.fetch!(opts, :resource),
      inputs: Keyword.get(opts, :inputs, :unsupported),
      search?: Keyword.get(opts, :search?, false),
      empty_yes_no_is_no: Keyword.get(opts, :empty_yes_no_is_no, false),
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
          |> Enum.map(fn
            {{{:keywords, kind}, ref}, {name, type}} ->
              %{name: name, input: {kind, ref}, type: type, keywords: true}

            {{kind, ref}, {name, type}} ->
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

  # Two yes/no sides, one a condition: expanded so that each side keeps its
  # own polarities and guards (a stored yes/no side is `== true` / `==
  # false`: empty is neither; in a search, `is no` holds on an empty one,
  # WTF-529). A condition's negation is not always its
  # complement (an empty value fails both), so comparing it as a plain
  # value could match where neither side holds (WTF-471).
  defp boolean_equality?(l, r), do: condition?(l) or condition?(r)

  defp boolean_equality(op, l, r, st, positive) do
    {[lp, ln, rp, rn], st} =
      Enum.map_reduce([{l, true}, {l, false}, {r, true}, {r, false}], st, fn {ir, pol}, st ->
        side(ir, st, pol, guarded_negation?(l, r))
      end)

    node =
      if op == :eq == positive,
        do: {:or, [{:and, [lp, rp]}, {:and, [ln, rn]}]},
        else: {:or, [{:and, [lp, rn]}, {:and, [ln, rp]}]}

    {all_ok(node, [lp, ln, rp, rn]), st}
  end

  # A condition's negative side also requires the record values it reads to
  # be non-empty, as the `everyone` rule's reach does (WTF-471): a
  # negation that holds on an empty value (`doesn't contain` on an empty
  # list, an empty text) rests on Bubble semantics not calibrated
  # (`empty_list_contains_nothing`, `empty_text_contains_nothing`), and the
  # value form it replaces was NULL there. Stricter than Bubble by the
  # owner's rule (`BubbleEx.Verify.Difference`,
  # `compared_condition_guards_record_values`). Only where neither side
  # reads the actor: those comparisons were expanded before, unguarded.
  defp guarded_negation?(l, r), do: not reads_actor?(l) and not reads_actor?(r)

  defp side(ir, st, pol, guarded?) do
    cond do
      not condition?(ir) ->
        atom(IR.node(:eq, [ir, IR.node(:literal, [pol], "boolean")], "boolean"), st, true)

      pol or not guarded? ->
        pred(ir, st, pol)

      true ->
        case record_guards([ir]) do
          [] ->
            pred(ir, st, false)

          guards ->
            pred(IR.node(:and, [IR.node(:not, [ir], "boolean") | guards], "boolean"), st, true)
        end
    end
  end

  # An atomic condition: its core for the requested polarity, guarded so
  # that every actor-side operand must be non-empty.
  defp atom(ir, st, positive) do
    case atom_(ir, st) do
      # (`doesn't contain` on the current user's list normalized to a
      # join: not compiled, so the rule grants nothing)
      {{_pos, {:unsupported, what}, _operands}, st} when not positive ->
        unsupported(st, {what, nil})

      {{pos, neg, operands}, st} ->
        {guard(if(positive, do: pos, else: neg), operands), st}

      {:error, st} ->
        {:error, st}
    end
  end

  defp atom_(%IR{op: op, args: [l, r]}, st) when op in [:eq, :neq] do
    {[a, b], st} = values([l, r], st)

    {eq, neq} =
      cond do
        st.empty_yes_no_is_no and yes_no_pair?(l, r) -> yes_no_read_as_no(l, r, a, b)
        yes_no_pair?(l, r) -> {eq_node(a, b, st), yes_no_neq(l, r, a, b)}
        true -> {eq_node(a, b, st), neq_node(a, b, st)}
      end

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

  # Built by the policy generator only (the `everyone` rule's reach, WTF-430):
  # a record-side reference is not dangling, that is its stored ID is nil
  # or names a record that exists. Under either reading of a dangling
  # reference (`dangling_ref_is_empty`) its emptiness is then settled.
  defp atom_(%IR{op: :not_dangling, args: [x]}, st) do
    case {classify(x.type), path(x, [], st, :relationship)} do
      {%Type{kind: :ref, cardinality: :one}, {{:related, rels, rel}, st}} ->
        {id, st} = value(x, st)

        present =
          ok(
            id,
            &{:or,
             [{:call, "is_nil", [&1]}, {:call, "exists", [{:ref, rels, rel}, {:value, true}]}]}
          )

        {all_ok({present, negate(present), []}, [present]), st}

      {_, {:error, st}} ->
        {:error, st}

      {_, {_, st}} ->
        {{{:value, true}, {:value, false}, []}, st}
    end
  end

  defp atom_(%IR{op: :logged_in}, st) do
    missing = {:call, "is_nil", [actor_id(st)]}
    {{{:not, missing}, missing, []}, st}
  end

  # `list contains item` is `item in list`. Its negation: an empty list (and
  # an empty record-side item) contains nothing, so it matches; `not (x in
  # list)` alone would be NULL.
  defp atom_(%IR{op: :member, args: [list, _item]} = ir, st) do
    case has_many(list, st) do
      {:ok, ref, st} ->
        has_many_member(ir, ref, st)

      :no ->
        case actor_list(list, st) do
          {:ok, info, owner, st} -> actor_list_member(ir, info, owner, st)
          :no -> member(ir, st)
        end
    end
  end

  defp atom_(%IR{op: :text_contains, args: [text, part]}, st) do
    {[t, p], st} = values([text, part], st)
    contains = {:call, "contains", [t, p]}
    absent = {:or, [{:call, "is_nil", [t]}, {:not, contains}]}
    {all_ok({contains, absent, [{t, text.type}, {p, part.type}]}, [t, p]), st}
  end

  # Bubble's keyword match (`contains keyword(s)`), read conservatively:
  # the words of the part (`BubbleEx.Target.Keywords`: split on
  # whitespace, capped), each a case-insensitive substring of the text
  # (`ILIKE ALL` over their patterns, `\`, `%` and `_` escaped). A part
  # with no words matches nothing; an empty text contains nothing, so its
  # negation holds there. The words are computed in Elixir, so the part
  # must be a context input (bound as a second argument of the same input,
  # `keywords: true`) or a literal; in a search only: the filter is SQL
  # (PostgreSQL), which a policy evaluated in Elixir cannot run.
  defp atom_(%IR{op: :text_contains_words, args: [text, part]}, %{search?: true} = st) do
    cond do
      text.type != "text" ->
        unsupported(st, {"contains keyword(s) on a value that is not a text", nil})

      part.type != "text" ->
        unsupported(st, {"contains keyword(s) whose words are not a text", nil})

      true ->
        {t, st} = value(text, st)
        {p, st} = keyword_patterns(part, st)
        contains = {:call, "fragment", [{:value, @keywords_sql}, p, t, p]}
        absent = {:or, [{:call, "is_nil", [t]}, {:not, contains}]}
        {all_ok({contains, absent, [{t, text.type}]}, [t, p]), st}
    end
  end

  defp atom_(%IR{op: :text_contains_words}, st),
    do: unsupported(st, {"contains keyword(s) outside a search", nil})

  # A yes/no value: `x == true`; negated, empty is not yes (in a search,
  # `x == false or is_nil(x)` on an attribute, `is_no/1`).
  defp atom_(%IR{op: op} = ir, st) when op in @boolean_values do
    {v, st} = value(ir, st)
    yes = {:op, "==", v, {:value, true}}

    no =
      if st.empty_yes_no_is_no,
        do: ok(v, &is_no/1),
        else: {:call, "is_distinct_from", [v, {:value, true}]}

    {all_ok({yes, no, [{v, ir.type}]}, [v]), st}
  end

  defp atom_(%IR{op: op}, st), do: unsupported(st, {"the condition #{inspect(op)}", nil})

  defp member(%IR{args: [list, item]}, st) do
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

  # A record-side list derived as a has_many (`derive_reverse_relationship`):
  # `{:ok, {:ref, rels, has_many}, st}`, else `:no`.
  defp has_many(%IR{op: :field} = list, st) do
    case path(list, [], st, :has_many) do
      {{:has_many, rels, many}, st} -> {:ok, {:ref, rels, many}, st}
      _ -> :no
    end
  end

  defp has_many(_list, _st), do: :no

  # `list contains item` on a has_many: some related record is the item,
  # `exists(list, id == item)` (a record-side item is read as `parent(...)`
  # from inside). The related records are the ones whose reference points
  # here; a deleted one is not listed (the stored list kept its ID).
  defp has_many_member(%IR{args: [list, item]}, {:ref, _rels, many} = ref, st) do
    {i, st} = value(item, st)

    case {i, destination_pk(list, many, st)} do
      {:error, _} ->
        {:error, st}

      {_, nil} ->
        unmapped(st, {"the list", many})

      {i, pk} ->
        inner = if actor?(i) or match?({:value, _}, i), do: i, else: {:call, "parent", [i]}
        member = {:call, "exists", [ref, {:op, "==", {:ref, [], pk}, inner}]}
        nil_item = if nonnull?(i, st) or actor?(i), do: [], else: [{:call, "is_nil", [i]}]
        absent = {:or, nil_item ++ [{:not, member}]}
        {{member, absent, [{i, item.type}]}, st}
    end
  end

  # The current user's list (or a record's the user references) that an
  # owner decision normalized to a join: `{:ok, info, owner ID, st}`, else
  # `:no`.
  defp actor_list(%IR{op: :field} = list, st) do
    case path(list, [], st, :actor_list) do
      {{:actor_list, [], info}, st} ->
        {:ok, info, {:actor, [info.owner_pk]}, st}

      {{:actor_list, rels, info}, st} ->
        {:ok, info, {:actor, rels ++ [info.owner_pk]}, %{st | loads: MapSet.put(st.loads, rels)}}

      _ ->
        :no
    end
  end

  defp actor_list(_list, _st), do: :no

  # `Current User's list contains item`, the list normalized to a join: a
  # row of the join names the item's record as member and the user as
  # owner, `exists(<item>.<rows>, <owner column> == ^actor(:id))`, through
  # the member's private rows relationship (the rows of that list only).
  # The item is the rule's record or a record it references. Its negation
  # (`doesn't contain`) is not compiled (`:ash_expr_unsupported`): the rule
  # is denied.
  defp actor_list_member(%IR{args: [_list, item]}, info, owner, st) do
    case member_path(item, info.member_type, st) do
      {:ok, rels, st} ->
        case get_in(st.lookup, [:types, info.member_type, :rows, info.key]) do
          nil ->
            unmapped(st, {"the join rows of the list", elem(info.key, 1)})

          rows ->
            member =
              {:call, "exists",
               [{:ref, rels, rows}, {:op, "==", {:ref, [], info.owner_column}, owner}]}

            {{member,
              {:unsupported, "doesn't contain on the current user's list normalized to a join"},
              [{owner, nil}]}, st}
        end

      error ->
        error
    end
  end

  # Relationship names from the rule's record to the record `item` is,
  # when it is of `type`.
  defp member_path(%IR{op: :this, args: [binder]}, type, st)
       when binder in [:rule_record, :filter_item] do
    if st.resource == type,
      do: {:ok, [], st},
      else: unsupported(st, {"membership of another type in a list normalized to a join", nil})
  end

  defp member_path(%IR{op: :field, type: item_type} = item, type, st) do
    case {classify(item_type), path(item, [], st, :relationship)} do
      {%Type{kind: :ref, cardinality: :one, target: ^type}, {{:related, rels, rel}, st}} ->
        {:ok, rels ++ [rel], st}

      {_, {:error, st}} ->
        {:error, st}

      {_, {_, st}} ->
        unsupported(st, {"membership of a value in a list normalized to a join", nil})
    end
  end

  defp member_path(_item, _type, st),
    do: unsupported(st, {"membership of a value in a list normalized to a join", nil})

  # The primary key of the records a has_many lists.
  defp destination_pk(%IR{type: type}, _many, st) do
    case classify(type) do
      %Type{kind: :ref, target: target} -> get_in(st.lookup, [:types, target, :pk])
      _ -> nil
    end
  end

  # `(x defaulting to d)` is empty when both are; a field chain over it is
  # the chain over `x` when `x` is not empty, else the chain over `d`.
  defp empty(%IR{op: op} = x, st) when op in [:field, :fallback] do
    case fallback_chain(x) do
      {:ok, fx, fd, :self} ->
        {[ex, ed], st} =
          Enum.map_reduce([fx, fd], st, &within(&1, &2, fn ir, st -> empty(ir, st) end))

        {all_ok({:and, [ex, ed]}, [ex, ed]), st}

      {:ok, fx, fd, rebuild} ->
        {[ex, cx, cd], st} =
          Enum.map_reduce(
            [fx, rebuild.(fx), rebuild.(fd)],
            st,
            &within(&1, &2, fn ir, st -> empty(ir, st) end)
          )

        {all_ok({:or, [{:and, [negate(ex), cx]}, {:and, [ex, cd]}]}, [ex, cx, cd]), st}

      :no ->
        empty_plain(x, st)
    end
  end

  defp empty(x, st), do: empty_value(x, st)

  defp empty_plain(%IR{op: :field} = x, st) do
    case has_many(x, st) do
      {:ok, ref, st} -> {{:not, {:call, "exists", [ref, {:value, true}]}}, st}
      :no -> empty_field(x, st)
    end
  end

  defp empty_plain(x, st), do: empty_value(x, st)

  # `x defaulting to d` (Bubble's `defaulting to`): `x` unless it is empty
  # (as `is empty` tests it: nil, `""`, `[]`, or a reference whose record
  # is gone), else `d`. A field chain over it (`(x defaulting to d)'s a`)
  # is `{:ok, x, d, rebuild}`, where `rebuild` puts another base under the
  # chain; the fallback itself is `{:ok, x, d, :self}`.
  defp fallback_chain(%IR{op: :fallback, args: [x, d]}), do: {:ok, x, d, :self}

  defp fallback_chain(%IR{op: :field, args: [base, type, field]} = ir) do
    case fallback_chain(base) do
      {:ok, x, d, :self} -> {:ok, x, d, &%{ir | args: [&1, type, field]}}
      {:ok, x, d, rebuild} -> {:ok, x, d, &%{ir | args: [rebuild.(&1), type, field]}}
      :no -> :no
    end
  end

  defp fallback_chain(_ir), do: :no

  # The value of `x defaulting to d`, or of a field chain over it: the
  # chain over `x` when `x` is not empty, else over `d`. `if(empty, d, x)`
  # (the emptiness test is never NULL).
  defp fallback_value(ir, st) do
    {:ok, x, d, rebuild} = fallback_chain(ir)
    {a, b} = if rebuild == :self, do: {x, d}, else: {rebuild.(x), rebuild.(d)}
    {e, st} = within(x, st, fn ir, st -> empty(ir, st) end)
    {[va, vb], st} = values([a, b], st)
    {all_ok({:call, "if", [e, vb, va]}, [e, va, vb]), st}
  end

  defp empty_field(x, st) do
    case {classify(x.type), path(x, [], st, :relationship)} do
      {%Type{kind: :ref, cardinality: :one}, {{:related, rels, rel}, st}} ->
        {{:not, {:call, "exists", [{:ref, rels, rel}, {:value, true}]}}, st}

      {%Type{kind: :ref, cardinality: :one}, {{:actor_related, path}, st}} ->
        {{:call, "is_nil", [{:actor, path}]}, %{st | loads: MapSet.put(st.loads, path)}}

      _ ->
        empty_value(x, st)
    end
  end

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

  # `x is not y` between yes/no values, at least one a yes/no value (not a
  # condition: a field, a parameter, an option attribute, ...; WTF-471): an
  # empty one reads as no, as in Bubble, and the result is never NULL.
  # `x is not no` is `is_not_distinct_from(x, true)`; `x is not yes` is
  # `is_distinct_from(x, true)`; between two values, exactly one of them is
  # yes. An actor-side value keeps `==` (its guard requires it non-empty).
  # `x is y` keeps `is_not_distinct_from` / `==` (stricter than Bubble on
  # an empty side against no: `BubbleEx.Verify.Difference`,
  # `empty_yes_no_is_no`).
  defp yes_no_pair?(l, r),
    do: (stored_yes_no?(l) or stored_yes_no?(r)) and yes_no_side?(l) and yes_no_side?(r)

  defp stored_yes_no?(%IR{op: op, type: "boolean"}), do: op in @boolean_values
  defp stored_yes_no?(_ir), do: false

  defp yes_no_side?(%IR{op: :literal, args: [b]}), do: is_boolean(b)
  defp yes_no_side?(ir), do: stored_yes_no?(ir)

  defp yes_no_neq(%IR{op: :literal, args: [b]}, _r, _a, v), do: yes_no_not(v, b)
  defp yes_no_neq(_l, %IR{op: :literal, args: [b]}, v, _b), do: yes_no_not(v, b)

  defp yes_no_neq(_l, _r, a, b), do: {:op, "!=", yes(a), yes(b)}

  defp yes_no_not(v, false), do: yes(v)
  defp yes_no_not(v, true), do: {:call, "is_distinct_from", [v, {:value, true}]}

  # In a search (`empty_yes_no_is_no`, WTF-529): Bubble reads an empty
  # yes/no as no (replay 2026-09-29 and 2026-10-01: `x is no` holds on a
  # record whose x is empty), so between yes/no values with a stored side
  # an empty one is no, in `is` as in `is not`. Against a literal: `x is
  # no` and `x is not yes` are `is_no(x)`, `x is yes` and `x is not no`
  # are `x == true`; between two values, both are read as yes or no. The
  # privacy rules keep the stricter `is` (`BubbleEx.Verify.Difference`,
  # `empty_yes_no_is_no`): `privacy/2` and `filter/3` do not set it.
  defp yes_no_read_as_no(%IR{op: :literal, args: [b]}, _r, _a, v), do: yes_no_literal(v, b)
  defp yes_no_read_as_no(_l, %IR{op: :literal, args: [b]}, v, _b), do: yes_no_literal(v, b)

  defp yes_no_read_as_no(_l, _r, a, b),
    do: {{:op, "==", read_as_no(a), read_as_no(b)}, {:op, "!=", read_as_no(a), read_as_no(b)}}

  # A side of a comparison between two yes/no values: yes or no, never
  # NULL; an actor-side one as is (guarded non-empty: NULL when it is
  # empty, so the comparison holds for no record).
  defp read_as_no(v), do: if(actor?(v), do: v, else: yes(v))

  defp yes_no_literal(v, true), do: {{:op, "==", v, {:value, true}}, is_no(v)}
  defp yes_no_literal(v, false), do: {is_no(v), {:op, "==", v, {:value, true}}}

  # `v` is no or empty. On an attribute, `v == false or is_nil(v)`, which
  # an index on it can serve (`IS DISTINCT FROM` cannot); an actor-side
  # `v` is guarded non-empty, so `v == false`.
  defp is_no({:ref, _rels, _attr} = v),
    do: {:or, [{:op, "==", v, {:value, false}}, {:call, "is_nil", [v]}]}

  defp is_no(v) do
    if actor?(v),
      do: {:op, "==", v, {:value, false}},
      else: {:call, "is_distinct_from", [v, {:value, true}]}
  end

  # `v` is yes, never NULL (an actor-side `v` is guarded non-empty).
  defp yes(v) do
    if actor?(v),
      do: {:op, "==", v, {:value, true}},
      else: {:call, "is_not_distinct_from", [v, {:value, true}]}
  end

  @doc false
  # The record-value guards of conditions (WTF-430, WTF-471): one IR
  # condition per record-side value they read, requiring it non-empty
  # (`not (x is empty)`), or, for a reference read only by an emptiness
  # test, not dangling. Used by the `everyone` rule's reach
  # (`Target.Ash.Policies`) and the negative side of a condition compared
  # as a value.
  @spec record_guards([IR.t()]) :: [IR.t()]
  def record_guards(irs) do
    irs
    |> Enum.flat_map(&record_values/1)
    |> Enum.uniq()
    |> Enum.map(fn
      {:not_dangling, ir} -> IR.node(:not_dangling, [ir], "boolean")
      ir -> IR.node(:not, [IR.node(:is_empty, [ir], "boolean")], "boolean")
    end)
  end

  # The outermost field chains read from the rule's record (`This
  # Thing's a's b`), not from the actor: each must be non-empty. A chain
  # read only as the operand of an emptiness test (`is empty`, `is not
  # empty`, `= empty`, also through `defaulting to`) is not guarded that
  # way: the test's negation is exact, and guarding it made the negation
  # `x is empty and x is not empty`, always false (WTF-430). Such a chain
  # that is a reference gets `{:not_dangling, chain}` instead: whether a
  # dangling reference is empty is not calibrated (`dangling_ref_is_empty`),
  # so the negation holds only where both readings agree (its ID is nil,
  # or its record exists). The interpreter lists the same guards
  # (`Verify.Interpreter.Eval.record_values/1`).
  defp record_values(%IR{op: :is_empty, args: [x]}), do: emptiness_operand(x)

  defp record_values(%IR{op: op, args: [l, r]}) when op in [:eq, :neq] do
    cond do
      match?(%IR{op: :empty}, l) -> emptiness_operand(r)
      match?(%IR{op: :empty}, r) -> emptiness_operand(l)
      true -> record_values(l) ++ record_values(r)
    end
  end

  defp record_values(%IR{op: :field, args: [base | _]} = ir) do
    if record_based?(base), do: [strip_path(ir)], else: []
  end

  defp record_values(%IR{args: args}), do: Enum.flat_map(args, &record_values/1)
  defp record_values(list) when is_list(list), do: Enum.flat_map(list, &record_values/1)
  defp record_values(_), do: []

  defp emptiness_operand(%IR{op: :field, args: [base | _]} = ir) do
    cond do
      not record_based?(base) ->
        []

      is_binary(ir.type) and
          match?({%Type{kind: :ref, cardinality: :one}, _}, Type.classify(ir.type)) ->
        [{:not_dangling, strip_path(ir)}]

      true ->
        []
    end
  end

  defp emptiness_operand(%IR{op: :fallback, args: args}),
    do: Enum.flat_map(args, &emptiness_operand/1)

  defp emptiness_operand(other), do: record_values(other)

  defp record_based?(%IR{op: :this, args: [binder]}), do: binder in [:rule_record, :filter_item]
  defp record_based?(%IR{op: :field, args: [base | _]}), do: record_based?(base)
  defp record_based?(%IR{op: :fallback, args: args}), do: Enum.all?(args, &record_based?/1)
  defp record_based?(_), do: false

  # Source paths differ between occurrences of the same chain.
  defp strip_path(%IR{args: args} = ir),
    do: %{ir | path: nil, args: Enum.map(args, &strip_path/1)}

  defp strip_path(other), do: other

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
  defp value_(%IR{op: :fallback} = ir, st), do: fallback_value(ir, st)

  defp value_(%IR{op: :field} = ir, st) do
    case fallback_chain(ir) do
      {:ok, _x, _d, _rebuild} -> fallback_value(ir, st)
      :no -> path(ir, [], st)
    end
  end

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
  # A condition used as a value: strictly yes or no (`if(c, true, false)`),
  # never NULL, so comparing it cannot match an unknown (WTF-471).
  defp value_(%IR{op: op, type: "boolean"} = ir, st) when op not in @boolean_values do
    if reads_actor?(ir) do
      unsupported(st, {"a condition reading the current user used as a value", nil})
    else
      {c, st} = pred(ir, st)
      {ok(c, &{:call, "if", [&1, {:value, true}, {:value, false}]}), st}
    end
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

      {:ok, rels, %{has_many: many}} when mode == :has_many ->
        {{:has_many, rels, many}, st}

      {:ok, _rels, %{has_many: _}} ->
        unsupported(st, {"a list derived as a has_many, used as a value", nil})

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

      {:ok, rels, %{actor_list: info}} when mode == :actor_list ->
        {{:actor_list, rels, info}, st}

      {:ok, _rels, %{has_many: _}} ->
        unsupported(st, {"the current user's list derived as a has_many", nil})

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

        {:ok, %{has_many: _}} ->
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

  # The `ILIKE` patterns of a keyword search's words: a literal's computed
  # here, an input's bound as an argument of its own (`keywords: true`),
  # computed by the caller from the input's value.
  defp keyword_patterns(%IR{op: :literal, args: [text]}, st),
    do: {{:value, BubbleEx.Target.Keywords.patterns(text)}, st}

  defp keyword_patterns(%IR{op: :input, args: [kind, ref]}, %{inputs: :arguments} = st) do
    key = {{:keywords, kind}, ref}

    case Map.get(st.args, key) do
      {name, _} ->
        {{:arg, name}, st}

      nil ->
        name = argument_name(kind, Map.put(ref, "_keywords", "keywords"), st.args)
        {{:arg, name}, %{st | args: Map.put(st.args, key, {name, "text"})}}
    end
  end

  defp keyword_patterns(_part, st),
    do: unsupported(st, {"contains keyword(s) whose words are not an input or a literal", nil})

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
