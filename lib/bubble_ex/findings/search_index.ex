defmodule BubbleEx.Findings.SearchIndex do
  @moduledoc false

  # `:search_index` - fields that `Do a search for` constrains or sorts on,
  # with the access each operator needs:
  #
  #   | operator                                      | access        | method      |
  #   |-----------------------------------------------|---------------|-------------|
  #   | equals, in, email equals                      | `:equality`   | `:btree`    |
  #   | greater/less than (or equal)                  | `:range`      | `:btree`    |
  #   | sort field                                    | `:sort`       | `:btree`    |
  #   | contains (list field)                         | `:membership` | `:gin`      |
  #   | text contains (Bubble's keyword search)       | `:full_text`  | `:full_text`|
  #   | text contains string (substring)              | `:substring`  | `:trigram`  |
  #   | geographic search / geographic address field  | `:geo`        | `:geo`      |
  #
  # Negative operators (not equal, not in, not contains, …), emptiness tests
  # and `unique id` constraints (already the primary key) propose nothing.
  # `method` names the conventional index method; the target adapter decides
  # what it renders. Only database searches count: `:filtered` runs on a list
  # already in memory. One finding per field lists every method it needs.
  #
  # Confidence: high when two or more searches use the field, medium for one.

  alias BubbleEx.{Finding, Index}
  alias BubbleEx.Expression.Ast
  alias BubbleEx.Findings.Context
  alias BubbleEx.Index.{Symbol, Types}

  @access %{
    equals: {:equality, :btree},
    in: {:equality, :btree},
    email_equals: {:equality, :btree},
    greater_than: {:range, :btree},
    less_than: {:range, :btree},
    greater_or_equal: {:range, :btree},
    less_or_equal: {:range, :btree},
    text_contains: {:full_text, :full_text},
    text_contains_string: {:substring, :trigram}
  }

  @spec run(Context.t()) :: [Finding.t()]
  def run(ctx) do
    ctx.index.references
    |> Enum.filter(&(&1.kind == :reads_field and &1.attrs[:via] in [:constraint, :sort]))
    |> Enum.group_by(&{&1.from, &1.path})
    |> Enum.sort()
    |> Enum.flat_map(fn {{_host, _path}, [ref | _] = refs} -> uses(ctx, ref, refs) end)
    |> Enum.group_by(& &1.field)
    |> Enum.sort()
    |> Enum.flat_map(fn {field_id, uses} -> finding(ctx, field_id, uses) end)
  end

  # Every indexable use in the search expression a reference was made from.
  defp uses(ctx, ref, refs) do
    case Context.expression_at(ctx, ref) do
      nil ->
        []

      ast ->
        for %Ast.Search{} = search <- Context.nodes(ast),
            type = Types.data_type_key(search.data_type),
            type != nil,
            {key, access, operator} <- accesses(ctx, type, search),
            field = Symbol.id(:field, [type, key]),
            refs = Enum.filter(refs, &(&1.to == field)),
            refs != [],
            do: %{
              field: field,
              access: access,
              operator: operator,
              host: ref.from,
              path: ref.path,
              refs: refs
            }
    end
  end

  defp accesses(ctx, type, search) do
    constraints =
      for %Ast.Constraint{key: key, op: op} <- search.constraints,
          is_binary(key) and key not in ["_id", "_advanced_search_constraint"],
          {access, method} <- [access(ctx, type, key, op)],
          do: {key, {access, method}, op}

    sort =
      case search.options do
        %{"sort_field" => key} when is_binary(key) and key != "_id" ->
          if String.starts_with?(key, "_dynamic"), do: [], else: [{key, {:sort, :btree}, :sort}]

        _ ->
          []
      end

    constraints ++ sort
  end

  defp access(ctx, type, key, op) do
    value_type =
      case Index.symbol(ctx.index, Symbol.id(:field, [type, key])) do
        %{attrs: %{value_type: vt}} -> vt
        _ -> nil
      end

    cond do
      op == "geographic_search" -> {:geo, :geo}
      value_type == "geographic_address" and op in [:equals, :in] -> {:geo, :geo}
      op == :contains and match?("list." <> _, value_type) -> {:membership, :gin}
      true -> Map.get(@access, op)
    end
  end

  defp finding(ctx, field_id, uses) do
    case Index.symbol(ctx.index, field_id) do
      %Symbol{kind: :field} = field ->
        if live?(ctx, field), do: [build(ctx, field, uses)], else: []

      _ ->
        []
    end
  end

  defp live?(ctx, field),
    do: Enum.any?(Context.fields(ctx, Context.type_of_field(field)), &(&1.id == field.id))

  defp build(ctx, field, uses) do
    type = Context.type_of_field(field)
    searches = uses |> Enum.map(&{&1.host, &1.path}) |> Enum.uniq() |> length()

    indexes =
      uses
      |> Enum.group_by(fn %{access: {_, method}} -> method end)
      |> Enum.sort()
      |> Enum.map(fn {method, group} ->
        %{
          method: method,
          access: group |> Enum.map(&elem(&1.access, 0)) |> Enum.uniq() |> Enum.sort(),
          operators:
            group |> Enum.map(& &1.operator) |> Enum.uniq() |> Enum.sort_by(&to_string/1),
          searches: group |> Enum.map(&{&1.host, &1.path}) |> Enum.uniq() |> length()
        }
      end)

    {confidence, reason} =
      if searches > 1,
        do: {:high, "#{searches} searches filter or sort on it"},
        else: {:medium, "one search filters or sorts on it"}

    Finding.new(:search_index, %{type: type, field: field.bubble_id},
      path: field.path,
      evidence: %{
        symbols: [field.id | Enum.map(uses, & &1.host)],
        references: Enum.flat_map(uses, & &1.refs),
        searches: searches
      },
      proposal: %{transform: :add_index, field: field.id, indexes: indexes},
      confidence: confidence,
      confidence_reason: reason,
      affects: Context.affects(ctx, Enum.map(uses, & &1.host)),
      message:
        "#{searches} search(es) on “#{Context.name(ctx, "data_type:" <> type)}” use " <>
          "“#{Context.name(ctx, field.id)}” (#{Enum.map_join(indexes, ", ", &Atom.to_string(&1.method))}); index it"
    )
  end
end
