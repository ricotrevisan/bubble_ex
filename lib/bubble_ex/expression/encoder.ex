defmodule BubbleEx.Expression.Encoder do
  @moduledoc false

  # AST -> Bubble JSON. Re-emits the key spelling and editor metadata recorded
  # in `meta`, so parsing then encoding reproduces the source's canonical JSON.
  # Nodes built without `meta` are written with readable keys.

  alias BubbleEx.Expression.{Keys, Vocabulary}

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

  @doc """
  Checks that every operator applies to a subject that encodes to an object:
  Bubble chains operators through the subject's `next` link, so an operator
  on a literal (or on a raw non-object) cannot be represented.
  """
  @spec validate(struct()) :: :ok | {:error, String.t()}
  def validate(node) do
    case unencodable(node) do
      nil ->
        :ok

      %module{} ->
        {:error, "#{inspect(module)} applies to a subject that is not an expression object"}
    end
  end

  defp unencodable(%_{} = node) do
    subject = chain_subject(node)

    if subject && not chainable?(subject),
      do: node,
      else: node |> children() |> Enum.find_value(&unencodable/1)
  end

  defp chain_subject(%module{left: left}) when module in [Compare, Logical, Arithmetic], do: left
  defp chain_subject(%Raw{subject: subject}), do: subject
  defp chain_subject(%{subject: subject}), do: subject
  defp chain_subject(_), do: nil

  defp chainable?(%Literal{}), do: false
  defp chainable?(%Raw{raw: raw}), do: is_map(raw)
  defp chainable?(_), do: true

  defp children(node) do
    node
    |> Map.from_struct()
    |> Map.drop([:meta, :raw, :ref, :options])
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&is_struct/1)
  end

  @spec encode(struct()) :: term()
  def encode(%Literal{value: value}), do: value
  def encode(%Raw{subject: nil, raw: raw}), do: raw
  def encode(%CurrentUser{meta: m}), do: object(m, type: "CurrentUser")
  def encode(%ThisThing{meta: m}), do: object(m, type: "InjectedValue")
  def encode(%Empty{meta: m}), do: object(m, type: "Empty")

  def encode(%Scope{source_type: type, ref: ref, meta: m}) do
    props =
      if ref == %{} and not Map.has_key?(keys(m), :properties), do: [], else: [properties: ref]

    object(m, [type: type] ++ props)
  end

  def encode(%OptionValue{option_set: set, value: value, meta: m}) do
    type = m[:source_type] || "OneOptionValue"
    props = Map.merge(m[:extra_props] || %{}, %{"option_set" => set, "option_value" => value})
    object(m, type: type, properties: props)
  end

  def encode(%AllOptions{option_set: set, meta: m}) do
    props = Map.put(m[:extra_props] || %{}, "option_set", set)
    object(m, type: "AllOptionValue", properties: props)
  end

  def encode(%DynamicText{parts: parts, meta: m}) do
    encoded = Enum.map(parts, fn p -> if is_binary(p), do: p, else: encode(p) end)

    entries =
      case m[:entry_keys] do
        :list ->
          encoded

        keys when is_list(keys) and length(keys) == length(parts) ->
          Map.new(Enum.zip(keys, encoded))

        _ ->
          encoded |> Enum.with_index() |> Map.new(fn {p, i} -> {Integer.to_string(i), p} end)
      end

    if m[:entry_keys] == :absent and parts == [],
      do: object(m, type: "TextExpression"),
      else: object(m, type: "TextExpression", entries: entries)
  end

  def encode(%ArbitraryText{text: text, meta: m}),
    do: object(m, type: "ArbitraryText", properties: %{"arbitrary_text" => encode(text)})

  def encode(%Search{data_type: data_type, constraints: cs, options: options, meta: m}) do
    props =
      options
      |> put(m[:prop_keys], :type_to_find, data_type, not is_nil(data_type))
      |> put(
        m[:prop_keys],
        :constraints,
        constraints(cs, m),
        m[:constraint_keys] != nil or cs != []
      )

    object(m, type: "Search", properties: props)
  end

  # --- chain operators: encode the subject, then append this message --------

  def encode(%Compare{op: op, left: l, right: r, meta: m}), do: binary(:compare, op, l, r, m)
  def encode(%Logical{op: op, left: l, right: r, meta: m}), do: binary(:logical, op, l, r, m)

  def encode(%Arithmetic{op: op, left: l, right: r, meta: m}),
    do: binary(:arithmetic, op, l, r, m)

  def encode(%Check{op: op, subject: s, meta: m}),
    do: message(s, m, name: Vocabulary.operator_name(:check, op))

  def encode(%Field{field: field, subject: s, meta: m}), do: message(s, m, name: field)
  def encode(%Property{name: name, subject: s, meta: m}), do: message(s, m, name: name)

  def encode(%Fallback{subject: s, fallback: f, meta: m}),
    do: message(s, m, name: "defaulting_to", args: encode(f))

  def encode(%ListOp{op: op, subject: s, arg: arg, options: options, meta: m}) do
    name = [name: Vocabulary.operator_name(:list, op)]
    arg = if arg, do: [args: encode(arg)], else: []

    props =
      if options != %{} or Map.has_key?(keys(m), :properties), do: [properties: options], else: []

    message(s, m, name ++ arg ++ props)
  end

  def encode(%Filter{subject: s, constraints: cs, options: options, meta: m}) do
    props =
      put(
        options,
        m[:prop_keys],
        :constraints,
        constraints(cs, m),
        m[:constraint_keys] != nil or cs != []
      )

    message(s, m, name: "filtered", properties: props)
  end

  def encode(%Raw{subject: s, raw: raw, meta: m}), do: attach(encode(s), raw, link(m, encode(s)))

  defp binary(class, op, left, right, m),
    do: message(left, m, name: Vocabulary.operator_name(class, op), args: encode(right))

  defp message(subject, m, fields) do
    base = encode(subject)
    attach(base, object(m, [type: "Message"] ++ fields), link(m, base))
  end

  # Appends `msg` at the end of `base`'s `next` chain.
  defp attach(base, msg, link) when is_map(base) do
    case Keys.get(base, :next) do
      {key, next} -> Map.put(base, key, attach(next, msg, link))
      nil -> Map.put(base, link, msg)
    end
  end

  defp attach(base, _msg, _link), do: base

  defp link(%{link: link}, _base), do: link
  defp link(_, base) when is_map(base), do: if(Map.has_key?(base, "%x"), do: "%n", else: "next")
  defp link(_, _), do: "next"

  defp constraints(cs, m) do
    encoded = Enum.map(cs, &constraint/1)

    case m[:constraint_keys] do
      :list -> encoded
      keys when is_list(keys) and length(keys) == length(cs) -> Map.new(Enum.zip(keys, encoded))
      _ -> encoded |> Enum.with_index() |> Map.new(fn {c, i} -> {Integer.to_string(i), c} end)
    end
  end

  defp constraint(%Constraint{key: key, op: op, value: value, meta: m}) do
    op_source =
      case Map.fetch(m, :op_source) do
        {:ok, source} -> source
        :error when is_atom(op) and not is_nil(op) -> Vocabulary.constraint_name(op)
        :error -> op || %{"type" => "Empty"}
      end

    fields =
      [key: key, constraint_type: op_source] ++
        if(value == nil, do: [], else: [value: encode(value)])

    fields
    |> Enum.reject(fn {logical, v} -> v == nil and not Map.has_key?(keys(m), logical) end)
    |> then(&object(m, &1))
  end

  defp put(map, used, logical, value, true),
    do: Map.put(map, Keys.key(used || %{}, logical), value)

  defp put(map, _used, _logical, _value, false), do: map

  # Builds an object with the recorded spelling for each logical key, merged
  # over the preserved uninterpreted members.
  defp object(m, fields) do
    used = keys(m)

    Enum.reduce(fields, m[:extra] || %{}, fn {logical, v}, acc ->
      Map.put(acc, Keys.key(used, logical), v)
    end)
  end

  defp keys(m), do: m[:keys] || %{}
end
