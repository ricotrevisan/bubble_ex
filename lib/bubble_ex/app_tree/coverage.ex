defmodule BubbleEx.AppTree.Coverage do
  @moduledoc """
  Rendered-vs-total counters for Layer 2 views. Partial rendering must never
  read as complete: anything not fully rendered counts against `rendered`.
  """

  @type t :: %{
          actions: %{total: non_neg_integer(), rendered: non_neg_integer()},
          expressions: %{total: non_neg_integer(), rendered: non_neg_integer()}
        }

  @spec zero() :: t()
  def zero, do: %{actions: %{total: 0, rendered: 0}, expressions: %{total: 0, rendered: 0}}

  @spec bump(t(), :actions | :expressions, boolean()) :: t()
  def bump(cov, dim, rendered?) when dim in [:actions, :expressions] do
    Map.update!(cov, dim, fn %{total: t, rendered: r} ->
      %{total: t + 1, rendered: r + if(rendered?, do: 1, else: 0)}
    end)
  end

  @spec merge(t(), t()) :: t()
  def merge(a, b) do
    Map.new([:actions, :expressions], fn dim ->
      {dim,
       %{
         total: a[dim].total + b[dim].total,
         rendered: a[dim].rendered + b[dim].rendered
       }}
    end)
  end
end
