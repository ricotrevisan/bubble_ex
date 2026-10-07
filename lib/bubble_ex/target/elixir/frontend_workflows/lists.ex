defmodule BubbleEx.Target.Elixir.FrontendWorkflows.Lists do
  @moduledoc """
  Lowers the list operators of a page's data source (WTF-495) so that
  sorting and filtering a list of things run in the database, as Ash
  queries read as the current user, before the source is bound
  (`BubbleEx.Target.Elixir.FrontendWorkflows.Data`).

  `lower/1` rewrites Expression IR into IR (no target names):

    * a sort (`:sorted`, or a search's further sort keys) of a sorted
      search is one search sorted by several keys, the outermost first
      (a sort keeps the order of what it sorts among equal keys);
    * `:filtered` on a search, possibly sorted, is the search with the
      filter's constraints added (what the filter keeps of the whole
      search, not of its first page);
    * a sort of any other list of things is a search for the records of
      that list (`unique id is in`), sorted;
    * a count of searches of one type merged is one count of a search
      for either's records (a merge holds each record once);
    * `:filtered` on any other list of things keeps the list's order: a
      search for its records that meet the constraints intersected with
      the list (`:intersect` follows the second list's order, as Bubble's
      does, and keeps the search's records).

  The list a rewritten search reads is wrapped in `:pinned`: the binding
  computes it first, in Elixir, and passes its things' IDs into the
  query (`BubbleData.pin/2`). Lists of other values (options, texts,
  numbers, dates) stay as they are: `BubbleEx.Target.Elixir` sorts and
  filters them.

  Each search reads what the current user may find, as any other search,
  so a record the list holds that the user may not find is not shown. A
  list that holds a thing twice shows it once once sorted or filtered
  (a search finds each record once).
  """

  alias BubbleEx.Expression.IR
  alias BubbleEx.Model.Type

  @doc "Rewrites the list operators of `ir` (see the moduledoc)."
  @spec lower(IR.t()) :: IR.t()
  def lower(%IR{op: :sort, args: [list, field, desc]} = ir) do
    list = lower(list)

    cond do
      search?(list) -> %{ir | args: [list, field, desc]}
      thing(list.type) -> %{ir | args: [records(list), field, desc]}
      true -> %{ir | args: [list, field, desc]}
    end
  end

  # Counting merged searches of one type is one count of either search
  # (`:or`): a merge holds each record once, and order does not count.
  def lower(%IR{op: :count, args: [list]} = ir) do
    list = lower(list)

    case union(list) do
      {:ok, %IR{} = search} -> %{ir | args: [search]}
      :error -> %{ir | args: [list]}
    end
  end

  def lower(%IR{op: :filter, args: [list, pred]} = ir) do
    list = lower(list)

    cond do
      search?(list) ->
        constrain(list, pred)

      thing(list.type) ->
        IR.node(:intersect, [constrain(records(list), pred), list], ir.type)
        |> Map.put(:path, ir.path)

      true ->
        %{ir | args: [list, pred]}
    end
  end

  # Predicates are not lists: a search inside one reads its own items.
  def lower(%IR{op: :search} = ir), do: ir

  def lower(%IR{args: args} = ir), do: %{ir | args: Enum.map(args, &lower_arg/1)}

  defp lower_arg(%IR{} = arg), do: lower(arg)
  defp lower_arg(arg), do: arg

  # Searches merged (sorted or not) of one data type as one search.
  defp union(%IR{op: :merge, args: [a, b], type: type}) do
    with {:ok, %IR{op: :search, args: [t, p1]}} <- union(a),
         {:ok, %IR{op: :search, args: [^t, p2]}} <- union(b) do
      pred = if is_nil(p1) or is_nil(p2), do: nil, else: IR.node(:or, [p1, p2], "boolean")
      {:ok, IR.node(:search, [t, pred], type)}
    else
      _ -> :error
    end
  end

  defp union(%IR{op: :sort, args: [inner | _]}), do: union(inner)
  defp union(%IR{op: :search} = ir), do: {:ok, ir}
  defp union(_ir), do: :error

  @doc "Whether `ir` is a search, sorted or not (what a query reads whole)."
  @spec search?(IR.t()) :: boolean()
  def search?(%IR{op: :search}), do: true
  def search?(%IR{op: :sort, args: [inner | _]}), do: search?(inner)
  def search?(_ir), do: false

  @doc """
  Whether `search` (sorted or not) reads the records of a list (`records/1`):
  what the user may view of them, as reading the list's things by ID does,
  not what they may find in searches.
  """
  @spec listed?(IR.t()) :: boolean()
  def listed?(%IR{op: :sort, args: [inner | _]}), do: listed?(inner)

  def listed?(%IR{op: :search, args: [_type, %IR{op: :and, args: [first | _]}]}),
    do: pinned_member?(first)

  def listed?(%IR{op: :search, args: [_type, pred]}), do: pinned_member?(pred)
  def listed?(_ir), do: false

  defp pinned_member?(%IR{op: :member, args: [%IR{op: :pinned}, %IR{op: :this}]}), do: true
  defp pinned_member?(_pred), do: false

  # The constraints of a `:filtered` added to the search it filters
  # (under its sorts).
  defp constrain(%IR{op: :sort, args: [inner | rest]} = ir, pred),
    do: %{ir | args: [constrain(inner, pred) | rest]}

  defp constrain(ir, nil), do: ir

  defp constrain(%IR{op: :search, args: [type, nil]} = ir, pred), do: %{ir | args: [type, pred]}

  defp constrain(%IR{op: :search, args: [type, %IR{op: :and, args: a}]} = ir, pred),
    do: %{ir | args: [type, IR.node(:and, a ++ conjuncts(pred), "boolean")]}

  defp constrain(%IR{op: :search, args: [type, p0]} = ir, pred),
    do: %{ir | args: [type, IR.node(:and, [p0 | conjuncts(pred)], "boolean")]}

  defp conjuncts(%IR{op: :and, args: args}), do: args
  defp conjuncts(pred), do: [pred]

  # A search for the records a list of things holds: `unique id is in`
  # the list, computed first (`:pinned`).
  defp records(%IR{type: type} = list) do
    {data_type, item_type} = thing(type)
    item = IR.node(:this, [:filter_item], item_type)
    pinned = IR.node(:pinned, [list], type)
    IR.node(:search, [data_type, IR.node(:member, [pinned, item], "boolean")], type)
  end

  # `{data type ID, item type}` of a list of things, else nil.
  defp thing(type) when is_binary(type) do
    case Type.classify(type) do
      {%Type{kind: :ref, cardinality: :many, target: target}, _} ->
        {target, String.replace_prefix(type, "list.", "")}

      _ ->
        nil
    end
  end

  defp thing(_type), do: nil
end
