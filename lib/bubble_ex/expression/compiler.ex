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
  (a dynamic or geographic sort), elements used as values
  without a state, and constraints whose value may be empty where what
  Bubble does with them is not known.

  ## Empty constraint values

  What a constraint whose value is empty does depends on where its search
  runs (`Env.searches`), as replayed against Bubble (2026-10-01):

  | where | `ignore_empty_constraints` unstated or false | `true` |
  |-------|----------------------------------------------|--------|
  | `:page` (a page's data, elements and workflows) | matches nothing, even a record whose field is empty | dropped |
  | `:backend` (a backend workflow, or a page workflow's server-side action) | matches nothing | matches nothing (no effect) |

  "Matches nothing" is `not is_empty(value) and constraint`; "dropped" is
  `is_empty(value) or constraint`. Only `equals` was replayed. A page
  workflow's server-side action takes the backend rule
  (`Sites.action_env/2`), stricter than Bubble on purpose: Bubble drops
  the constraint there with `true` (replay 2026-10-07), so a delete with
  an empty input would reach every record. Either is a filter of the same
  search, read for the actor like any other, so privacy rules still
  apply. The Current User itself is never empty: Bubble's logged-out
  visitor is a temporary user (`logged_out_user_is_empty` is refuted), so
  `X = Current User` is not dropped for them. A page's `:filtered` follows
  the page rule (replay 2026-10-07: unstated or false matches nothing,
  `true` drops). Where `Env.searches` is nil (a privacy condition), and
  for any other `:filtered`, the search's own option or
  `Env.ignore_empty_constraints` decides: `true` drops, `false` compares,
  and nil leaves the constraint uncompiled.

  ## Sorts

  A search's, `:filtered`'s or `:sorted`'s sort is `:sort` over the list;
  `:sorted` on a list of texts, numbers or dates (no sort field) is
  `:sort` with a nil field;
  Bubble's further sort keys (`additional_sort_fields`) are nested sorts,
  the primary key outermost (a sort keeps the order of what it sorts
  among equal keys). The editor's display names (`*_friendly`) and unset
  settings (an `Empty` dynamic sort field or geographic reference) are
  ignored; a dynamic or geographic sort has no IR. An option value of
  `"all values"` is the editor's `All <option set>` (`:all_options`).
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
  @search_options ~w(sort_field descending ignore_empty_constraints additional_sort_fields)
  # The lists `:sorted` sorts by their values (no sort field).
  @value_lists ~w(list.text list.number list.date)

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

  # Lowers a node and stamps the IR with the node's source pointer, so a
  # target can point its diagnostics at the part it cannot compile.
  defp c(node, base, ctx) do
    {ir, path, diags} = lower(node, base, ctx)
    {stamp(ir, path), path, diags}
  end

  defp stamp(%IR{path: nil} = ir, path), do: %{ir | path: Diagnostic.pointer(path)}
  defp stamp(ir, _path), do: ir

  # --- sources ---------------------------------------------------------------------

  # Each clause returns `{ir | :error, own source path, diagnostics}`.
  defp lower(%Literal{value: nil}, base, _ctx), do: {IR.node(:empty), base, []}
  defp lower(%Literal{value: v, type: t}, base, _ctx), do: {IR.node(:literal, [v], t), base, []}
  defp lower(%Empty{}, base, _ctx), do: {IR.node(:empty), base, []}
  defp lower(%CurrentUser{}, base, _ctx), do: {IR.node(:current_user, [], "user"), base, []}
  defp lower(%ThisThing{binder: b, type: t}, base, _ctx), do: {IR.node(:this, [b], t), base, []}

  # The editor's "All <option set>" (an option value of "all values"),
  # unless the set has an option stored as that.
  defp lower(
         %OptionValue{option_set: set, value: "all values", type: "list." <> _} = n,
         base,
         ctx
       ) do
    case option_key(ctx.env.model, strip_option(set), n.value) do
      nil -> {IR.node(:all_options, [strip_option(set)], n.type), base, []}
      _ -> lower(%{n | type: set}, base, ctx)
    end
  end

  defp lower(%OptionValue{option_set: set, value: value, type: type}, base, ctx) do
    set_id = strip_option(set)

    {key, diags} =
      case option_key(ctx.env.model, set_id, value) do
        {:key, key} -> {key, []}
        {:id, key} -> {key, [option_by_id(base, set_id, value, key)]}
        nil -> {nil, []}
      end

    {IR.node(:option, [set_id, value, key], type), base, diags}
  end

  defp lower(%AllOptions{option_set: set, type: type}, base, _ctx),
    do: {IR.node(:all_options, [strip_option(set)], type), base, []}

  defp lower(%Scope{} = n, base, ctx) do
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

  defp lower(%DynamicText{parts: parts} = n, base, ctx) do
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

  defp lower(%ArbitraryText{text: text} = n, base, ctx) do
    {ir, _p, diags} = c(text, base ++ [key(n, :properties), "arbitrary_text"], ctx)
    {ir, base, diags}
  end

  defp lower(%Search{} = n, base, ctx) do
    pbase = base ++ [key(n, :properties)]
    item = %{ctx | this_type: n.data_type, this_binder: :filter_item}

    with {:ok, type_id} <- data_type_id(n.data_type),
         {:ok, sorts} <- search_options(n.options, pbase) do
      cbase = pbase ++ [n.meta[:prop_keys][:constraints] || "constraints"]
      {pred, diags} = constraints(n, n.data_type, cbase, item)
      search = combine(IR.node(:search, [type_id, pred], n.type), [pred])
      {sorted(search, sorts), base, diags}
    else
      {:error, diag} -> {:error, base, [diag]}
      :error -> {:error, base, [uncompiled(pbase, "a search of an unknown data type", :search)]}
    end
  end

  defp lower(%Raw{subject: nil} = n, base, _ctx),
    do: {:error, base, [uncompiled(base, "a raw source (#{n.reason})", :raw)]}

  defp lower(%Raw{subject: subject, raw: raw} = n, base, ctx) do
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

  defp lower(%Field{} = n, base, ctx) do
    {subject, spath, diags} = c(n.subject, base, ctx)
    path = spath ++ [link(n)]

    case {subject, field_node(subject, n, ctx.env)} do
      {:error, _} -> {:error, path, diags}
      {_, {:ok, ir}} -> {ir, path, diags}
      {_, :error} -> {:error, path, diags ++ [uncompiled(path, "an unresolved field", :field)]}
    end
  end

  defp lower(%Property{type: nil} = n, base, ctx) do
    # Untyped: typing reported it.
    {_ir, spath, diags} = operand(n.subject, base, ctx)
    {:error, spath ++ [link(n)], diags}
  end

  defp lower(%Property{subject: %Scope{} = scope, name: name, type: type} = n, base, ctx) do
    case Typing.context(scope, ctx.env) do
      {:element, %{id: id}} ->
        input = IR.node(:input, [:element_state, %{"element" => id, "state" => name}], type)
        {input, base ++ [link(n)], []}

      _ ->
        property_operator(n, base, ctx)
    end
  end

  defp lower(%Property{} = n, base, ctx), do: property_operator(n, base, ctx)

  defp lower(%Compare{op: op} = n, base, ctx) do
    binary(n, base, ctx, fn l, r -> IR.node(Map.fetch!(@compare, op), [l, r], "boolean") end)
  end

  defp lower(%Logical{op: op} = n, base, ctx),
    do: binary(n, base, ctx, fn l, r -> IR.node(op, flatten(op, [l, r]), "boolean") end)

  defp lower(%Arithmetic{op: op} = n, base, ctx),
    do: binary(n, base, ctx, fn l, r -> IR.node(Map.fetch!(@arithmetic, op), [l, r], n.type) end)

  defp lower(%Check{op: op} = n, base, ctx) do
    {subject, spath, diags} = c(n.subject, base, ctx)
    path = spath ++ [link(n)]
    {check(op, subject), path, diags}
  end

  defp lower(%ListOp{op: :sorted} = n, base, ctx) do
    {subject, spath, diags} = c(n.subject, base, ctx)
    path = spath ++ [link(n)]

    case search_options(n.options, path ++ [key(n, :properties)]) do
      {:ok, []} ->
        case sorted_values(subject, settings(n.options)) do
          :error when subject != :error ->
            {:error, path,
             diags ++ [unknown_options(path ++ [key(n, :properties)], ["descending"])]}

          ir ->
            {ir, path, diags}
        end

      {:ok, sorts} ->
        {sorted(subject, sorts), path, diags}

      {:error, diag} ->
        {:error, path, diags ++ [diag]}
    end
  end

  defp lower(%ListOp{} = n, base, ctx) do
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

  defp lower(%Filter{} = n, base, ctx) do
    {subject, spath, diags} = c(n.subject, base, ctx)
    path = spath ++ [link(n)]
    pbase = path ++ [key(n, :properties)]
    item_type = item_type(n.subject.type)
    item = %{ctx | this_type: item_type, this_binder: :filter_item}

    case search_options(n.options, pbase) do
      {:ok, sorts} ->
        cbase = pbase ++ [n.meta[:prop_keys][:constraints] || "constraints"]
        {pred, more} = constraints(n, item_type, cbase, item)
        ir = combine(IR.node(:filter, [subject, pred], n.type), [subject, pred])
        {sorted(ir, sorts), path, diags ++ more}

      {:error, diag} ->
        {:error, path, diags ++ [diag]}
    end
  end

  defp lower(%Fallback{} = n, base, ctx) do
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
        {combine(IR.node(:format_date, [subject, nil, nil], type), [subject]), path, diags}

      _ when name == "format_number" ->
        {combine(IR.node(:format_number, [subject, %{}], type), [subject]), path, diags}

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

  # `formatted as` a date: a named format is its own pattern (`mmm d,
  # yyyy`), `custom` reads `custom_format`, no format is Bubble's default
  # (nil). The time zone follows it (see `zone/5`).
  defp raw_operator("format_date", raw, subject, path, ctx) do
    props = raw |> Keys.value(:properties) |> format_props()

    format =
      case props["formatting_type"] do
        "custom" -> props["custom_format"]
        other -> other
      end

    with true <- is_nil(format) or is_binary(format),
         {:ok, zone, diags} <- zone(raw, props, ~w(tz_type tz_static tz_dynamic), path, ctx) do
      {:ok, IR.node(:format_date, [subject, format, zone], "text"), diags}
    else
      _ -> :unknown
    end
  end

  # Options are Bubble's settings with readable keys; a setting that is
  # itself an expression is not compiled.
  defp raw_operator("format_number", raw, subject, _path, _ctx) do
    props = raw |> Keys.value(:properties) |> format_props()

    if Enum.all?(props, fn {_, v} -> not is_map(v) and not is_list(v) end),
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

  defp raw_operator(name, raw, subject, path, ctx)
       when name in ["rounded_down", "extract_from_date"] do
    props = raw |> Keys.value(:properties) |> format_props()
    unit = props["component_to_extract"]

    {op, type, zone_keys} =
      if name == "rounded_down",
        do:
          {:date_floor, "date", ~w(tz_type_overridden tz_static_overridden tz_dynamic_overridden)},
        else: {:date_part, "number", ~w(tz_type tz_static tz_dynamic)}

    with true <- is_binary(unit),
         {:ok, zone, diags} <- zone(raw, props, zone_keys, path, ctx) do
      {:ok, IR.node(op, [subject, unit, zone], type), diags}
    else
      _ -> :unknown
    end
  end

  defp raw_operator(_name, _raw, _subject, _path, _ctx), do: :unknown

  defp format_props(props) when is_map(props), do: Keys.normalize(props)
  defp format_props(_props), do: %{}

  # The time zone a date operator works in: nil for Bubble's default (the
  # user's, which the target decides), a zone name (`static`), or the IR of
  # an expression giving one (`dynamic`).
  defp zone(raw, props, [type_key, static_key, dynamic_key], path, ctx) do
    case props[type_key] do
      type when type in [nil, "browser"] ->
        {:ok, nil, []}

      "static" ->
        if is_binary(props[static_key]), do: {:ok, props[static_key], []}, else: :unknown

      "dynamic" ->
        operand_prop(raw, dynamic_key, path, ctx)

      _ ->
        :unknown
    end
  end

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
          {:option, set} -> {:ok, option_field(subject, set, field, type)}
          {:external, ext} -> {:ok, IR.node(:external_field, [subject, ext, field], type)}
          nil -> :error
        end

      _ ->
        :error
    end
  end

  # An option's label is Bubble's built-in `display`; other names are attributes.
  defp option_field(subject, set, "display", type),
    do: IR.node(:option_label, [subject, set], type)

  defp option_field(subject, set, attr, type),
    do: IR.node(:option_attribute, [subject, set, attr], type)

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

  # The sort keys of a search's, filter's or `:sorted`'s options, the
  # primary one first: `{:ok, [{field, descending?}]}`, or an uncompiled
  # diagnostic for an option with no IR (a dynamic sort field, a
  # geographic sort). The editor's display names (`*_friendly`) and unset
  # settings (an `Empty` dynamic sort field or geographic reference, a
  # dynamic sort field that is an empty text) say nothing.
  defp search_options(options, path) do
    options = settings(options)

    with {:unknown, []} <- {:unknown, Map.keys(options) -- @search_options},
         {:ok, more} <- additional_sorts(options["additional_sort_fields"]) do
      {:ok, primary_sort(options) ++ more}
    else
      {:unknown, unknown} -> {:error, unknown_options(path, unknown)}
      :error -> {:error, unknown_options(path, ["additional_sort_fields"])}
    end
  end

  defp unknown_options(path, keys),
    do: uncompiled(path, "the search options #{inspect(Enum.sort(keys))}", :search_option)

  defp settings(options) when is_map(options) do
    for {k, v} <- options,
        not (is_binary(k) and String.ends_with?(k, "_friendly")),
        not (k in ["dynamic_sort_field", "geo_reference"] and empty_setting?(v)),
        not (k == "dynamic_sort_field" and empty_text?(v)),
        into: %{},
        do: {k, v}
  end

  defp settings(_options), do: %{}

  defp empty_setting?(nil), do: true
  defp empty_setting?(v) when is_map(v), do: Keys.value(v, :type) == "Empty"
  defp empty_setting?(_v), do: false

  # A dynamic sort field that is an empty text (the editor keeps
  # `{"entries": {"1": ""}}` once it is cleared) names no field (WTF-520).
  defp empty_text?(""), do: true

  defp empty_text?(v) when is_map(v),
    do: Keys.value(v, :type) == "TextExpression" and empty_entries?(Keys.value(v, :entries))

  defp empty_text?(_v), do: false

  defp empty_entries?(nil), do: true

  defp empty_entries?(entries) when is_map(entries),
    do: Enum.all?(Map.values(entries), &(&1 == ""))

  defp empty_entries?(entries) when is_list(entries), do: Enum.all?(entries, &(&1 == ""))
  defp empty_entries?(_entries), do: false

  # `{field, descending?}` of the primary sort; `_dynamic_sort_field` names
  # a dynamic one, which has no IR (its options keep `dynamic_sort_field`).
  defp primary_sort(%{"sort_field" => field} = options)
       when is_binary(field) and field not in ["", "_dynamic_sort_field"],
       do: [{field, options["descending"] == true}]

  defp primary_sort(_options), do: []

  # Bubble's further sort keys, in order (`"0"`, `"1"`, …): each a static
  # field with its direction; anything else has no IR.
  defp additional_sorts(nil), do: {:ok, []}

  defp additional_sorts(entries) when is_map(entries) or is_list(entries) do
    ordered =
      if is_map(entries),
        do: entries |> Enum.sort_by(fn {k, _} -> sort_index(k) end) |> Enum.map(&elem(&1, 1)),
        else: entries

    Enum.reduce_while(ordered, {:ok, []}, fn entry, {:ok, acc} ->
      case sort_key(settings(entry)) do
        {:ok, key} -> {:cont, {:ok, acc ++ [key]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp additional_sorts(_entries), do: :error

  defp sort_key(%{"sort_field" => field} = e)
       when is_binary(field) and field not in ["", "_dynamic_sort_field"] do
    if Map.keys(e) -- ["sort_field", "descending"] == [],
      do: {:ok, {field, e["descending"] == true}},
      else: :error
  end

  defp sort_key(_entry), do: :error

  defp sort_index(k) when is_binary(k) do
    case Integer.parse(k) do
      {n, ""} -> {0, n}
      _ -> {1, k}
    end
  end

  defp sort_index(k), do: {1, k}

  # `:sorted` with no sort field: a list of texts, numbers or dates sorts
  # by its values (`descending` a yes/no); any other list keeps its order.
  defp sorted_values(%IR{type: type} = ir, options) when type in @value_lists do
    case options["descending"] do
      desc when desc in [nil, false] -> IR.node(:sort, [ir, nil, false], type)
      true -> IR.node(:sort, [ir, nil, true], type)
      _ -> :error
    end
  end

  defp sorted_values(ir, _options), do: ir

  # A sort by several keys is nested sorts, the primary one outermost: a
  # sort keeps the order of what it sorts among equal keys.
  defp sorted(:error, _sorts), do: :error

  defp sorted(ir, sorts) do
    sorts
    |> Enum.reverse()
    |> Enum.reduce(ir, fn {field, desc}, acc -> IR.node(:sort, [acc, field, desc], ir.type) end)
  end

  # The constraints of a search or filter as one predicate over the item
  # (nil when there are none).
  defp constraints(n, item_type, base, ctx) do
    keys = keys(n.meta, :constraint_keys, length(n.constraints))
    mode = empty_mode(n, ctx.env)

    {preds, diags} =
      n.constraints
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {constraint, i}, acc ->
        {pred, d} = constraint(constraint, item_type, mode, base ++ [Enum.at(keys, i)], ctx)
        {pred, acc ++ d}
      end)

    cond do
      Enum.member?(preds, :error) -> {:error, diags}
      preds == [] -> {nil, diags}
      match?([_], preds) -> {hd(preds), diags}
      true -> {IR.node(:and, flatten(:and, preds), "boolean"), diags}
    end
  end

  defp constraint(%Constraint{} = con, item_type, mode, path, ctx) do
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

      {_, {:ok, pred}} when con.op in [:is_empty, :is_not_empty] ->
        {pred, diags}

      {_, {:ok, pred}} ->
        empty_guard(pred, value, mode, path, diags)
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

  # What a constraint whose value is empty does (see the moduledoc):
  # `:drop`, `:nothing` (matches no record), `:compare` or `:unknown`.
  defp empty_mode(%Search{options: options}, %Env{searches: :page}),
    do: if(options["ignore_empty_constraints"] == true, do: :drop, else: :nothing)

  defp empty_mode(%Search{}, %Env{searches: :backend}), do: :nothing

  # A page's `:filtered`: as a page search (replay 2026-10-07: unstated or
  # false matches nothing, true drops).
  defp empty_mode(%Filter{options: options}, %Env{searches: :page}),
    do: if(options["ignore_empty_constraints"] == true, do: :drop, else: :nothing)

  defp empty_mode(n, env) do
    case Map.get(n.options, "ignore_empty_constraints", env.ignore_empty_constraints) do
      true -> :drop
      false -> :compare
      _ -> :unknown
    end
  end

  # An empty constraint value only matters when the value can be empty.
  defp empty_guard(pred, value, mode, path, diags) do
    cond do
      value == nil or not nullable?(value) or mode == :compare ->
        {pred, diags}

      mode == :drop ->
        {IR.node(:or, [IR.node(:is_empty, [value], "boolean"), pred], "boolean"), diags}

      mode == :nothing ->
        {IR.node(:and, [negate(IR.node(:is_empty, [value], "boolean")), pred], "boolean"), diags}

      true ->
        reason =
          "a constraint whose value may be empty, where what Bubble does with an empty value is not known"

        {:error, diags ++ [uncompiled(path, reason, :ignore_empty_constraints)]}
    end
  end

  # The Current User is never empty: a logged-out visitor is Bubble's
  # temporary user. Its fields can be.
  defp nullable?(%IR{op: op})
       when op in [:literal, :option, :all_options, :this, :current_user],
       do: false

  defp nullable?(%IR{type: "boolean", op: op}) when op not in [:field, :input, :fallback],
    do: false

  defp nullable?(_), do: true

  # --- helpers ---------------------------------------------------------------------------

  # Expressions name an option by its stored key (`db_value`, e.g.
  # "retired"). Naming it by its Bubble ID instead is not verified against
  # Bubble: it is accepted and diagnosed.
  defp option_key(%Model{} = model, set, value) do
    values =
      case Model.option_set(model, set) do
        %OptionSet{values: values} -> values
        nil -> []
      end

    case {Enum.find(values, &(&1.key == value)), Enum.find(values, &(&1.id == value))} do
      {%ModelOptionValue{key: key}, _} -> {:key, key}
      {nil, %ModelOptionValue{key: key}} -> {:id, key}
      _ -> nil
    end
  end

  defp option_key(_model, _set, _value), do: nil

  defp option_by_id(path, set, value, key) do
    Diagnostic.new(
      :expr_option_by_id,
      path,
      "option #{inspect(value)} of #{inspect(set)} is named by its Bubble ID, not its stored key; read as #{inspect(key)}",
      subject: %{option_set: set},
      details: %{value: value, key: key}
    )
  end

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
