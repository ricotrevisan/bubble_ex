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
    * a data source with the conditional states that set one (WTF-521,
      folded by `BubbleEx.PageData`), outside a repeating group's cell, is
      `read: {:switch, %{cases, else}}`: each case `%{when, then}`, a
      condition (a value) and a branch (a whole query or a value, as
      above), and the base (`else`: the element's own source, or empty);
      the runtime tests the conditions in order and reads only the winning
      branch. In a cell the fold is one value, computed per cell
    * an element with no data source that a "Display data" step sets
      (WTF-492, `ctx.displayed`) reads what the step showed
      (`read: :displayed`), and so does one no step sets, which shows
      nothing (WTF-520); every source a step sets is `displayed?`

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
  Ash with the actor, like any other source. A source may read an
  instance's property from outside the instance where it sets none
  (WTF-520): the default, `{:data, %{path: [instance], element: key}}`,
  for an instance rendered once; the loader reads the sources of the
  page and its instances in the order they read each other, across the
  instances' boundaries (`reads`, printed as `deps`), and sources reading
  each other in a cycle through a boundary are residue
  (`across_instances/2`).

  A reusable instance in a repeating group's cell (WTF-494) is rendered
  once per cell, in a scope of its own (the cell's thing's): its own
  data source and the properties it sets are computed per cell (they
  read the cell's thing as `{:cell, rg}`, and depend on the list), and
  its reusable element's sources run in each cell's scope. The runtime
  reads a source for every cell together (`shared?`: one that reads
  nothing of its scope, only the current user, the time or the URL, is
  read once). A search that reads the cell or the instance is read for
  every cell together (WTF-520, `cell_batch/2`: one query per round of
  cells, each cell's records found by its keys; the query gets `batch`,
  printed through `BubbleData.cell_read/4`); one that cannot be would
  query once per cell: a reusable element (or one it nests) with such a
  search is not rendered per cell (`cell_instances/4`), and such a
  search in a cell is residue.

  A repeating group in another's cell (WTF-520, two levels:
  `ctx.nested_lists`, inner => outer, from the page's structure) is read
  per outer cell, as a group there: its list is a value per outer cell
  (its search batched). The sources of its cells (`outer` set: the outer
  repeating group) read the inner cell as `{:cell, inner}` and the outer
  one as `{:outer_cell, outer}`, `{:outer_cell_index, outer}` and
  `{:outer_cell_data, group}`; they are read for every inner cell of
  every outer cell together, and need their list loaded.

  ## Residue added here

    * `:page_data_in_cell` - a repeating group in a repeating group's
      cell that is not rendered per outer cell (`ctx.nested_lists`: a
      third level, or one in a table's row or another runtime container),
      or a search there that cannot be read for every cell together: the
      page would read once per cell (`detail.kind` `"list"` or
      `"query"`); a reusable instance in a cell whose reusable element
      has such a search reading its instance (`"query"`, on the
      instance's sources)
    * `:uncompiled_expression` - constructs prefixed `ash:` (a search the
      Ash filter compiler rejects) or `elixir:`
    * `:unavailable_input` - an input the page does not provide, or
      another data source that is not loaded (`inputs: ["data_source"]`)
    * `:unresolved_reference` (`detail.target` `"ash"`) - a type the Ash
      project does not map; `reference: "data_source"` for sources that
      read each other in a cycle (in one surface, or through an
      instance's boundary: the source reading the instance's default)
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
        %{
          elements: %{},
          roots: MapSet.new(),
          params: %{},
          set: %{},
          defaults: MapSet.new(),
          valued: MapSet.new()
        },
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
  # for the values instances outside a cell set that load; `defaults`, the
  # keys of the properties with a default; `valued`, every `{instance,
  # param}` an instance sets (loaded or not, in a cell or not).
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
        ),
      defaults:
        for(
          %{kind: :param, element: e, holder: e} = s <- sources,
          into: MapSet.new(),
          do: Spec.param_key(s.holder, s.param)
        ),
      valued:
        for(
          %{kind: :param} = s <- sources,
          s.element != s.holder,
          into: MapSet.new(),
          do: {s.element, s.param}
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
  The reusable-element instances whose own data source does not load
  while their reusable element reads its own thing and those reads load
  (WTF-522): instance => the residue reasons of its source. `wired` is
  `wired_index/1`'s: the reusable element is a root there because
  another instance's source (or a step) gives it its thing, so what it
  reads of its own thing is bound as loaded, but in this instance it
  would read nothing. `self_reads` (`BubbleEx.PageData`'s) are the
  reusable elements that read it at all: an instance of one that never
  does renders whatever its source. The page does not render such an
  instance (its element is residue, `BubbleEx.Target.Phoenix`), nor its
  scope: none of its reusable element's sources, texts or workflows run
  there.
  """
  @spec unloaded_instances(%{String.t() => [map()]}, map(), MapSet.t(String.t())) ::
          %{String.t() => [atom()]}
  def unloaded_instances(bound, wired, self_reads) do
    for {_surface, list} <- bound,
        %{kind: :instance, residue: [_ | _], holder: holder} = b <- list,
        is_binary(holder),
        MapSet.member?(self_reads, holder),
        MapSet.member?(wired.roots, holder),
        not Map.has_key?(wired.elements, b.element),
        into: %{},
        do: {b.element, b.residue |> Enum.map(& &1.reason) |> Enum.uniq()}
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

    # The reusable elements whose sources run once per cell (WTF-494): what
    # their sources read of their scope differs from cell to cell.
    ctx =
      Map.put(
        ctx,
        :per_cell,
        in_cell_reusables(Map.get(ctx, :in_cells, %{}), Map.get(ctx, :nested, %{}))
      )

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
    |> across_instances(Map.get(Map.get(ctx, :data, %{}), :instances, %{}))
    |> Enum.map(&Map.put(&1, :shared?, &1.residue == [] and shared?(&1)))
    |> Enum.group_by(& &1.surface)
    |> Map.new(fn {surface, bound} -> {surface, order(bound)} end)
  end

  # --- across instance boundaries (WTF-520) -----------------------------------------------

  # A source may read an instance's property from outside it (its default,
  # computed inside the instance's reusable element) and that default may
  # read what is outside the instance (its thing, its other properties):
  # the loader orders them across surfaces (`<Web>.BubbleData`). Sources
  # reading each other in a cycle through an instance's boundary cannot be
  # ordered: what reads the default, in the cycle, is not loaded
  # (`:unresolved_reference`, as a cycle in one surface), and neither is
  # what reads it. Found per surface with its instances (`instances`, from
  # `Spec.data_read/4`'s index) expanded, so two instances of one reusable
  # element are told apart.
  defp across_instances(bound, instances) when map_size(instances) == 0, do: bound

  defp across_instances(bound, instances) do
    case cyclic_readers(bound, instances) do
      [] ->
        bound

      cyclic ->
        cyclic = MapSet.new(cyclic)

        bound
        |> Enum.map(&cyclic(&1, cyclic))
        |> prune()
        |> across_instances(instances)
    end
  end

  defp cyclic(%{residue: []} = b, cyclic) do
    if MapSet.member?(cyclic, {b.surface, id(b)}),
      do: %{
        b
        | read: nil,
          residue: [Residue.entry(b.symbol, :unresolved_reference, %{reference: "data_source"})]
      },
      else: b
  end

  defp cyclic(b, _cyclic), do: b

  # `{surface, id}` of the sources reading an instance's default in a cycle
  # through the instance's boundary.
  defp cyclic_readers(bound, instances) do
    wired = for b <- bound, b.residue == [], do: b

    by_surface =
      wired
      |> Enum.group_by(& &1.surface)
      |> Map.new(fn {surface, bs} -> {surface, Map.new(bs, &{id(&1), &1})} end)

    nested =
      instances
      |> Enum.group_by(fn {_i, %{surface: surface}} -> surface end, fn {i, %{holder: h}} ->
        {i, h}
      end)
      |> Map.new(fn {surface, list} -> {surface, Enum.sort(list)} end)

    # Only a read of an instance's default from outside crosses a boundary
    # downwards; without one there is no cycle across instances.
    down? = Enum.any?(wired, fn b -> Enum.any?(b.reads, &default_read?(&1, b, by_surface)) end)

    if down? do
      # The pages, and the reusable elements no instance renders once
      # (those in cells only): the others are expanded where they are.
      held = for {_i, %{holder: h}} <- instances, into: MapSet.new(), do: h

      roots =
        by_surface
        |> Map.keys()
        |> Enum.concat(Map.keys(nested))
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(held, &1))

      graph = :digraph.new()

      try do
        Enum.each(roots, &expand(graph, &1, [], by_surface, nested, MapSet.new([&1])))

        for scc <- :digraph_utils.cyclic_strong_components(graph),
            members = MapSet.new(scc),
            {scope, surface, bid} <- scc,
            b = by_surface[surface][bid],
            read <- b.reads,
            default_read?(read, b, by_surface),
            MapSet.member?(members, default_vertex(read, scope, b, nested)),
            uniq: true,
            do: {surface, bid}
      after
        :digraph.delete(graph)
      end
    else
      []
    end
  end

  # An instance's property read where no value the instance sets is a
  # source of the reader's surface: its default.
  defp default_read?({:data, %{path: [i], element: "param_" <> _ = p}}, b, by_surface),
    do: not Map.has_key?(Map.get(by_surface, b.surface, %{}), {i, p})

  defp default_read?(_read, _b, _by_surface), do: false

  defp default_vertex({:data, %{path: [i], element: p}}, scope, b, nested) do
    case List.keyfind(Map.get(nested, b.surface, []), i, 0) do
      {^i, holder} -> {[i | scope], holder, {holder, p}}
      nil -> nil
    end
  end

  # The sources of `surface` in `scope` (instance IDs, innermost first) and
  # of the instances it renders once, as vertices `{scope, surface, id}`
  # with an edge from each source to what it reads. `stack`: the reusable
  # elements being expanded (one nesting itself is not followed).
  defp expand(graph, surface, scope, by_surface, nested, stack) do
    own = Map.get(by_surface, surface, %{})

    Enum.each(own, fn {bid, _b} -> :digraph.add_vertex(graph, {scope, surface, bid}) end)

    for {i, holder} <- Map.get(nested, surface, []), not MapSet.member?(stack, holder) do
      expand(graph, holder, [i | scope], by_surface, nested, MapSet.put(stack, holder))
    end

    parent = parent_surface(scope, nested)

    Enum.each(own, fn {bid, b} ->
      from = {scope, surface, bid}

      for to <- vertices_read(b, scope, surface, parent, by_surface, nested),
          to != from,
          do: :digraph.add_edge(graph, from, to)
    end)
  end

  # The surface rendering the instance `scope` names, with its scope.
  defp parent_surface([], _nested), do: nil

  defp parent_surface([i | outer], nested) do
    Enum.find_value(nested, fn {surface, list} ->
      if List.keymember?(list, i, 0), do: {surface, outer}
    end)
  end

  defp vertices_read(b, scope, surface, parent, by_surface, nested) do
    own = Map.get(by_surface, surface, %{})

    at = fn s, sur, bid ->
      if Map.has_key?(Map.get(by_surface, sur, %{}), bid), do: [{s, sur, bid}], else: []
    end

    # A default is read where the instance sets none: after the value it
    # may set (the loader reads that first).
    after_set =
      case {b, scope, parent} do
        {%{kind: :param, element: e, holder: e}, [i | _], {psurface, pscope}} ->
          at.(pscope, psurface, {i, b.key.element})

        _ ->
          []
      end

    after_set ++
      Enum.flat_map(b.reads, fn
        {:data, %{path: [], element: "param_" <> _ = p}} ->
          up =
            case {scope, parent} do
              {[i | _], {psurface, pscope}} -> at.(pscope, psurface, {i, p})
              _ -> []
            end

          up ++ at.(scope, surface, {surface, p})

        {:data, %{path: [], element: ^surface}} ->
          case {scope, parent} do
            {[i | _], {psurface, pscope}} -> at.(pscope, psurface, i)
            _ -> []
          end

        {:data, %{path: [i], element: "param_" <> _ = p}} = read ->
          if Map.has_key?(own, {i, p}),
            do: [{scope, surface, {i, p}}],
            else: List.wrap(default_vertex(read, scope, b, nested))

        {:data, %{path: [i]}} ->
          at.(scope, surface, i)

        {:data, %{element: e}} ->
          at.(scope, surface, e)

        {kind, e}
        when kind in [
               :cell,
               :cell_index,
               :cell_data,
               :outer_cell,
               :outer_cell_index,
               :outer_cell_data
             ] ->
          at.(scope, surface, e)

        _ ->
          []
      end)
  end

  # --- instances in cells (WTF-494) ----------------------------------------------------

  # An instance in a cell that would query once per cell (a search source
  # of its reusable element reads its scope) is not rendered per cell: its
  # own sources are residue, and so is what reads them. A value over
  # searches read first (WTF-495) or a conditional source (WTF-521) of a
  # reusable element rendered in cells, one of whose searches reads the
  # scope, is residue itself, and what reads it, but its instances are
  # still rendered per cell.
  defp per_cell(bound, ctx) do
    nested = Map.get(ctx, :nested, %{})
    bound = queries_in_cells(bound, Map.get(ctx, :per_cell, MapSet.new()))
    blocked = not_per_cell(bound, nested)

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

  # In a reusable element rendered per cell, a source whose searches read
  # its scope is read for every cell together (WTF-520): its queries are
  # batched. A value or conditional source whose searches cannot be is
  # residue; a search source that cannot be keeps its instances from
  # being rendered per cell (`per_cell_blocked/2`).
  defp queries_in_cells(bound, reusables) do
    marked =
      Enum.map(bound, fn
        %{residue: [], cell: nil, read: {kind, _}} = b
        when kind in [:switch, :value, :query] ->
          if MapSet.member?(reusables, b.surface), do: batch_in_reusable(b), else: b

        b ->
          b
      end)

    if marked == bound, do: bound, else: prune(marked)
  end

  defp batch_in_reusable(%{read: {kind, _} = read} = b) do
    case batch_read(read, true) do
      {:ok, read} -> %{b | read: read}
      :error when kind == :query -> b
      :error -> %{b | read: nil, residue: [in_cell_entry(b.symbol, :query)]}
    end
  end

  # The reusable elements whose sources run once per cell: those with an
  # instance in a repeating group's cell, and the ones they nest outside
  # their own cells.
  defp in_cell_reusables(in_cells, nested) do
    start = for {_instance, %{holder: h}} <- in_cells, into: MapSet.new(), do: h
    nest_closure(MapSet.to_list(start), start, nested)
  end

  defp nest_closure([], seen, _nested), do: seen

  defp nest_closure([r | rest], seen, nested) do
    new = nested |> Map.get(r, []) |> Enum.reject(&MapSet.member?(seen, &1))
    nest_closure(new ++ rest, Enum.into(new, seen), nested)
  end

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
      for %{residue: [], read: read, cell: nil} = b <- bound,
          match?({:query, _}, read),
          per_cell_query?(read, b),
          into: MapSet.new(),
          do: b.surface

    reusables =
      bound |> Enum.map(& &1.surface) |> Enum.concat(Map.keys(nested)) |> Enum.uniq()

    for r <- reusables, blocked?(r, direct, nested, MapSet.new()), into: MapSet.new(), do: r
  end

  # A search that would read once per cell: one whose filter reads the
  # scope, unless it is read for every cell together (WTF-520). A value's
  # searches and a conditional source's are batched or residue
  # (`queries_in_cells/2`).
  defp per_cell_query?({:query, q}, b), do: not shared?(b) and not batched?(q)

  # Read for every cell together (WTF-520): the query, or one it reads first.
  defp batched?(q),
    do: Map.has_key?(q, :batch) or Enum.any?(Map.get(q, :queries, []), &batched?/1)

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
  def shared?(%{cell: nil, read: {kind, _}} = b) when kind in [:value, :query, :switch],
    do: b |> read_bindings() |> Enum.all?(&unscoped?/1)

  def shared?(_bound), do: false

  defp read_bindings(%{read: read}), do: bindings_of(read)

  defp bindings_of({:value, %{bindings: bindings}}), do: bindings

  defp bindings_of({:query, %{pins: pins}}),
    do: for(%{value: %{bindings: bindings}} <- pins, b <- bindings, do: b)

  # A conditional source (WTF-521): every condition's and branch's, their
  # queries' too.
  defp bindings_of({:switch, sw}), do: Enum.flat_map(Spec.switch_reads(sw), &all_bindings/1)

  defp all_bindings({_kind, read} = r),
    do: bindings_of(r) ++ Enum.flat_map(Map.get(read, :queries, []), &bindings_of({:query, &1}))

  defp unscoped?(%{bind: {kind, _}}), do: kind in [:url, :url_value, :url_thing]
  defp unscoped?(%{bind: bind}), do: bind in [:actor, :now]

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
          not cells_loaded?(wired, surface, rg, Map.get(s, :outer)) ->
            [Residue.entry(symbol, :unavailable_input, %{inputs: ["data_source"]})]

          MapSet.member?(blocked, instance) or MapSet.member?(holders, holder) ->
            [in_cell_entry(symbol, :query)]

          true ->
            []
        end

      {instance, Map.put(s, :residue, residue)}
    end)
  end

  @doc """
  Whether the page loads the list whose cells hold an element (an
  instance, WTF-494; a click or an input, WTF-520): `rg`, a list of
  `surface` outside a cell, or with `outer` one rendered per cell of
  another (WTF-520), with its outer list. `wired` is `wired_index/1`'s.
  """
  @spec cells_loaded?(map(), String.t(), String.t(), String.t() | nil) :: boolean()
  def cells_loaded?(wired, surface, rg, nil),
    do: match?(%{kind: :list, cell: nil, surface: ^surface}, wired.elements[rg])

  def cells_loaded?(wired, surface, rg, outer),
    do:
      match?(%{kind: :list, cell: ^outer, surface: ^surface}, wired.elements[rg]) and
        cells_loaded?(wired, surface, outer, nil)

  # --- one source ---------------------------------------------------------------------

  defp source(%Source{} = s, ctx, fns) do
    base = %{
      element: s.element,
      symbol: s.id,
      kind: s.kind,
      surface: s.surface,
      cell: s.cell,
      outer: outer(s.cell, ctx),
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

      # A repeating group in a cell is read per cell, as a group there is,
      # when the page renders it per outer cell (WTF-520, two levels); any
      # other would read once per cell. A group, an instance (WTF-494) and
      # its properties there are read per cell.
      s.cell != nil and s.kind == :list and not nested_list?(s, ctx) ->
        in_cell(base, s.kind)

      s.kind == :page_thing ->
        case resource(s.type, ctx) do
          nil -> %{base | residue: [unmapped(s.id, "data_type")]}
          module -> %{base | resource: module, read: :url_thing}
        end

      true ->
        s |> value(base, ctx, fns) |> nested_cell(s, ctx)
    end
  end

  # --- repeating groups in a repeating group's cell (WTF-520) ------------------------------

  # A repeating group the page renders once per cell of another
  # (`ctx.nested_lists`, inner => outer, from the page's structure): its
  # list is a value per outer cell, read for every outer cell together as
  # a group's there (its search batched, `cell_batch/2`), and its cells'
  # sources are read for every inner cell of every outer cell together.
  defp nested_list?(%Source{kind: :list, element: e, cell: cell}, ctx),
    do: is_binary(cell) and Map.get(Map.get(ctx, :nested_lists, %{}), e) == cell

  defp nested_list?(_source, _ctx), do: false

  # The outer repeating group of a source in a nested repeating group's
  # cell (`cell` is the inner one), else nil.
  defp outer(cell, ctx) when is_binary(cell), do: Map.get(Map.get(ctx, :nested_lists, %{}), cell)
  defp outer(_cell, _ctx), do: nil

  # A nested list, and a source in its cells, need what holds their cells
  # loaded (the outer list, the inner list per outer cell), whatever their
  # values read: the loader reads them after it.
  defp nested_cell(%{residue: []} = b, s, ctx) do
    if b.outer != nil or nested_list?(s, ctx),
      do: %{b | reads: Enum.uniq(b.reads ++ [{:cell, s.cell}])},
      else: b
  end

  defp nested_cell(b, _s, _ctx), do: b

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
      outer: outer(holder.cell, ctx),
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

      # A search in a repeating group's cell (WTF-520): read for every cell
      # together, one query per cell round, or residue.
      {:query, search, take} ->
        s |> search_source(base, search, take, bctx, fns) |> in_cell_batch(bctx)

      :value ->
        cond do
          s.cell != nil and queries?(ir) ->
            s |> value_source(%{s.value | ir: ir}, base, bctx, fns) |> in_cell_batch(bctx)

          s.cell == nil and fold?(s, ir) ->
            switch_source(s, ir, base, bctx, fns)

          true ->
            value_source(s, %{s.value | ir: ir}, base, bctx, fns)
        end
    end
  end

  # --- searches read for every cell together (WTF-520) -------------------------------------

  # A source in a repeating group's cell whose searches read the cell (or
  # the scope of a reusable element rendered per cell) is read for every
  # cell together: each such query is batched (`cell_batch/2`), else the
  # source is residue (`:page_data_in_cell`, `kind` `"query"`), as before.
  defp in_cell_batch(%{residue: []} = b, ctx) do
    case batch_read(b.read, per_scope?(b.surface, ctx)) do
      {:ok, read} -> %{b | read: read}
      :error -> %{b | read: nil, reads: [], residue: [in_cell_entry(b.symbol, :query)]}
    end
  end

  defp in_cell_batch(b, _ctx), do: b

  # Whether what a source reads of its scope differs from unit to unit: in
  # a reusable element rendered per cell, each cell has its own scope.
  defp per_scope?(surface, ctx),
    do: MapSet.member?(Map.get(ctx, :per_cell, MapSet.new()), surface)

  @doc false
  # `read` with each query that differs from unit to unit (a cell's, or a
  # per-cell scope's: `per_scope?`) given its batch (`cell_batch/2`), or
  # `:error` when one cannot be batched. A query that reads nothing that
  # differs is the same in every unit: read once (`once/3`).
  @spec batch_read(term(), boolean()) :: {:ok, term()} | :error
  def batch_read({:query, q}, per_scope?) do
    with {:ok, q} <- batch_part(q, per_scope?), do: {:ok, {:query, q}}
  end

  def batch_read({:value, v}, per_scope?) do
    with {:ok, v} <- batch_part(v, per_scope?), do: {:ok, {:value, v}}
  end

  def batch_read({:switch, sw}, per_scope?) do
    with {:ok, cases} <- batch_cases(sw.cases, per_scope?),
         {:ok, otherwise} <- batch_read(sw.else, per_scope?),
         do: {:ok, {:switch, %{sw | cases: cases, else: otherwise}}}
  end

  def batch_read(read, _per_scope?), do: {:ok, read}

  defp batch_cases(cases, per_scope?) do
    Enum.reduce_while(cases, {:ok, []}, fn c, {:ok, acc} ->
      with {:ok, w} <- batch_read(c.when, per_scope?),
           {:ok, t} <- batch_read(c.then, per_scope?) do
        {:cont, {:ok, acc ++ [%{c | when: w, then: t}]}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  # One read (a query or a value) and the queries it reads first, in their
  # order (`query_<n>` reads the ones before it).
  defp batch_part(part, per_scope?) do
    with {:ok, queries, varying} <- batch_queries(Map.get(part, :queries, []), per_scope?) do
      part = if queries == [], do: part, else: Map.put(part, :queries, queries)
      batch_own(part, per_scope?, varying)
    end
  end

  # A query's own filter; a value is computed per unit, only its queries
  # need the batch.
  defp batch_own(%{filter: _} = q, per_scope?, varying) do
    with {:ok, q, _v?} <- batch_query(q, per_scope?, varying), do: {:ok, q}
  end

  defp batch_own(value, _per_scope?, _varying), do: {:ok, value}

  # The queries a read reads first, in order, and the numbers of those
  # that differ from unit to unit.
  defp batch_queries(queries, per_scope?) do
    Enum.reduce_while(queries, {:ok, [], MapSet.new()}, fn q, {:ok, done, varying} ->
      case batch_query(q, per_scope?, varying) do
        {:ok, q, true} -> {:cont, {:ok, done ++ [q], MapSet.put(varying, Integer.to_string(q.n))}}
        {:ok, q, false} -> {:cont, {:ok, done ++ [q], varying}}
        :error -> {:halt, :error}
      end
    end)
  end

  # A query whose pins differ from unit to unit is batched, one reading
  # another batched query's records too: the loader reads the batches in
  # rounds, the query read first before the one reading it.
  defp batch_query(q, per_scope?, varying) do
    vary = Map.new(q.pins, &{&1.var, pin_varies?(&1, per_scope?, varying)})

    if Enum.any?(Map.values(vary)) do
      case cell_batch(q, vary) do
        {:ok, batch} -> {:ok, Map.put(q, :batch, batch), true}
        :error -> :error
      end
    else
      {:ok, q, false}
    end
  end

  # Whether a pin's value differs from unit to unit: it reads the cell, the
  # scope of a reusable element rendered per cell, or a query that does.
  defp pin_varies?(%{value: %{bindings: bindings}}, per_scope?, varying),
    do: Enum.any?(bindings, &binding_varies?(&1.bind, per_scope?, varying))

  defp pin_varies?(_pin, _per_scope?, _varying), do: false

  defp binding_varies?({kind, _}, _per_scope?, _varying)
       when kind in [:url, :url_value, :url_thing],
       do: false

  defp binding_varies?(bind, _per_scope?, _varying) when bind in [:actor, :now], do: false

  defp binding_varies?({kind, _}, _per_scope?, _varying)
       when kind in [
              :cell,
              :cell_index,
              :cell_data,
              :outer_cell,
              :outer_cell_index,
              :outer_cell_data
            ],
       do: true

  defp binding_varies?({:query, n}, _per_scope?, varying), do: MapSet.member?(varying, n)
  defp binding_varies?(_bind, per_scope?, _varying), do: per_scope?

  @doc false
  # The batch of a query read per cell (WTF-520): `vary` names the pins
  # that differ from cell to cell. Its filter must be a conjunction whose
  # parts are either the same in every cell, or one of:
  #
  #   * a key: `attribute == ^pin` / `is_not_distinct_from(attribute,
  #     ^pin)` on a thing's unique ID (`:eq`), or `attribute in ^pin` on
  #     unique IDs (`:in`, the records a list holds), the attribute of the
  #     searched resource itself;
  #   * a key under an empty constraint dropped (`^empty == true or key`:
  #     the key holds only where the value is not empty, `unless`);
  #   * anything else reading only yes/no pins (whether a value is empty):
  #     cells are grouped by them, at most three groups per pin.
  #
  # One query reads every cell's records at once (`batch.filter`: each key
  # `attribute in ^values`, the cells' values), and each cell's are those
  # whose attributes equal its keys: a key is a part of the conjunction,
  # so a record matches a cell's search exactly when it matches the
  # batched one and the cell's keys. Anything else (an ordering or a text
  # comparison with the cell, a cell's value under `or`, Bubble's random
  # sort) is `:error`: the source stays residue.
  @spec cell_batch(map(), %{String.t() => boolean()}) :: {:ok, map()} | :error
  def cell_batch(%{filter: %Expr{} = filter} = q, vary) do
    by_var = Map.new(q.pins, &{&1.var, &1})
    varies? = &Map.get(vary, &1, false)

    parts = Enum.map(conjuncts(filter.expr), &batch_conjunct(&1, by_var, varies?))
    keys = for {:key, key} <- parts, do: key
    key_vars = MapSet.new(keys, & &1.var)
    counts = filter.expr |> pins_in() |> Enum.frequencies()

    # What else differs from cell to cell: yes/no values only, never a key.
    others =
      for({:other, vars} <- parts, v <- vars, varies?.(v), do: v) ++
        for %{unless: u} <- keys, is_binary(u), do: u

    sound? =
      q.sort != [:random] and length(keys) in 1..3 and
        Enum.all?(keys, &(Map.get(counts, &1.var) == 1)) and
        Enum.all?(others, &yes_no?(&1, key_vars, by_var)) and
        not listed_unkeyed?(q, key_vars, varies?)

    if sound?,
      do:
        {:ok,
         %{
           keys: keys,
           void: void_pins(filter.expr, varies?),
           filter: %{filter | expr: batch_expr(filter.expr, key_vars)}
         }},
      else: :error
  end

  def cell_batch(_q, _vary), do: :error

  # The yes/no pins that make the whole search match nothing (a part of
  # its conjunction: an empty value a search does not ignore), as `{pin,
  # :yes}` (when yes) or `{pin, :no}` (unless yes): a cell with one reads
  # nothing.
  defp void_pins(expr, varies?) do
    for node <- conjuncts(expr),
        {var, _when} = void <- [void_var(node)],
        is_binary(var) and varies?.(var),
        uniq: true,
        do: void
  end

  defp void_var({:call, "is_distinct_from", [{:pin, var}, {:value, true}]}), do: {var, :yes}
  defp void_var({:call, "is_distinct_from", [{:value, true}, {:pin, var}]}), do: {var, :yes}
  defp void_var({:not, {:pin, var}}), do: {var, :yes}
  defp void_var({:pin, var}), do: {var, :no}
  defp void_var({:op, "==", {:pin, var}, {:value, true}}), do: {var, :no}
  defp void_var({:op, "==", {:value, true}, {:pin, var}}), do: {var, :no}
  defp void_var(_node), do: {nil, nil}

  # The records of a list (WTF-495): its IDs, when they differ, are a key.
  defp listed_unkeyed?(q, key_vars, varies?) do
    case Map.get(q, :listed) do
      var when is_binary(var) -> varies?.(var) and not MapSet.member?(key_vars, var)
      _ -> false
    end
  end

  defp yes_no?(var, key_vars, by_var),
    do: not MapSet.member?(key_vars, var) and match?(%{type: "boolean"}, by_var[var])

  defp conjuncts({:and, nodes}), do: Enum.flat_map(nodes, &conjuncts/1)
  defp conjuncts(node), do: [node]

  defp batch_conjunct(node, by_var, varies?) do
    vars = pins_in(node)

    cond do
      not Enum.any?(vars, varies?) ->
        {:other, vars}

      key = key_atom(node, by_var, varies?) ->
        {:key, Map.put(key, :unless, nil)}

      match?({:or, [_, _]}, node) ->
        {:or, [a, b]} = node
        guarded_key(a, b, by_var, varies?) || guarded_key(b, a, by_var, varies?) || other(vars)

      true ->
        other(vars)
    end
  end

  defp other(vars), do: {:other, vars}

  # `^empty == true or key`: the key holds where the value is not empty.
  defp guarded_key(guard, node, by_var, varies?) do
    with var when is_binary(var) <- guard_var(guard),
         true <- varies?.(var),
         %{} = key <- key_atom(node, by_var, varies?) do
      {:key, Map.put(key, :unless, var)}
    else
      _ -> nil
    end
  end

  defp guard_var({:pin, var}), do: var
  defp guard_var({:op, "==", {:pin, var}, {:value, true}}), do: var
  defp guard_var({:op, "==", {:value, true}, {:pin, var}}), do: var
  defp guard_var({:call, "is_not_distinct_from", [{:pin, var}, {:value, true}]}), do: var
  defp guard_var({:call, "is_not_distinct_from", [{:value, true}, {:pin, var}]}), do: var
  defp guard_var(_node), do: nil

  # A key: the searched record's own attribute equal to a thing's unique
  # ID, or in a list of unique IDs, that differs from cell to cell.
  defp key_atom({:op, "==", a, b}, by_var, varies?), do: eq_key(a, b, by_var, varies?)

  defp key_atom({:call, "is_not_distinct_from", [a, b]}, by_var, varies?),
    do: eq_key(a, b, by_var, varies?)

  defp key_atom({:op, "in", {:ref, [], attr}, {:pin, var}}, by_var, varies?) do
    if varies?.(var) and by_var[var].ref in [:many, :listed],
      do: %{var: var, attr: attr, kind: :in}
  end

  defp key_atom(_node, _by_var, _varies?), do: nil

  defp eq_key({:ref, [], attr}, {:pin, var}, by_var, varies?) do
    if varies?.(var) and by_var[var].ref == :one, do: %{var: var, attr: attr, kind: :eq}
  end

  defp eq_key({:pin, _} = pin, {:ref, [], _} = ref, by_var, varies?),
    do: eq_key(ref, pin, by_var, varies?)

  defp eq_key(_a, _b, _by_var, _varies?), do: nil

  # The batched filter: each `:eq` key compares with the cells' values.
  defp batch_expr({:op, "==", a, b} = node, keys), do: batch_eq(node, a, b, keys)

  defp batch_expr({:call, "is_not_distinct_from", [a, b]} = node, keys),
    do: batch_eq(node, a, b, keys)

  defp batch_expr({op, nodes}, keys) when op in [:and, :or],
    do: {op, Enum.map(nodes, &batch_expr(&1, keys))}

  defp batch_expr(node, _keys), do: node

  defp batch_eq(node, {:ref, [], attr}, {:pin, var}, keys) do
    if MapSet.member?(keys, var), do: {:op, "in", {:ref, [], attr}, {:pin, var}}, else: node
  end

  defp batch_eq(node, {:pin, var}, {:ref, [], attr}, keys) do
    if MapSet.member?(keys, var), do: {:op, "in", {:ref, [], attr}, {:pin, var}}, else: node
  end

  defp batch_eq(node, _a, _b, _keys), do: node

  defp pins_in({:pin, var}), do: [var]
  defp pins_in({:op, _op, l, r}), do: pins_in(l) ++ pins_in(r)
  defp pins_in({:call, _name, args}), do: Enum.flat_map(args, &pins_in/1)
  defp pins_in({op, nodes}) when op in [:and, :or], do: Enum.flat_map(nodes, &pins_in/1)
  defp pins_in({:not, node}), do: pins_in(node)
  defp pins_in(list) when is_list(list), do: Enum.flat_map(list, &pins_in/1)
  defp pins_in(_node), do: []

  # --- conditional data sources (WTF-521) ------------------------------------------------

  # A data source folded with the conditional states that set one
  # (`BubbleEx.PageData`, IR `:if`, the last state outermost), outside a
  # repeating group's cell: read as `{:switch, %{cases, else}}`, each case
  # `%{when, then}`. The runtime tests the conditions in order (the last
  # state first) and reads only the winning branch, or the base (`else`):
  # each branch is a whole read of its own, a search with its constraints,
  # sort and page size (`{:query, q}`) or a value (`{:value, compiled}`),
  # and each condition a value. What it reads is the union of what they
  # all read (`reads`), so a change to the base's inputs or the
  # conditions' reads it again. Any part that does not bind leaves the
  # source unloaded. In a cell the fold is one value, computed per cell.
  defp fold?(%Source{kind: kind}, %IR{op: :if}) when kind in [:group, :list, :instance],
    do: true

  defp fold?(_source, _ir), do: false

  defp switch_source(s, ir, base, ctx, fns) do
    {cases, otherwise} = unfold(ir, [])

    parts =
      Enum.map(cases, fn {c, v} ->
        {condition_read(s, c, base, ctx, fns), branch(s, v, base, ctx, fns)}
      end)

    otherwise = branch(s, otherwise, base, ctx, fns)
    all = Enum.flat_map(parts, &Tuple.to_list/1) ++ [otherwise]

    case Enum.flat_map(all, & &1.residue) do
      [] ->
        %{
          base
          | read:
              {:switch,
               %{
                 cases: Enum.map(parts, fn {c, v} -> %{when: c.read, then: v.read} end),
                 else: otherwise.read
               }},
            resource: resource(s.type, ctx),
            reads: all |> Enum.flat_map(& &1.reads) |> Enum.uniq()
        }

      residue ->
        %{base | residue: Enum.uniq(residue)}
    end
  end

  # The cases of a fold, outermost (the last state) first, and its base.
  defp unfold(%IR{op: :if, args: [c, v, rest]}, acc), do: unfold(rest, [{c, v} | acc])
  defp unfold(base, acc), do: {Enum.reverse(acc), base}

  # A condition: a value (its searches read first, as any value's).
  defp condition_read(s, c, base, ctx, fns),
    do: value_source(s, %{s.value | ir: c}, %{base | read: nil, reads: []}, ctx, fns)

  # A branch: a whole search, or a value, of the element's kind of value
  # (`BubbleEx.PageData` checks the states; checked again here, after the
  # list operators are lowered).
  defp branch(s, ir, base, ctx, fns) do
    base = %{base | read: nil, reads: []}

    cond do
      ir.op != :empty and not PageData.same_shape?(s.type, ir.type) ->
        %{
          base
          | residue: [
              Residue.entry(s.id, :uncompiled_expression, %{
                expressions: 1,
                constructs: ["conditional_source_type"]
              })
            ]
        }

      match?({:query, _, _}, query(ir)) ->
        {:query, search, take} = query(ir)
        search_source(s, base, search, take, ctx, fns)

      true ->
        value_source(s, %{s.value | ir: ir}, base, ctx, fns)
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
        reads =
          Enum.uniq(data_reads(compiled.bindings, ctx) ++ query_reads(queries, ctx))

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
    with {:ok, ir, acc} <- extract(ir, s, ctx, fns, acc),
         :ok <- whole_lists(ir, s, acc) do
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

  # A search read as a query stops at `:max_items`: what is shown from it
  # may show less than Bubble, never more. Counting it, taking its last
  # item or subtracting it from a list (`:minus list`) would show a
  # different count or item, or items Bubble would remove: residue
  # (`elixir:capped_list`). A listed query reads all of a list's records.
  defp whole_lists(ir, s, acc) do
    capped =
      for q <- acc.queries,
          q.take == :all,
          !Map.get(q, :listed),
          into: MapSet.new(),
          do: Integer.to_string(q.n)

    if needs_whole?(ir, capped),
      do:
        {:error,
         [
           Residue.entry(s.id, :uncompiled_expression, %{
             expressions: 1,
             constructs: ["elixir:capped_list"]
           })
         ]},
      else: :ok
  end

  defp needs_whole?(%IR{op: op, args: [list | _]} = ir, capped) when op in [:count, :last],
    do: capped?(list, capped) or Enum.any?(ir.args, &needs_whole?(&1, capped))

  defp needs_whole?(%IR{op: :minus_list, args: [a, b]}, capped),
    do: capped?(b, capped) or needs_whole?(a, capped) or needs_whole?(b, capped)

  defp needs_whole?(%IR{args: args}, capped), do: Enum.any?(args, &needs_whole?(&1, capped))
  defp needs_whole?(_arg, _capped), do: false

  defp capped?(%IR{op: :input, args: [:query, %{"n" => n}]}, capped),
    do: MapSet.member?(capped, n)

  defp capped?(%IR{args: args}, capped), do: Enum.any?(args, &capped?(&1, capped))
  defp capped?(_arg, _capped), do: false

  defp query_input(n, type), do: IR.node(:input, [:query, %{"n" => Integer.to_string(n)}], type)

  defp queries?(%IR{} = ir), do: query(ir) != :value or Enum.any?(ir.args, &queries?/1)
  defp queries?(_arg), do: false

  # The page data the queries' pins read.
  defp query_reads(queries, ctx) do
    for q <- queries,
        %{value: %{bindings: bindings}} <- q.pins,
        read <- data_reads(bindings, ctx),
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
            reads: Enum.uniq(query_reads([query], ctx) ++ query_reads(queries, ctx))
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

  # A query for the records a list holds names the pin of their IDs
  # (`listed`): the loader reads all of them, in the list's order among
  # equal sort keys.
  defp listed({:ok, query, acc}, true) do
    case Enum.find(query.pins, &(&1.ref == :listed)) do
      %{var: var} -> {:ok, Map.put(query, :listed, var), acc}
      nil -> {:ok, query, acc}
    end
  end

  defp listed(result, _listed?), do: result

  # A list's things' IDs for a listed query, else what the pin holds.
  defp pin_ref(arg, hoisted), do: if(pinned?(arg, hoisted), do: :listed, else: ref_kind(arg.type))

  defp pinned?(%{input: {:hoisted, %{"n" => n}}}, hoisted),
    do: match?(%IR{op: :pinned}, Map.get(hoisted, n))

  defp pinned?(_arg, _hoisted), do: false

  # The filter with its context inputs and actor reads as pinned variables.
  defp pin(s, expr, take, hoisted, prefix, ctx, fns, acc) do
    {args, residue, acc} =
      expr.arguments
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], acc}, fn {arg, i}, {args, residue, acc} ->
        var = "#{prefix}pin_#{i}"

        case pin_value(arg, hoisted, s, ctx, fns, acc) do
          {:ok, value, acc} ->
            pin = %{var: var, value: value, ref: pin_ref(arg, hoisted), type: arg.type}
            {[{arg.name, pin} | args], residue, acc}

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
  # A keyword search's words (WTF-520): the `ILIKE` patterns of the
  # input's value, computed by the runtime (`keyword_patterns/1`), so the
  # database never splits the input per row.
  defp pin_value(%{keywords: true} = arg, hoisted, s, ctx, fns, acc) do
    input =
      case arg.input do
        {:hoisted, %{"n" => n}} ->
          case Map.fetch!(hoisted, n) do
            %IR{op: :pinned, args: [list]} -> list
            ir -> ir
          end

        {kind, ref} ->
          IR.node(:input, [kind, ref], arg.type)
      end

    compile_pin(IR.node(:keyword_patterns, [input], "list.text"), s, ctx, fns, acc)
  end

  defp pin_value(%{input: {:hoisted, %{"n" => n}}}, hoisted, s, ctx, fns, acc) do
    case Map.fetch!(hoisted, n) do
      %IR{op: :pinned, args: [list]} -> compile_pin(list, s, ctx, fns, acc)
      ir -> compile_pin(ir, s, ctx, fns, acc)
    end
  end

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
      {IR.node(:input, [:hoisted, %{"n" => n}], ir.type), Map.put(hoisted, n, ir)}
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

  # The page data a compiled value reads: an input whose first value is
  # page data (WTF-520, `ctx.initial`) is read after its initial content.
  defp data_reads(bindings, ctx) do
    initial = Map.get(ctx, :initial, MapSet.new())

    for %{bind: bind} <- bindings,
        read <- data_read(bind, initial),
        uniq: true,
        do: read
  end

  defp data_read({kind, _} = bind, _initial)
       when kind in [
              :data,
              :cell,
              :cell_index,
              :cell_data,
              :outer_cell,
              :outer_cell_index,
              :outer_cell_data
            ],
       do: [bind]

  defp data_read({:input, %{path: [], element: e}}, initial) do
    if MapSet.member?(initial, e), do: [{:data, %{path: [], element: e}}], else: []
  end

  defp data_read(_bind, _initial), do: []

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

  # An instance's property, read where the instance is: the value it sets,
  # else its default (WTF-520), when every value of the property loads.
  defp read_wired?(
         {:data, %{path: [i], element: "param_" <> _ = p}},
         _b,
         {by_element, params},
         wired
       ) do
    if Map.has_key?(by_element, {i, p}),
      do: MapSet.member?(wired, {i, p}),
      else: every_value?(params, p, wired)
  end

  # A read of the surface's own reusable-element thing is the instance's
  # (whatever it holds, possibly nothing).
  defp read_wired?({:data, %{path: [], element: e}}, %{surface: e}, {by_element, _}, wired),
    do: not Map.has_key?(by_element, e) or MapSet.member?(wired, e)

  defp read_wired?({:data, %{path: [instance]}}, _b, _maps, wired),
    do: MapSet.member?(wired, instance)

  defp read_wired?({:data, %{element: e}}, _b, _maps, wired), do: MapSet.member?(wired, e)

  defp read_wired?({kind, e}, _b, _by, wired)
       when kind in [
              :cell,
              :cell_index,
              :cell_data,
              :outer_cell,
              :outer_cell_index,
              :outer_cell_data
            ],
       do: MapSet.member?(wired, e)

  # A property read from outside an instance that sets none: its default
  # is one of its values, and every value loads.
  defp every_value?(params, p, wired) do
    case Map.get(params, p, []) do
      [] -> false
      ids -> Enum.all?(ids, &MapSet.member?(wired, &1))
    end
  end

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
        # property), an input's initial content reading the input
        # (WTF-520), or a conditional source whose condition or branch
        # reads the element's own value (WTF-521: it would read it empty,
        # and decide on that), is a cycle.
        e != id(b) or b.kind in [:param, :input] or match?({:switch, _}, b.read),
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

  defp dep_element({kind, e})
       when kind in [
              :cell,
              :cell_index,
              :cell_data,
              :outer_cell,
              :outer_cell_index,
              :outer_cell_data
            ],
       do: [e]

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
