defmodule BubbleEx.Findings.IdInText do
  @moduledoc false

  # `:id_in_text` - a text (or list of texts) field that holds Bubble unique
  # IDs: a write sets it from a record's `unique id`, or an expression
  # compares it with one (`unique id = F` / `F = unique id` search
  # constraints, `=`/`≠` comparisons, `F contains unique id`). It is a
  # reference stored as text; making it a reference gives it a type and lets
  # the database check it. Only unique IDs of a data type the app defines
  # count; IDs whose type is unknown may belong to an external system and
  # are not flagged.
  #
  # Confidence: high when writes show one target type; medium when only
  # comparisons do; low when several target types appear.

  alias BubbleEx.{Finding, Index}
  alias BubbleEx.Expression.Ast
  alias BubbleEx.Findings.{Context, Values}
  alias BubbleEx.Index.Types

  @id "_id"

  @spec run(Context.t()) :: [Finding.t()]
  def run(ctx) do
    for field <- Context.all_fields(ctx),
        not Map.has_key?(field.attrs, :builtin),
        field.attrs[:value_type] in ["text", "list.text"],
        finding <- analyze(ctx, field),
        do: finding
  end

  defp analyze(ctx, field) do
    type = Context.type_of_field(field)

    written =
      for w <- Index.writers(ctx.index, field.id),
          {ast, reads} <- [Context.write_value(ctx, w)],
          {:read, %{keys: keys} = chain} <- [Values.describe(ast, reads)],
          List.last(keys) == @id,
          app_type?(ctx, chain.owner),
          do: {w, chain.owner}

    compared =
      for r <- Index.readers(ctx.index, field.id),
          ast = Context.expression_at(ctx, r),
          ast != nil,
          target <- comparisons(ast, type, field.bubble_id),
          app_type?(ctx, target),
          uniq: true,
          do: {r, target}

    if written == [] and compared == [],
      do: [],
      else: [finding(ctx, field, type, written, compared)]
  end

  # Only unique IDs of a data type the app defines count: an ID of unknown
  # origin may be an external system's ID.
  defp app_type?(_ctx, nil), do: false
  defp app_type?(ctx, type), do: Index.symbol(ctx.index, "data_type:" <> type) != nil

  # Target types (nil when unknown) of the unique IDs `key` is compared with.
  defp comparisons(ast, type, key) do
    Enum.flat_map(Context.nodes(ast), fn
      %Ast.Search{data_type: data_type, constraints: constraints} ->
        searched = Types.data_type_key(data_type)
        Enum.flat_map(constraints, &constraint(&1, searched, type, key))

      %Ast.Compare{op: op, left: l, right: r} when op in [:equals, :not_equals] ->
        pair(l, r, type, key) ++ pair(r, l, type, key)

      %Ast.ListOp{op: op, subject: list, arg: item} when op in [:contains, :not_contains] ->
        pair(list, item, type, key)

      _ ->
        []
    end)
  end

  defp constraint(%Ast.Constraint{key: @id, op: op, value: v}, searched, type, key)
       when op in [:equals, :in, :not_equals, :not_in] do
    if ends_in?(v, type, key), do: [searched], else: []
  end

  defp constraint(%Ast.Constraint{key: key, op: op, value: v}, type, type, key)
       when op in [:equals, :in, :contains, :not_equals, :not_in, :not_contains] do
    case chain(v) do
      %{keys: keys, owner: owner} -> if List.last(keys) == @id, do: [owner], else: []
      nil -> []
    end
  end

  defp constraint(_, _, _, _), do: []

  defp pair(field_side, id_side, type, key) do
    with true <- ends_in?(field_side, type, key),
         %{keys: keys} = chain <- chain(id_side),
         @id <- List.last(keys) do
      [chain.owner]
    else
      _ -> []
    end
  end

  defp ends_in?(node, type, key) do
    case chain(node) do
      %{keys: keys, owner: owner} -> List.last(keys) == key and owner in [type, nil]
      nil -> false
    end
  end

  defp chain(nil), do: nil
  defp chain(node), do: Values.chain(unwrap(node), [])

  defp unwrap(%Ast.DynamicText{parts: [part]}) when is_struct(part), do: unwrap(part)
  defp unwrap(%Ast.ArbitraryText{text: text}), do: unwrap(text)
  defp unwrap(node), do: node

  defp finding(ctx, field, type, written, compared) do
    written_targets = written |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    compared_targets = compared |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    known =
      (written_targets ++ compared_targets)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    {confidence, reason} =
      cond do
        length(known) > 1 ->
          {:low, "unique IDs of #{length(known)} different types appear"}

        written != [] ->
          {:high, "written from the unique ID of one data type"}

        true ->
          {:medium, "compared with unique IDs of one data type"}
      end

    target = if match?([_], known), do: "data_type:" <> hd(known)
    readers = Enum.map(compared, fn {r, _} -> r.from end)
    maintainers = Enum.map(written, fn {w, _} -> w.from end)
    refs = Enum.map(written, &elem(&1, 0)) ++ Enum.map(compared, &elem(&1, 0))

    Finding.new(:id_in_text, %{type: type, field: field.bubble_id},
      path: field.path,
      evidence: %{
        symbols: [field.id | Enum.map(known, &("data_type:" <> &1))],
        references: refs,
        written_from_id: length(written),
        compared_with_id: compared |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length(),
        target_types: Enum.map(known, &("data_type:" <> &1))
      },
      proposal: %{
        transform: :text_to_reference,
        field: field.id,
        target_type: target,
        cardinality: if(field.attrs.value_type == "list.text", do: :many, else: :one)
      },
      confidence: confidence,
      confidence_reason: reason,
      affects: Context.affects(ctx, readers, maintainers),
      message:
        "“#{Context.name(ctx, field.id)}” on “#{Context.name(ctx, "data_type:" <> type)}” stores unique IDs" <>
          if(target, do: " of “#{Context.name(ctx, target)}”", else: "") <>
          " as text; make it a reference"
    )
  end
end
