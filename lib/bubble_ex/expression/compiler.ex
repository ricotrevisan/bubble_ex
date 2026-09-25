defmodule BubbleEx.Expression.Compiler do
  @moduledoc """
  Compiles an expression AST to the stack-neutral `BubbleEx.Expression.IR`.

      env = BubbleEx.Expression.Env.new(model, this_type: "custom.task", this_binder: :rule_record)
      {:ok, %{ir: ir, typed: typed, diagnostics: diagnostics}} =
        BubbleEx.Expression.Compiler.compile(ast, env)

  It types the AST first (`BubbleEx.Expression.Typing`), then lowers every
  node. An expression compiles whole or not at all: `ir` is nil when any
  part has no IR, and `diagnostics` itemizes every such part (stage
  `:model`, `:expr_uncompiled`, pointing at the part) next to the typing
  diagnostics. A part left untyped by typing is reported once, by typing.

  What has no IR yet: raw nodes (the parser's unmodeled operators and
  sources), searches and filters with unmodeled constraints or options
  (`dynamic_sort_field`, `additional_sort_fields`), elements used as values
  without a state, and constraints whose value may be empty while the
  search does not say whether empty constraints are ignored (Bubble's
  `ignore_empty_constraints`; absent in most searches, and its default is
  not verified: `Env.ignore_empty_constraints` supplies one).
  """

  alias BubbleEx.{Diagnostic, Error, Expression, Model}
  alias BubbleEx.Expression.{Ast, Env, IR, Keys, Typing}
  alias BubbleEx.Model.OptionSet
  alias BubbleEx.Model.OptionValue, as: ModelOptionValue

  alias BubbleEx.Expression.Ast.{
    AllOptions,
    ArbitraryText,
    Arithmetic,
    Check,
    Compare,
    Constraint,
    CurrentUser,
    DynamicText,
    Empty,
    Fallback,
    Field,
    Filter,
    ListOp,
    Literal,
    Logical,
    OptionValue,
    Property,
    Raw,
    Scope,
    Search,
    ThisThing
  }

  @type result :: %{ir: IR.t() | nil, typed: Ast.t(), diagnostics: [Diagnostic.t()]}

  @compare %{
    equals: :eq,
    not_equals: :neq,
    greater_than: :gt,
    less_than: :lt,
    greater_or_equal: :gte,
    less_or_equal: :lte
  }
  @arithmetic %{plus: :add, minus: :sub, times: :mul, divided_by: :div, modulo: :mod}
  @list_unary %{count: :count, first_item: :first, last_item: :last, unique: :unique}
  @list_binary %{
    item_number: :item_at,
    limit_to: :limit,
    merged_with: :merge,
    minus_list: :minus_list,
    intersect_with: :intersect,
    plus_item: :plus_item,
    minus_item: :minus_item,
    contains_list: :contains_all
  }
  @operators %{
    "to_lowercase" => :lowercase,
    "to_uppercase" => :uppercase,
    "trim" => :trim,
    "capitalized_words" => :capitalize_words,
    "format_json_encode" => :json_encode,
    "format_url_encode" => :url_encode,
    "length" => :text_length,
    "number_of_characters" => :text_length,
    "is_email" => :is_email,
    "absolute_value" => :abs,
    "rounded" => :round,
    "as_text" => :to_text,
    "convert_to_number" => :to_number,
    "url" => :to_text
  }
  @search_options ~w(sort_field descending ignore_empty_constraints)

  @doc "Types and compiles `ast` in `env`. See the moduledoc."
  @spec compile(Ast.t(), Env.t()) :: {:ok, result()} | {:error, Error.t()}
  def compile(ast, %Env{} = env) do
    if Ast.node?(ast) do
      {:ok, %{ast: typed, diagnostics: typing_diags}} = Typing.type(ast, env)
      ctx = %{env: env, this_type: env.this_type, this_binder: env.this_binder}
      {ir, _path, diags} = c(typed, env.path, ctx)
      diags = diags |> Diagnostic.put_subject(env.subject)

      {:ok,
       %{
         ir: if(ir == :error, do: nil, else: ir),
         typed: typed,
         diagnostics: Diagnostic.normalize(typing_diags ++ diags)
       }}
    else
      {:error, Error.new(:invalid_input, "expected a BubbleEx.Expression.Ast node")}
    end
  end

  # --- sources ---------------------------------------------------------------------

  # Each clause returns `{ir | :error, own source path, diagnostics}`.
  defp c(%Literal{value: nil}, base, _ctx), do: {IR.node(:empty), base, []}
  defp c(%Literal{value: v, type: t}, base, _ctx), do: {IR.node(:literal, [v], t), base, []}
  defp c(%Empty{}, base, _ctx), do: {IR.node(:empty), base, []}
  defp c(%CurrentUser{}, base, _ctx), do: {IR.node(:current_user, [], "user"), base, []}
  defp c(%ThisThing{binder: b, type: t}, base, _ctx), do: {IR.node(:this, [b], t), base, []}

  defp c(%OptionValue{option_set: set, value: value, type: type}, base, ctx) do
    set_id = strip_option(set)
    {IR.node(:option, [set_id, value, option_key(ctx.env.model, set_id, value)], type), base, []}
  end

  defp c(%AllOptions{option_set: set, type: type}, base, _ctx),
    do: {IR.node(:all_options, [strip_option(set)], type), base, []}

  defp c(%Scope{} = n, base, ctx) do
    case Typing.context(n, ctx.env) do
      {:value, {kind, ref}, type} when is_binary(type) ->
        {IR.node(:input, [kind, ref], type), base, []}

      {:element, %{}} ->
        {:error, base, [uncompiled(base, "an element used as a value", :element)]}

      # Typing reported it.
      _ ->
        {:error, base, []}
    end
  end

  defp c(%DynamicText{parts: parts} = n, base, ctx) do
    keys = keys(n.meta, :entry_keys, length(parts))
    ekey = key(n, :entries)

    {irs, diags} =
      parts
      |> Enum.with_index()
      |> Enum.map_reduce([], fn
        {part, _i}, acc when is_binary(part) ->
          {IR.node(:literal, [part], "text"), acc}

        {part, i}, acc ->
          {ir, _p, d} = c(part, base ++ [ekey, Enum.at(keys, i)], ctx)
          {ir, acc ++ d}
      end)

    ir =
      cond do
        Enum.member?(irs, :error) -> :error
        match?([%IR{op: :literal}], irs) -> hd(irs)
        irs == [] -> IR.node(:literal, [""], "text")
        true -> IR.node(:concat, irs, "text")
      end

    {ir, base, diags}
  end

  defp c(%ArbitraryText{text: text} = n, base, ctx) do
    {ir, _p, diags} = c(text, base ++ [key(n, :properties), "arbitrary_text"], ctx)
    {ir, base, diags}
  end

  defp c(%Search{} = n, base, ctx) do
    pbase = base ++ [key(n, :properties)]
    item = %{ctx | this_type: n.data_type, this_binder: :filter_item}

    with {:ok, type_id} <- data_type_id(n.data_type),
         :ok <- search_options(n.options, pbase) do
      cbase = pbase ++ [n.meta[:prop_keys][:constraints] || "constraints"]
      {pred, diags} = constraints(n, n.data_type, cbase, item)
      search = combine(IR.node(:search, [type_id, pred], n.type), [pred])
      {sorted(search, n.options), base, diags}
    else
      {:error, diag} -> {:error, base, [diag]}
      :error -> {:error, base, [uncompiled(pbase, "a search of an unknown data type", :search)]}
    end
  end

  defp c(%Raw{subject: nil} = n, base, _ctx),
    do: {:error, base, [uncompiled(base, "a raw source (#{n.reason})", :raw)]}

  defp c(%Raw{subject: subject, raw: raw} = n, base, ctx) do
    {ir, spath, diags} = operand(subject, base, ctx)
    path = spath ++ [link(n)]
    name = if is_map(raw), do: Keys.value(raw, :name)

    case raw_operator(name, raw, ir, path, ctx) do
      {:ok, op_ir, more} ->
        {combine(op_ir, op_ir.args), path, diags ++ more}

      :unknown ->
        {:error, path, diags ++ [uncompiled(path, "the operator #{inspect(name)}", :raw)]}
    end
  end

  # --- operators ------------------------------------------------------------------

  defp c(%Field{} = n, base, ctx) do
    {subject, spath, diags} = c(n.subject, base, ctx)
    path = spath ++ [link(n)]

    case {subject, field_node(subject, n, ctx.env)} do
      {:error, _} -> {:error, path, diags}
      {_, {:ok, ir}} -> {ir, path, diags}
      {_, :error} -> {:error, path, diags ++ [uncompiled(path, "an unresolved field", :field)]}
    end
  end

  defp c(%Property{type: nil} = n, base, ctx) do
    # Untyped: typing reported it.
    {_ir, spath, diags} = operand(n.subject, base, ctx)
    {:error, spath ++ [link(n)], diags}
  end

  defp c(%Property{subject: %Scope{} = scope, name: name, type: type} = n, base, ctx) do
    case Typing.context(scope, ctx.env) do
      {:element, %{id: id}} ->
        input = IR.node(:input, [:element_state, %{"element" => id, "state" => name}], type)
        {input, base ++ [link(n)], []}

      _ ->
        property_operator(n, base, ctx)
    end
  end

  defp c(%Property{} = n, base, ctx), do: property_operator(n, base, ctx)

  defp c(%Compare{op: op} = n, base, ctx) do
    binary(n, base, ctx, fn l, r -> IR.node(Map.fetch!(@compare, op), [l, r], "boolean") end)
  end

  defp c(%Logical{op: op} = n, base, ctx),
    do: binary(n, base, ctx, fn l, r -> IR.node(op, flatten(op, [l, r]), "boolean") end)

  defp c(%Arithmetic{op: op} = n, base, ctx),
    do: binary(n, base, ctx, fn l, r -> IR.node(Map.fetch!(@arithmetic, op), [l, r], n.type) end)

  defp c(%Check{op: op} = n, base, ctx) do
    {subject, spath, diags} = c(n.subject, base, ctx)
    path = spath ++ [link(n)]
    {check(op, subject), path, diags}
  end

  defp c(%ListOp{op: :sorted} = n, base, ctx) do
    {subject, spath, diags} = c(n.subject, base, ctx)
    path = spath ++ [link(n)]

    case search_options(n.options, path ++ [key(n, :properties)]) do
      :ok -> {sorted(subject, n.options), path, diags}
      {:error, diag} -> {:error, path, diags ++ [diag]}
    end
  end

  defp c(%ListOp{} = n, base, ctx) do
    {subject, spath, diags} = c(n.subject, base, ctx)
    path = spath ++ [link(n)]

    {arg, more} =
      case n.arg do
        nil ->
          {nil, []}

        arg ->
          {ir, _p, d} = c(arg, path ++ [key(n, :args)], ctx)
          {ir, d}
      end

    {list_op(n.op, subject, arg, n.type), path, diags ++ more}
  end

  defp c(%Filter{} = n, base, ctx) do
    {subject, spath, diags} = c(n.subject, base, ctx)
    path = spath ++ [link(n)]
    pbase = path ++ [key(n, :properties)]
    item_type = item_type(n.subject.type)
    item = %{ctx | this_type: item_type, this_binder: :filter_item}

    case search_options(n.options, pbase) do
      :ok ->
        cbase = pbase ++ [n.meta[:prop_keys][:constraints] || "constraints"]
        {pred, more} = constraints(n, item_type, cbase, item)
        ir = combine(IR.node(:filter, [subject, pred], n.type), [subject, pred])
        {sorted(ir, n.options), path, diags ++ more}

      {:error, diag} ->
        {:error, path, diags ++ [diag]}
    end
  end

  defp c(%Fallback{} = n, base, ctx) do
    {subject, spath, diags} = c(n.subject, base, ctx)
    path = spath ++ [link(n)]
    {fallback, _p, more} = c(n.fallback, path ++ [key(n, :args)], ctx)
    ir = combine(IR.node(:fallback, [subject, fallback], n.type), [subject, fallback])
    {ir, path, diags ++ more}
  end

  # The subject of an operator. An element is not a value, but the operator
  # after it fails on its own account, so it is not reported twice.
  defp operand(%Scope{} = scope, base, ctx) do
    case Typing.context(scope, ctx.env) do
      {:element, %{}} -> {:error, base, []}
      _ -> c(scope, base, ctx)
    end
  end

  defp operand(node, base, ctx), do: c(node, base, ctx)

  defp binary(n, base, ctx, build) do
    {left, spath, diags} = c(n.left, base, ctx)
    path = spath ++ [link(n)]
    {right, _p, more} = c(n.right, path ++ [key(n, :args)], ctx)
    ir = if left == :error or right == :error, do: :error, else: build.(left, right)
    {ir, path, diags ++ more}
  end

  defp property_operator(%Property{name: name, type: type} = n, base, ctx) do
    {subject, spath, diags} = c(n.subject, base, ctx)
    path = spath ++ [link(n)]

    case Map.fetch(@operators, name) do
      _ when name == "format_date" ->
        {combine(IR.node(:format_date, [subject, nil], type), [subject]), path, diags}

      {:ok, op} ->
        {combine(IR.node(op, [subject], type), [subject]), path, diags}

      :error ->
        {:error, path, diags ++ [uncompiled(path, "the operator #{inspect(name)}", :operator)]}
    end
  end

  # --- operators the parser keeps raw -----------------------------------------------

  # Bubble operators outside the parser's vocabulary, kept verbatim in a
  # `Raw` node with their operands unparsed. Those with an IR are lowered
  # here, parsing their operands in the same context.
  @date_units %{
    "plus_seconds" => :second,
    "plus_minutes" => :minute,
    "plus_hours" => :hour,
    "plus_days" => :day,
    "plus_months" => :month,
    "plus_years" => :year
  }

  defp raw_operator(name, raw, subject, path, ctx) when is_map_key(@date_units, name) do
    with {:ok, amount, diags} <- operand_arg(raw, :args, path, ctx) do
      {:ok, IR.node(:date_add, [subject, amount, Map.fetch!(@date_units, name)], "date"), diags}
    end
  end

  defp raw_operator("truncated", raw, subject, path, ctx) do
    with {:ok, n, diags} <- operand_arg(raw, :args, path, ctx),
         do: {:ok, IR.node(:truncate, [subject, n], "text"), diags}
  end

  defp raw_operator("format_boolean", raw, subject, path, ctx) do
    with {:ok, yes, d1} <- operand_prop(raw, "formatting_for_true", path, ctx),
         {:ok, no, d2} <- operand_prop(raw, "formatting_for_false", path, ctx) do
      {:ok, IR.node(:format_boolean, [subject, yes, no], "text"), d1 ++ d2}
    end
  end

  defp raw_operator("format_date", raw, subject, _path, _ctx) do
    format = raw |> Keys.value(:properties) |> prop("formatting_type")

    if is_binary(format),
      do: {:ok, IR.node(:format_date, [subject, format], "text"), []},
      else: :unknown
  end

  defp raw_operator("format_number", raw, subject, _path, _ctx) do
    props = Keys.value(raw, :properties)

    if is_map(props) and Enum.all?(props, fn {_, v} -> not is_map(v) end),
      do: {:ok, IR.node(:format_number, [subject, props], "text"), []},
      else: :unknown
  end

  defp raw_operator("find_replace", raw, subject, path, ctx) do
    regex = raw |> Keys.value(:properties) |> prop("use_regex")

    with true <- regex in [true, false, nil],
         {:ok, find, d1} <- operand_prop(raw, "find", path, ctx),
         {:ok, replace, d2} <- operand_prop(raw, "replace", path, ctx) do
      {:ok, IR.node(:replace, [subject, find, replace, regex == true], "text"), d1 ++ d2}
    else
      false -> :unknown
      other -> other
    end
  end

  defp raw_operator("split_by", raw, subject, path, ctx) do
    with {:ok, sep, diags} <- operand_prop(raw, "separator", path, ctx),
         do: {:ok, IR.node(:split, [subject, sep], "list.text"), diags}
  end

  defp raw_operator(name, raw, subject, _path, _ctx)
       when name in ["rounded_down", "extract_from_date"] do
    unit = raw |> Keys.value(:properties) |> prop("component_to_extract")
    op = if name == "rounded_down", do: :date_floor, else: :date_part
    type = if name == "rounded_down", do: "date", else: "number"
    if is_binary(unit), do: {:ok, IR.node(op, [subject, unit], type), []}, else: :unknown
  end

  defp raw_operator(_name, _raw, _subject, _path, _ctx), do: :unknown

  defp prop(props, name) when is_map(props), do: Map.get(props, name)
  defp prop(_props, _name), do: nil

  defp operand_arg(raw, key, path, ctx) do
    case Keys.get(raw, key) do
      {k, value} -> sub_expression(value, path ++ [k], ctx)
      nil -> :unknown
    end
  end

  defp operand_prop(raw, name, path, ctx) do
    case Keys.get(raw, :properties) do
      {pkey, %{^name => value}} -> sub_expression(value, path ++ [pkey, name], ctx)
      _ -> :unknown
    end
  end

  # Parses, types and compiles an operand kept verbatim in a raw operator.
  defp sub_expression(raw, path, ctx) do
    opts = [
      schema: ctx.env.schema,
      this_type: ctx.this_type,
      this_binder: ctx.this_binder,
      path: path
    ]

    case Expression.parse(raw, opts) do
      {:ok, %{ast: ast, diagnostics: parse_diags}} ->
        env = %{ctx.env | this_type: ctx.this_type, this_binder: ctx.this_binder, path: path}
        {:ok, %{ast: typed, diagnostics: typing_diags}} = Typing.type(ast, env)
        {ir, _p, diags} = c(typed, path, ctx)
        {:ok, ir, parse_diags ++ typing_diags ++ diags}

      {:error, _} ->
        :unknown
    end
  end

  # --- fields -------------------------------------------------------------------------

  defp field_node(subject, %Field{field: field, type: type, subject: s}, env) do
    case {s.type, Typing.field(env, s.type, field)} do
      {_, :error} ->
        :error

      {subject_type, {:ok, _}} when is_binary(subject_type) ->
        case owner(subject_type) do
          {:data_type, id} -> {:ok, IR.node(:field, [subject, id, field], type)}
          {:option, set} -> {:ok, IR.node(:option_attribute, [subject, set, field], type)}
          {:external, ext} -> {:ok, IR.node(:external_field, [subject, ext, field], type)}
          nil -> :error
        end

      _ ->
        :error
    end
  end

  defp owner("list." <> item), do: owner(item)
  defp owner("user"), do: {:data_type, "user"}
  defp owner("custom." <> id), do: {:data_type, id}
  defp owner("option." <> id), do: {:option, id}
  defp owner("api." <> _ = id), do: {:external, id}
  defp owner(_), do: nil

  defp data_type_id(type) do
    case owner(type) do
      {:data_type, id} -> {:ok, id}
      _ -> :error
    end
  end

  # --- checks and list operators ------------------------------------------------------

  defp check(_op, :error), do: :error
  defp check(:is_empty, x), do: IR.node(:is_empty, [x], "boolean")
  defp check(:is_not_empty, x), do: negate(IR.node(:is_empty, [x], "boolean"))

  defp check(:is_true, x),
    do: IR.node(:eq, [x, IR.node(:literal, [true], "boolean")], "boolean")

  defp check(:is_false, x),
    do: IR.node(:eq, [x, IR.node(:literal, [false], "boolean")], "boolean")

  defp check(:logged_in, _x), do: IR.node(:logged_in, [], "boolean")
  defp check(:logged_out, _x), do: negate(IR.node(:logged_in, [], "boolean"))

  defp list_op(_op, :error, _arg, _type), do: :error
  defp list_op(_op, _subject, :error, _type), do: :error
  defp list_op(:as_list, s, nil, type), do: IR.node(:as_list, [s], type)
  defp list_op(:contains, s, a, _type), do: IR.node(:member, [s, a], "boolean")
  defp list_op(:not_contains, s, a, _type), do: negate(IR.node(:member, [s, a], "boolean"))
  defp list_op(:is_contained_by, s, a, _type), do: IR.node(:member, [a, s], "boolean")

  defp list_op(:is_not_contained_by, s, a, _type),
    do: negate(IR.node(:member, [a, s], "boolean"))

  defp list_op(op, s, nil, type) when is_map_key(@list_unary, op),
    do: IR.node(Map.fetch!(@list_unary, op), [s], type)

  defp list_op(op, s, a, type) when is_map_key(@list_binary, op),
    do: IR.node(Map.fetch!(@list_binary, op), [s, a], type)

  defp negate(:error), do: :error
  defp negate(%IR{op: :not, args: [x]}), do: x
  defp negate(ir), do: IR.node(:not, [ir], "boolean")

  defp flatten(op, args) do
    Enum.flat_map(args, fn
      %IR{op: ^op, args: inner} -> inner
      other -> [other]
    end)
  end

  defp combine(ir, parts), do: if(Enum.member?(parts, :error), do: :error, else: ir)

  # --- searches, filters and constraints ----------------------------------------------

  defp search_options(options, path) do
    case Map.keys(options) -- @search_options do
      [] ->
        :ok

      unknown ->
        {:error,
         uncompiled(path, "the search options #{inspect(Enum.sort(unknown))}", :search_option)}
    end
  end

  defp sorted(:error, _options), do: :error

  defp sorted(ir, %{"sort_field" => field} = options) when is_binary(field),
    do: IR.node(:sort, [ir, field, options["descending"] == true], ir.type)

  defp sorted(ir, _options), do: ir

  # The constraints of a search or filter as one predicate over the item
  # (nil when there are none).
  defp constraints(n, item_type, base, ctx) do
    keys = keys(n.meta, :constraint_keys, length(n.constraints))
    ignore = Map.get(n.options, "ignore_empty_constraints", ctx.env.ignore_empty_constraints)

    {preds, diags} =
      n.constraints
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {constraint, i}, acc ->
        {pred, d} = constraint(constraint, item_type, ignore, base ++ [Enum.at(keys, i)], ctx)
        {pred, acc ++ d}
      end)

    cond do
      Enum.member?(preds, :error) -> {:error, diags}
      preds == [] -> {nil, diags}
      match?([_], preds) -> {hd(preds), diags}
      true -> {IR.node(:and, flatten(:and, preds), "boolean"), diags}
    end
  end

  defp constraint(%Constraint{} = con, item_type, ignore, path, ctx) do
    vpath = path ++ [get_in(con.meta, [:keys, :value]) || "value"]

    {value, diags} =
      case con.value do
        nil ->
          {nil, []}

        v ->
          {ir, _p, d} = c(v, vpath, ctx)
          {ir, d}
      end

    item = IR.node(:this, [:filter_item], item_type)

    case {value, predicate(con, item, value, ctx.env)} do
      {:error, _} ->
        {:error, diags}

      {_, :error} ->
        {:error, diags ++ [uncompiled(path, "the constraint #{inspect(con.op)}", :constraint)]}

      {_, {:ok, pred}} ->
        empty_guard(pred, value, ignore, path, diags)
    end
  end

  defp predicate(
         %Constraint{key: "_advanced_search_constraint", value: %{type: "boolean"}},
         _i,
         v,
         _e
       ),
       do: {:ok, v}

  defp predicate(%Constraint{key: key, op: op}, item, value, env) when is_binary(key) do
    with {:ok, f} <- Typing.field(env, item.type, key),
         {:data_type, id} <- owner(item.type) do
      lhs = IR.node(:field, [item, id, key], f.type)
      constraint_op(op || if(key == "_id", do: :equals), lhs, value)
    else
      _ -> :error
    end
  end

  defp predicate(_con, _item, _value, _env), do: :error

  defp constraint_op(op, lhs, v) when is_map_key(@compare, op) and not is_nil(v),
    do: {:ok, IR.node(Map.fetch!(@compare, op), [lhs, v], "boolean")}

  defp constraint_op(:is_empty, lhs, _v), do: {:ok, IR.node(:is_empty, [lhs], "boolean")}
  defp constraint_op(:is_not_empty, lhs, _v), do: {:ok, negate(check(:is_empty, lhs))}
  defp constraint_op(_op, _lhs, nil), do: :error
  defp constraint_op(:in, lhs, v), do: {:ok, IR.node(:member, [v, lhs], "boolean")}
  defp constraint_op(:not_in, lhs, v), do: {:ok, negate(IR.node(:member, [v, lhs], "boolean"))}
  defp constraint_op(:contains, lhs, v), do: {:ok, IR.node(:member, [lhs, v], "boolean")}

  defp constraint_op(:not_contains, lhs, v),
    do: {:ok, negate(IR.node(:member, [lhs, v], "boolean"))}

  defp constraint_op(:text_contains_string, lhs, v),
    do: {:ok, IR.node(:text_contains, [lhs, v], "boolean")}

  defp constraint_op(:text_contains, lhs, v),
    do: {:ok, IR.node(:text_contains_words, [lhs, v], "boolean")}

  defp constraint_op(:not_text_contains, lhs, v),
    do: {:ok, negate(IR.node(:text_contains_words, [lhs, v], "boolean"))}

  defp constraint_op(_op, _lhs, _v), do: :error

  # Bubble can ignore a constraint whose value is empty. That only matters
  # when the value can be empty; then the search must say which it does.
  defp empty_guard(pred, value, ignore, path, diags) do
    cond do
      value == nil or not nullable?(value) or ignore == false ->
        {pred, diags}

      ignore == true ->
        {IR.node(:or, [IR.node(:is_empty, [value], "boolean"), pred], "boolean"), diags}

      true ->
        reason =
          "a constraint whose value may be empty, in a search that does not state ignore_empty_constraints"

        {:error, diags ++ [uncompiled(path, reason, :ignore_empty_constraints)]}
    end
  end

  defp nullable?(%IR{op: op}) when op in [:literal, :option, :all_options, :this], do: false

  defp nullable?(%IR{type: "boolean", op: op}) when op not in [:field, :input, :fallback],
    do: false

  defp nullable?(_), do: true

  # --- helpers ---------------------------------------------------------------------------

  # Expressions name an option by its stored key (`db_value`, e.g.
  # "archived"); a value without one is keyed by its Bubble ID.
  defp option_key(%Model{} = model, set, value) do
    with %OptionSet{values: values} <- Model.option_set(model, set),
         %ModelOptionValue{key: key} <-
           Enum.find(values, &(&1.key == value)) || Enum.find(values, &(&1.id == value)) do
      key
    else
      _ -> nil
    end
  end

  defp option_key(_model, _set, _value), do: nil

  defp strip_option("option." <> set), do: set
  defp strip_option(set), do: set

  defp item_type("list." <> type), do: type
  defp item_type(type), do: type

  defp link(%{meta: meta}), do: Map.get(meta, :link) || "next"
  defp key(%{meta: meta}, name), do: get_in(meta, [:keys, name]) || Atom.to_string(name)

  defp keys(meta, name, count) do
    case Map.get(meta, name) do
      keys when is_list(keys) -> keys
      _ -> Enum.to_list(0..max(count - 1, 0))
    end
  end

  defp uncompiled(path, what, construct) do
    Diagnostic.new(:expr_uncompiled, path, "#{what} has no stack-neutral IR",
      details: %{construct: construct}
    )
  end
end
