defmodule BubbleEx.Target.Elixir.FrontendWorkflows.Data do
  @moduledoc """
  Binds a page's data sources (`BubbleEx.PageData`, WTF-420) to Ash reads
  for Phoenix LiveView, as part of
  `BubbleEx.Target.Elixir.FrontendWorkflows.map/3` (`page_data:`).

  Each source becomes plain data in the spec (see
  `BubbleEx.Target.Elixir.FrontendWorkflows.Spec`):

    * a page's thing reads the record whose Bubble ID is the URL's path
      segment (`read: :url_thing`)
    * a search (with its constraints and sort, optionally under `first
      item`, `item #n`, `items until #n` or `count`) is an Ash query on
      the searched resource (`read: {:query, query}`): the filter is a
      `BubbleEx.Target.Ash.Expr` from `BubbleEx.Target.Ash.Expressions`
      whose context inputs, and whatever it reads from the actor, are
      `{:pin, var}` variables bound from the page like a workflow's
      values (`pins`); a value the filter cannot read itself (a field of
      a group's thing) is computed in Elixir first and pinned
    * any other data source is an Elixir value
      (`BubbleEx.Target.Elixir`, `read: {:value, compiled}`); a thing or a
      list of things may be records or Bubble IDs, which the runtime reads
      through Ash (`resource`)
    * list operators are lowered first (WTF-495,
      `BubbleEx.Target.Elixir.FrontendWorkflows.Lists`): sorting and
      filtering a list of things are queries; a search under any other
      operator is a query read first (`queries`, each `%{n, ...}` read as
      `query_<n>`, a query's own shape), its value compiled in Elixir;
      a query for the records a list holds is `listed` (read as the user
      may view them). A value the Ash filter cannot compute (a list
      operator, a search, a dynamic text) is computed in Elixir and
      pinned when the filter needs it
    * an element with no data source that a "Display data" step sets
      (WTF-492, `ctx.displayed`) reads what the step showed
      (`read: :displayed`); every source a step sets is `displayed?`

  What a source reads of the page is bound as a workflow's values are
  (`BubbleEx.Target.Elixir.FrontendWorkflows`), plus the page's data:
  `{:data, key}` (a page's thing, a group's, a repeating group's list or
  an instance's thing, `key` `%{path, element}` as a custom state's),
  `{:cell, rg}`, `{:cell_index, rg}` and `{:cell_data, group}` (in a
  repeating group's cell).

  A reusable element's property (WTF-493) is page data too: the value an
  instance sets is a source of the instance's surface, kept under the
  instance (`key` `%{path: [instance], element: key}`, `key` from
  `Spec.param_key/2`: property IDs are unique only within a reusable
  element), and its default a source of the reusable element, kept where
  the instance's would be (`%{path: [], element: key}`), read only when
  the instance sets none. "This Reusable's <property>" reads
  `{:data, %{path: [], element: key}}`: it loads when every
  instance's value of it (those rendered per cell included) and its
  default load. A thing it holds is read where the instance is, through
  Ash with the actor, like any other source.

  A reusable instance in a repeating group's cell (WTF-494) is rendered
  once per cell, in a scope of its own (the cell's thing's): its own
  data source and the properties it sets are computed per cell (they
  read the cell's thing as `{:cell, rg}`, and depend on the list), and
  its reusable element's sources run in each cell's scope. The runtime
  reads a source for every cell together (`shared?`: one that reads
  nothing of its scope, only the current user, the time or the URL, is
  read once), so a search there must be shared: a reusable element (or
  one it nests) with a search that reads its instance would query once
  per cell, and its instances in cells are not rendered per cell
  (`cell_instances/4`), nor is one whose own data source is a search.

  ## Residue added here

    * `:page_data_in_cell` - a repeating group in a repeating group's
      cell, or a search there: the page would read once per cell
      (`detail.kind` `"list"` or `"query"`); a reusable instance in a cell
      whose reusable element has a search reading its instance
      (`"query"`, on the instance's sources)
    * `:uncompiled_expression` - constructs prefixed `ash:` (a search the
      Ash filter compiler rejects) or `elixir:`
    * `:unavailable_input` - an input the page does not provide, or
      another data source that is not loaded (`inputs: ["data_source"]`)
    * `:unresolved_reference` (`detail.target` `"ash"`) - a type the Ash
      project does not map; `reference: "data_source"` for sources that
      read each other in a cycle
  """

  alias BubbleEx.Expression.IR
  alias BubbleEx.Model.Type
  alias BubbleEx.PageData
  alias BubbleEx.PageData.Source
  alias BubbleEx.Plan.Residue
  alias BubbleEx.Target.Ash.{Expr, Expressions, Project}
  alias BubbleEx.Target.Elixir.FrontendWorkflows.{Lists, Spec}
  alias BubbleEx.Workflows.Lowering

  # Values the Ash filter does not compute: computed in Elixir and pinned
  # when the filter needs them (see `hoistable?/2`).
  @elixir_values ~w(search filter sort merge unique minus_item plus_item minus_list intersect
                    limit item_at first last count as_list concat date_add split truncate replace
                    format_date format_number format_boolean to_text)a

  @doc """
  The page's data holders (every source that lowered, and every element a
  "Display data" step shows data in, `displayed`: element => `%{kind,
  surface, cell, holder}`), for binding reads before the sources
  themselves are bound; nil page data has none but the displayed ones.
  """
  @spec index(PageData.t() | nil, map()) :: map()
  def index(page_data, displayed \\ %{})

  def index(nil, displayed),
    do:
      with_displayed(
        %{elements: %{}, roots: MapSet.new(), params: %{}, set: %{}},
        displayed,
        MapSet.new()
      )

  def index(%PageData{sources: sources}, displayed) do
    elements =
      for s <- sources,
          s.kind != :param,
          Source.native?(s),
          into: %{},
          do: {s.element, %{kind: s.kind, surface: s.surface, cell: s.cell, holder: s.holder}}

    %{elements: elements, roots: roots(sources)}
    |> Map.merge(params(sources, &Source.native?/1))
    |> with_displayed(displayed, own_elements(sources))
  end

  # The elements with a data source of their own (a property's value is
  # not the instance's thing: "Display data" may still set that).
  defp own_elements(sources),
    do: for(s <- sources, s.kind != :param, into: MapSet.new(), do: s.element)

  # The reusable element properties (WTF-493): `params`, the property's
  # key (`Spec.param_key/2`) => whether every value of it (each
  # instance's, those of instances rendered per cell included, WTF-494,
  # and its default) loads; `set`, `{instance, param} => %{surface, key}`
  # for the values instances outside a cell set that load.
  defp params(sources, loads?) do
    # The lists that load: an instance in the cell of another is never
    # rendered.
    lists =
      for s <- sources, s.kind == :list, loads?.(s), into: MapSet.new(), do: s.element

    values = Enum.filter(sources, &counted_param?(&1, lists))

    %{
      params:
        values
        |> Enum.group_by(&Spec.param_key(&1.holder, &1.param))
        |> Map.new(fn {key, ss} -> {key, Enum.all?(ss, loads?)} end),
      set:
        for(
          s <- values,
          s.cell == nil,
          s.element != s.holder,
          loads?.(s),
          into: %{},
          do:
            {{s.element, s.param}, %{surface: s.surface, key: Spec.param_key(s.holder, s.param)}}
        )
    }
  end

  # A property value the reusable element's reads depend on: any but those
  # of an instance in a cell that is not rendered per cell (the list is
  # not loaded, or the instance cannot be read per cell): its values are
  # never read.
  defp counted_param?(%{kind: :param, cell: nil}, _lists), do: true

  defp counted_param?(%{kind: :param, cell: cell, residue: residue}, lists) do
    MapSet.member?(lists, cell) and not Enum.any?(residue, &(&1.reason == :page_data_in_cell))
  end

  defp counted_param?(_source, _lists), do: false

  # A displayed element with no source of its own (WTF-492) holds what the
  # step shows; one with a source keeps the source's entry. A source that
  # did not lower stays unread: its element is not added.
  defp with_displayed(index, displayed, own) do
    displayed
    |> Enum.reject(fn {element, _} -> MapSet.member?(own, element) end)
    |> Enum.reduce(index, fn {element, holder}, acc ->
      entry = Map.take(holder, [:kind, :surface, :cell, :holder])
      %{acc | elements: Map.put(acc.elements, element, entry), roots: root(acc.roots, holder)}
    end)
  end

  defp root(roots, %{kind: :instance, holder: holder}) when is_binary(holder),
    do: MapSet.put(roots, holder)

  defp root(roots, _holder), do: roots

  @doc """
  The Ash resource (relative module) of a thing or list-of-things type
  (`"custom.task"`, `"list.custom.task"`), or nil.
  """
  @spec resource_of_type(String.t() | nil, map()) :: String.t() | nil
  def resource_of_type(type, ctx), do: resource(type, ctx)

  # Reusable elements an instance gives their thing to.
  defp roots(sources),
    do:
      for(%Source{kind: :instance, holder: h} <- sources, is_binary(h), into: MapSet.new(), do: h)

  @doc """
  How the page supplies `input` read in `surface` (inside the cell of the
  repeating group `cell`, or nil): `{:ok, bind}` or `{:error, kind}`. See
  `BubbleEx.Target.Elixir.FrontendWorkflows.Spec.data_read/4`.
  """
  @spec read(map(), String.t(), String.t() | nil, term()) :: {:ok, term()} | {:error, String.t()}
  defdelegate read(index, surface, cell, input),
    to: BubbleEx.Target.Elixir.FrontendWorkflows.Spec,
    as: :data_read

  @doc "The index of the bound sources that load (no residue)."
  @spec wired_index(%{String.t() => [map()]}) :: map()
  def wired_index(bound) do
    wired = for {_surface, list} <- bound, b <- list, b.residue == [], do: b

    all = for {_surface, list} <- bound, b <- list, do: b

    Map.merge(
      %{
        elements:
          for(
            b <- wired,
            b.kind != :param,
            into: %{},
            do: {b.element, %{kind: b.kind, surface: b.surface, cell: b.cell, holder: b.holder}}
          ),
        roots:
          for(%{kind: :instance, holder: h} <- wired, is_binary(h), into: MapSet.new(), do: h)
      },
      params(all, &(&1.residue == []))
    )
  end

  @doc """
  Binds every source of `page_data`. `ctx` is the frontend workflows
  binding's context (with `:project`, `:data` from `index/1`, and
  `:nested`, see `cell_instances/4`); `fns` has
  `compile` (`fn expr, subject, ctx -> {compiled | nil, residue}`) and
  `bind` (`fn input, ctx -> {:ok, bind} | {:error, kind}`), the binding's
  own. Returns the bound sources by surface, in the order the page reads
  them (a source after those it reads).
  """
  @spec bind(PageData.t() | nil, map(), map()) :: %{String.t() => [map()]}
  def bind(page_data, ctx, fns) do
    displayed = Map.get(ctx, :displayed, %{})
    sources = if page_data, do: page_data.sources, else: []
    own = own_elements(sources)

    # A "Display data" step sets an element's own thing, never a property
    # of an instance (WTF-493: those stay the parent's values).
    bound =
      Enum.map(sources, fn s ->
        s
        |> source(ctx, fns)
        |> Map.put(:displayed?, s.kind != :param and Map.has_key?(displayed, s.element))
      end)

    shown =
      for {element, holder} <- Enum.sort(displayed),
          not MapSet.member?(own, element),
          do: displayed_source(element, holder, ctx)

    (bound ++ shown)
    |> prune()
    |> per_cell(ctx)
    |> Enum.map(&Map.put(&1, :shared?, &1.residue == [] and shared?(&1)))
    |> Enum.group_by(& &1.surface)
    |> Map.new(fn {surface, bound} -> {surface, order(bound)} end)
  end

  # --- instances in cells (WTF-494) ----------------------------------------------------

  # An instance in a cell that would query once per cell is not rendered
  # per cell: its own sources are residue, and so is what reads them.
  defp per_cell(bound, ctx) do
    blocked = not_per_cell(bound, Map.get(ctx, :nested, %{}))

    if MapSet.size(blocked) == 0,
      do: bound,
      else: bound |> Enum.map(&block_in_cell(&1, blocked)) |> prune()
  end

  defp block_in_cell(%{cell: cell, kind: kind, residue: []} = b, blocked)
       when is_binary(cell) and kind in [:instance, :param] do
    if MapSet.member?(blocked, b.element),
      do: %{b | read: nil, residue: [in_cell_entry(b.symbol, :query)]},
      else: b
  end

  defp block_in_cell(b, _blocked), do: b

  # The instances in cells that cannot be read for every cell together:
  # their own data source is a search (once per cell), or their reusable
  # element's would be.
  defp not_per_cell(bound, nested) do
    holders = per_cell_blocked(bound, nested)

    for %{cell: cell, kind: kind} = b <- bound,
        is_binary(cell) and kind in [:instance, :param],
        MapSet.member?(holders, b.holder) or
          (kind == :instance and Enum.any?(b.residue, &(&1.reason == :page_data_in_cell))),
        into: MapSet.new(),
        do: b.element
  end

  # The reusable elements that cannot be read for every cell together: a
  # search of theirs (or of a reusable element they nest, outside its own
  # cells) that reads something of the instance's scope.
  defp per_cell_blocked(bound, nested) do
    direct =
      for %{residue: [], read: {:query, _}, cell: nil} = b <- bound,
          not shared?(b),
          into: MapSet.new(),
          do: b.surface

    reusables =
      bound |> Enum.map(& &1.surface) |> Enum.concat(Map.keys(nested)) |> Enum.uniq()

    for r <- reusables, blocked?(r, direct, nested, MapSet.new()), into: MapSet.new(), do: r
  end

  defp blocked?(r, direct, nested, seen) do
    cond do
      MapSet.member?(direct, r) ->
        true

      MapSet.member?(seen, r) ->
        false

      true ->
        nested
        |> Map.get(r, [])
        |> Enum.any?(&blocked?(&1, direct, nested, MapSet.put(seen, r)))
    end
  end

  @doc """
  Whether a bound source reads nothing of the scope it runs in (an
  instance's, a cell's): only the current user, the current time or the
  URL. The runtime reads it once for every cell of a repeating group
  (WTF-494).
  """
  @spec shared?(map()) :: boolean()
  def shared?(%{cell: nil, read: {kind, _}} = b) when kind in [:value, :query],
    do: b |> read_bindings() |> Enum.all?(&unscoped?/1)

  def shared?(_bound), do: false

  defp read_bindings(%{read: {:value, %{bindings: bindings}}}), do: bindings

  defp read_bindings(%{read: {:query, %{pins: pins}}}),
    do: for(%{value: %{bindings: bindings}} <- pins, b <- bindings, do: b)

  defp unscoped?(%{bind: bind}), do: bind in [:actor, :now] or match?({:url, _}, bind)

  @doc """
  The instances in repeating group cells (`structure`: instance =>
  `%{surface, cell, holder}`) with whether the page renders each per cell
  (WTF-494): `%{surface, cell, holder, residue}`, `residue` empty when it
  does. It needs the list loaded (`wired`, from `wired_index/1`) and a
  reusable element read for every cell together (`bound`, by surface;
  `nested`: reusable => the reusable elements of its instances outside
  its cells).
  """
  @spec cell_instances(map(), %{String.t() => [map()]}, map(), map()) :: map()
  def cell_instances(structure, bound, wired, nested) do
    all = for {_surface, list} <- bound, b <- list, do: b
    blocked = not_per_cell(all, nested)
    holders = per_cell_blocked(all, nested)

    Map.new(structure, fn {instance, %{surface: surface, cell: rg, holder: holder} = s} ->
      symbol = "element:" <> instance

      residue =
        cond do
          not match?(%{kind: :list, cell: nil, surface: ^surface}, wired.elements[rg]) ->
            [Residue.entry(symbol, :unavailable_input, %{inputs: ["data_source"]})]

          MapSet.member?(blocked, instance) or MapSet.member?(holders, holder) ->
            [in_cell_entry(symbol, :query)]

          true ->
            []
        end

      {instance, Map.put(s, :residue, residue)}
    end)
  end

  # --- one source ---------------------------------------------------------------------

  defp source(%Source{} = s, ctx, fns) do
    base = %{
      element: s.element,
      symbol: s.id,
      kind: s.kind,
      surface: s.surface,
      cell: s.cell,
      holder: s.holder,
      param: s.param,
      key: key(s),
      type: s.type,
      list?: list?(s),
      page_size: s.page_size,
      resource: nil,
      read: nil,
      reads: [],
      residue: s.residue
    }

    cond do
      s.residue != [] ->
        base

      # A repeating group in a cell would read once per cell; a group, an
      # instance (WTF-494) and its properties there are read per cell.
      s.cell != nil and s.kind == :list ->
        in_cell(base, s.kind)

      s.kind == :page_thing ->
        case resource(s.type, ctx) do
          nil -> %{base | residue: [unmapped(s.id, "data_type")]}
          module -> %{base | resource: module, read: :url_thing}
        end

      true ->
        value(s, base, ctx, fns)
    end
  end

  # A list's value, or a property holding a list.
  defp list?(%Source{kind: :list}), do: true

  defp list?(%Source{kind: :param, type: type}),
    do: match?(%Type{cardinality: :many}, classify(type))

  defp list?(_source), do: false

  # An element with no data source of its own whose data a "Display data"
  # step sets (WTF-492): read from what the step showed, re-read as the
  # current user (`read: :displayed`).
  defp displayed_source(element, holder, ctx) do
    %{
      element: element,
      symbol: "element:" <> element,
      kind: holder.kind,
      surface: holder.surface,
      cell: holder.cell,
      holder: holder.holder,
      param: nil,
      key:
        if(holder.kind == :instance,
          do: %{path: [element], element: holder.holder},
          else: %{path: [], element: element}
        ),
      type: holder.type,
      list?: holder.kind == :list,
      page_size: holder.page_size,
      resource: resource(holder.type, ctx),
      read: :displayed,
      reads: [],
      residue: [],
      displayed?: true
    }
  end

  defp key(%Source{kind: :instance, element: e, holder: holder}),
    do: %{path: [e], element: holder}

  # A property's default is kept where the instance's value would be.
  defp key(%Source{kind: :param, element: e, holder: e, param: p}),
    do: %{path: [], element: Spec.param_key(e, p)}

  defp key(%Source{kind: :param, element: e, holder: h, param: p}),
    do: %{path: [e], element: Spec.param_key(h, p)}

  defp key(%Source{element: e}), do: %{path: [], element: e}

  defp in_cell(base, kind), do: %{base | residue: [in_cell_entry(base.symbol, kind)]}

  defp in_cell_entry(symbol, kind),
    do: Residue.entry(symbol, :page_data_in_cell, %{kind: Atom.to_string(kind)})

  defp value(%Source{value: %{ir: ir}} = s, base, ctx, fns) do
    bctx =
      Map.merge(ctx, %{
        surface: s.surface,
        cell: s.cell,
        subject: s.id,
        workflow: %{bubble_id: nil, parameters: []}
      })

    # Sorting and filtering lists of things in the database (WTF-495).
    ir = Lists.lower(ir)

    case query(ir) do
      {:query, search, take} when s.cell == nil ->
        search_source(s, base, search, take, bctx, fns)

      {:query, _search, _take} ->
        in_cell(base, :query)

      :value ->
        if s.cell != nil and queries?(ir),
          do: in_cell(base, :query),
          else: value_source(s, %{s.value | ir: ir}, base, bctx, fns)
    end
  end

  # A value computed in Elixir, after the queries it reads (WTF-495: a
  # search under a list operator, `query_<n>`), each read as a query is.
  defp value_source(s, expr, base, ctx, fns) do
    case compile_value(expr, s, ctx, fns, new_acc()) do
      {:ok, compiled, acc} ->
        queries = Enum.reverse(acc.queries)
        compiled = if queries == [], do: compiled, else: Map.put(compiled, :queries, queries)

        # An instance in a cell, and its properties, are rendered per cell
        # of the list (WTF-494): they need it loaded.
        reads = Enum.uniq(data_reads(compiled.bindings) ++ query_reads(queries))

        reads =
          if s.cell != nil and s.kind in [:instance, :param],
            do: Enum.uniq(reads ++ [{:cell, s.cell}]),
            else: reads

        %{base | read: {:value, compiled}, resource: resource(s.type, ctx), reads: reads}

      {:error, residue} ->
        %{base | residue: residue}
    end
  end

  defp new_acc, do: %{queries: [], seen: %{}, next: 1}

  # Compiles `expr` in Elixir, its searches first read as queries.
  defp compile_value(%Lowering.Expr{ir: ir} = expr, s, ctx, fns, acc) do
    with {:ok, ir, acc} <- extract(ir, s, ctx, fns, acc) do
      case fns.compile.(%{expr | ir: ir}, s.id, ctx) do
        {%{} = compiled, []} -> {:ok, compiled, acc}
        {_compiled, residue} -> {:error, residue}
      end
    end
  end

  # Replaces each search under a list operator (with its sorts, and
  # `first item`, `item #`, `items until #` or `count` over it) with the
  # query reading it (`{:query, %{"n" => n}}`). Predicates are left as
  # they are: a search inside one reads its own items.
  defp extract(%IR{} = ir, s, ctx, fns, acc) do
    case query(ir) do
      {:query, search, take} ->
        key = IR.strip_paths(ir)

        case acc.seen do
          %{^key => n} -> {:ok, query_input(n, ir.type), acc}
          _ -> new_query(ir, key, search, take, s, ctx, fns, acc)
        end

      :value ->
        extract_args(ir, s, ctx, fns, acc)
    end
  end

  # A query read once per source, whatever reads it (`key`).
  defp new_query(ir, key, search, take, s, ctx, fns, acc) do
    n = acc.next

    with {:ok, q, acc} <- build_query(search, take, "q#{n}_", s, ctx, fns, %{acc | next: n + 1}) do
      queries = [Map.put(q, :n, n) | acc.queries]
      {:ok, query_input(n, ir.type), %{acc | queries: queries, seen: Map.put(acc.seen, key, n)}}
    end
  end

  defp extract_args(%IR{op: op, args: [list, pred]} = ir, s, ctx, fns, acc) when op == :filter do
    with {:ok, list, acc} <- extract(list, s, ctx, fns, acc),
         do: {:ok, %{ir | args: [list, pred]}, acc}
  end

  defp extract_args(%IR{args: args} = ir, s, ctx, fns, acc) do
    args
    |> Enum.reduce_while({:ok, [], acc}, fn
      %IR{} = arg, {:ok, done, acc} ->
        case extract(arg, s, ctx, fns, acc) do
          {:ok, arg, acc} -> {:cont, {:ok, [arg | done], acc}}
          error -> {:halt, error}
        end

      arg, {:ok, done, acc} ->
        {:cont, {:ok, [arg | done], acc}}
    end)
    |> case do
      {:ok, args, acc} -> {:ok, %{ir | args: Enum.reverse(args)}, acc}
      error -> error
    end
  end

  defp query_input(n, type), do: IR.node(:input, [:query, %{"n" => Integer.to_string(n)}], type)

  defp queries?(%IR{} = ir), do: query(ir) != :value or Enum.any?(ir.args, &queries?/1)
  defp queries?(_arg), do: false

  # The page data the queries' pins read.
  defp query_reads(queries) do
    for q <- queries,
        %{value: %{bindings: bindings}} <- q.pins,
        read <- data_reads(bindings),
        do: read
  end

  # A search read as a query: the search (possibly sorted) and how much of
  # it the source takes.
  defp query(%IR{op: :search} = ir), do: {:query, ir, :all}

  defp query(%IR{op: :sort, args: [inner | _]} = ir) do
    if Lists.search?(inner), do: {:query, ir, :all}, else: :value
  end

  defp query(%IR{op: :first, args: [inner]}), do: take(inner, :first)
  defp query(%IR{op: :count, args: [inner]}), do: take(inner, :count)

  defp query(%IR{op: :item_at, args: [inner, %IR{op: :literal, args: [n]}]})
       when is_integer(n) and n > 0,
       do: take(inner, {:item, n})

  defp query(%IR{op: :limit, args: [inner, %IR{op: :literal, args: [n]}]})
       when is_integer(n) and n >= 0,
       do: take(inner, {:limit, n})

  defp query(_ir), do: :value

  defp take(inner, how) do
    case query(inner) do
      {:query, search, :all} -> {:query, search, how}
      _ -> :value
    end
  end

  defp search_source(s, base, search, take, ctx, fns) do
    case build_query(search, take, "", s, ctx, fns, new_acc()) do
      {:ok, query, acc} ->
        queries = Enum.reverse(acc.queries)
        query = if queries == [], do: query, else: Map.put(query, :queries, queries)

        %{
          base
          | read: {:query, query},
            resource: query.resource,
            reads: Enum.uniq(query_reads([query]) ++ query_reads(queries))
        }

      {:error, residue} ->
        %{base | residue: residue}
    end
  end

  # The Ash query of a search, its pins named with `prefix`.
  defp build_query(search, take, prefix, s, ctx, fns, acc) do
    listed? = Lists.listed?(search)
    {search, hoisted} = hoisted(search, ctx.project)

    case Expressions.search(search, ctx.project) do
      {:ok, %{expr: %Expr{} = expr}} ->
        case hidden_fields(expr, ctx.project) do
          [] ->
            s |> pin(expr, take, hoisted, prefix, ctx, fns, acc) |> listed(listed?)

          fields ->
            {:error, [Residue.entry(s.id, :search_field_hidden, %{fields: fields})]}
        end

      {:ok, %{diagnostics: diags}} ->
        constructs =
          diags
          |> Enum.flat_map(&Map.get(&1.details, :constructs, []))
          |> Enum.map(&("ash:" <> &1))
          |> Enum.uniq()
          |> Enum.sort()

        {:error,
         [
           Residue.entry(s.id, :uncompiled_expression, %{
             expressions: 1,
             constructs: if(constructs == [], do: ["ash:uncompiled"], else: constructs)
           })
         ]}
    end
  end

  # With enforced policies (WTF-423), what a search's filter or sort reads
  # that cannot be decided per actor, as `<Resource>.<field>` or
  # `<Resource>.<relationship>`: a field some users may not view, or a
  # gated relationship, further along a relationship path. Empty
  # otherwise. Field policies guard `filter_input` and reads, not a filter
  # written in code; on the searched resource itself, a field some users
  # may not view (or a gated relationship followed to fields everyone
  # views) is decided per actor and record at run time by
  # `<namespace>.Privacy.SearchFields` (WTF-457: only the records where
  # the actor may view it), so the search is loaded. Further along a path
  # that check returns nothing for everyone: the search is residue.
  defp hidden_fields(%Expr{} = expr, %Project{privacy: :enforced} = project) do
    modules = Map.new(project.resources ++ project.joins, &{&1.module, &1})

    # Bubble's random sort (`:random`) reads no field of the record.
    refs =
      expr_refs(expr.expr) ++ for({attribute, _} <- expr.sort, do: {[], attribute})

    refs
    |> Enum.flat_map(fn {rels, attribute} ->
      hidden_path(expr.resource, rels, attribute, modules, true)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp hidden_fields(_expr, _project), do: []

  defp hidden_path(_module, [], _attribute, _modules, true = _root?), do: []

  defp hidden_path(module, [], attribute, modules, false) do
    case modules[module] do
      nil -> []
      r -> if visible_to_all?(r, attribute), do: [], else: ["#{module}.#{attribute}"]
    end
  end

  defp hidden_path(module, [rel | rest], attribute, modules, root?) do
    with %{} = r <- modules[module],
         %{} = relationship <- Enum.find(r.relationships, &(&1.name == rel)) do
      if relationship.gate == nil or root?,
        do: hidden_path(relationship.destination, rest, attribute, modules, false),
        else: ["#{module}.#{rel}"]
    else
      _ -> ["#{module}.#{rel}"]
    end
  end

  defp visible_to_all?(resource, attribute) do
    Enum.all?(resource.field_policies, fn fp ->
      attribute not in fp.fields or
        Enum.any?(fp.checks, &match?(%{kind: :authorize_if, test: :always}, &1))
    end)
  end

  defp expr_refs({:ref, rels, attribute}) when is_binary(attribute), do: [{rels, attribute}]
  defp expr_refs({:call, _name, args}), do: Enum.flat_map(args, &expr_refs/1)
  defp expr_refs({:op, _op, l, r}), do: expr_refs(l) ++ expr_refs(r)
  defp expr_refs({bool, nodes}) when bool in [:and, :or], do: Enum.flat_map(nodes, &expr_refs/1)
  defp expr_refs({:not, node}), do: expr_refs(node)
  defp expr_refs(list) when is_list(list), do: Enum.flat_map(list, &expr_refs/1)
  defp expr_refs(_node), do: []

  defp listed({:ok, query, acc}, true), do: {:ok, Map.put(query, :listed, true), acc}
  defp listed(result, _listed?), do: result

  # The filter with its context inputs and actor reads as pinned variables.
  defp pin(s, expr, take, hoisted, prefix, ctx, fns, acc) do
    {args, residue, acc} =
      expr.arguments
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], acc}, fn {arg, i}, {args, residue, acc} ->
        var = "#{prefix}pin_#{i}"

        case pin_value(arg, hoisted, s, ctx, fns, acc) do
          {:ok, value, acc} ->
            {[{arg.name, %{var: var, value: value, ref: ref_kind(arg.type)}} | args], residue,
             acc}

          {:error, r} ->
            {args, residue ++ r, acc}
        end
      end)

    if residue != [] do
      {:error, Residue.sort(Enum.uniq(residue))}
    else
      args = Map.new(args)
      {node, actors} = rewrite(expr.expr, args, %{}, prefix)

      actor_pins =
        actors
        |> Enum.sort_by(&elem(&1, 1))
        |> Enum.map(fn {path, var} -> %{var: var, value: {:actor, path}, ref: nil} end)

      pins = Enum.sort_by(Map.values(args), & &1.var) ++ actor_pins

      query = %{
        resource: expr.resource,
        filter: %{expr | expr: node, arguments: []},
        sort: expr.sort,
        actor_loads: expr.actor_loads,
        take: take,
        pins: pins
      }

      {:ok, query, acc}
    end
  end

  # A pinned argument: a hoisted value, compiled in Elixir (a list a
  # rewritten search reads, `:pinned`, with its own queries first), or a
  # context input bound as a workflow's.
  defp pin_value(%{input: {:hoisted, %{"n" => n}}}, hoisted, s, ctx, fns, acc),
    do: compile_pin(Map.fetch!(hoisted, n), s, ctx, fns, acc)

  defp pin_value(%{input: {kind, ref}, type: type}, _hoisted, s, ctx, fns, acc),
    do: compile_pin(IR.node(:input, [kind, ref], type), s, ctx, fns, acc)

  defp compile_pin(ir, s, ctx, fns, acc),
    do: compile_value(%Lowering.Expr{path: s.path, ir: ir}, s, ctx, fns, acc)

  defp ref_kind(type) do
    case classify(type) do
      %Type{kind: :ref, cardinality: :one} -> :one
      %Type{kind: :ref, cardinality: :many} -> :many
      _ -> nil
    end
  end

  # Replaces `^arg(name)` with its pin and every `^actor(path)` with one
  # pin per path (`<prefix>actor_<n>`).
  defp rewrite({:arg, name}, args, actors, _prefix), do: {{:pin, args[name].var}, actors}

  defp rewrite({:actor, path}, _args, actors, prefix) do
    case actors[path] do
      nil ->
        var = "#{prefix}actor_#{map_size(actors) + 1}"
        {{:pin, var}, Map.put(actors, path, var)}

      var ->
        {{:pin, var}, actors}
    end
  end

  defp rewrite({:op, op, l, r}, args, actors, prefix) do
    {l, actors} = rewrite(l, args, actors, prefix)
    {r, actors} = rewrite(r, args, actors, prefix)
    {{:op, op, l, r}, actors}
  end

  defp rewrite({op, nodes}, args, actors, prefix) when op in [:and, :or] do
    {nodes, actors} = Enum.map_reduce(nodes, actors, &rewrite(&1, args, &2, prefix))
    {{op, nodes}, actors}
  end

  defp rewrite({:not, node}, args, actors, prefix) do
    {node, actors} = rewrite(node, args, actors, prefix)
    {{:not, node}, actors}
  end

  defp rewrite({:call, name, nodes}, args, actors, prefix) do
    {nodes, actors} = Enum.map_reduce(nodes, actors, &rewrite(&1, args, &2, prefix))
    {{:call, name, nodes}, actors}
  end

  defp rewrite(node, _args, actors, _prefix), do: {node, actors}

  # Every maximal part of a search's constraints that does not read the
  # searched item and reads a context value through a field (which the
  # Ash filter cannot) is computed in Elixir and passed in as a hoisted
  # input.
  # The search with what the filter cannot read itself hoisted: fields of
  # context values, else every value of the context it cannot compute.
  defp hoisted(search, project) do
    {fields, _} = by_field = hoist(search)

    with {:ok, %{expr: nil}} <- Expressions.search(fields, project),
         {values, _} = by_value = hoist(search, :values),
         {:ok, %{expr: %Expr{}}} <- Expressions.search(values, project) do
      by_value
    else
      _ -> by_field
    end
  end

  defp hoist(ir, mode \\ :fields)

  defp hoist(%IR{op: :sort, args: [inner | rest]} = ir, mode) do
    {inner, hoisted} = hoist(inner, mode)
    {%{ir | args: [inner | rest]}, hoisted}
  end

  defp hoist(%IR{op: :search, args: [type, pred]} = ir, mode) when not is_nil(pred) do
    {pred, hoisted} = hoist_node(pred, %{}, mode)
    {%{ir | args: [type, pred]}, hoisted}
  end

  defp hoist(ir, _mode), do: {ir, %{}}

  defp hoist_node(%IR{} = ir, hoisted, mode) do
    if hoistable?(ir, mode) do
      n = Integer.to_string(map_size(hoisted) + 1)
      value = with %IR{op: :pinned, args: [list]} <- ir, do: list
      {IR.node(:input, [:hoisted, %{"n" => n}], ir.type), Map.put(hoisted, n, value)}
    else
      {args, hoisted} =
        Enum.map_reduce(ir.args, hoisted, fn
          %IR{} = arg, acc -> hoist_node(arg, acc, mode)
          other, acc -> {other, acc}
        end)

      {%{ir | args: args}, hoisted}
    end
  end

  # A field (or anything over one) of a context input, not of the item;
  # whether a context value is empty (a search ignoring empty constraints)
  # is known before the query, so it is computed first too. A list a
  # rewritten search reads (`Lists`, `:pinned`) is computed first, whole.
  # When the filter does not compile so (`:values`, WTF-495), so is any
  # value not of the item that the Ash filter cannot compute (a list
  # operator, a search, a dynamic text, a date's arithmetic).
  defp hoistable?(%IR{op: :pinned}, _mode), do: true

  defp hoistable?(%IR{op: op} = ir, _mode) when op in [:field, :is_empty],
    do: not reads_item?(ir) and reads_input?(ir)

  defp hoistable?(%IR{} = ir, :values),
    do: not reads_item?(ir) and Enum.any?(IR.ops(ir), &(&1 in @elixir_values))

  defp hoistable?(_ir, _mode), do: false

  defp reads_item?(%IR{op: :this}), do: true
  # A nested `:filtered`'s or search's constraints read their own items.
  defp reads_item?(%IR{op: :filter, args: [list, _pred]}), do: reads_item?(list)
  defp reads_item?(%IR{op: :search}), do: false
  defp reads_item?(%IR{args: args}), do: Enum.any?(args, &reads_item?/1)
  defp reads_item?(list) when is_list(list), do: Enum.any?(list, &reads_item?/1)
  defp reads_item?(_), do: false

  defp reads_input?(%IR{op: :input}), do: true
  defp reads_input?(%IR{args: args}), do: Enum.any?(args, &reads_input?/1)
  defp reads_input?(_), do: false

  # --- reading each other --------------------------------------------------------------

  # The page data a compiled value reads.
  defp data_reads(bindings) do
    for %{bind: bind} <- bindings,
        match?({kind, _} when kind in [:data, :cell, :cell_index, :cell_data], bind),
        uniq: true,
        do: bind
  end

  # A source whose value reads another source that is not bound (or reads
  # page data outside what its surface keeps) is not loaded either,
  # transitively.
  defp prune(bound) do
    wired = for b <- bound, b.residue == [], into: MapSet.new(), do: id(b)
    wired = prune_fixpoint(wired, bound)

    Enum.map(bound, fn b ->
      if b.residue == [] and not MapSet.member?(wired, id(b)),
        do: %{
          b
          | read: nil,
            residue: [Residue.entry(b.symbol, :unavailable_input, %{inputs: ["data_source"]})]
        },
        else: b
    end)
  end

  defp prune_fixpoint(wired, bound) do
    by_element = Map.new(bound, &{id(&1), &1})

    # The values of each property: every one must load for the reusable
    # element to read it (an instance's in a cell when it is rendered per
    # cell, WTF-494).
    params =
      bound
      |> Enum.filter(&counted_param?(&1, wired))
      |> Enum.group_by(&Spec.param_key(&1.holder, &1.param), &id/1)

    next =
      for b <- bound,
          MapSet.member?(wired, id(b)),
          Enum.all?(b.reads, &read_wired?(&1, b, {by_element, params}, wired)),
          into: MapSet.new(),
          do: id(b)

    if next == wired, do: wired, else: prune_fixpoint(next, bound)
  end

  # A source's identity: its element, and a property's name (an instance
  # has a source per property it sets, besides its own data source).
  defp id(%{kind: :param, element: e, key: %{element: k}}), do: {e, k}
  defp id(%{element: e}), do: e

  # This Reusable's property: every value of it (WTF-493).
  defp read_wired?({:data, %{path: [], element: "param_" <> _ = p}}, _b, {_, params}, wired),
    do: params |> Map.get(p, []) |> Enum.all?(&MapSet.member?(wired, &1))

  # An instance's property, read where the instance is.
  defp read_wired?({:data, %{path: [i], element: "param_" <> _ = p}}, _b, _maps, wired),
    do: MapSet.member?(wired, {i, p})

  # A read of the surface's own reusable-element thing is the instance's
  # (whatever it holds, possibly nothing).
  defp read_wired?({:data, %{path: [], element: e}}, %{surface: e}, {by_element, _}, wired),
    do: not Map.has_key?(by_element, e) or MapSet.member?(wired, e)

  defp read_wired?({:data, %{path: [instance]}}, _b, _maps, wired),
    do: MapSet.member?(wired, instance)

  defp read_wired?({:data, %{element: e}}, _b, _maps, wired), do: MapSet.member?(wired, e)

  defp read_wired?({kind, rg}, _b, _by, wired) when kind in [:cell, :cell_index],
    do: MapSet.member?(wired, rg)

  defp read_wired?({:cell_data, g}, _b, _by, wired), do: MapSet.member?(wired, g)

  # The order a surface reads its sources in: after those they read. The
  # ones reading each other in a cycle are residue.
  defp order(bound) do
    by_element = Map.new(bound, &{id(&1), &1})
    {ordered, left} = kahn(bound, by_element, [], MapSet.new())

    cyclic =
      Enum.map(left, fn b ->
        %{
          b
          | read: nil,
            residue: [
              Residue.entry(b.symbol, :unresolved_reference, %{reference: "data_source"})
            ]
        }
      end)

    Enum.reverse(ordered) ++ Enum.sort_by(cyclic, &id/1)
  end

  defp kahn(bound, by_element, ordered, done) do
    {ready, waiting} =
      bound
      |> Enum.reject(&MapSet.member?(done, id(&1)))
      |> Enum.split_with(fn b ->
        Enum.all?(deps(b, by_element), &MapSet.member?(done, &1))
      end)

    case Enum.sort_by(ready, &id/1) do
      [] ->
        {ordered, waiting}

      ready ->
        kahn(
          bound,
          by_element,
          Enum.reverse(ready) ++ ordered,
          Enum.into(Enum.map(ready, &id/1), done)
        )
    end
  end

  # The sources of the same surface a source reads first.
  defp deps(b, by_element) do
    for read <- b.reads,
        e <- dep_element(read, b),
        Map.has_key?(by_element, e),
        # A property's value reading itself (a default naming its own
        # property) is a cycle.
        e != id(b) or b.kind == :param,
        uniq: true,
        do: e
  end

  # A property's default, of the same reusable element; an instance's
  # value of it.
  defp dep_element({:data, %{path: [], element: "param_" <> _ = p}}, b), do: [{b.surface, p}]
  defp dep_element({:data, %{path: [i], element: "param_" <> _ = p}}, _b), do: [{i, p}]
  defp dep_element(read, _b), do: dep_element(read)

  defp dep_element({:data, %{path: [instance]}}), do: [instance]
  defp dep_element({:data, %{element: e}}), do: [e]
  defp dep_element({kind, rg}) when kind in [:cell, :cell_index], do: [rg]
  defp dep_element({:cell_data, g}), do: [g]

  # --- helpers ---------------------------------------------------------------------------

  # The Ash resource (relative module) of a thing or list-of-things type.
  defp resource(type, ctx) do
    case classify(type) do
      %Type{kind: :ref, target: target} ->
        case Enum.find(ctx.project.resources, &(&1.source.type == target)) do
          %{module: module} -> module
          nil -> nil
        end

      _ ->
        nil
    end
  end

  defp classify(type) when is_binary(type), do: type |> Type.classify() |> elem(0)
  defp classify(_type), do: nil

  defp unmapped(id, what),
    do: Residue.entry(id, :unresolved_reference, %{reference: what, target: "ash"})
end
