defmodule BubbleEx.Index.Subject do
  @moduledoc false

  # The `BubbleEx.Diagnostic` subject (Bubble IDs only) of index symbols.

  alias BubbleEx.Diagnostic
  alias BubbleEx.Index.{Symbol, Types}

  @doc """
  Subject of symbol `id`. `workflow_of` maps an action's symbol ID to its
  workflow's Bubble ID (or nil).
  """
  @spec of(String.t(), (String.t() -> String.t() | nil)) :: Diagnostic.subject()
  def of(id, workflow_of \\ fn _ -> nil end) do
    {kind, parts} = split(id)
    subject(kind, parts, fn -> workflow_of.(id) end)
  end

  defp subject("data_type", [type], _), do: %{type: type}
  defp subject("field", [type, field], _), do: %{type: type, field: field}

  defp subject(kind, [set | _], _) when kind in ["option_set", "option_value"],
    do: %{option_set: set}

  defp subject("option_attribute", [set, attr], _), do: %{option_set: set, field: attr}
  defp subject("privacy_rule", [type, rule], _), do: %{type: type, rule: rule}
  defp subject("workflow", [workflow], _), do: %{workflow: workflow}

  defp subject("api_call", [group, call], _),
    do: %{external_type: "api.apiconnector2.#{group}.#{call}"}

  defp subject("action", _, workflow) do
    case workflow.() do
      nil -> %{}
      id -> %{workflow: id}
    end
  end

  defp subject(_, _, _), do: %{}

  @doc """
  The symbol IDs a subject names: the most specific symbol for its type,
  option set or API Connector keys (a field, privacy rule or option set
  attribute over its parent), plus its workflow. The inverse of `of/2` for
  data-model subjects.
  """
  @spec symbol_ids(Diagnostic.subject()) :: [String.t()]
  def symbol_ids(subject) when is_map(subject) do
    [owner_symbol(subject), workflow_symbol(subject), external_symbol(subject)]
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp owner_symbol(%{type: type, field: field}), do: Symbol.id(:field, [type, field])
  defp owner_symbol(%{type: type, rule: rule}), do: Symbol.id(:privacy_rule, [type, rule])
  defp owner_symbol(%{type: type}), do: Symbol.id(:data_type, type)

  defp owner_symbol(%{option_set: set, field: attr}),
    do: Symbol.id(:option_attribute, [set, attr])

  defp owner_symbol(%{option_set: set}), do: Symbol.id(:option_set, set)
  defp owner_symbol(_), do: nil

  defp workflow_symbol(%{workflow: workflow}), do: Symbol.id(:workflow, workflow)
  defp workflow_symbol(_), do: nil

  defp external_symbol(%{external_type: descriptor}) do
    case Types.target(descriptor) do
      %{id: "api_call:" <> _ = id} -> id
      _ -> nil
    end
  end

  defp external_symbol(_), do: nil

  @doc "Subject of a reference: its source's, plus the target's IDs the source lacks."
  @spec of_reference(String.t(), String.t(), (String.t() -> String.t() | nil)) ::
          Diagnostic.subject()
  def of_reference(from, to, workflow_of),
    do: Map.merge(of(to, workflow_of), of(from, workflow_of))

  defp split(id) do
    case String.split(id, ":", parts: 2) do
      [kind, rest] ->
        {kind,
         rest
         |> String.split("/")
         |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))}

      _ ->
        {nil, []}
    end
  end
end
