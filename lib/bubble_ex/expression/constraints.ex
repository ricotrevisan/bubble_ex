defmodule BubbleEx.Expression.Constraints do
  @moduledoc false

  # `Do a search for` sources and `:filtered` operators: both carry an ordered
  # constraint collection in their properties. Settings other than constraints
  # (and the searched type) are sort/ignore-empty options, kept verbatim.

  alias BubbleEx.AppTree.Expr.Explanation
  alias BubbleEx.Diagnostic
  alias BubbleEx.Expression.{Keys, Parser, Vocabulary}
  alias BubbleEx.Expression.Ast.{Constraint, Filter, Search}

  @spec search(map(), list(), Parser.ctx()) :: Parser.result()
  def search(raw, path, ctx) do
    {used, extra} = Keys.split(raw, [:type, :properties])

    with {pkey, props} when is_map(props) <- Keys.get(raw, :properties),
         {prop_keys, options} = Keys.split(props, [:constraints, :type_to_find]),
         data_type = Keys.value(props, :type_to_find),
         true <- is_binary(data_type) or is_nil(data_type),
         item_ctx = %{ctx | this_type: data_type, this_binder: :filter_item},
         {:ok, constraints, meta, diags} <- collection(props, path ++ [pkey], item_ctx) do
      node = %Search{
        data_type: data_type,
        constraints: constraints,
        options: options,
        type: data_type && "list." <> data_type,
        meta: Map.merge(meta, %{keys: used, extra: extra, prop_keys: prop_keys})
      }

      {node, Parser.extra_diags(extra, path) ++ diags}
    else
      _ -> Parser.raw(raw, :unexpected_shape, path, "malformed search properties")
    end
  end

  @spec filter(map(), list(), term(), map(), Parser.ctx()) ::
          {:ok, Filter.t(), [Diagnostic.t()]} | {:raw, atom(), String.t()}
  def filter(props, path, subject, meta, ctx) do
    {prop_keys, options} = Keys.split(props, [:constraints])

    case collection(props, path, ctx) do
      {:ok, constraints, cmeta, diags} ->
        node = %Filter{
          subject: subject,
          constraints: constraints,
          options: options,
          type: subject.type,
          meta: meta |> Map.merge(cmeta) |> Map.put(:prop_keys, prop_keys)
        }

        {:ok, node, diags}

      :error ->
        {:raw, :unexpected_shape, "malformed filter constraints"}
    end
  end

  defp collection(props, path, ctx),
    do: ordered_constraints(Keys.get(props, :constraints), path, ctx)

  defp ordered_constraints(nil, _path, _ctx), do: {:ok, [], %{constraint_keys: nil}, []}

  defp ordered_constraints({ckey, entries}, path, ctx) do
    with {:ok, ordered} <- Explanation.ordered(entries),
         true <- Enum.all?(ordered, fn {_, c} -> is_map(c) end) do
      {constraints, diags} = constraints(ordered, path ++ [ckey], ctx)
      keys = if is_list(entries), do: :list, else: Enum.map(ordered, &elem(&1, 0))
      {:ok, constraints, %{constraint_keys: keys}, diags}
    else
      _ -> :error
    end
  end

  defp constraints(ordered, path, ctx) do
    Enum.map_reduce(ordered, [], fn {k, c}, acc ->
      {node, more} = constraint(c, path ++ [k], ctx)
      {node, acc ++ more}
    end)
  end

  defp constraint(raw, path, ctx) do
    {used, extra} = Keys.split(raw, [:key, :constraint_type, :value])
    op_source = Keys.value(raw, :constraint_type)
    {op, op_diags} = op(op_source, path ++ [Map.get(used, :constraint_type, "constraint_type")])

    {value, value_diags} =
      case Keys.get(raw, :value) do
        nil -> {nil, []}
        {vkey, value} -> Parser.parse(value, path ++ [vkey], ctx)
      end

    node = %Constraint{
      key: Keys.value(raw, :key),
      op: op,
      value: value,
      meta: %{keys: used, extra: extra, op_source: op_source}
    }

    {node, Parser.extra_diags(extra, path) ++ op_diags ++ value_diags}
  end

  # Bubble stores an Empty node, not a string, when a constraint has no
  # operator (advanced constraints, `_id` lookups).
  defp op(name, path) when is_binary(name) do
    case Vocabulary.constraint_op(name) do
      nil ->
        {name,
         [Diagnostic.new(:unknown_constraint, path, "unmodeled constraint #{inspect(name)}")]}

      op ->
        {op, []}
    end
  end

  defp op(empty, path) when is_map(empty) do
    case Keys.value(empty, :type) do
      "Empty" -> {nil, []}
      _ -> {nil, [Diagnostic.new(:unknown_constraint, path, "unmodeled constraint operator")]}
    end
  end

  defp op(nil, _path), do: {nil, []}

  defp op(_, path),
    do: {nil, [Diagnostic.new(:unknown_constraint, path, "unmodeled constraint operator")]}
end
