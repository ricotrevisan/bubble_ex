defmodule BubbleEx.Expression.Text do
  @moduledoc false

  # Readable, editor-like rendering of an AST. Derived from the AST only; it is
  # a view, not a source of truth. Field captions are used when the schema
  # supplied them, otherwise the field ID. Unmodeled pieces render as ⟨…⟩.

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

  @compare %{
    equals: "is",
    not_equals: "is not",
    greater_than: ">",
    less_than: "<",
    greater_or_equal: ">=",
    less_or_equal: "<="
  }
  @check %{
    is_empty: "is empty",
    is_not_empty: "is not empty",
    is_true: "is yes",
    is_false: "is no",
    logged_in: "is logged in",
    logged_out: "is logged out"
  }
  @arithmetic %{plus: "+", minus: "-", times: "*", divided_by: "/", modulo: "%"}

  @spec render(struct()) :: String.t()
  def render(%Literal{value: value}), do: Jason.encode!(value)
  def render(%Empty{}), do: "empty"
  def render(%CurrentUser{}), do: "Current User"
  def render(%ThisThing{type: nil}), do: "This Thing"
  def render(%ThisThing{type: type}), do: "This " <> type
  def render(%Scope{kind: kind}), do: "⟨#{kind}⟩"
  def render(%OptionValue{option_set: set, value: value}), do: "#{set}.#{value}"
  def render(%AllOptions{option_set: set}), do: "All #{set}"
  def render(%ArbitraryText{text: text}), do: "Arbitrary text(#{render(text)})"

  def render(%DynamicText{parts: parts}),
    do: Enum.map_join(parts, fn p -> if is_binary(p), do: p, else: "[" <> render(p) <> "]" end)

  def render(%Search{data_type: type, constraints: cs}),
    do: "Search for #{type}" <> constraints(cs)

  def render(%Field{subject: s, field: field, display: display}),
    do: "#{render(s)}'s #{display || field}"

  def render(%Property{subject: s, name: name}), do: "#{render(s)}'s ⟨#{name}⟩"

  def render(%Compare{op: op, left: l, right: r}),
    do: "#{render(l)} #{@compare[op]} #{operand(r)}"

  def render(%Logical{op: op, left: l, right: r}), do: "#{render(l)} #{op} #{operand(r)}"

  def render(%Arithmetic{op: op, left: l, right: r}),
    do: "#{render(l)} #{@arithmetic[op]} #{operand(r)}"

  def render(%Check{op: op, subject: s}), do: "#{render(s)} #{@check[op]}"
  def render(%Fallback{subject: s, fallback: f}), do: "#{render(s)} defaulting to #{operand(f)}"
  def render(%Filter{subject: s, constraints: cs}), do: "#{render(s)}:filtered" <> constraints(cs)

  def render(%ListOp{op: op, subject: s, arg: nil}), do: "#{render(s)}:#{humanize(op)}"

  def render(%ListOp{op: op, subject: s, arg: arg}),
    do: "#{render(s)}:#{humanize(op)} #{operand(arg)}"

  def render(%Raw{subject: nil, reason: reason}), do: "⟨#{reason}⟩"
  def render(%Raw{subject: s, raw: raw}), do: "#{render(s)}:⟨#{raw_name(raw)}⟩"

  # Arguments are separate sub-expressions in Bubble; bracket compound ones so
  # the left-to-right grouping stays visible.
  defp operand(node) do
    text = render(node)
    if compound?(node), do: "(" <> text <> ")", else: text
  end

  defp compound?(node), do: match?(%{op: _}, node) or match?(%Raw{subject: %{}}, node)

  defp constraints([]), do: ""
  defp constraints(cs), do: " (" <> Enum.map_join(cs, ", ", &constraint/1) <> ")"

  defp constraint(%Constraint{key: "_advanced_search_constraint", value: value}),
    do: "advanced: " <> maybe(value)

  defp constraint(%Constraint{key: key, op: op, value: value}),
    do: String.trim("#{key} #{humanize(op)} #{maybe(value)}")

  defp maybe(nil), do: ""
  defp maybe(value), do: operand(value)

  defp humanize(nil), do: ""
  defp humanize(op), do: op |> to_string() |> String.replace("_", " ")

  defp raw_name(%{"name" => name}) when is_binary(name), do: name
  defp raw_name(%{"%nm" => name}) when is_binary(name), do: name
  defp raw_name(_), do: "…"
end
