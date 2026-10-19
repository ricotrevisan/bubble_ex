defmodule BubbleEx.AppTree.Expr do
  @moduledoc """
  Best-effort rendering of Bubble expression trees.

  Bubble text expressions are `%{"type" => "TextExpression", "entries" => ...}`
  where each entry is a static string or a dynamic node. Conditions are chains
  where the subject node carries a `"next"` Message (operator) whose `"args"`
  is the operand. Everything unrecognized degrades explicitly (`:partial` /
  `:fallback`) — callers keep a pointer to the lossless raw JSON.

  These are legacy text views. The typed source of truth for an expression is
  `BubbleEx.Expression`.

  A `Breakpoint` reads as its width in pixels, as Bubble shows one used as
  text (replayed 2026-10-19: Tablet is `992`), given the app's breakpoint
  widths (`BubbleEx.Frontend.Responsive.widths/1`); one whose width is not
  known stays `breakpoint <id>`.
  """

  @doc false
  @spec explain(term(), list(), map()) :: map()
  defdelegate explain(raw, path, context), to: BubbleEx.AppTree.Expr.Explanation

  @placeholder "[⟨expr⟩]"

  @spec render_text(term(), %{String.t() => number()}) ::
          {:ok, String.t()} | {:partial, String.t()} | :fallback
  def render_text(expr, breakpoints \\ %{})

  def render_text(%{"type" => "TextExpression", "entries" => entries}, breakpoints)
      when is_map(entries) do
    parts =
      entries
      |> Enum.sort_by(fn {k, _} -> entry_order(k) end)
      |> Enum.map(fn {_, part} -> render_part(part, breakpoints) end)

    text = Enum.map_join(parts, "", &elem(&1, 1))

    if Enum.all?(parts, &match?({:ok, _}, &1)) do
      {:ok, text}
    else
      {:partial, text}
    end
  end

  def render_text(_, _breakpoints), do: :fallback

  defp entry_order(key) do
    case Integer.parse(key) do
      {i, ""} -> i
      _ -> 0
    end
  end

  defp render_part(part, _breakpoints) when is_binary(part), do: {:ok, part}

  defp render_part(%{"type" => "PageData", "properties" => %{"name" => name}}, _breakpoints)
       when is_binary(name),
       do: {:ok, "[#{name}]"}

  defp render_part(%{"type" => "Breakpoint"} = part, breakpoints) do
    case width(part, breakpoints) do
      nil -> {:partial, @placeholder}
      width -> {:ok, width}
    end
  end

  defp render_part(_, _breakpoints), do: {:partial, @placeholder}

  @spec render_condition(term(), %{String.t() => number()}) :: {:ok, String.t()} | :fallback
  def render_condition(condition, breakpoints \\ %{})

  def render_condition(
        %{"next" => %{"type" => "Message", "name" => op} = msg} = node,
        breakpoints
      )
      when is_binary(op) do
    # A Message chaining into another Message is beyond v1 — fall back losslessly.
    with false <- Map.has_key?(msg, "next"),
         {:ok, subject} <- term(Map.delete(node, "next"), breakpoints),
         {:ok, operand} <- operand(msg["args"], breakpoints) do
      {:ok, String.trim("#{subject} #{humanize(op)} #{operand}")}
    else
      _ -> :fallback
    end
  end

  def render_condition(_, _breakpoints), do: :fallback

  defp operand(nil, _breakpoints), do: {:ok, ""}
  defp operand(args, breakpoints), do: term(args, breakpoints)

  defp term(%{"type" => "PageData", "properties" => %{"name" => name}}, _breakpoints)
       when is_binary(name),
       do: {:ok, name}

  defp term(%{"type" => "Breakpoint", "properties" => %{"breakpoint_id" => id}} = bp, breakpoints)
       when is_binary(id),
       do: {:ok, width(bp, breakpoints) || "breakpoint #{id}"}

  defp term(_, _breakpoints), do: :fallback

  # A breakpoint's width as Bubble shows it: a whole number of pixels
  # without decimals (`992`), else nil.
  defp width(%{"properties" => %{"breakpoint_id" => id}}, breakpoints)
       when is_binary(id) and is_map(breakpoints) do
    case Map.get(breakpoints, id) do
      w when is_integer(w) -> Integer.to_string(w)
      w when is_float(w) and w == trunc(w) -> Integer.to_string(trunc(w))
      w when is_float(w) -> Float.to_string(w)
      _ -> nil
    end
  end

  defp width(_bp, _breakpoints), do: nil

  defp humanize(op), do: String.replace(op, "_", " ")
end
