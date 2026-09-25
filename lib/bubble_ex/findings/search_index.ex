defmodule BubbleEx.Findings.SearchIndex do
  @moduledoc false

  # `:search_index` (category `:hint`) - one finding per data type listing
  # the indexes its `Do a search for` expressions need, as access patterns
  # (the target adapter picks physical index types):
  #
  #   | operator                                      | access        |
  #   |-----------------------------------------------|---------------|
  #   | equals, in, email equals                      | `:equality`   |
  #   | greater/less than (or equal)                  | `:range`      |
  #   | sort field                                    | `:sort`       |
  #   | contains (list field)                         | `:membership` |
  #   | text contains (Bubble's keyword search)       | `:full_text`  |
  #   | text contains string (substring)              | `:substring`  |
  #   | geographic search / geographic address field  | `:geo`        |
  #
  # Each search contributes one ordered index: its equality columns (sorted
  # by field ID), then its first range column or else its sort column.
  # Membership, text and geographic accesses are single-column indexes.
  # Negative operators, emptiness tests and `unique id` (the primary key)
  # contribute nothing, nor does `:filtered` (it runs in memory).
  #
  # Single-column indexes that targets create anyway or that rarely help are
  # dropped: equality on a reference (foreign keys are indexed by default),
  # equality on a yes/no field, and a sort on Created Date alone. They stay
  # as columns of wider indexes.
  #
  # Confidence: high when some index serves two or more searches, else
  # medium.

  alias BubbleEx.{Finding, Index}
  alias BubbleEx.Expression.Ast
  alias BubbleEx.Findings.Context
  alias BubbleEx.Index.{Symbol, Types}
  alias BubbleEx.Model.Type

  @access %{
    equals: :equality,
    in: :equality,
    email_equals: :equality,
    greater_than: :range,
    less_than: :range,
    greater_or_equal: :range,
    less_or_equal: :range,
    text_contains: :full_text,
    text_contains_string: :substring
  }

  @spec run(Context.t()) :: [Finding.t()]
  def run(ctx) do
    ctx.index.references
    |> Enum.filter(&(&1.kind == :reads_field and &1.attrs[:via] in [:constraint, :sort]))
    |> Enum.group_by(&{&1.from, &1.path})
    |> Enum.sort()
    |> Enum.flat_map(fn {_, [ref | _] = refs} -> searches(ctx, ref, refs) end)
    |> Enum.group_by(& &1.type)
    |> Enum.sort()
    |> Enum.flat_map(fn {type, indexes} -> finding(ctx, type, indexes) end)
  end

  # The indexes each search in the expression a reference was made from
  # needs: `%{type, columns, operators, search, refs}`.
  defp searches(ctx, ref, refs) do
    case Context.expression_at(ctx, ref) do
      nil ->
        []

      ast ->
        ast
        |> Context.nodes()
        |> Enum.filter(&match?(%Ast.Search{}, &1))
        |> Enum.with_index()
        |> Enum.flat_map(fn {search, n} ->
          search_indexes(ctx, search, {ref.from, ref.path, n}, refs)
        end)
    end
  end

  defp search_indexes(ctx, search, id, refs) do
    case Types.data_type_key(search.data_type) do
      nil -> []
      type -> indexes(ctx, type, search, id, refs)
    end
  end

  defp indexes(ctx, type, search, id, refs) do
    uses =
      for {key, access, op} <- uses(ctx, type, search),
          field = Symbol.id(:field, [type, key]),
          live?(ctx, type, field),
          do: %{field: field, access: access, op: op}

    equality = uses |> Enum.filter(&(&1.access == :equality)) |> Enum.uniq_by(& &1.field)
    trailing = Enum.find(uses, &(&1.access == :range)) || Enum.find(uses, &(&1.access == :sort))
    ordered = Enum.sort_by(equality, & &1.field) ++ List.wrap(trailing)
    singles = for u <- uses, u.access in [:membership, :full_text, :substring, :geo], do: [u]

    for cols <- [ordered | singles],
        cols != [],
        keep?(ctx, cols),
        fields = Enum.map(cols, & &1.field),
        do: %{
          type: type,
          columns: Enum.map(cols, &%{field: &1.field, access: &1.access}),
          operators: Enum.map(cols, & &1.op),
          search: id,
          refs: Enum.filter(refs, &(&1.to in fields))
        }
  end

  defp uses(ctx, type, search) do
    constraints =
      for %Ast.Constraint{key: key, op: op} <- search.constraints,
          is_binary(key) and key not in ["_id", "_advanced_search_constraint"],
          access = access(ctx, type, key, op),
          access != nil,
          do: {key, access, op}

    sort =
      case search.options do
        %{"sort_field" => key} when is_binary(key) and key != "_id" ->
          if String.starts_with?(key, "_dynamic"), do: [], else: [{key, :sort, :sort}]

        _ ->
          []
      end

    constraints ++ sort
  end

  defp access(ctx, type, key, op) do
    value_type = value_type(ctx, Symbol.id(:field, [type, key]))

    cond do
      op == "geographic_search" -> :geo
      value_type == "geographic_address" and op in [:equals, :in] -> :geo
      op == :contains and Type.list?(value_type) -> :membership
      true -> Map.get(@access, op)
    end
  end

  defp value_type(ctx, field_id) do
    case Index.symbol(ctx.index, field_id) do
      %{attrs: %{value_type: vt}} -> vt
      _ -> nil
    end
  end

  defp live?(ctx, type, field_id),
    do: Enum.any?(Context.fields(ctx, type), &(&1.id == field_id))

  defp keep?(ctx, [%{access: :equality, field: field}]) do
    Context.target(ctx, field) == nil and value_type(ctx, field) != "boolean"
  end

  defp keep?(ctx, [%{access: :sort, field: field}]),
    do: not match?(%{attrs: %{builtin: :created_date}}, Index.symbol(ctx.index, field))

  defp keep?(_ctx, _cols), do: true

  defp finding(ctx, type, uses) do
    indexes =
      uses
      |> Enum.group_by(& &1.columns)
      |> Enum.map(fn {columns, group} ->
        %{
          columns: columns,
          operators:
            group |> Enum.flat_map(& &1.operators) |> Enum.uniq() |> Enum.sort_by(&to_string/1),
          searches: group |> Enum.map(& &1.search) |> Enum.uniq() |> length()
        }
      end)
      |> Enum.sort_by(&{-&1.searches, Enum.map(&1.columns, fn c -> {c.field, c.access} end)})

    if indexes == [], do: [], else: [build(ctx, type, uses, indexes)]
  end

  defp build(ctx, type, uses, indexes) do
    hosts = Enum.map(uses, fn %{search: {host, _, _}} -> host end)
    searches = uses |> Enum.map(& &1.search) |> Enum.uniq() |> length()
    top = indexes |> Enum.map(& &1.searches) |> Enum.max()
    type_id = "data_type:" <> type

    {confidence, reason} =
      if top > 1,
        do: {:high, "an index serves #{top} searches"},
        else: {:medium, "each index serves one search"}

    Finding.new(:search_index, %{type: type},
      path: ctx.index |> Index.symbol(type_id) |> Map.fetch!(:path),
      evidence: %{
        symbols:
          [type_id | Enum.flat_map(indexes, fn i -> Enum.map(i.columns, & &1.field) end)] ++ hosts,
        references: Enum.flat_map(uses, & &1.refs),
        searches: searches
      },
      proposal: %{transform: :add_indexes, type: type_id, indexes: indexes},
      confidence: confidence,
      confidence_reason: reason,
      affects: Context.affects(ctx, hosts, []),
      message:
        "#{searches} search(es) on “#{Context.name(ctx, type_id)}” need #{length(indexes)} index(es)"
    )
  end
end
