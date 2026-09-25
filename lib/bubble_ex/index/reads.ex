defmodule BubbleEx.Index.Reads do
  @moduledoc false

  # What a definition's expressions read. Finds the outermost expressions in
  # a definition's own JSON, parses each with `BubbleEx.Expression` (field
  # chains typed against the app schema) and walks the AST:
  #
  #   * `Field` on a record type          -> :reads_field (via :expression)
  #   * `Search` / `:filtered` constraint -> :reads_field (via :constraint)
  #   * sort settings (`sort_field`)       -> :reads_field (via :sort)
  #   * `Search` data type                 -> :reads_type
  #   * option value / all options         -> :reads_option
  #   * `GetDataFromAPI` data source       -> :calls_api (via :data_source)
  #   * an element's value (`GetElement`)  -> :reads_element
  #
  # Expressions kept verbatim by the parser (scope references, raw
  # operators and sources) are scanned again for nested expressions.

  alias BubbleEx.Expression
  alias BubbleEx.Expression.{Ast, Schema, Vocabulary}
  alias BubbleEx.Index.{Reference, Symbol, Types}
  alias BubbleEx.Workflows.Source

  @sources ~w(CurrentUser InjectedValue TextExpression Search OneOptionValue OptionValue
              AllOptionValue ArbitraryText GetDataFromAPI)
  @trigger_items ~w(CurrentDataItem OldDataItem)
  @skip_keys [:meta, :raw, :ref, :options]

  @type ctx :: %{
          required(:schema) => Schema.t(),
          optional(:trigger_type) => String.t() | nil,
          optional(:attrs) => map()
        }

  @doc """
  References from symbol `from` made by expressions in `value` (found at
  `path`). With `:trigger_type`, `CurrentDataItem`/`OldDataItem` sources
  without a type are the record a database trigger fired for.
  """
  @spec scan(term(), list(), Symbol.id(), ctx()) :: [Reference.t()]
  def scan(value, path, from, ctx) do
    attrs = Map.get(ctx, :attrs, %{})

    value
    |> roots(path, [])
    |> Enum.reverse()
    |> Enum.flat_map(fn {raw, rpath} ->
      pointer = Source.pointer(rpath)

      raw
      |> reads(ctx)
      |> Enum.map(fn {kind, to, edge_attrs} ->
        %Reference{
          from: from,
          to: to,
          kind: kind,
          path: pointer,
          attrs: Map.merge(edge_attrs, attrs)
        }
      end)
    end)
  end

  @doc "References from symbol `from` made by an already parsed expression at `path`."
  @spec from_ast(Ast.t(), String.t(), Symbol.id(), ctx()) :: [Reference.t()]
  def from_ast(ast, pointer, from, ctx) do
    attrs = Map.get(ctx, :attrs, %{})

    ast
    |> walk([], ctx)
    |> Enum.reverse()
    |> Enum.map(fn {kind, to, edge_attrs} ->
      %Reference{
        from: from,
        to: to,
        kind: kind,
        path: pointer,
        attrs: Map.merge(edge_attrs, attrs)
      }
    end)
  end

  @doc "The Bubble type of an expression, e.g. the record a data action changes."
  @spec type_of(term(), ctx()) :: String.t() | nil
  def type_of(raw, ctx) do
    case Expression.parse(bind_context(raw, ctx), schema: ctx.schema) do
      {:ok, %{ast: ast}} -> ast.type
      {:error, _} -> nil
    end
  end

  defp roots(map, path, acc) when is_map(map) do
    if root?(map) do
      [{map, path} | acc]
    else
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(acc, fn {k, v}, a -> roots(v, path ++ [k], a) end)
    end
  end

  defp roots(list, path, acc) when is_list(list) do
    list |> Enum.with_index() |> Enum.reduce(acc, fn {v, i}, a -> roots(v, path ++ [i], a) end)
  end

  defp roots(_, _, acc), do: acc

  defp root?(map) do
    case Source.value(map, ~w(type %x)) do
      "Empty" -> false
      type when is_binary(type) -> type in @sources or next?(map) or Vocabulary.scope(type) != nil
      _ -> false
    end
  end

  defp next?(map), do: Map.has_key?(map, "next") or Map.has_key?(map, "%n")

  defp reads(raw, ctx) do
    case Expression.parse(bind_context(raw, ctx), schema: ctx.schema) do
      {:ok, %{ast: ast}} -> ast |> walk([], ctx) |> Enum.reverse()
      {:error, _} -> []
    end
  end

  # --- AST walk ---------------------------------------------------------------

  defp walk(%Ast.Field{subject: subject, field: field}, acc, ctx) do
    acc = field_read(acc, subject.type, field, :expression)
    walk(subject, acc, ctx)
  end

  defp walk(%Ast.Search{} = node, acc, ctx) do
    acc =
      case Types.data_type_key(node.data_type) do
        nil -> acc
        key -> [{:reads_type, Symbol.id(:data_type, key), %{}} | acc]
      end

    acc = constraints(node.constraints, node.data_type, acc, ctx)
    sort(node.options, node.data_type, acc)
  end

  defp walk(%Ast.Filter{subject: subject} = node, acc, ctx) do
    acc = constraints(node.constraints, subject.type, acc, ctx)
    acc = sort(node.options, subject.type, acc)
    walk(subject, acc, ctx)
  end

  defp walk(%Ast.ListOp{subject: subject, arg: arg, options: options}, acc, ctx) do
    acc = sort(options, subject.type, acc)
    walk(arg, walk(subject, acc, ctx), ctx)
  end

  defp walk(%Ast.OptionValue{option_set: set, value: value}, acc, _ctx) do
    case Types.option_set_key(set) do
      nil -> acc
      key -> [{:reads_option, Symbol.id(:option_value, [key, value]), %{}} | acc]
    end
  end

  defp walk(%Ast.AllOptions{option_set: set}, acc, _ctx) do
    case Types.option_set_key(set) do
      nil -> acc
      key -> [{:reads_option, Symbol.id(:option_set, key), %{}} | acc]
    end
  end

  defp walk(%Ast.Scope{kind: :element, ref: %{"element_id" => element} = ref}, acc, ctx)
       when is_binary(element) and element != "" do
    to = Map.get(Map.get(ctx, :bubble_ids, %{}), element, Symbol.id(:element, element))
    nested(ref, [{:reads_element, to, %{}} | acc], ctx)
  end

  defp walk(%Ast.Scope{ref: ref}, acc, ctx), do: nested(ref, acc, ctx)

  defp walk(%Ast.Raw{raw: raw, subject: subject}, acc, ctx) do
    acc = api_source(raw, acc)
    walk(subject, nested(raw, acc, ctx), ctx)
  end

  defp walk(%_{} = node, acc, ctx) do
    if Ast.node?(node) or match?(%Ast.Constraint{}, node) do
      node
      |> Map.from_struct()
      |> Map.drop(@skip_keys)
      |> Enum.sort()
      |> Enum.reduce(acc, fn {_, v}, a -> walk(v, a, ctx) end)
    else
      acc
    end
  end

  defp walk(list, acc, ctx) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, &2, ctx))
  defp walk(_, acc, _ctx), do: acc

  # Expressions nested in JSON the parser keeps verbatim.
  defp nested(value, acc, ctx) when is_map(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(acc, fn {_, v}, a ->
      v
      |> roots([], [])
      |> Enum.reverse()
      |> Enum.reduce(a, fn {r, _}, a2 -> Enum.reverse(reads(r, ctx), a2) end)
    end)
  end

  defp nested(value, acc, ctx) when is_list(value),
    do: Enum.reduce(value, acc, &nested(%{"" => &1}, &2, ctx))

  defp nested(_, acc, _ctx), do: acc

  defp api_source(raw, acc) when is_map(raw) do
    with "GetDataFromAPI" <- Source.value(raw, ~w(type %x)),
         props when is_map(props) <- Source.value(raw, ~w(properties %p)),
         "apiconnector2." <> provider <- props["provider"],
         [group, call] <- String.split(provider, ".", parts: 2) do
      [{:calls_api, Symbol.id(:api_call, [group, call]), %{via: :data_source}} | acc]
    else
      _ -> acc
    end
  end

  defp api_source(_, acc), do: acc

  defp constraints(constraints, item_type, acc, ctx) do
    Enum.reduce(constraints, acc, fn %Ast.Constraint{key: key, value: value}, a ->
      a = if constraint_field?(key), do: field_read(a, item_type, key, :constraint), else: a
      walk(value, a, ctx)
    end)
  end

  defp constraint_field?(key), do: is_binary(key) and key != "_advanced_search_constraint"

  # `_dynamic_sort_field` means the sort field is chosen at run time.
  defp sort(%{"sort_field" => field}, type, acc) when is_binary(field) do
    if String.starts_with?(field, "_dynamic"),
      do: acc,
      else: field_read(acc, type, field, :sort)
  end

  defp sort(_, _, acc), do: acc

  # Built-in fields (`_id`, `Created Date`, a User's `email`, …) are field
  # symbols too; see `BubbleEx.Index.DataModel`.
  defp field_read(acc, type, field, via) do
    case Types.data_type_key(type) do
      nil -> acc
      key -> [{:reads_field, Symbol.id(:field, [key, field]), %{via: via}} | acc]
    end
  end

  # --- context types ----------------------------------------------------------

  # Sources whose type comes from context rather than a `btype_id`: the
  # record a database trigger fired for (`CurrentDataItem`/`OldDataItem` in a
  # trigger workflow) and the result of an earlier step (`PreviousStep`) whose
  # type is known. Adds the type to a copy of the expression before parsing.
  defp bind_context(raw, ctx) do
    trigger = Map.get(ctx, :trigger_type)
    steps = Map.get(ctx, :step_types, %{})

    if is_binary(trigger) or map_size(steps) > 0,
      do: bind(raw, trigger, steps),
      else: raw
  end

  # Returns the input itself (no copy) when nothing needs a type.
  defp bind(map, trigger, steps) when is_map(map) do
    map =
      Enum.reduce(map, map, fn {k, v}, acc ->
        case bind(v, trigger, steps) do
          ^v -> acc
          bound -> Map.put(acc, k, bound)
        end
      end)

    case context_type(Source.value(map, ~w(type %x)), props_of(map), trigger, steps) do
      nil -> map
      type -> put_btype(map, type)
    end
  end

  defp bind(list, trigger, steps) when is_list(list) do
    bound = Enum.map(list, &bind(&1, trigger, steps))
    if bound == list, do: list, else: bound
  end

  defp bind(value, _trigger, _steps), do: value

  defp props_of(map) do
    case Source.value(map, ~w(properties %p)) do
      props when is_map(props) -> props
      _ -> %{}
    end
  end

  defp put_btype(map, type) do
    case Source.get(map, ~w(properties %p)) do
      {_pkey, %{"btype_id" => _}} -> map
      {pkey, props} when is_map(props) -> Map.put(map, pkey, Map.put(props, "btype_id", type))
      nil -> Map.put(map, "properties", %{"btype_id" => type})
      _ -> map
    end
  end

  defp context_type(type, _props, trigger, _steps)
       when type in @trigger_items and is_binary(trigger),
       do: trigger

  defp context_type("PreviousStep", %{"action_id" => step}, _trigger, steps),
    do: Map.get(steps, step)

  defp context_type(_, _, _, _), do: nil
end
