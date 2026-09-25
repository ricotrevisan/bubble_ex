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
  | `x is y` | `x == y` when either side cannot be empty; otherwise `is_not_distinct_from(x, y)`, keeping Bubble's "empty is empty" |
  | `x is not y` | `x != y` when neither side can be empty; otherwise `is_distinct_from(x, y)` |
  | `x is empty` | `is_nil(x)`; also `x == ""` for text and `x == []` for a list |
  | `>`, `<`, `>=`, `<=` | the operator |
  | `and`, `or`, `not` | the operator |
  | a yes/no value used as a condition | `x == true` |
  | `logged in` | `not is_nil(^actor(:id))` |
  | `list contains item` | `item in list` (lists of things are `{:array, :string}` of IDs, WTF-338) |
  | `text contains string` | `contains(text, string)` |
  | `+`, `-`, `*`, `/` on numbers | the operator |
  | a context input (element value, parameter, …) | `^arg(:name)`, listed in `arguments`, where allowed (`inputs: :arguments`); unsupported in privacy rules |

  Anything else (a path through a list of things, a field of a context
  input, list algebra, counts, fallbacks, text operators other than
  lowercase, searches inside a filter) is not compiled: the result has
  `expr: nil` and an `:ash_expr_unsupported` diagnostic (stage
  `{:target, :ash}`) listing each construct in `details.constructs`. A
  field, type or option value the Project does not map gives
  `:ash_expr_unmapped_reference`.
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
      unsupported: [],
      unmapped: []
    }
  end

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

  # A condition: predicates compile as themselves, other yes/no values as `x == true`.
  defp pred(%IR{op: op} = ir, st) when op in [:and, :or] do
    {nodes, st} = Enum.map_reduce(ir.args, st, &pred/2)
    {all_ok({op, nodes}, nodes), st}
  end

  defp pred(%IR{op: :not, args: [x]}, st) do
    {node, st} = pred(x, st)
    {ok(node, &{:not, &1}), st}
  end

  defp pred(%IR{op: :literal, args: [b]}, st) when is_boolean(b), do: {{:value, b}, st}

  defp pred(%IR{op: op, args: [l, r]}, st) when op in [:eq, :neq] do
    case {l, r} do
      {%IR{op: :empty}, x} -> pred(empty_check(op, x), st)
      {x, %IR{op: :empty}} -> pred(empty_check(op, x), st)
      _ -> equality(op, l, r, st)
    end
  end

  defp pred(%IR{op: op, args: [l, r]}, st) when is_map_key(@compare, op) do
    {[a, b], st} = values([l, r], st)
    {all_ok({:op, Map.fetch!(@compare, op), a, b}, [a, b]), st}
  end

  defp pred(%IR{op: :is_empty, args: [x]}, st) do
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

  defp pred(%IR{op: :logged_in}, st) do
    {node, st} = value(IR.node(:current_user, [], "user"), st)
    {ok(node, &{:not, {:call, "is_nil", [&1]}}), st}
  end

  defp pred(%IR{op: :member, args: [list, item]}, st) do
    if list_type?(list.type) do
      {[l, i], st} = values([list, item], st)
      {all_ok({:op, "in", i, l}, [l, i]), st}
    else
      unsupported(st, {"contains on a value that is not a list", nil})
    end
  end

  defp pred(%IR{op: :text_contains, args: [text, part]}, st) do
    {[t, p], st} = values([text, part], st)
    {all_ok({:call, "contains", [t, p]}, [t, p]), st}
  end

  defp pred(%IR{op: op, type: "boolean"} = ir, st) when op in @boolean_values do
    {node, st} = value(ir, st)
    {ok(node, &{:op, "==", &1, {:value, true}}), st}
  end

  defp pred(%IR{op: op}, st), do: unsupported(st, {"the condition #{inspect(op)}", nil})

  defp empty_check(:eq, x), do: IR.node(:is_empty, [x], "boolean")
  defp empty_check(:neq, x), do: IR.node(:not, [IR.node(:is_empty, [x], "boolean")], "boolean")

  defp equality(op, l, r, st) do
    {[a, b], st} = values([l, r], st)
    nonnull = {nonnull?(a, st), nonnull?(b, st)}

    node =
      case {op, nonnull} do
        {:eq, {false, false}} -> {:call, "is_not_distinct_from", [a, b]}
        {:eq, _} -> {:op, "==", a, b}
        {:neq, {true, true}} -> {:op, "!=", a, b}
        {:neq, _} -> {:call, "is_distinct_from", [a, b]}
      end

    {all_ok(node, [a, b]), st}
  end

  defp nonnull?({:value, v}, _st), do: not is_nil(v)
  defp nonnull?({:ref, [], attr}, st), do: attr == st.lookup.types[st.resource].pk
  defp nonnull?(_, _st), do: false

  defp values(irs, st), do: Enum.map_reduce(irs, st, &value/2)

  # --- values ---------------------------------------------------------------------

  defp value(%IR{op: :literal, args: [v]}, st), do: {{:value, v}, st}
  defp value(%IR{op: :empty}, st), do: {{:value, nil}, st}

  defp value(%IR{op: :option, args: [set, value_id, key]}, st) do
    case Map.get(st.lookup.enums, set) do
      nil ->
        unmapped(st, {"the option set", set})

      keys ->
        if is_binary(key) and MapSet.member?(keys, key),
          do: {{:value, key}, st},
          else: unmapped(st, {"the option", "#{set}.#{value_id}"})
    end
  end

  defp value(%IR{op: :this, args: [binder]} = ir, st) when binder in [:rule_record, :filter_item],
    do: path(ir, [], st)

  defp value(%IR{op: :current_user} = ir, st), do: path(ir, [], st)
  defp value(%IR{op: :field} = ir, st), do: path(ir, [], st)

  defp value(%IR{op: :input, args: [kind, ref], type: type}, %{inputs: :arguments} = st) do
    case Map.get(st.args, {kind, ref}) do
      {name, _} ->
        {{:arg, name}, st}

      nil ->
        name = argument_name(kind, ref, st.args)
        {{:arg, name}, %{st | args: Map.put(st.args, {kind, ref}, {name, type})}}
    end
  end

  defp value(%IR{op: :input, args: [kind, _]}, st),
    do: unsupported(st, {"the context input #{kind}", nil})

  defp value(%IR{op: op, args: [l, r], type: "number"}, st) when is_map_key(@arithmetic, op) do
    {[a, b], st} = values([l, r], st)
    {all_ok({:op, Map.fetch!(@arithmetic, op), a, b}, [a, b]), st}
  end

  defp value(%IR{op: :lowercase, args: [x]}, st) do
    {node, st} = value(x, st)
    {ok(node, &{:call, "string_downcase", [&1]}), st}
  end

  # A predicate used as a value (e.g. compared with yes/no).
  defp value(%IR{op: op, type: "boolean"} = ir, st) when op not in @boolean_values,
    do: pred(ir, st)

  defp value(%IR{op: op}, st), do: unsupported(st, {"the value #{inspect(op)}", nil})

  # A field chain down to its base: `steps` are `{data_type, field}` from
  # the base outwards.
  defp path(%IR{op: :field, args: [base, type, field]}, steps, st),
    do: path(base, [{type, field} | steps], st)

  defp path(%IR{op: :this, args: [binder]}, steps, st)
       when binder in [:rule_record, :filter_item] do
    case resolve(steps, st.resource, st) do
      {:ok, [], nil} -> {{:ref, [], st.lookup.types[st.resource].pk}, st}
      {:ok, rels, attr} -> {{:ref, rels, attr}, st}
      {:error, what} -> classify(st, what)
    end
  end

  defp path(%IR{op: :current_user}, steps, st) do
    case resolve(steps, "user", st) do
      {:ok, [], nil} ->
        {{:actor, [st.lookup.types["user"].pk]}, st}

      {:ok, rels, attr} ->
        st = if rels == [], do: st, else: %{st | loads: MapSet.put(st.loads, rels)}
        {{:actor, rels ++ [attr]}, st}

      {:error, what} ->
        classify(st, what)
    end
  end

  defp path(%IR{op: op}, _steps, st), do: unsupported(st, {"a field of #{op}", nil})

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
      {:ok, rels, info.attribute}
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

  defp unsupported(st, what), do: {:error, %{st | unsupported: [what | st.unsupported]}}
  defp unmapped(st, what), do: {:error, %{st | unmapped: [what | st.unmapped]}}

  defp diagnostics(st, opts) do
    path = Keyword.get(opts, :path, "")
    subject = Keyword.get(opts, :subject, %{})

    [
      {:ash_expr_unsupported, st.unsupported, "has no Ash.Expr mapping"},
      {:ash_expr_unmapped_reference, st.unmapped, "is not mapped by the Ash project"}
    ]
    |> Enum.reject(fn {_code, whats, _} -> whats == [] end)
    |> Enum.map(fn {code, whats, why} ->
      whats = whats |> Enum.uniq() |> Enum.sort()
      text = Enum.map_join(whats, "; ", &describe/1)

      diagnostic(code, path, "#{text} #{why}; the expression is not compiled",
        target: :ash,
        subject: subject,
        details: %{
          constructs: whats |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
          at: for({_, at} <- whats, at != nil, do: at)
        }
      )
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
