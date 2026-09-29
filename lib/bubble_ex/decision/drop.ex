defmodule BubbleEx.Decision.Drop do
  @moduledoc """
  The owner's decision to drop a symbol from the migration (WTF-422): a
  page, data type, field, option set or workflow the generated project
  deliberately leaves out. A drop is a `BubbleEx.Decision` of kind `:drop`
  (never a free-form skip): keyed to the symbol ID, with a rationale,
  resolved by `BubbleEx.Decision.resolve/3` like every decision.

  | `params.symbol` | subject | drops |
  |-----------------|---------|-------|
  | `:data_type` | `%{type}` | the type, its fields, every relationship to it |
  | `:field` | `%{type, field}` | the field (not a built-in one) |
  | `:option_set` | `%{option_set}` | the set, its values and attributes |
  | `:page` | `%{page}` | the page (not a reusable element), its elements and workflows |
  | `:workflow` | `%{workflow}` | the workflow and its actions |

  The built-in User type and built-in fields (`_id`, Created Date, …) cannot
  be dropped.

  ## Dangling references (fail-safe default: block)

  A field of a type that is kept whose values reference a dropped data type
  or option set would dangle. Such a reference **blocks**
  (`BubbleEx.Decision.Resolved.blocking/1` lists the drop with
  `:dangling_references`, and `BubbleEx.Target.Ash` reports an
  `:ash_drop_dangling_reference` error) unless the referencing field is
  dropped too, or the owner accepts it explicitly by listing its symbol ID
  in `params.dangling`: the field then keeps its Bubble IDs as plain
  strings, with no relationship (a warning). A reference added later is not
  covered by an earlier acceptance: it blocks until the owner lists it.

  A workflow calling or scheduling a dropped workflow does not block: the
  calling step is residue (`:uses_dropped`) and its generated body refuses to
  run before step 1 until someone rewrites it.

  ## Basis

  `basis.basis_sha256` is `BubbleEx.Index.subject_sha256/2` of `symbols/1`
  (the dropped symbol and the accepted dangling fields), so a drop made
  against another version of them is `:stale`.
  """

  alias BubbleEx.Index
  alias BubbleEx.Index.Symbol

  @symbols [:data_type, :field, :option_set, :page, :workflow]

  # Subject shape (sorted keys) per dropped symbol kind.
  @shapes %{
    data_type: [:type],
    field: [:field, :type],
    option_set: [:option_set],
    page: [:page],
    workflow: [:workflow]
  }

  # What a dangling reference may come from: a field or an option set
  # attribute whose value type names the dropped symbol.
  @dangling_kinds ["field", "option_attribute"]

  @doc "The symbol kinds a drop may name."
  @spec symbols() :: [atom()]
  def symbols, do: @symbols

  @doc "The subject shape (sorted keys) of a drop of `symbol` kind."
  @spec shape(atom()) :: [atom()] | nil
  def shape(symbol), do: Map.get(@shapes, symbol)

  @doc "The symbol ID a drop's subject names."
  @spec symbol_id(atom(), map()) :: String.t()
  def symbol_id(:data_type, %{type: t}), do: Symbol.id(:data_type, t)
  def symbol_id(:field, %{type: t, field: f}), do: Symbol.id(:field, [t, f])
  def symbol_id(:option_set, %{option_set: s}), do: Symbol.id(:option_set, s)
  def symbol_id(:page, %{page: p}), do: Symbol.id(:page, p)
  def symbol_id(:workflow, %{workflow: w}), do: Symbol.id(:workflow, w)

  @doc "The subject of a symbol a drop may name, with its kind, or `:error`."
  @spec subject(Symbol.t()) :: {:ok, atom(), map()} | :error
  def subject(%Symbol{kind: :data_type, bubble_id: t}), do: {:ok, :data_type, %{type: t}}

  def subject(%Symbol{kind: :field, id: id}) do
    case split(id) do
      [t, f] -> {:ok, :field, %{type: t, field: f}}
      _ -> :error
    end
  end

  def subject(%Symbol{kind: :option_set, bubble_id: s}), do: {:ok, :option_set, %{option_set: s}}
  def subject(%Symbol{kind: :page, bubble_id: p}), do: {:ok, :page, %{page: p}}
  def subject(%Symbol{kind: :workflow, bubble_id: w}), do: {:ok, :workflow, %{workflow: w}}
  def subject(_), do: :error

  defp split("field:" <> rest) do
    rest
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
  end

  @doc "Whether `id` may be listed as an accepted dangling reference."
  @spec dangling_id?(term()) :: boolean()
  def dangling_id?(id) when is_binary(id) do
    case String.split(id, ":", parts: 2) do
      [kind, rest] -> kind in @dangling_kinds and rest != ""
      _ -> false
    end
  end

  def dangling_id?(_), do: false

  @doc """
  The symbols a drop's basis hashes: the dropped symbol and the accepted
  dangling references, sorted.
  """
  @spec symbols(%{params: map(), subject: map()}) :: [String.t()]
  def symbols(%{params: %{symbol: symbol} = params, subject: subject}),
    do: Enum.sort(Enum.uniq([symbol_id(symbol, subject) | Map.get(params, :dangling, [])]))

  @doc "`basis_sha256` of a drop of `symbol` with `dangling` in `index`."
  @spec basis_sha256(Index.t(), atom(), map(), [String.t()]) :: String.t()
  def basis_sha256(%Index{} = index, symbol, subject, dangling),
    do:
      Index.subject_sha256(
        index,
        symbols(%{params: %{symbol: symbol, dangling: dangling}, subject: subject})
      )

  @doc """
  Why the symbol cannot be dropped in `index`, or nil: `:subject_gone` (not
  in the index, or deleted), `:not_droppable` (the User type, a built-in
  field, a mobile view).
  """
  @spec refusal(Index.t(), atom(), map()) :: :subject_gone | :not_droppable | nil
  def refusal(%Index{} = index, symbol, subject) do
    case Index.symbol(index, symbol_id(symbol, subject)) do
      nil -> :subject_gone
      %Symbol{attrs: %{deleted: true}} -> :subject_gone
      s -> if droppable?(s), do: nil, else: :not_droppable
    end
  end

  defp droppable?(%Symbol{kind: :data_type, bubble_id: "user"}), do: false
  defp droppable?(%Symbol{kind: :field, attrs: %{builtin: _}}), do: false
  defp droppable?(%Symbol{kind: :page, attrs: %{section: "mobile_views"}}), do: false
  defp droppable?(%Symbol{}), do: true

  @doc """
  Every symbol ID `drops` remove from `index`: each dropped symbol and its
  descendants (a type's fields, a set's values and attributes, a page's
  elements and workflows, a workflow's actions). `drops` are
  `%{params: %{symbol: kind}, subject: subject}` maps (decisions or
  applied entries).
  """
  @spec removed(Index.t(), [map()]) :: MapSet.t(String.t())
  def removed(%Index{} = index, drops) do
    drops
    |> Enum.map(&symbol_id(&1.params.symbol, &1.subject))
    |> Enum.reduce(MapSet.new(), fn id, acc -> descend(index, id, acc) end)
  end

  defp descend(index, id, acc) do
    if MapSet.member?(acc, id) do
      acc
    else
      index
      |> Index.children(id)
      |> Enum.reduce(MapSet.put(acc, id), &descend(index, &1.id, &2))
    end
  end

  @doc """
  The references to a dropped data type or option set from fields and
  option set attributes that are kept (not removed by `drops`, not deleted,
  not of a deleted type or set), as sorted symbol IDs: the dangling
  references of `drop`. Other symbol kinds have none.
  """
  @spec referencing(Index.t(), map(), MapSet.t(String.t())) :: [String.t()]
  def referencing(%Index{} = index, %{params: %{symbol: symbol}, subject: subject}, removed)
      when symbol in [:data_type, :option_set] do
    index
    |> Index.references_to(symbol_id(symbol, subject), [:field_type])
    |> Enum.map(& &1.from)
    |> Enum.uniq()
    |> Enum.filter(&kept?(index, &1, removed))
    |> Enum.sort()
  end

  def referencing(_index, _drop, _removed), do: []

  defp kept?(index, id, removed) do
    case Index.symbol(index, id) do
      %Symbol{kind: kind} = s when kind in [:field, :option_attribute] ->
        not MapSet.member?(removed, id) and not deleted?(s) and
          not deleted?(Index.symbol(index, s.parent))

      _ ->
        false
    end
  end

  defp deleted?(%Symbol{attrs: %{deleted: true}}), do: true
  defp deleted?(_), do: false

  @doc """
  Checks an applied drop (`BubbleEx.Decision.Applied` of kind `:drop`)
  against itself and, with an index, against the snapshot: its key is the
  drop's of its subject, its parameters fit, its `basis` is the
  `basis_sha256` it carries and, with `index`, the symbol is in the index,
  droppable, and hashes to it. Anything else is stale or forged
  (`{:error, reason}`); generators refuse it.
  """
  @spec check_applied(struct(), Index.t() | nil) :: :ok | {:error, atom()}
  def check_applied(%{kind: :drop, params: %{symbol: symbol}} = a, index)
      when is_map(a.subject) do
    checks = [
      {:identity, fn -> identity?(a) end},
      {:params, fn -> dangling_param?(symbol, Map.get(a.params, :dangling, [])) end},
      {:key, fn -> a.key == key(symbol, a.subject) end},
      {:basis, fn -> basis?(a) end}
    ]

    case Enum.find(checks, fn {_, check} -> not check.() end) do
      {reason, _} -> {:error, reason}
      nil when index == nil -> :ok
      nil -> against(a, index)
    end
  end

  def check_applied(_a, _index), do: {:error, :identity}

  defp identity?(%{transform: transform, params: %{symbol: symbol}, subject: subject}),
    do: transform == :drop and shape(symbol) != nil and shape(symbol) == subject_shape(subject)

  defp subject_shape(subject), do: subject |> Map.keys() |> Enum.sort()

  defp dangling_param?(symbol, dangling) when is_list(dangling) do
    Enum.all?(dangling, &dangling_id?/1) and Enum.sort(Enum.uniq(dangling)) == dangling and
      (dangling == [] or symbol in [:data_type, :option_set])
  end

  defp dangling_param?(_symbol, _dangling), do: false

  defp basis?(%{basis_sha256: sha, basis: basis}),
    do: is_binary(sha) and sha =~ ~r/\A[0-9a-f]{64}\z/ and basis == %{basis_sha256: sha}

  # The applied drop against the snapshot: droppable there, and hashing to
  # its basis.
  defp against(a, index) do
    case refusal(index, a.params.symbol, a.subject) do
      nil ->
        if Index.subject_sha256(index, symbols(a)) == a.basis_sha256,
          do: :ok,
          else: {:error, :basis_changed}

      why ->
        {:error, why}
    end
  end

  @doc "The key of a drop of `symbol` with `subject` (see `BubbleEx.Decision.key/1`)."
  @spec key(atom(), map()) :: String.t()
  def key(symbol, subject) do
    BubbleEx.Decision.key(%BubbleEx.Decision{
      key: "",
      kind: :drop,
      revision: 1,
      subject: subject,
      choice: :accept,
      params: %{symbol: symbol, dangling: []}
    })
  end

  @doc """
  What dropping `symbol_id` would break in `index`, for an impact preview:
  Bubble IDs and counts only, no names.

    * `symbol`, `kind` - the symbol and its kind
    * `refusal` - nil, `:subject_gone` or `:not_droppable`
    * `removed` - the symbol IDs the drop removes (itself and descendants)
    * `dangling` - fields and attributes that reference it (they block
      unless dropped or accepted)
    * `callers` - workflows calling or scheduling a dropped workflow
    * `dependents` - every other kept symbol referencing a removed one
      (reads, writes, navigation, …), sorted
  """
  @spec impact(Index.t(), String.t()) :: {:ok, map()} | :error
  def impact(%Index{} = index, symbol_id) when is_binary(symbol_id) do
    with %Symbol{} = s <- Index.symbol(index, symbol_id),
         {:ok, kind, subject} <- subject(s) do
      drop = %{params: %{symbol: kind}, subject: subject}
      removed = removed(index, [drop])

      callers =
        for id <- removed,
            String.starts_with?(id, "workflow:"),
            call <- Index.callers(index, id),
            not MapSet.member?(removed, call.workflow),
            uniq: true,
            do: call.workflow

      dependents =
        for id <- removed,
            ref <- Index.references_to(index, id),
            not MapSet.member?(removed, ref.from),
            uniq: true,
            do: ref.from

      {:ok,
       %{
         symbol: symbol_id,
         kind: kind,
         refusal: refusal(index, kind, subject),
         removed: removed |> MapSet.to_list() |> Enum.sort(),
         dangling: referencing(index, drop, removed),
         callers: Enum.sort(callers),
         dependents: Enum.sort(dependents)
       }}
    else
      _ -> :error
    end
  end
end
