defmodule BubbleEx.Verify.Interpreter.Eval do
  @moduledoc """
  Evaluates a privacy-rule condition, compiled to `BubbleEx.Expression.IR`,
  for one user and one record of a `BubbleEx.Verify.Interpreter.Dataset`.

  The semantics are the ones `BubbleEx.Target.Ash.Expressions` compiles
  (so that, with the default assumptions, the interpreter predicts the
  generated policies), stated over Bubble values instead of SQL:

    * negation is pushed down to the atomic conditions (De Morgan), and a
      condition is evaluated for a polarity: `holds(ir, false)` is "the
      negation of `ir` holds", which is not always `not holds(ir, true)`
    * an atom reading an empty value from the current user is false in
      either polarity (`actor_empty_denies`); a logged-out user is empty
    * records compare by key; a field of an empty or dangling reference is
      empty; `x is y` with one side empty is false, `x is not y` true;
      both empty is `empty_equals_empty`
    * ordering with an empty side is false in either polarity
    * `list contains x` is false for an empty list or item; its negation
      holds for an empty record-side list (`empty_list_contains_nothing`)
      or an empty record-side item
    * a yes/no value used as a condition holds when it is yes; its
      negation when it is not yes (empty is not yes); `x is no` on an
      empty yes/no is `empty_yes_no_is_no`
    * `is empty` is nil, `""` or an empty list; a dangling reference is
      `dangling_ref_is_empty`

  Every function returns the flags of `BubbleEx.Verify.Interpreter.Assumptions`
  it consulted (read at a point where the flag decides), so a verdict can
  say which assumptions it rests on.

  Unsupported constructs throw `{:unsupported, what}` (callers check
  `supported/1` first); reading an unset field of an open record throws
  `{:need, key, field}` (matrix synthesis chooses a value and retries).
  """

  alias BubbleEx.Expression.IR
  alias BubbleEx.Model
  alias BubbleEx.Model.Type
  alias BubbleEx.Verify.Interpreter.Dataset

  @type ctx :: %{
          required(:ds) => Dataset.t(),
          required(:user) => String.t() | nil,
          required(:this) => String.t() | nil,
          required(:flags) => map(),
          required(:model) => Model.t()
        }
  @type flags :: [atom()]

  # Stored yes/no values (not predicates): empty is neither yes nor no.
  @boolean_values [:field, :input, :fallback, :option_attribute, :option_label, :external_field]
  @compare [:gt, :lt, :gte, :lte]
  @arithmetic [:add, :sub, :mul, :div]
  @predicates [:and, :or, :not, :eq, :neq, :is_empty, :logged_in, :member, :text_contains] ++
                @compare
  @values [:literal, :empty, :option, :all_options, :current_user, :this, :field, :count, :first] ++
            [:last, :fallback] ++ @arithmetic

  @doc """
  Whether the interpreter evaluates every construct of `ir`: `:ok`, or
  `{:error, what}` naming the first construct it does not.
  """
  @spec supported(IR.t()) :: :ok | {:error, String.t()}
  def supported(%IR{op: :this, args: [binder]}) when binder != :rule_record,
    do: {:error, "This Thing as #{binder}"}

  def supported(%IR{op: :option, args: [set, _value, nil]}),
    do: {:error, "an option of #{set} with no stored key"}

  def supported(%IR{op: :member, args: [list, _]} = ir) do
    if many?(list.type),
      do: children(ir),
      else: {:error, "contains on a value that is not a list"}
  end

  def supported(%IR{op: op} = ir) when op in @predicates or op in @values, do: children(ir)
  def supported(%IR{op: op}), do: {:error, "#{op}"}

  defp children(%IR{args: args}) do
    Enum.find_value(args, :ok, fn
      %IR{} = child -> error_or_nil(supported(child))
      _ -> nil
    end)
  end

  defp error_or_nil(:ok), do: nil
  defp error_or_nil(error), do: error

  # --- conditions --------------------------------------------------------------

  @doc "Whether `ir` holds (`positive`) or its negation holds, and the flags consulted."
  @spec holds(IR.t(), boolean(), ctx()) :: {boolean(), flags()}
  def holds(%IR{op: op, args: args}, positive, ctx) when op in [:and, :or] do
    # `and` (or the negation of `or`) needs every part; otherwise any.
    all? = op == :and == positive

    Enum.reduce_while(args, {all?, []}, fn arg, {_, flags} ->
      {b, more} = holds(arg, positive, ctx)
      acc = {b, flags ++ more}
      if b == all?, do: {:cont, acc}, else: {:halt, acc}
    end)
  end

  def holds(%IR{op: :not, args: [x]}, positive, ctx), do: holds(x, not positive, ctx)

  def holds(%IR{op: :literal, args: [b]}, positive, _ctx) when is_boolean(b),
    do: {b == positive, []}

  def holds(%IR{op: op, args: [l, r]} = ir, positive, ctx) when op in [:eq, :neq] do
    cond do
      match?(%IR{op: :empty}, l) -> holds(empty_check(op, r), positive, ctx)
      match?(%IR{op: :empty}, r) -> holds(empty_check(op, l), positive, ctx)
      condition_is_literal?(l, r) -> holds(r, literal_polarity(op, l, positive), ctx)
      condition_is_literal?(r, l) -> holds(l, literal_polarity(op, r, positive), ctx)
      boolean_equality?(l, r) -> boolean_equality(op, l, r, positive, ctx)
      true -> atom(ir, positive, ctx)
    end
  end

  def holds(ir, positive, ctx), do: atom(ir, positive, ctx)

  defp empty_check(:eq, x), do: IR.node(:is_empty, [x], "boolean")
  defp empty_check(:neq, x), do: IR.node(:not, [IR.node(:is_empty, [x], "boolean")], "boolean")

  defp condition_is_literal?(%IR{op: :literal, args: [b]}, other) when is_boolean(b),
    do: condition?(other)

  defp condition_is_literal?(_, _), do: false

  defp literal_polarity(op, %IR{args: [b]}, positive), do: op == :eq == b == positive

  defp condition?(%IR{op: op, type: "boolean"}), do: op not in @boolean_values and op != :literal
  defp condition?(_), do: false

  defp boolean_equality?(l, r),
    do: (condition?(l) or condition?(r)) and (reads_actor?(l) or reads_actor?(r))

  # `a is b` between yes/no values, one a condition reading the user: each
  # side keeps its own guards.
  defp boolean_equality(op, l, r, positive, ctx) do
    {lp, f1} = side(l, true, ctx)
    {ln, f2} = side(l, false, ctx)
    {rp, f3} = side(r, true, ctx)
    {rn, f4} = side(r, false, ctx)
    flags = f1 ++ f2 ++ f3 ++ f4

    if op == :eq == positive,
      do: {(lp and rp) or (ln and rn), flags},
      else: {(lp and rn) or (ln and rp), flags}
  end

  defp side(ir, pol, ctx) do
    if condition?(ir),
      do: holds(ir, pol, ctx),
      else: atom(IR.node(:eq, [ir, IR.node(:literal, [pol], "boolean")], "boolean"), true, ctx)
  end

  # --- atoms ----------------------------------------------------------------------

  defp atom(%IR{op: :logged_in}, positive, ctx), do: {is_nil(ctx.user) != positive, []}

  defp atom(%IR{op: :is_empty, args: [x]}, positive, ctx) do
    guarded(reads_actor?(x) and is_nil(ctx.user), ctx, fn ->
      {empty, flags} = empty?(x, value(x, ctx), ctx)
      {empty == positive, flags}
    end)
  end

  defp atom(%IR{op: op, args: [l, r]}, positive, ctx) when op in [:eq, :neq] do
    {a, b, flags} = operands([l, r], ctx)

    guarded(actor_empty?([{l, a}, {r, b}]), ctx, fn ->
      {equal, more} = equal(a, b, ctx)
      {equal == (op == :eq) == positive, flags ++ more}
    end)
  end

  defp atom(%IR{op: op, args: [l, r]}, positive, ctx) when op in @compare do
    {a, b, flags} = operands([l, r], ctx)

    guarded(actor_empty?([{l, a}, {r, b}]), ctx, fn ->
      case compare(op, a, b) do
        nil -> {false, flags}
        result -> {result == positive, flags}
      end
    end)
  end

  defp atom(%IR{op: :member, args: [list, item]}, positive, ctx) do
    lv = value(list, ctx)
    iv = value(item, ctx)

    guarded(actor_empty?([{list, lv}, {item, iv}]), ctx, fn ->
      found = not is_nil(iv) and iv in items(lv)

      cond do
        positive -> {not is_nil(lv) and found, []}
        is_nil(lv) -> {ctx.flags.empty_list_contains_nothing, [:empty_list_contains_nothing]}
        is_nil(iv) and not nonnull?(item) and not actor?(item) -> {true, []}
        true -> {not found, []}
      end
    end)
  end

  defp atom(%IR{op: :text_contains, args: [text, part]}, positive, ctx) do
    tv = value(text, ctx)
    pv = value(part, ctx)

    guarded(actor_empty?([{text, tv}, {part, pv}]), ctx, fn ->
      case {tv, pv} do
        {{:text, t}, {:text, p}} -> {String.contains?(t, p) == positive, []}
        {nil, _} -> {not positive, []}
        _ -> {false, []}
      end
    end)
  end

  defp atom(%IR{op: op} = ir, positive, ctx) when op in @boolean_values do
    {v, flags} = stored_boolean(ir, value(ir, ctx), ctx)

    guarded(actor_empty?([{ir, v}]), ctx, fn ->
      {v == {:boolean, true} == positive, flags}
    end)
  end

  defp atom(%IR{op: op}, _positive, _ctx), do: throw({:unsupported, "the condition #{op}"})

  # The fail-safe guard: an atom reading an empty value from the user is
  # false in either polarity.
  defp guarded(false, _ctx, fun), do: fun.()

  defp guarded(true, ctx, fun) do
    if ctx.flags.actor_empty_denies do
      {false, [:actor_empty_denies]}
    else
      {b, flags} = fun.()
      {b, [:actor_empty_denies | flags]}
    end
  end

  defp actor_empty?(operands), do: Enum.any?(operands, fn {ir, v} -> actor?(ir) and blank?(v) end)

  defp operands([l, r], ctx) do
    {a, f1} = stored_boolean(l, value(l, ctx), ctx)
    {b, f2} = stored_boolean(r, value(r, ctx), ctx)
    {a, b, f1 ++ f2}
  end

  # An empty stored yes/no, under `empty_yes_no_is_no`, reads as no.
  defp stored_boolean(%IR{op: op, type: "boolean"}, nil, ctx) when op in @boolean_values do
    if ctx.flags.empty_yes_no_is_no,
      do: {{:boolean, false}, [:empty_yes_no_is_no]},
      else: {nil, [:empty_yes_no_is_no]}
  end

  defp stored_boolean(_ir, v, _ctx), do: {v, []}

  defp equal(nil, nil, ctx), do: {ctx.flags.empty_equals_empty, [:empty_equals_empty]}
  defp equal(nil, _, _ctx), do: {false, []}
  defp equal(_, nil, _ctx), do: {false, []}
  defp equal(a, b, _ctx), do: {a == b, []}

  defp compare(_op, nil, _), do: nil
  defp compare(_op, _, nil), do: nil

  defp compare(op, {tag, a}, {tag, b}) when tag in [:number, :date, :text] do
    case op do
      :gt -> a > b
      :lt -> a < b
      :gte -> a >= b
      :lte -> a <= b
    end
  end

  defp compare(op, _, _), do: throw({:unsupported, "#{op} between values of different types"})

  defp empty?(%IR{} = x, {:ref, key} = _v, ctx) do
    if ref_one?(x.type) and is_nil(Dataset.fetch(ctx.ds, key)),
      do: {ctx.flags.dangling_ref_is_empty, [:dangling_ref_is_empty]},
      else: {false, []}
  end

  defp empty?(_x, v, _ctx), do: {blank?(v), []}

  defp blank?(v), do: v in [nil, {:text, ""}, {:list, []}]

  # --- values ---------------------------------------------------------------------

  @doc "The value of `ir` (a canonical `BubbleEx.Verify.Value`, or nil when empty)."
  @spec value(IR.t(), ctx()) :: BubbleEx.Verify.Value.t()
  def value(%IR{op: :literal, args: [v]}, _ctx), do: literal(v)
  def value(%IR{op: :empty}, _ctx), do: nil
  def value(%IR{op: :option, args: [_set, _value, key]}, _ctx), do: {:option, key}

  def value(%IR{op: :all_options, args: [set]}, ctx) do
    case Model.option_set(ctx.model, set) do
      %{values: values} ->
        list(for v <- values, not v.deleted, is_binary(v.key), do: {:option, v.key})

      nil ->
        nil
    end
  end

  def value(%IR{op: :current_user}, ctx), do: ctx.user && {:ref, ctx.user}
  def value(%IR{op: :this}, ctx), do: ctx.this && {:ref, ctx.this}

  def value(%IR{op: :field, args: [base, _type, field]}, ctx),
    do: base |> value(ctx) |> read(field, ctx)

  def value(%IR{op: :count, args: [l]}, ctx), do: {:number, length(items(value(l, ctx))) / 1}
  def value(%IR{op: :first, args: [l]}, ctx), do: l |> value(ctx) |> items() |> List.first()
  def value(%IR{op: :last, args: [l]}, ctx), do: l |> value(ctx) |> items() |> List.last()

  def value(%IR{op: :fallback, args: [x, d]}, ctx) do
    v = value(x, ctx)
    if blank?(v), do: value(d, ctx), else: v
  end

  def value(%IR{op: op, args: [l, r]}, ctx) when op in @arithmetic,
    do: arithmetic(op, value(l, ctx), value(r, ctx))

  def value(%IR{op: op} = ir, ctx) when op in @predicates do
    {b, _flags} = holds(ir, true, ctx)
    {:boolean, b}
  end

  def value(%IR{op: op}, _ctx), do: throw({:unsupported, "#{op}"})

  defp literal(v) when is_binary(v), do: {:text, v}
  defp literal(v) when is_number(v), do: {:number, v / 1}
  defp literal(v) when is_boolean(v), do: {:boolean, v}
  defp literal(nil), do: nil
  defp literal(v), do: throw({:unsupported, "the literal #{inspect(v)}"})

  defp arithmetic(_op, nil, _), do: nil
  defp arithmetic(_op, _, nil), do: nil
  defp arithmetic(:add, {:number, a}, {:number, b}), do: {:number, a + b}
  defp arithmetic(:sub, {:number, a}, {:number, b}), do: {:number, a - b}
  defp arithmetic(:mul, {:number, a}, {:number, b}), do: {:number, a * b}
  defp arithmetic(:div, {:number, _}, {:number, b}) when b == 0, do: nil
  defp arithmetic(:div, {:number, a}, {:number, b}), do: {:number, a / b}
  defp arithmetic(op, _, _), do: throw({:unsupported, "#{op} on values that are not numbers"})

  # A field of a record (by key), of every record of a list, or of nothing.
  defp read(nil, _field, _ctx), do: nil

  defp read({:ref, key}, field, ctx) do
    case Dataset.fetch(ctx.ds, key) do
      nil ->
        nil

      _record when field == "_id" ->
        {:text, key}

      %{open: true, fields: fields} when not is_map_key(fields, field) ->
        throw({:need, key, field})

      %{fields: fields} ->
        Map.get(fields, field)
    end
  end

  defp read({:list, items}, field, ctx) do
    items
    |> Enum.map(&read(&1, field, ctx))
    |> Enum.flat_map(fn
      nil -> []
      {:list, vs} -> vs
      v -> [v]
    end)
    |> list()
  end

  defp read(other, _field, _ctx), do: throw({:unsupported, "a field of #{inspect(other)}"})

  defp list([]), do: nil
  defp list(items), do: {:list, items}

  defp items(nil), do: []
  defp items({:list, items}), do: items
  defp items(v), do: [v]

  # --- shape --------------------------------------------------------------------------

  @doc "Whether `ir` reads the current user anywhere."
  @spec reads_actor?(term()) :: boolean()
  def reads_actor?(%IR{op: op}) when op in [:current_user, :logged_in], do: true
  def reads_actor?(%IR{args: args}), do: Enum.any?(args, &reads_actor?/1)
  def reads_actor?(list) when is_list(list), do: Enum.any?(list, &reads_actor?/1)
  def reads_actor?(_), do: false

  @doc "Whether `ir` is read from the current user (the user or a field chain of it)."
  @spec actor?(IR.t()) :: boolean()
  def actor?(%IR{op: :current_user}), do: true
  def actor?(%IR{op: :field, args: [base | _]}), do: actor?(base)
  def actor?(_), do: false

  defp nonnull?(%IR{op: :literal, args: [v]}), do: not is_nil(v)
  defp nonnull?(%IR{op: :option}), do: true
  defp nonnull?(%IR{op: :this}), do: true
  defp nonnull?(_), do: false

  @doc """
  The outermost field chains of `ir` read from the rule's record (`This
  Thing's a's b`), without source paths.
  """
  @spec record_values(term()) :: [IR.t()]
  def record_values(%IR{op: :field, args: [base | _]} = ir) do
    if record_based?(base), do: [IR.strip_paths(ir)], else: []
  end

  def record_values(%IR{args: args}), do: Enum.flat_map(args, &record_values/1)
  def record_values(list) when is_list(list), do: Enum.flat_map(list, &record_values/1)
  def record_values(_), do: []

  defp record_based?(%IR{op: :this}), do: true
  defp record_based?(%IR{op: :field, args: [base | _]}), do: record_based?(base)
  defp record_based?(_), do: false

  @doc "Whether a record value is empty, as `is empty` tests it (with the flags consulted)."
  @spec value_empty?(IR.t(), ctx()) :: {boolean(), flags()}
  def value_empty?(ir, ctx), do: empty?(ir, value(ir, ctx), ctx)

  defp many?(type), do: match?(%Type{cardinality: :many}, classify(type))
  defp ref_one?(type), do: match?(%Type{kind: :ref, cardinality: :one}, classify(type))

  defp classify(type) when is_binary(type), do: type |> Type.classify() |> elem(0)
  defp classify(_), do: nil
end
