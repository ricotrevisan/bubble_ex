defmodule BubbleEx.Frontend.Table do
  @moduledoc """
  Bubble's Table element in the normalized frontend (WTF-507), which keeps
  it and its parts as placeholder nodes with their Bubble properties:

    * `Table` - `data_source` (a dynamic table; none: a static one) and
      `group_type`
    * `TableMainAxis` - a column, ordered by `axis_index`
    * `TableCrossAxis` - a row, ordered by `axis_index`; a dynamic table
      repeats the one with `cross_axis_repeat` once per item of its list,
      the rows before it are its header and those after it its footer
    * `TableCell` - a cell of a row, in the column `cell_main_axis_id`
      names, a container of elements

  A target renders a table and its parts itself: only the repeated row of
  a dynamic table is a runtime template (its elements exist once per
  item). Its header and footer rows, and every row of a static table, are
  rendered once, like the page's own elements (`once/1`).
  """

  alias BubbleEx.Frontend.Normalized.Node

  @parts ~w(Table TableMainAxis TableCrossAxis TableCell)

  @doc "The table part a node is (`\"Table\"`, `\"TableCrossAxis\"`, …), or nil."
  @spec part(Node.t()) :: String.t() | nil
  def part(%Node{kind: :placeholder, attributes: %{"data-placeholder-kind" => kind}})
      when kind in @parts,
      do: kind

  def part(_node), do: nil

  @doc "Whether the node is a Table."
  @spec table?(Node.t()) :: boolean()
  def table?(node), do: part(node) == "Table"

  @doc "A part's own Bubble properties, as the normalizer keeps them."
  @spec props(Node.t()) :: map()
  def props(%Node{bindings: %{"plugin" => %{payload: %{"properties" => props}}}})
      when is_map(props),
      do: props

  def props(_node), do: %{}

  @doc "Whether a table has a data source (its rows repeat over a list)."
  @spec dynamic?(Node.t()) :: boolean()
  def dynamic?(node), do: Map.has_key?(props(node), "data_source")

  @doc "Whether a row is set to repeat once per item of its table's list."
  @spec repeats?(Node.t()) :: boolean()
  def repeats?(row), do: props(row)["cross_axis_repeat"] == true

  @doc "A table's columns, in order."
  @spec columns(Node.t()) :: [Node.t()]
  def columns(table), do: parts(table, "TableMainAxis")

  @doc "A table's rows, in order."
  @spec rows(Node.t()) :: [Node.t()]
  def rows(table), do: parts(table, "TableCrossAxis")

  @doc """
  A table's rows as `{header, repeated, footer}`: a dynamic table's rows
  before its (first) repeated row, that row (nil when none), the rows
  after it. A static table's rows are all in `header` (none repeats).
  """
  @spec split(Node.t()) :: {[Node.t()], Node.t() | nil, [Node.t()]}
  def split(table) do
    rows = rows(table)

    if dynamic?(table) do
      case Enum.split_while(rows, &(not repeats?(&1))) do
        {head, [repeated | foot]} -> {head, repeated, foot}
        {head, []} -> {head, nil, []}
      end
    else
      {rows, nil, []}
    end
  end

  @doc """
  The elements a table renders once (not per item): those in the cells of
  its rows other than the repeated one.
  """
  @spec once(Node.t()) :: [Node.t()]
  def once(table) do
    {head, _repeated, foot} = split(table)
    for row <- head ++ foot, cell <- row.children, element <- cell.children, do: element
  end

  @doc "A table's parts: its columns, rows and their cells."
  @spec structure(Node.t()) :: [Node.t()]
  def structure(table) do
    parts = Enum.filter(table.children, &(part(&1) in ~w(TableMainAxis TableCrossAxis)))

    parts ++
      Enum.flat_map(rows(table), fn row ->
        Enum.filter(row.children, &(part(&1) == "TableCell"))
      end)
  end

  defp parts(table, part),
    do: table.children |> Enum.filter(&(part(&1) == part)) |> Enum.sort_by(&axis_index/1)

  defp axis_index(node) do
    case props(node)["axis_index"] do
      n when is_number(n) -> n
      _ -> 0
    end
  end
end
