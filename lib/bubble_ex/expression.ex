defmodule BubbleEx.Expression do
  @moduledoc """
  Bubble expressions as a typed, stack-neutral AST (`BubbleEx.Expression.Ast`).

  The AST is the source of truth for an expression; readable text is derived
  from it. Parsing accepts both key forms Bubble uses — readable keys from
  `.bubble` exports (`type`, `next`, `name`, `args`, `properties`, `entries`)
  and the live payload's compact aliases (`%x`, `%n`, `%nm`, `%a`, `%p`, `%e`).

      {:ok, %{ast: ast, diagnostics: []}} =
        BubbleEx.Expression.parse(condition, schema: schema, this_type: "custom.task")

      {:ok, "Current User's admin is yes"} = BubbleEx.Expression.render(ast)

  Unmodeled operators and sources are kept verbatim as `Ast.Raw` nodes and
  itemized in `diagnostics`; parsing never drops input. `to_bubble/1`
  re-emits the source JSON, and `canonical/1` / `sha256/1` give a key-order-
  and spelling-independent identity for fidelity checks.
  """

  alias BubbleEx.{CanonicalJson, Error}
  alias BubbleEx.Expression.{Ast, Diagnostic, Encoder, Parser, Schema, Semantic, Text}

  @enforce_keys [:ast, :diagnostics]
  defstruct [:ast, :diagnostics]

  @type t :: %__MODULE__{ast: Ast.t(), diagnostics: [Diagnostic.t()]}

  @type parse_option ::
          {:schema, Schema.t()}
          | {:this_type, String.t() | nil}
          | {:path, [String.t() | integer()]}

  @doc """
  Parses decoded Bubble expression JSON.

  ## Options

    * `:schema` - field lookup from `BubbleEx.Expression.Schema.from_app/1`,
      used to type field chains. Without it, accessors on records are kept as
      diagnosed `Ast.Property` nodes.
    * `:this_type` - Bubble type of `This Thing` (e.g. `"custom.task"`).
    * `:path` - source path of the expression, prefixed to diagnostic pointers.
  """
  @spec parse(term(), [parse_option()]) :: {:ok, t()} | {:error, Error.t()}
  def parse(raw, opts \\ []) do
    if json?(raw) do
      ctx = %{schema: Keyword.get(opts, :schema, %{}), this_type: Keyword.get(opts, :this_type)}
      {ast, diagnostics} = Parser.parse(raw, Keyword.get(opts, :path, []), ctx)
      {:ok, %__MODULE__{ast: ast, diagnostics: diagnostics}}
    else
      {:error, Error.new(:invalid_input, "expected decoded JSON with string map keys")}
    end
  end

  @doc "Re-emits Bubble JSON for an AST, in the key form it was parsed from."
  @spec to_bubble(Ast.t()) :: {:ok, term()} | {:error, Error.t()}
  def to_bubble(ast), do: with_node(ast, &Encoder.encode/1)

  @doc "Readable text for an AST."
  @spec render(Ast.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def render(ast), do: with_node(ast, &Text.render/1)

  @doc "Stack-neutral map form of an AST, without source-form metadata."
  @spec to_map(Ast.t()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(ast), do: with_node(ast, &Semantic.to_map/1)

  @doc "Canonical JSON of `to_map/1` (sorted keys, preserved nulls)."
  @spec canonical(Ast.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def canonical(ast), do: with_node(ast, &(&1 |> Semantic.to_map() |> CanonicalJson.encode()))

  @doc "SHA-256 of `canonical/1`."
  @spec sha256(Ast.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def sha256(ast), do: with_node(ast, &(&1 |> Semantic.to_map() |> CanonicalJson.sha256()))

  @doc """
  Counts AST nodes by kind (`"compare"`, `"field"`, `"raw"`, …), including
  search/filter constraint values. Useful as a coverage measure.
  """
  @spec node_counts(Ast.t()) :: {:ok, %{String.t() => pos_integer()}} | {:error, Error.t()}
  def node_counts(ast), do: with_node(ast, &count(&1, %{}))

  # Walk AST structs only; `raw`, `ref` and `options` hold verbatim JSON.
  defp count(%module{} = node, acc) do
    acc = if Ast.node?(node), do: Map.update(acc, Semantic.kind(module), 1, &(&1 + 1)), else: acc

    node
    |> Map.from_struct()
    |> Map.drop([:meta, :raw, :ref, :options])
    |> Map.values()
    |> count(acc)
  end

  defp count(list, acc) when is_list(list), do: Enum.reduce(list, acc, &count/2)
  defp count(_, acc), do: acc

  defp with_node(ast, fun) do
    if Ast.node?(ast),
      do: {:ok, fun.(ast)},
      else: {:error, Error.new(:invalid_input, "expected a BubbleEx.Expression.Ast node")}
  end

  defp json?(map) when is_map(map) and not is_struct(map),
    do: Enum.all?(map, fn {k, v} -> is_binary(k) and json?(v) end)

  defp json?(list) when is_list(list), do: Enum.all?(list, &json?/1)
  defp json?(v), do: is_binary(v) or is_number(v) or v in [true, false, nil]
end
