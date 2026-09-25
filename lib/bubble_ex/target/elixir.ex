defmodule BubbleEx.Target.Elixir do
  @moduledoc """
  Compiles expression IR (`BubbleEx.Expression.IR`) to an Elixir
  expression, as source text, for value expressions in generated LiveViews
  and workflow bodies (dynamic text, arithmetic, comparisons, conditions).
  Records are the generated Ash resources' structs, so field names come
  from the mapped `BubbleEx.Target.Ash.Project`.

      {:ok, project} = BubbleEx.Target.Ash.map(model)
      {:ok, %{source: source, bindings: bindings, runtime: runtime}} =
        BubbleEx.Target.Elixir.compile(ir, project)

  The expression is pure. Its free variables are its `bindings`:
  `current_user` (the actor, nil when logged out), `this` (the context's
  record) and one variable per context input (element values, parameters,
  step results, …), named from the input and its Bubble IDs:
  `%{var, input, type}`. `loads` lists the relationship paths each record
  variable must have loaded (`%{"this" => [["project"]]}`).

  ## Semantics

  Field access is nil-safe (a field of an empty value is empty), written as
  `get_in(x, [Access.key(:a), Access.key(:b)])`. Records are compared by
  Bubble ID. `==` treats empty as equal to empty, as Bubble does.
  Everything whose Bubble behavior Elixir's operators do not match (ordering
  with empty values, arithmetic, emptiness, text formatting) is a call to a
  runtime module the generated app provides (`:runtime`, default
  `"Bubble.Runtime"`); `runtime` lists the functions used:

  | Function | Bubble |
  |----------|--------|
  | `text(x)` | a value shown in text (numbers without a trailing `.0`, yes/no, dates) |
  | `empty?(x)` | `is empty`: nil, `""` or `[]` |
  | `compare(op, a, b)` | `>`, `<`, `>=`, `<=`; false when either side is empty |
  | `add/sub/mul/div/mod(a, b)` | arithmetic; dates plus intervals |
  | `default(x, d)` | `defaulting to` |
  | `lowercase/uppercase/trim/capitalize_words/text_length/json_encode/url_encode/is_email/abs/round/to_text/to_number(x)` | the operators |
  | `format_date(x, format)`, `format_number(x, options)`, `format_boolean(x, yes, no)`, `truncate(x, n)`, `replace(x, find, replace, regex?)`, `split(x, sep)`, `date_add(x, n, unit)`, `date_floor(x, unit)`, `date_part(x, unit)`, `text_contains?(a, b)`, `text_contains_words?(a, b)` | the formatting and date operators (stubs until the runtime is written) |

  Not compiled yet (diagnosed with `:elixir_expr_unsupported`, stage
  `{:target, :elixir}`): searches and `:filtered` (these become Ash
  queries), sorting, API type fields, fields of list items (a list of
  things is a list of IDs), list algebra other than `count`, `first`,
  `last` and `contains`.

  An option is its stored key; its label is the generated enum's
  `label/1` and an attribute its `attributes/1` entry.
  """

  alias BubbleEx.{Diagnostic, Error}
  alias BubbleEx.Expression.IR
  alias BubbleEx.Model.Type
  alias BubbleEx.Target.Ash.Project

  @type result :: %{
          source: String.t() | nil,
          bindings: [map()],
          loads: %{String.t() => [[String.t()]]},
          runtime: [atom()],
          diagnostics: [Diagnostic.t()]
        }

  @type option ::
          {:runtime, String.t()}
          | {:namespace, String.t()}
          | {:subject, Diagnostic.subject()}
          | {:path, String.t() | list()}

  @runtime_unary ~w(lowercase uppercase trim capitalize_words text_length json_encode url_encode
                    is_email abs round to_text to_number)a
  @arithmetic ~w(add sub mul div mod)a
  @compare %{gt: :gt, lt: :lt, gte: :gte, lte: :lte}

  @doc """
  Compiles `ir` to Elixir source. See the moduledoc.

  ## Options

    * `:runtime` - the runtime module, default `"Bubble.Runtime"`
    * `:namespace` - root namespace of the generated modules, default
      `"MyApp"` (for enum modules)
    * `:subject` / `:path` - diagnostic subject and pointer
  """
  @spec compile(IR.t(), Project.t(), [option()]) :: {:ok, result()} | {:error, Error.t()}
  def compile(ir, project, opts \\ [])

  def compile(%IR{} = ir, %Project{} = project, opts) when is_list(opts),
    do: {:ok, do_compile(ir, project, opts)}

  def compile(_ir, _project, _opts),
    do:
      {:error,
       Error.new(:invalid_input, "expected an IR node, a BubbleEx.Target.Ash.Project and options")}

  defp do_compile(ir, project, opts) do
    st = %{
      lookup: lookup(project),
      runtime: Keyword.get(opts, :runtime, "Bubble.Runtime"),
      namespace: Keyword.get(opts, :namespace, "MyApp"),
      bindings: %{},
      loads: %{},
      used: MapSet.new(),
      unsupported: []
    }

    {source, st} = value(ir, st)

    if source == :error or st.unsupported != [] do
      %{source: nil, bindings: [], loads: %{}, runtime: [], diagnostics: diagnostics(st, opts)}
    else
      formatted = source |> Code.format_string!() |> IO.iodata_to_binary()

      %{
        source: formatted,
        bindings: st.bindings |> Map.values() |> Enum.sort_by(& &1.var),
        loads:
          Map.new(st.loads, fn {var, paths} -> {var, paths |> MapSet.to_list() |> Enum.sort()} end),
        runtime: st.used |> MapSet.to_list() |> Enum.sort(),
        diagnostics: []
      }
    end
  end

  defp lookup(project) do
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

        {resource.source.type, %{pk: pk && pk.name, fields: fields}}
      end)

    enums = Map.new(project.enums, &{&1.source.option_set, &1})
    %{types: types, enums: enums}
  end

  # --- values ---------------------------------------------------------------------

  defp value(%IR{op: :literal, args: [v]}, st), do: {inspect(v), st}
  defp value(%IR{op: :empty}, st), do: {"nil", st}

  defp value(%IR{op: :option, args: [set, _value, key]}, st) do
    case st.lookup.enums[set] do
      %{values: values} when is_binary(key) ->
        if Enum.any?(values, &(&1.value == key)),
          do: {inspect(key), st},
          else: unsupported(st, {"an unmapped option", "#{set}.#{key}"})

      _ ->
        unsupported(st, {"an unmapped option set", set})
    end
  end

  defp value(%IR{op: :all_options, args: [set]}, st) do
    case st.lookup.enums[set] do
      %{module: module} -> {"#{st.namespace}.#{module}.values()", st}
      nil -> unsupported(st, {"an unmapped option set", set})
    end
  end

  defp value(%IR{op: :option_label, args: [x, set]}, st) do
    case st.lookup.enums[set] do
      nil ->
        unsupported(st, {"an unmapped option set", set})

      enum ->
        {part, st} = value(x, st)
        {ok(part, &"then(#{&1}, &(&1 && #{st.namespace}.#{enum.module}.label(&1)))"), st}
    end
  end

  defp value(%IR{op: :option_attribute, args: [x, set, attr]}, st) do
    case st.lookup.enums[set] do
      nil ->
        unsupported(st, {"an unmapped option set", set})

      enum ->
        case Enum.find(enum.attributes, &(&1.source.field == attr)) do
          nil ->
            unsupported(st, {"an unmapped option attribute", "#{set}.#{attr}"})

          %{name: name} ->
            {part, st} = value(x, st)
            module = "#{st.namespace}.#{enum.module}"
            {ok(part, &"then(#{&1}, &(&1 && #{module}.attributes(&1).#{name}))"), st}
        end
    end
  end

  defp value(%IR{op: :current_user}, st),
    do: {"current_user", bind(st, "current_user", :current_user, "user")}

  defp value(%IR{op: :this, args: [binder], type: t}, st),
    do: {"this", bind(st, "this", {:this, binder}, t)}

  defp value(%IR{op: :input, args: [kind, ref], type: type}, st) do
    case Enum.find(st.bindings, fn {_, b} -> b.input == {kind, ref} end) do
      {var, _} ->
        {var, st}

      nil ->
        var = variable(kind, ref, st.bindings)
        {var, bind(st, var, {kind, ref}, type)}
    end
  end

  defp value(%IR{op: :field} = ir, st), do: path(ir, [], :value, st)

  defp value(%IR{op: op, args: [l, r]}, st) when op in [:eq, :neq] do
    {[a, b], st} = Enum.map_reduce([l, r], st, &id_value/2)
    {all_ok("(#{a} #{if op == :eq, do: "==", else: "!="} #{b})", [a, b]), st}
  end

  defp value(%IR{op: op, args: [l, r]}, st) when is_map_key(@compare, op) do
    {[a, b], st} = Enum.map_reduce([l, r], st, &value/2)
    runtime(st, :compare, [inspect(Map.fetch!(@compare, op)), a, b])
  end

  defp value(%IR{op: op, args: args}, st) when op in [:and, :or] do
    {parts, st} = Enum.map_reduce(args, st, &condition/2)
    {all_ok("(" <> Enum.join(parts, " #{op} ") <> ")", parts), st}
  end

  defp value(%IR{op: :not, args: [x]}, st) do
    {part, st} = condition(x, st)
    {ok(part, &"not #{&1}"), st}
  end

  defp value(%IR{op: :is_empty, args: [x]}, st) do
    {part, st} = value(x, st)
    runtime(st, :empty?, [part])
  end

  defp value(%IR{op: :logged_in}, st),
    do: {"not is_nil(current_user)", bind(st, "current_user", :current_user, "user")}

  defp value(%IR{op: :member, args: [list, item]}, st) do
    if member_list?(list) do
      {[l, i], st} = Enum.map_reduce([list, item], st, &id_value/2)
      {all_ok("Enum.member?(#{l} || [], #{i})", [l, i]), st}
    else
      unsupported(st, {"contains on a list of records", nil})
    end
  end

  defp value(%IR{op: :count, args: [list]}, st) do
    {l, st} = value(list, st)
    {ok(l, &"length(#{&1} || [])"), st}
  end

  defp value(%IR{op: op, args: [list]}, st) when op in [:first, :last] do
    fun = if op == :first, do: "List.first", else: "List.last"
    {l, st} = value(list, st)
    {ok(l, &"#{fun}(#{&1} || [])"), st}
  end

  defp value(%IR{op: op, args: [l, r]}, st) when op in @arithmetic do
    {[a, b], st} = Enum.map_reduce([l, r], st, &value/2)
    runtime(st, op, [a, b])
  end

  defp value(%IR{op: :concat, args: parts}, st) do
    {texts, st} =
      Enum.map_reduce(parts, st, fn
        %IR{op: :literal, args: [text]}, st when is_binary(text) -> {inspect(text), st}
        part, st -> part |> value(st) |> then(fn {p, st} -> text(p, st) end)
      end)

    {all_ok("(" <> Enum.join(texts, " <> ") <> ")", texts), st}
  end

  defp value(%IR{op: :fallback, args: [x, d]}, st) do
    {[a, b], st} = Enum.map_reduce([x, d], st, &value/2)
    runtime(st, :default, [a, b])
  end

  defp value(%IR{op: op, args: [x]}, st) when op in @runtime_unary do
    {a, st} = value(x, st)
    runtime(st, op, [a])
  end

  defp value(%IR{op: op, args: [x | options]}, st)
       when op in [:format_date, :format_number, :date_floor, :date_part] do
    {a, st} = value(x, st)
    runtime(st, op, [a | Enum.map(options, &inspect/1)])
  end

  defp value(%IR{op: :date_add, args: [x, n, unit]}, st) do
    {[a, b], st} = Enum.map_reduce([x, n], st, &value/2)
    runtime(st, :date_add, [a, b, inspect(unit)])
  end

  defp value(%IR{op: :replace, args: [x, find, replace, regex]}, st) do
    {parts, st} = Enum.map_reduce([x, find, replace], st, &value/2)
    runtime(st, :replace, parts ++ [inspect(regex)])
  end

  defp value(%IR{op: op, args: args}, st)
       when op in [:format_boolean, :truncate, :split, :text_contains, :text_contains_words] do
    {parts, st} = Enum.map_reduce(args, st, &value/2)
    name = if op in [:text_contains, :text_contains_words], do: :"#{op}?", else: op
    runtime(st, name, parts)
  end

  defp value(%IR{op: op}, st), do: unsupported(st, {"#{op}", nil})

  # A yes/no in a condition: predicates are booleans, other values may be nil.
  defp condition(%IR{op: op} = ir, st)
       when op in [:field, :input, :fallback, :option_attribute, :option_label] do
    {part, st} = value(ir, st)
    {ok(part, &"(#{&1} == true)"), st}
  end

  defp condition(ir, st), do: value(ir, st)

  defp text(:error, st), do: {:error, st}
  defp text(part, st), do: runtime(st, :text, [part])

  # Records compare by Bubble ID: a record-valued expression as its ID.
  defp id_value(%IR{type: type} = ir, st) do
    if record_type?(type) do
      case ir do
        %IR{op: :field} -> path(ir, [], :id, st)
        %IR{op: op} when op in [:this, :current_user] -> path(ir, [], :id, st)
        _ -> value(ir, st)
      end
    else
      value(ir, st)
    end
  end

  defp record_type?(type), do: match?(%Type{kind: :ref, cardinality: :one}, classify(type))

  # A list whose items are values or Bubble IDs: a list-of-things field is
  # an array of IDs, other lists of records (inputs, searches) hold records.
  defp member_list?(%IR{op: op, type: type}) do
    case classify(type) do
      %Type{cardinality: :many, kind: :ref} -> op in [:field, :literal]
      %Type{cardinality: :many} -> true
      _ -> false
    end
  end

  # IR types are Bubble descriptors; the Model classifies them.
  defp classify(type) when is_binary(type), do: type |> Type.classify() |> elem(0)
  defp classify(_type), do: nil

  # --- field paths ----------------------------------------------------------------

  defp path(%IR{op: :field, args: [base, type, field]}, steps, mode, st),
    do: path(base, [{type, field} | steps], mode, st)

  defp path(%IR{op: :this} = base, steps, mode, st), do: access(base, "this", steps, mode, st)

  defp path(%IR{op: :current_user} = base, steps, mode, st),
    do: access(base, "current_user", steps, mode, st)

  defp path(%IR{op: :input} = base, steps, mode, st) do
    {var, st} = value(base, st)
    access(base, var, steps, mode, st)
  end

  defp path(%IR{op: op}, _steps, _mode, st), do: unsupported(st, {"a field of #{op}", nil})

  defp access(%IR{} = base, var, steps, mode, st) do
    {_, st} = if var in ["this", "current_user"], do: value(base, st), else: {var, st}
    base_type = type_id(base.type)

    case keys(steps, base_type, mode, st) do
      {:ok, [], _loads} ->
        {var, st}

      {:ok, keys, loads} ->
        st = if loads == [], do: st, else: add_load(st, var, loads)
        {"get_in(#{var}, [" <> Enum.map_join(keys, ", ", &"Access.key(#{atom(&1)})") <> "])", st}

      {:error, what} ->
        unsupported(st, what)
    end
  end

  # Access keys for a field chain. Relationship steps need loading; the
  # last step is its attribute, or in `:id` mode a reference's `_id`
  # attribute (no load); in `:value` mode a reference is its relationship.
  defp keys([], type, :id, st) do
    case st.lookup.types[type] do
      %{pk: pk} -> {:ok, [pk], []}
      nil -> {:error, {"an unmapped data type", type}}
    end
  end

  defp keys([], _type, :value, _st), do: {:ok, [], []}

  defp keys(steps, _type, mode, st) do
    {init, [{last_type, last_field}]} = Enum.split(steps, -1)

    with {:ok, rels} <- relationships(init, st),
         {:ok, info} <- field_info(last_type, last_field, st) do
      last =
        if mode == :value and info.relationship,
          do: info.relationship,
          else: info.attribute

      loads = if mode == :value and info.relationship, do: rels ++ [last], else: rels
      {:ok, rels ++ [last], if(loads == [], do: [], else: [loads])}
    end
  end

  defp relationships(steps, st) do
    Enum.reduce_while(steps, {:ok, []}, fn {type, field}, {:ok, rels} ->
      case field_info(type, field, st) do
        {:ok, %{relationship: rel}} when is_binary(rel) -> {:cont, {:ok, rels ++ [rel]}}
        {:ok, _} -> {:halt, {:error, {"a path through a list or value", "#{type}.#{field}"}}}
        error -> {:halt, error}
      end
    end)
  end

  defp field_info(type, field, st) do
    case get_in(st.lookup, [:types, type, :fields, field]) do
      nil -> {:error, {"an unmapped field", "#{type}.#{field}"}}
      info -> {:ok, info}
    end
  end

  defp add_load(st, var, loads) do
    paths = Map.get(st.loads, var, MapSet.new())
    %{st | loads: Map.put(st.loads, var, Enum.into(loads, paths))}
  end

  defp type_id(type) do
    case classify(type) do
      %Type{kind: :ref, target: id} -> id
      _ -> nil
    end
  end

  # --- bindings and names ------------------------------------------------------------

  defp bind(st, var, input, type) do
    if Map.has_key?(st.bindings, var),
      do: st,
      else: %{st | bindings: Map.put(st.bindings, var, %{var: var, input: input, type: type})}
  end

  defp variable(kind, ref, bindings) do
    base =
      [
        Atom.to_string(kind)
        | for({_, v} <- Enum.sort(ref), is_binary(v) or is_number(v), do: to_string(v))
      ]
      |> Enum.join("_")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, "_")
      |> String.trim("_")

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}_#{n}"
    end)
    |> Enum.find(&(not Map.has_key?(bindings, &1)))
  end

  defp atom(name) do
    if Regex.match?(~r/^[a-z_][A-Za-z0-9_]*[?!]?$/, name),
      do: ":" <> name,
      else: ":" <> inspect(name)
  end

  # --- results -------------------------------------------------------------------------

  defp runtime(st, fun, args) do
    if Enum.member?(args, :error) do
      {:error, st}
    else
      {"#{st.runtime}.#{fun}(#{Enum.join(args, ", ")})", %{st | used: MapSet.put(st.used, fun)}}
    end
  end

  defp ok(:error, _fun), do: :error
  defp ok(part, fun), do: fun.(part)

  defp all_ok(source, parts), do: if(Enum.member?(parts, :error), do: :error, else: source)

  # A construct is `{kind, at}`: `kind` holds no Bubble IDs (reports count
  # it); `at` names the Bubble IDs involved, or nil.
  defp unsupported(st, {_kind, _at} = what),
    do: {:error, %{st | unsupported: [what | st.unsupported]}}

  defp describe({kind, nil}), do: kind
  defp describe({kind, at}), do: "#{kind} #{inspect(at)}"

  defp diagnostics(st, opts) do
    whats = st.unsupported |> Enum.uniq() |> Enum.sort()
    text = Enum.map_join(whats, "; ", &describe/1)

    [
      Diagnostic.new(
        :elixir_expr_unsupported,
        Keyword.get(opts, :path, ""),
        "#{text} has no Elixir mapping yet; the expression is not compiled",
        target: :elixir,
        subject: Keyword.get(opts, :subject, %{}),
        details: %{
          constructs: whats |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
          at: for({_, at} <- whats, at != nil, do: at)
        }
      )
    ]
  end
end
