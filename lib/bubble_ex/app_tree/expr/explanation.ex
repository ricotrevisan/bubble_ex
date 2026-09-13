defmodule BubbleEx.AppTree.Expr.Explanation do
  @moduledoc false
  alias BubbleEx.Workflows.Source

  @binary %{
    "equals" => "is",
    "not_equals" => "is not",
    "greater_than" => ">",
    "less_than" => "<",
    "greater_or_equal_than" => ">=",
    "less_or_equal_than" => "<=",
    "and_" => "and",
    "or_" => "or"
  }
  @unary %{
    "is_true" => "is yes",
    "is_false" => "is no",
    "is_empty" => "is empty",
    "is_not_empty" => "is not empty",
    "logged_in" => "is logged in",
    "not_logged_in" => "is logged out"
  }
  @aliases [
    ~w(type %x),
    ~w(properties %p),
    ~w(next %n),
    ~w(name %nm),
    ~w(args %a),
    ~w(entries %e)
  ]

  @spec explain(term(), list(), map()) :: map()
  def explain(raw, path, context) when is_map(raw) do
    base = base(raw, path, context)

    result =
      case Source.get(raw, ~w(next %n)) do
        nil -> base
        {key, next} -> chain(next, path ++ [key], base, context)
      end

    %{result | path: Source.pointer(path), raw: raw}
  end

  def explain(raw, path, _)
      when is_binary(raw) or is_number(raw) or is_boolean(raw) or is_nil(raw),
      do:
        record("literal", raw, path, "fully_supported", Jason.encode!(raw))
        |> Map.put(:data_type, literal_type(raw))

  def explain(raw, path, _), do: unknown(raw, path, "Unsupported expression value")

  @spec unknown(term(), list(), String.t()) :: map()
  def unknown(raw, path, reason),
    do: record("unknown", raw, path, "unresolved", "[#{reason} at #{Source.pointer(path)}]")

  @spec unavailable(list(), String.t()) :: map()
  def unavailable(path, reason),
    do: %{
      kind: "missing",
      path: Source.pointer(path),
      status: "unavailable",
      text: "[#{reason}]",
      children: []
    }

  @spec combine([map()]) :: String.t()
  def combine(children) do
    cond do
      Enum.all?(children, &(&1.status == "fully_supported")) -> "fully_supported"
      Enum.any?(children, &(&1.status in ["fully_supported", "partial"])) -> "partial"
      Enum.all?(children, &(&1.status == "unavailable")) -> "unavailable"
      true -> "unresolved"
    end
  end

  defp base(raw, path, context) do
    type = Source.value(raw, ~w(type %x))
    result = source(type, raw, path, context)
    allowed = ~w(type %x next %n is_slidable) ++ source_keys(type)
    guard_fields(result, raw, path, allowed)
  end

  defp source("CurrentUser", raw, path, _),
    do:
      record("reference", raw, path, "fully_supported", "current user")
      |> Map.put(:data_type, "user")
      |> Map.put(:source_kind, "CurrentUser")

  defp source(type, raw, path, context) when type in ["CurrentPageItem", "ThisElement"],
    do: context.resolve.(type, raw, path)

  defp source(type, raw, path, context) when type in ["GetElement", "PreviousStep", "PageData"],
    do: context.resolve.(type, raw, path)

  defp source("TextExpression", raw, path, context) do
    case Source.get(raw, ~w(entries %e)) do
      {key, entries} when is_map(entries) or is_list(entries) ->
        text_entries(ordered(entries), raw, path, key, context)

      _ ->
        unknown(raw, path, "Missing or malformed text entries")
    end
  end

  defp source(_, raw, path, _), do: unknown(raw, path, "Unsupported expression")

  defp text_entries({:ok, entries}, raw, path, key, context) do
    children = Enum.map(entries, fn {k, v} -> explain(v, path ++ [key, k], context) end)

    record(
      "text",
      raw,
      path,
      combine(children),
      "text(" <> Enum.map_join(children, " + ", & &1.text) <> ")",
      children
    )
  end

  defp text_entries(:error, raw, path, _, _),
    do: unknown(raw, path, "Unresolved text entry order")

  defp source_keys("TextExpression"), do: ~w(entries %e)
  defp source_keys(type) when type in ~w(GetElement PreviousStep PageData), do: ~w(properties %p)
  defp source_keys(_), do: []

  defp chain(raw, path, left, context) when is_map(raw) do
    result = message(Source.value(raw, ~w(type %x)), raw, path, left, context)
    result = guard_fields(result, raw, path, ~w(type %x name %nm args %a next %n is_slidable))

    case Source.get(raw, ~w(next %n)) do
      nil -> result
      {key, next} -> chain(next, path ++ [key], result, context)
    end
  end

  defp chain(raw, path, left, _), do: unsupported_chain(raw, path, left)

  defp message("Message", raw, path, left, context) do
    op = Source.value(raw, ~w(name %nm))

    cond do
      Map.has_key?(@binary, op) ->
        binary(raw, path, left, context, op)

      Map.has_key?(@unary, op) ->
        unary(raw, path, left, op)

      is_binary(op) and is_nil(Source.get(raw, ~w(args %a))) ->
        field = context.field.(Map.get(left, :data_type), op, path)

        record("field", raw, path, combine([left, field]), "#{left.text}'s #{field.text}", [
          left,
          field
        ])
        |> Map.put(:data_type, Map.get(field, :data_type))

      true ->
        unsupported_chain(raw, path, left)
    end
  end

  defp message(_, raw, path, left, _), do: unsupported_chain(raw, path, left)

  defp binary(raw, path, left, context, op) do
    right =
      case Source.get(raw, ~w(args %a)) do
        {key, value} -> explain(value, path ++ [key], context)
        nil -> unavailable(path, "Missing operator operand")
      end

    record(
      "operator",
      raw,
      path,
      combine([left, right]),
      "(#{left.text} #{@binary[op]} #{right.text})",
      [left, right]
    )
    |> Map.put(:operator, op)
    |> Map.put(:data_type, "boolean")
  end

  defp unary(raw, path, left, op) do
    if Source.get(raw, ~w(args %a)) != nil or
         (op in ~w(logged_in not_logged_in) and Map.get(left, :source_kind) != "CurrentUser") do
      unsupported_chain(raw, path, left)
    else
      record("operator", raw, path, left.status, "(#{left.text} #{@unary[op]})", [left])
      |> Map.put(:operator, op)
      |> Map.put(:data_type, "boolean")
    end
  end

  defp literal_type(value) when is_boolean(value), do: "boolean"
  defp literal_type(value) when is_number(value), do: "number"
  defp literal_type(value) when is_binary(value), do: "text"
  defp literal_type(nil), do: "null"

  defp unsupported_chain(raw, path, left) do
    unknown = unknown(raw, path, "Unsupported operator")

    record(
      "unknown_operator",
      raw,
      path,
      combine([left, unknown]),
      "(#{left.text} → #{unknown.text})",
      [left, unknown]
    )
  end

  defp guard_fields(result, raw, path, allowed) do
    extras = Enum.sort(Map.keys(raw) -- allowed)

    collisions =
      Enum.filter(@aliases, fn keys -> Enum.count(keys, &Map.has_key?(raw, &1)) > 1 end)

    if extras == [] and collisions == [] do
      result
    else
      children =
        Enum.map(extras, &unknown(Map.fetch!(raw, &1), path ++ [&1], "Uninterpreted field"))

      %{
        result
        | status:
            if(result.status in ["fully_supported", "partial"], do: "partial", else: "unresolved"),
          text: result.text <> " [uninterpreted fields or alias collision]",
          children: result.children ++ children
      }
      |> Map.put(:alias_collisions, collisions)
    end
  end

  @spec record(String.t(), term(), list(), String.t(), String.t(), [map()]) :: map()
  def record(kind, raw, path, status, text, children \\ []),
    do: %{
      kind: kind,
      raw: raw,
      path: Source.pointer(path),
      status: status,
      text: text,
      children: children
    }

  @spec ordered(term()) :: {:ok, list()} | :error
  def ordered(entries) when is_list(entries), do: {:ok, Source.entries(entries)}

  def ordered(entries) when is_map(entries) do
    pairs = Source.entries(entries)
    keys = Enum.map(pairs, fn {key, _} -> Integer.parse(key) end)

    if Enum.all?(keys, &match?({n, ""} when n >= 0, &1)) and
         length(Enum.uniq(keys)) == length(keys),
       do: {:ok, Enum.sort_by(pairs, fn {k, _} -> String.to_integer(k) end)},
       else: :error
  end

  def ordered(_), do: :error
end
