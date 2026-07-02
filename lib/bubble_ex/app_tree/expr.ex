defmodule BubbleEx.AppTree.Expr do
  @moduledoc """
  Best-effort rendering of Bubble expression trees.

  Bubble text expressions are `%{"type" => "TextExpression", "entries" => ...}`
  where each entry is a static string or a dynamic node. Conditions are chains
  where the subject node carries a `"next"` Message (operator) whose `"args"`
  is the operand. Everything unrecognized degrades explicitly (`:partial` /
  `:fallback`) — callers keep a pointer to the lossless raw JSON.
  """

  @placeholder "[⟨expr⟩]"

  @spec render_text(term()) :: {:ok, String.t()} | {:partial, String.t()} | :fallback
  def render_text(%{"type" => "TextExpression", "entries" => entries}) when is_map(entries) do
    parts =
      entries
      |> Enum.sort_by(fn {k, _} -> entry_order(k) end)
      |> Enum.map(fn {_, part} -> render_part(part) end)

    text = Enum.map_join(parts, "", &elem(&1, 1))

    if Enum.all?(parts, &match?({:ok, _}, &1)) do
      {:ok, text}
    else
      {:partial, text}
    end
  end

  def render_text(_), do: :fallback

  defp entry_order(key) do
    case Integer.parse(key) do
      {i, ""} -> i
      _ -> 0
    end
  end

  defp render_part(part) when is_binary(part), do: {:ok, part}

  defp render_part(%{"type" => "PageData", "properties" => %{"name" => name}})
       when is_binary(name),
       do: {:ok, "[#{name}]"}

  defp render_part(_), do: {:partial, @placeholder}

  @spec render_condition(term()) :: {:ok, String.t()} | :fallback
  def render_condition(%{"next" => %{"type" => "Message", "name" => op} = msg} = node)
      when is_binary(op) do
    # A Message chaining into another Message is beyond v1 — fall back losslessly.
    with false <- Map.has_key?(msg, "next"),
         {:ok, subject} <- term(Map.delete(node, "next")),
         {:ok, operand} <- operand(msg["args"]) do
      {:ok, String.trim("#{subject} #{humanize(op)} #{operand}")}
    else
      _ -> :fallback
    end
  end

  def render_condition(_), do: :fallback

  defp operand(nil), do: {:ok, ""}
  defp operand(args), do: term(args)

  defp term(%{"type" => "PageData", "properties" => %{"name" => name}}) when is_binary(name),
    do: {:ok, name}

  defp term(%{"type" => "Breakpoint", "properties" => %{"breakpoint_id" => id}})
       when is_binary(id),
       do: {:ok, "breakpoint #{id}"}

  defp term(_), do: :fallback

  defp humanize(op), do: String.replace(op, "_", " ")
end
