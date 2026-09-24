defmodule BubbleEx.Expression.Parser do
  @moduledoc false

  # Bubble JSON -> AST. A node is a source object whose `next` link starts a
  # chain of `Message` operators; each operator wraps everything to its left.
  # Returns `{ast, diagnostics}` and never raises on JSON input: anything
  # outside the vocabulary becomes a `Raw` node plus a diagnostic.

  alias BubbleEx.AppTree.Expr.Explanation
  alias BubbleEx.Expression.{Ast, Constraints, Diagnostic, Keys, Schema, Vocabulary}

  alias BubbleEx.Expression.Ast.{
    AllOptions,
    ArbitraryText,
    Arithmetic,
    Check,
    Compare,
    CurrentUser,
    DynamicText,
    Empty,
    Fallback,
    Field,
    ListOp,
    Literal,
    Logical,
    OptionValue,
    Property,
    Raw,
    Scope,
    ThisThing
  }

  @node_keys [:type, :properties, :next, :name, :args, :entries]

  @type ctx :: %{schema: Schema.t(), this_type: String.t() | nil}
  @type result :: {Ast.t(), [Diagnostic.t()]}

  @spec parse(term(), list(), ctx()) :: result()
  def parse(raw, _path, _ctx)
      when is_binary(raw) or is_number(raw) or is_boolean(raw) or is_nil(raw),
      do: {%Literal{value: raw, type: literal_type(raw)}, []}

  def parse(raw, path, ctx) when is_map(raw) do
    case Keys.collisions(raw, @node_keys) do
      [] ->
        {next, base} = pop_next(raw)
        {source, diags} = source(Keys.value(base, :type), base, path, ctx)
        continue(next, path, source, diags, ctx)

      keys ->
        raw(raw, :alias_collision, path, "keys spelled both ways: #{inspect(keys)}")
    end
  end

  def parse(raw, path, _ctx), do: raw(raw, :malformed_node, path, "not an expression object")

  # --- sources ----------------------------------------------------------------

  defp source("CurrentUser", raw, path, _), do: simple(%CurrentUser{}, raw, path)

  defp source("InjectedValue", raw, path, ctx),
    do: simple(%ThisThing{type: ctx.this_type}, raw, path)

  defp source("Empty", raw, path, _), do: simple(%Empty{}, raw, path)
  defp source("TextExpression", raw, path, ctx), do: text(raw, path, ctx)
  defp source("Search", raw, path, ctx), do: Constraints.search(raw, path, ctx)

  defp source(type, raw, path, _) when type in ["OneOptionValue", "OptionValue"] do
    with_props(raw, path, ~w(option_set option_value), fn props, meta ->
      %{"option_set" => set, "option_value" => value} = props

      if is_binary(set) and is_binary(value),
        do: %OptionValue{
          option_set: set,
          value: value,
          type: set,
          meta: Map.put(meta, :source_type, type)
        }
    end)
  end

  defp source("AllOptionValue", raw, path, _) do
    with_props(raw, path, ~w(option_set), fn
      %{"option_set" => set}, meta when is_binary(set) ->
        %AllOptions{option_set: set, type: "list." <> set, meta: meta}

      _, _ ->
        nil
    end)
  end

  defp source("ArbitraryText", raw, path, ctx) do
    case {Keys.split(raw, [:type, :properties]), Keys.get(raw, :properties)} do
      {{used, extra}, {pkey, %{"arbitrary_text" => text} = props}} when map_size(props) == 1 ->
        {inner, diags} = parse(text, path ++ [pkey, "arbitrary_text"], ctx)
        node = %ArbitraryText{text: inner, meta: %{keys: used, extra: extra}}
        {node, extra_diags(extra, path) ++ diags}

      _ ->
        shape(raw, path, "ArbitraryText needs exactly an arbitrary_text property")
    end
  end

  defp source(type, raw, path, _) when is_binary(type) do
    case Vocabulary.scope(type) do
      nil -> raw(raw, :unknown_source, path, "unmodeled source #{inspect(type)}")
      kind -> scope(kind, type, raw, path)
    end
  end

  defp source(_, raw, path, _), do: raw(raw, :malformed_node, path, "missing source type")

  defp scope(kind, type, raw, path) do
    {used, extra} = Keys.split(raw, [:type, :properties])

    case Keys.value(raw, :properties) do
      ref when is_map(ref) or is_nil(ref) ->
        ref = ref || %{}
        btype = if is_binary(ref["btype_id"]), do: ref["btype_id"]
        node = %Scope{kind: kind, source_type: type, ref: ref, type: btype}
        {%{node | meta: %{keys: used, extra: extra}}, extra_diags(extra, path)}

      _ ->
        shape(raw, path, "#{type} properties must be an object")
    end
  end

  defp simple(node, raw, path) do
    {used, extra} = Keys.split(raw, [:type])
    {%{node | meta: %{keys: used, extra: extra}}, extra_diags(extra, path)}
  end

  # Source with a properties object whose members are exactly `names` (extra
  # members are kept and diagnosed). `build` returns nil on a bad shape.
  defp with_props(raw, path, names, build) do
    {used, extra} = Keys.split(raw, [:type, :properties])

    with {pkey, props} when is_map(props) <- Keys.get(raw, :properties),
         true <- Enum.all?(names, &Map.has_key?(props, &1)),
         {known, extra_props} = Map.split(props, names),
         meta = %{keys: used, extra: extra, extra_props: extra_props},
         node when not is_nil(node) <- build.(known, meta) do
      {node, extra_diags(extra, path) ++ extra_diags(extra_props, path ++ [pkey])}
    else
      _ -> shape(raw, path, "expected properties #{Enum.join(names, ", ")}")
    end
  end

  defp text(raw, path, ctx) do
    {used, extra} = Keys.split(raw, [:type, :entries])

    with {ekey, entries} <- Keys.get(raw, :entries) || {nil, :absent},
         {:ok, ordered} <- ordered_entries(entries) do
      {parts, diags} =
        Enum.map_reduce(ordered, [], fn {k, part}, acc ->
          {node, more} = entry(part, path ++ [ekey, k], ctx)
          {node, acc ++ more}
        end)

      keys =
        cond do
          entries == :absent -> :absent
          is_list(entries) -> :list
          true -> Enum.map(ordered, &elem(&1, 0))
        end

      meta = %{keys: used, extra: extra, entry_keys: keys}
      {%DynamicText{parts: parts, meta: meta}, extra_diags(extra, path) ++ diags}
    else
      :error -> raw(raw, :unresolved_order, path, "text entries have no unambiguous order")
    end
  end

  # Bubble omits `entries` for an empty text.
  defp ordered_entries(:absent), do: {:ok, []}
  defp ordered_entries(entries), do: Explanation.ordered(entries)

  defp entry(part, _path, _ctx) when is_binary(part), do: {part, []}
  defp entry(part, path, ctx), do: parse(part, path, ctx)

  # --- operator chains -------------------------------------------------------

  defp continue(nil, _path, node, diags, _ctx), do: {node, diags}

  defp continue({key, msg}, path, subject, diags, ctx) do
    {node, more} = chain(msg, path ++ [key], subject, key, ctx)
    {node, diags ++ more}
  end

  defp chain(msg, path, subject, link, ctx) do
    with true <- is_map(msg),
         [] <- Keys.collisions(msg, @node_keys),
         "Message" <- Keys.value(msg, :type),
         name when is_binary(name) <- Keys.value(msg, :name) do
      {next, base} = pop_next(msg)
      {node, diags} = message(Vocabulary.operator(name), name, base, path, subject, link, ctx)
      continue(next, path, node, diags, ctx)
    else
      _ ->
        {next, base} = if is_map(msg), do: pop_next(msg), else: {nil, msg}

        code =
          if is_map(msg) and Keys.collisions(msg, @node_keys) != [],
            do: :alias_collision,
            else: :malformed_node

        node = %Raw{raw: base, reason: code, subject: subject, meta: %{link: link}}
        continue(next, path, node, [Diagnostic.new(code, path, "not an operator message")], ctx)
    end
  end

  defp message(op, name, raw, path, subject, link, ctx) do
    {used, extra} = Keys.split(raw, [:type, :name, :args, :properties])
    meta = %{keys: used, extra: extra, link: link}
    args = Keys.get(raw, :args)
    props = Keys.value(raw, :properties)

    case operand_node(op, name, args, props, path, subject, meta, ctx) do
      {:ok, node, diags} ->
        {node, extra_diags(extra, path) ++ diags}

      {:raw, code, message} ->
        {%Raw{raw: raw, reason: code, subject: subject, meta: %{link: link}},
         [Diagnostic.new(code, path, message)]}
    end
  end

  defp operand_node({class, op}, _, {key, arg}, nil, path, subject, meta, ctx)
       when class in [:compare, :logical, :arithmetic] do
    {right, diags} = parse(arg, path ++ [key], ctx)
    {:ok, binary(class, op, subject, right, meta), diags}
  end

  defp operand_node({:check, op}, _, nil, nil, _, subject, meta, _),
    do: {:ok, %Check{op: op, subject: subject, meta: meta}, []}

  defp operand_node({:list, op, :none}, _, nil, nil, _, subject, meta, _),
    do: {:ok, %ListOp{op: op, subject: subject, type: list_type(op, subject), meta: meta}, []}

  defp operand_node({:list, op, :arg}, _, {key, arg}, nil, path, subject, meta, ctx) do
    {operand, diags} = parse(arg, path ++ [key], ctx)
    node = %ListOp{op: op, subject: subject, arg: operand, meta: meta}
    {:ok, %{node | type: list_type(op, subject)}, diags}
  end

  defp operand_node({:list, :sorted, :options}, _, nil, props, _, subject, meta, _)
       when is_map(props),
       do:
         {:ok,
          %ListOp{op: :sorted, subject: subject, options: props, type: subject.type, meta: meta},
          []}

  defp operand_node(:filtered, _, nil, props, path, subject, meta, ctx) when is_map(props) do
    item_type = item_type(subject.type)

    Constraints.filter(props, path ++ [meta.keys.properties], subject, meta, %{
      ctx
      | this_type: item_type
    })
  end

  defp operand_node(:fallback, _, {key, arg}, nil, path, subject, meta, ctx) do
    {fallback, diags} = parse(arg, path ++ [key], ctx)
    {:ok, %Fallback{subject: subject, fallback: fallback, type: subject.type, meta: meta}, diags}
  end

  defp operand_node(nil, name, nil, nil, path, subject, meta, ctx),
    do: accessor(name, path, subject, meta, ctx)

  defp operand_node(nil, name, _, _, _, _, _, _),
    do: {:raw, :unknown_operator, "unmodeled operator #{inspect(name)}"}

  defp operand_node(_, name, _, _, _, _, _, _),
    do: {:raw, :unexpected_shape, "operator #{inspect(name)} has unexpected operands"}

  defp binary(:compare, op, left, right, meta),
    do: %Compare{op: op, left: left, right: right, meta: meta}

  defp binary(:logical, op, left, right, meta),
    do: %Logical{op: op, left: left, right: right, meta: meta}

  defp binary(:arithmetic, op, left, right, meta),
    do: %Arithmetic{op: op, left: left, right: right, type: left.type, meta: meta}

  # A bare message is a field access when the schema (or Bubble's built-in
  # fields) confirms it; otherwise a diagnosed Property.
  defp accessor(name, path, subject, meta, ctx) do
    builtin = Vocabulary.builtin_field(name)
    field = &%Field{subject: subject, field: name, display: &1, type: &2, meta: meta}

    case {Schema.field(ctx.schema, subject.type, name), builtin} do
      {{:ok, f}, _} ->
        {:ok, %{field.(f.display, f.value) | builtin: builtin && elem(builtin, 0)}, []}

      {_, {kind, type}} ->
        {:ok, %{field.(name, type) | builtin: kind}, []}

      {:error, nil} ->
        {:ok, %Property{subject: subject, name: name, meta: meta},
         [
           Diagnostic.new(
             :unresolved_field,
             path,
             "#{subject.type} has no field #{inspect(name)}"
           )
         ]}

      {:unknown_type, nil} ->
        {:ok, %Property{subject: subject, name: name, meta: meta},
         [
           Diagnostic.new(
             :unresolved_property,
             path,
             "#{inspect(name)} on a subject of unknown type"
           )
         ]}
    end
  end

  @predicates [:contains, :not_contains, :contains_list, :is_contained_by, :is_not_contained_by]
  defp list_type(op, _) when op in @predicates, do: "boolean"
  defp list_type(:count, _), do: "number"
  defp list_type(:as_list, %{type: "list." <> _ = type}), do: type
  defp list_type(:as_list, %{type: type}) when is_binary(type), do: "list." <> type

  defp list_type(op, subject) when op in [:first_item, :last_item, :item_number],
    do: item_type(subject.type)

  defp list_type(_, subject), do: subject.type

  defp item_type("list." <> type), do: type
  defp item_type(type), do: type

  # --- helpers ----------------------------------------------------------------

  defp pop_next(map) do
    case Keys.get(map, :next) do
      nil -> {nil, map}
      {key, _} = next -> {next, Map.delete(map, key)}
    end
  end

  @spec extra_diags(map(), list()) :: [Diagnostic.t()]
  def extra_diags(extra, path) do
    for {key, _} <- Enum.sort(extra),
        not Vocabulary.metadata_key?(key),
        do:
          Diagnostic.new(:uninterpreted_field, path ++ [key], "unexpected member #{inspect(key)}")
  end

  defp shape(raw, path, message), do: raw(raw, :unexpected_shape, path, message)

  @spec raw(term(), atom(), list(), String.t()) :: result()
  def raw(raw, code, path, message),
    do: {%Raw{raw: raw, reason: code}, [Diagnostic.new(code, path, message)]}

  defp literal_type(value) when is_boolean(value), do: "boolean"
  defp literal_type(value) when is_number(value), do: "number"
  defp literal_type(value) when is_binary(value), do: "text"
  defp literal_type(nil), do: nil
end
