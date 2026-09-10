defmodule BubbleEx.Frontend.StaticExpression do
  @moduledoc false

  @max_text_bytes 100_000
  @max_items 100
  @max_depth 24

  @spec resolve(term(), term()) :: {:ok, term()} | :unknown
  def resolve(expression, parent \\ :unknown), do: evaluate(expression, parent, 0)

  defp evaluate(_expression, _parent, depth) when depth > @max_depth, do: :unknown

  defp evaluate(value, _parent, _depth) when is_number(value) or is_boolean(value),
    do: {:ok, value}

  defp evaluate(value, _parent, _depth)
       when is_binary(value) and byte_size(value) <= @max_text_bytes,
       do: {:ok, value}

  defp evaluate(%{} = expression, parent, depth) do
    with {:ok, value} <- base(expression, parent, depth + 1) do
      messages(value, expression["%n"], parent, depth + 1)
    end
  end

  defp evaluate(_expression, _parent, _depth), do: :unknown

  defp base(%{"%x" => "ElementParent"}, parent, depth)
       when is_binary(parent) or is_number(parent) or is_boolean(parent),
       do: evaluate(parent, :unknown, depth)

  defp base(%{"%x" => "ArbitraryText", "%p" => %{"arbitrary_text" => text}}, parent, depth),
    do: evaluate(text, parent, depth)

  defp base(%{"%x" => "TextExpression", "%e" => parts}, parent, depth)
       when is_map(parts) and map_size(parts) <= @max_items do
    if Enum.all?(Map.keys(parts), &numeric_key?/1) do
      parts
      |> Enum.sort_by(fn {key, _} -> String.to_integer(key) end)
      |> Enum.reduce_while({:ok, ""}, fn {_key, part}, {:ok, text} ->
        append_part(text, evaluate(part, parent, depth))
      end)
    else
      :unknown
    end
  end

  defp base(_expression, _parent, _depth), do: :unknown

  defp append_part(text, {:ok, value}) when is_binary(value) or is_number(value) do
    joined = text <> to_string(value)

    if byte_size(joined) <= @max_text_bytes,
      do: {:cont, {:ok, joined}},
      else: {:halt, :unknown}
  end

  defp append_part(_text, _result), do: {:halt, :unknown}

  defp numeric_key?(key) when is_binary(key) and byte_size(key) <= 12,
    do: Regex.match?(~r/^\d+$/, key)

  defp numeric_key?(_key), do: false

  defp messages(_value, _message, _parent, depth) when depth > @max_depth, do: :unknown
  defp messages(value, nil, _parent, _depth), do: {:ok, value}

  defp messages(value, %{} = message, parent, depth) do
    with true <- supported_arguments?(message),
         {:ok, result} <- operation(value, message, parent, depth + 1) do
      messages(result, message["%n"], parent, depth + 1)
    else
      _ -> :unknown
    end
  end

  defp messages(_value, _message, _parent, _depth), do: :unknown

  defp supported_arguments?(%{"%nm" => "split_by"} = message),
    do: Map.drop(message, ["%nm", "%n", "%p"]) == %{}

  defp supported_arguments?(%{"%nm" => "convert_to_number"} = message),
    do: Map.drop(message, ["%nm", "%n"]) == %{}

  defp supported_arguments?(_message), do: false

  defp operation(
         value,
         %{"%nm" => "split_by", "%p" => %{"separator" => expression} = params},
         parent,
         depth
       )
       when is_binary(value) and map_size(params) == 1 do
    with {:ok, separator} when is_binary(separator) and separator != "" <-
           evaluate(expression, parent, depth),
         parts when length(parts) <= @max_items <-
           String.split(value, separator, parts: @max_items + 1) do
      {:ok, parts}
    else
      _ -> :unknown
    end
  end

  defp operation(values, %{"%nm" => "convert_to_number"}, _parent, _depth) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case number(value) do
        {:ok, n} -> {:cont, {:ok, [n | acc]}}
        _ -> {:halt, :unknown}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      _ -> :unknown
    end
  end

  defp operation(value, %{"%nm" => "convert_to_number"}, _parent, _depth), do: number(value)
  defp operation(_value, _message, _parent, _depth), do: :unknown

  defp number(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} ->
        {:ok, n}

      _ ->
        float(value)
    end
  end

  defp number(value) when is_number(value), do: {:ok, value}
  defp number(_value), do: :unknown

  defp float(value) do
    case Float.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :unknown
    end
  end
end
