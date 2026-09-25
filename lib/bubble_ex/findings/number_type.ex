defmodule BubbleEx.Findings.NumberType do
  @moduledoc false

  # `:number_type` - a number field (Bubble's one number type, a float by
  # default) whose every write is integral: a list count, an integer
  # literal, or `+`, `-`, `×` of integral values and the field itself
  # (`This Thing's Count + 1`). Proposes an integer.
  #
  # Only proposed when every indexed write is understood: any input, other
  # field, division or fractional literal means no finding. Decimal
  # (money) hints need evidence the index does not have yet.
  #
  # Confidence: high when a write counts or increments; medium when the
  # evidence is integer literals only.

  alias BubbleEx.{Finding, Index}
  alias BubbleEx.Findings.{Context, Values}

  @spec run(Context.t()) :: [Finding.t()]
  def run(ctx) do
    for field <- Context.all_fields(ctx),
        not Map.has_key?(field.attrs, :builtin),
        field.attrs[:value_type] == "number",
        finding <- analyze(ctx, field),
        do: finding
  end

  defp analyze(ctx, field) do
    type = Context.type_of_field(field)
    writes = Index.writers(ctx.index, field.id)

    kinds =
      Enum.map(writes, fn w ->
        case Context.write_value(ctx, w) do
          {ast, reads} -> ast |> Values.describe(reads) |> integral(type, field.bubble_id)
          nil -> :unknown
        end
      end)

    cond do
      writes == [] ->
        []

      Enum.all?(kinds, &(&1 in [:count, :increment, :literal, :self])) and
          Enum.any?(kinds, &(&1 != :self)) ->
        [finding(ctx, field, type, writes, kinds)]

      true ->
        []
    end
  end

  # :count | :increment | :literal | :self (the field's own value, or empty:
  # no evidence either way) | :unknown
  defp integral({:literal, nil}, _type, _key), do: :self
  defp integral({:literal, v}, _type, _key) when is_integer(v), do: :literal
  defp integral({:literal, v}, _type, _key) when is_float(v) and v == trunc(v), do: :literal
  defp integral({:count, _}, _type, _key), do: :count

  defp integral({:read, %{keys: keys, owner: owner}}, type, key),
    do: if(List.last(keys) == key and owner == type, do: :self, else: :unknown)

  defp integral({:arith, op, l, r}, type, key) when op in [:plus, :minus, :times] do
    if :unknown in [integral(l, type, key), integral(r, type, key)],
      do: :unknown,
      else: :increment
  end

  defp integral(_, _type, _key), do: :unknown

  defp finding(ctx, field, type, writes, kinds) do
    counts = Enum.frequencies(kinds)

    {confidence, reason} =
      if Map.has_key?(counts, :count) or Map.has_key?(counts, :increment),
        do: {:high, "every write is a count, an integer literal or integer arithmetic"},
        else: {:medium, "every write is an integer literal"}

    Finding.new(:number_type, %{type: type, field: field.bubble_id},
      path: field.path,
      evidence: %{
        symbols: [field.id],
        references: writes,
        writes: Map.new(counts, fn {k, n} -> {k, n} end)
      },
      proposal: %{transform: :refine_number_type, field: field.id, from: :number, to: :integer},
      confidence: confidence,
      confidence_reason: reason,
      affects: Context.affects(ctx, [], Enum.map(writes, & &1.from)),
      message:
        "every write to “#{Context.name(ctx, field.id)}” on “#{Context.name(ctx, "data_type:" <> type)}” " <>
          "is integral; store it as an integer"
    )
  end
end
