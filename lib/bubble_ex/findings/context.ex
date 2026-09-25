defmodule BubbleEx.Findings.Context do
  @moduledoc false

  # Facts every analyzer shares: the app JSON, its symbol index and schema,
  # the live (not deleted) fields of each data type with the live data types
  # they reference (missing and deleted targets are not references here), and helpers to read the value expression of a field write and to
  # list the workflows, pages, reusables and privacy rules a set of symbols
  # belongs to.

  alias BubbleEx.Expression
  alias BubbleEx.Expression.{Ast, Schema}
  alias BubbleEx.Index
  alias BubbleEx.Index.{Reference, Symbol, Types}

  @enforce_keys [:app, :index, :schema, :fields, :targets]
  defstruct [:app, :index, :schema, :fields, :targets]

  @type target :: %{type: String.t(), list: boolean()}

  @type t :: %__MODULE__{
          app: map(),
          index: Index.t(),
          schema: Schema.t(),
          fields: %{String.t() => [Symbol.t()]},
          targets: %{Symbol.id() => target()}
        }

  @spec build(map(), Index.t()) :: t()
  def build(app, index) do
    deleted_types =
      for %{kind: :data_type, attrs: %{deleted: true}} = s <- index.symbols,
          into: MapSet.new(),
          do: s.id

    fields =
      index.symbols
      |> Enum.filter(fn s ->
        s.kind == :field and match?("data_type:" <> _, s.parent) and
          not MapSet.member?(deleted_types, s.parent) and not Map.get(s.attrs, :deleted, false)
      end)
      |> Enum.group_by(fn %{parent: "data_type:" <> type} -> type end)

    targets =
      for %Reference{kind: :field_type, from: from, to: "data_type:" <> type} = r <-
            index.references,
          Index.symbol(index, "data_type:" <> type) != nil,
          not MapSet.member?(deleted_types, "data_type:" <> type),
          into: %{},
          do: {from, %{type: type, list: Map.get(r.attrs, :list, false)}}

    %__MODULE__{
      app: app,
      index: index,
      schema: Schema.from_app(app),
      fields: fields,
      targets: targets
    }
  end

  @doc "Live fields of data type `type` (built-ins included), sorted by ID."
  @spec fields(t(), String.t()) :: [Symbol.t()]
  def fields(ctx, type), do: Map.get(ctx.fields, type, [])

  @doc "Every live field of every live data type, sorted by ID."
  @spec all_fields(t()) :: [Symbol.t()]
  def all_fields(ctx), do: ctx.fields |> Map.values() |> List.flatten() |> Enum.sort_by(& &1.id)

  @doc "The data type a field references, or nil."
  @spec target(t(), Symbol.id()) :: target() | nil
  def target(ctx, field_id), do: Map.get(ctx.targets, field_id)

  @doc "Scalar reference fields of `type` pointing at data type `to`."
  @spec scalar_refs(t(), String.t(), String.t()) :: [Symbol.t()]
  def scalar_refs(ctx, type, to) do
    ctx
    |> fields(type)
    |> Enum.filter(&match?(%{type: ^to, list: false}, target(ctx, &1.id)))
  end

  @doc "The data type key of a field symbol."
  @spec type_of_field(Symbol.t()) :: String.t()
  def type_of_field(%Symbol{parent: "data_type:" <> type}), do: type

  @doc "The display name of symbol `id` (its Bubble ID when unnamed), for messages."
  @spec name(t(), Symbol.id()) :: String.t()
  def name(ctx, id) do
    case Index.symbol(ctx.index, id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{bubble_id: bubble_id} -> bubble_id
      nil -> id
    end
  end

  @doc "The value at RFC 6901 `pointer` in the app JSON, or nil."
  @spec fetch(t(), String.t()) :: term()
  def fetch(ctx, pointer) do
    pointer
    |> Index.Workflows.segments()
    |> Enum.reduce_while(ctx.app, fn
      segment, map when is_map(map) ->
        {:cont, Map.get(map, segment)}

      segment, list when is_list(list) ->
        case Integer.parse(segment) do
          {i, ""} -> {:cont, Enum.at(list, i)}
          _ -> {:halt, nil}
        end

      _, _ ->
        {:halt, nil}
    end)
  end

  @doc """
  The value expression of a `:writes_field` reference, parsed: `{ast, reads}`
  where `reads` are the index's typed `:reads_field` references made inside
  the value. `This Thing` in a `ChangeThing`/`ChangeListOfThings` value is
  the (each) changed record. Nil when the entry has no value.
  """
  @spec write_value(t(), Reference.t()) :: {Ast.t(), [Reference.t()]} | nil
  def write_value(ctx, %Reference{kind: :writes_field} = write) do
    with %{"value" => raw} <- fetch(ctx, write.path),
         {:ok, %{ast: ast}} <- Expression.parse(raw, parse_opts(ctx, write)) do
      prefix = write.path <> "/value"

      reads =
        ctx.index
        |> Index.references_from(write.from, [:reads_field])
        |> Enum.filter(&(&1.path == prefix or String.starts_with?(&1.path, prefix <> "/")))

      {ast, reads}
    else
      _ -> nil
    end
  end

  defp parse_opts(ctx, write) do
    this_type =
      case Index.symbol(ctx.index, write.from) do
        %{attrs: %{type: type}} when type in ~w(ChangeThing ChangeListOfThings) ->
          {type, _} = split_field(write.to)
          Types.record_type(type)

        _ ->
          nil
      end

    [schema: ctx.schema, this_type: this_type]
  end

  @doc "Parses the outermost expression a reference was made from."
  @spec expression_at(t(), Reference.t()) :: Ast.t() | nil
  def expression_at(ctx, %Reference{} = ref) do
    raw = fetch(ctx, ref.path)

    this_type =
      case Index.symbol(ctx.index, ref.from) do
        %{kind: :privacy_rule, parent: "data_type:" <> type} -> Types.record_type(type)
        _ -> nil
      end

    binder = if this_type, do: :rule_record, else: :context

    case Expression.parse(raw, schema: ctx.schema, this_type: this_type, this_binder: binder) do
      {:ok, %{ast: ast}} -> ast
      _ -> nil
    end
  end

  @doc """
  Workflows, pages, reusables and privacy rules that the symbols with the
  given IDs are, or belong to.
  """
  @spec affects(t(), [Symbol.id()]) :: map()
  def affects(ctx, ids) do
    ids
    |> Enum.uniq()
    |> Enum.reduce(%{workflows: [], pages: [], reusables: [], privacy_rules: []}, fn id, acc ->
      acc
      |> add(:workflows, self_or_ancestor(ctx, id, :workflow))
      |> add(:pages, self_or_ancestor(ctx, id, :page))
      |> add(:reusables, self_or_ancestor(ctx, id, :reusable))
      |> add(:privacy_rules, self_or_ancestor(ctx, id, :privacy_rule))
    end)
  end

  defp add(acc, _key, nil), do: acc
  defp add(acc, key, %Symbol{id: id}), do: Map.update!(acc, key, &[id | &1])

  defp self_or_ancestor(ctx, id, kind) do
    case Index.symbol(ctx.index, id) do
      %{kind: ^kind} = s -> s
      nil -> nil
      _ -> Index.ancestor(ctx.index, id, kind)
    end
  end

  @doc "The workflow symbol ID of an action (or of a workflow itself), or nil."
  @spec workflow_of(t(), Symbol.id()) :: Symbol.id() | nil
  def workflow_of(ctx, id) do
    case self_or_ancestor(ctx, id, :workflow) do
      %{id: workflow} -> workflow
      nil -> nil
    end
  end

  @doc "`{type, field}` Bubble IDs of a field symbol ID."
  @spec split_field(Symbol.id()) :: {String.t(), String.t()} | nil
  def split_field("field:" <> rest) do
    case rest |> String.split("/") |> Enum.map(&unescape/1) do
      [type, field] -> {type, field}
      _ -> nil
    end
  end

  def split_field(_), do: nil

  defp unescape(part), do: part |> String.replace("~1", "/") |> String.replace("~0", "~")

  @doc "Every AST node and constraint in `ast`, depth first in a stable order."
  @spec nodes(term()) :: [struct()]
  def nodes(ast), do: ast |> collect([]) |> Enum.reverse()

  defp collect(%_{} = node, acc) do
    if Ast.node?(node) or match?(%Ast.Constraint{}, node) do
      node
      |> Map.from_struct()
      |> Map.drop([:meta, :raw, :options, :ref])
      |> Enum.sort()
      |> Enum.reduce([node | acc], fn {_, v}, a -> collect(v, a) end)
    else
      acc
    end
  end

  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect(_, acc), do: acc
end
