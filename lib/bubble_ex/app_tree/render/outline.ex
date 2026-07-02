defmodule BubbleEx.AppTree.Render.Outline do
  @moduledoc """
  Layer 2: OUTLINE.md — the indented element tree of a page or component.
  Generated, never hand-edited; anything below full fidelity points at the
  Layer-1 raw file.
  """

  alias BubbleEx.AppTree.{Coverage, Expr, Names}

  @spec render(map(), %{title: String.t(), raw: String.t()}) :: {iodata(), Coverage.t()}
  def render(container, %{title: title, raw: raw}) do
    {lines, coverage} = walk_children(container["elements"], 0, raw, Coverage.zero())

    header = "# Outline: #{title}\n\n_Generated from #{raw} — do not edit._\n"
    body = if lines == [], do: "", else: "\n" <> Enum.join(lines, "\n") <> "\n"
    {[header, body], coverage}
  end

  defp walk_children(nil, _depth, _raw, coverage), do: {[], coverage}

  defp walk_children(elements, _depth, _raw, coverage) when not is_map(elements),
    do: {[], coverage}

  defp walk_children(elements, depth, raw, coverage) when is_map(elements) do
    elements
    |> Enum.filter(fn {_, el} -> is_map(el) end)
    |> Enum.sort_by(fn {_, el} -> order_of(el) end)
    |> Enum.reduce({[], coverage}, fn {_, el}, {lines, cov} ->
      {el_lines, cov} = element_lines(el, depth, raw, cov)
      {children, cov} = walk_children(el["elements"], depth + 1, raw, cov)
      {lines ++ el_lines ++ children, cov}
    end)
  end

  defp order_of(%{"properties" => %{"order" => order}}) when is_number(order), do: order
  defp order_of(_), do: 1_000_000

  defp element_lines(el, depth, raw, coverage) do
    indent = String.duplicate("  ", depth)
    name = Names.element_name(el) || "?"
    style = if is_binary(el["style"]), do: " (style: #{el["style"]})", else: ""

    {text_part, coverage} = text_part(el["properties"]["text"], raw, coverage)
    line = "#{indent}- [#{el["type"]}] #{name}#{style}#{text_part}"

    {state_lines, coverage} = state_lines(el["states"], indent, raw, coverage)
    {[line | state_lines], coverage}
  end

  defp text_part(nil, _raw, coverage), do: {"", coverage}

  defp text_part(text, raw, coverage) do
    case Expr.render_text(text) do
      {:ok, s} ->
        {~s( => "#{s}"), Coverage.bump(coverage, :expressions, true)}

      {:partial, s} ->
        {~s( => "#{s}"), Coverage.bump(coverage, :expressions, false)}

      :fallback ->
        {" => ⟨unrendered expression — see #{raw}⟩", Coverage.bump(coverage, :expressions, false)}
    end
  end

  defp state_lines(nil, _indent, _raw, coverage), do: {[], coverage}

  defp state_lines(states, indent, raw, coverage) when is_map(states) do
    states
    |> Enum.filter(fn {_, s} -> is_map(s) and is_map(s["condition"]) end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.reduce({[], coverage}, fn {_, state}, {lines, cov} ->
      changed =
        state["properties"] |> Kernel.||(%{}) |> Map.keys() |> Enum.sort() |> Enum.join(", ")

      case Expr.render_condition(state["condition"]) do
        {:ok, cond_text} ->
          {lines ++ ["#{indent}  - when #{cond_text}: #{changed}"],
           Coverage.bump(cov, :expressions, true)}

        :fallback ->
          {lines ++ ["#{indent}  - conditional state (see #{raw})"],
           Coverage.bump(cov, :expressions, false)}
      end
    end)
  end
end
