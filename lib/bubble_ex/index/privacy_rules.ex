defmodule BubbleEx.Index.PrivacyRules do
  @moduledoc false

  # Privacy rule symbols from `BubbleEx.Privacy`, with the fields each rule
  # references: condition reads (`:reads_field`), visible fields
  # (`:grants_view`) and auto-binding fields (`:grants_binding`).

  alias BubbleEx.Index.{Reads, Reference, Symbol}
  alias BubbleEx.Privacy

  @spec build(map(), map()) :: {[Symbol.t()], [Reference.t()]}
  def build(app, ctx) do
    case Privacy.parse(app) do
      {:ok, %Privacy{data_types: types}} ->
        types
        |> Enum.flat_map(fn type -> Enum.map(type.rules, &rule(type, &1, ctx)) end)
        |> then(&{Enum.map(&1, fn {s, _} -> s end), Enum.flat_map(&1, fn {_, r} -> r end)})

      {:error, _} ->
        {[], []}
    end
  end

  defp rule(type, rule, ctx) do
    id = Symbol.id(:privacy_rule, [type.id, rule.id])

    symbol = %Symbol{
      id: id,
      kind: :privacy_rule,
      bubble_id: rule.id,
      name: rule.name,
      parent: Symbol.id(:data_type, type.id),
      path: rule.path,
      attrs: if(rule.default?, do: %{default: true}, else: %{})
    }

    {symbol, condition(rule, id, ctx) ++ grants(type.id, rule, id)}
  end

  defp condition(%{condition: nil}, _id, _ctx), do: []

  defp condition(rule, id, ctx),
    do: Reads.from_ast(rule.condition, rule.path <> "/condition", id, ctx)

  defp grants(type_id, rule, id) do
    perms = rule.permissions || %Privacy.Permissions{}

    Enum.flat_map(
      [
        {:grants_view, "view_fields", perms.view_fields},
        {:grants_binding, "binding_fields", perms.binding_fields}
      ],
      fn
        {_kind, _key, nil} ->
          []

        {kind, key, fields} ->
          for field <- fields,
              do: %Reference{
                from: id,
                to: Symbol.id(:field, [type_id, field]),
                kind: kind,
                path: rule.path <> "/permissions/" <> key
              }
      end
    )
  end
end
