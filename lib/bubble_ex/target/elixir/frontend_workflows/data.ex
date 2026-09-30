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

  What a source reads of the page is bound as a workflow's values are
  (`BubbleEx.Target.Elixir.FrontendWorkflows`), plus the page's data:
  `{:data, key}` (a page's thing, a group's, a repeating group's list or
  an instance's thing, `key` `%{path, element}` as a custom state's),
  `{:cell, rg}`, `{:cell_index, rg}` and `{:cell_data, group}` (in a
  repeating group's cell).

  ## Residue added here

    * `:page_data_in_cell` - a repeating group or reusable instance in a
      repeating group's cell, or a search there: the page would read once
      per cell
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
  alias BubbleEx.Workflows.Lowering

  @doc """
  The page's data holders (every source that lowered), for binding reads
  before the sources themselves are bound; nil page data has none.
  """
  @spec index(PageData.t() | nil) :: map()
  def index(nil), do: %{elements: %{}, roots: MapSet.new()}

  def index(%PageData{sources: sources}) do
    elements =
      for s <- sources,
          Source.native?(s),
          into: %{},
          do: {s.element, %{kind: s.kind, surface: s.surface, cell: s.cell, holder: s.holder}}

    %{elements: elements, roots: roots(sources)}
  end

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

    %{
      elements:
        Map.new(
          wired,
          &{&1.element, %{kind: &1.kind, surface: &1.surface, cell: &1.cell, holder: &1.holder}}
        ),
      roots: for(%{kind: :instance, holder: h} <- wired, is_binary(h), into: MapSet.new(), do: h)
    }
  end

  @doc """
  Binds every source of `page_data`. `ctx` is the frontend workflows
  binding's context (with `:project`, `:data` from `index/1`); `fns` has
  `compile` (`fn expr, subject, ctx -> {compiled | nil, residue}`) and
  `bind` (`fn input, ctx -> {:ok, bind} | {:error, kind}`), the binding's
  own. Returns the bound sources by surface, in the order the page reads
  them (a source after those it reads).
  """
  @spec bind(PageData.t() | nil, map(), map()) :: %{String.t() => [map()]}
  def bind(nil, _ctx, _fns), do: %{}

  def bind(%PageData{sources: sources}, ctx, fns) do
    sources
    |> Enum.map(&source(&1, ctx, fns))
    |> prune()
    |> Enum.group_by(& &1.surface)
    |> Map.new(fn {surface, bound} -> {surface, order(bound)} end)
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
      key: key(s),
      type: s.type,
      list?: s.kind == :list,
      page_size: s.page_size,
      resource: nil,
      read: nil,
      reads: [],
      residue: s.residue
    }

    cond do
      s.residue != [] ->
        base

      s.cell != nil and s.kind != :group ->
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

  defp key(%Source{kind: :instance, element: e, holder: holder}),
    do: %{path: [e], element: holder}

  defp key(%Source{element: e}), do: %{path: [], element: e}

  defp in_cell(base, kind),
    do: %{
      base
      | residue: [Residue.entry(base.symbol, :page_data_in_cell, %{kind: Atom.to_string(kind)})]
    }

  defp value(%Source{value: %{ir: ir}} = s, base, ctx, fns) do
    bctx =
      Map.merge(ctx, %{
        surface: s.surface,
        cell: s.cell,
        subject: s.id,
        workflow: %{bubble_id: nil, parameters: []}
      })

    case query(ir) do
      {:query, search, take} when s.cell == nil ->
        search_source(s, base, search, take, bctx, fns)

      {:query, _search, _take} ->
        in_cell(base, :query)

      :value ->
        {compiled, residue} = fns.compile.(s.value, s.id, bctx)
        reads = if compiled, do: data_reads(compiled.bindings), else: []

        %{
          base
          | read: if(compiled, do: {:value, compiled}),
            resource: resource(s.type, ctx),
            reads: reads,
            residue: residue
        }
    end
  end

  # A search read as a query: the search (possibly sorted) and how much of
  # it the source takes.
  defp query(%IR{op: :search} = ir), do: {:query, ir, :all}
  defp query(%IR{op: :sort, args: [%IR{op: :search} | _]} = ir), do: {:query, ir, :all}

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
    {search, hoisted} = hoist(search)

    case Expressions.search(search, ctx.project) do
      {:ok, %{expr: %Expr{} = expr}} ->
        case hidden_fields(expr, ctx.project) do
          [] ->
            pin(s, base, expr, take, hoisted, ctx, fns)

          fields ->
            %{base | residue: [Residue.entry(s.id, :search_field_hidden, %{fields: fields})]}
        end

      {:ok, %{diagnostics: diags}} ->
        constructs =
          diags
          |> Enum.flat_map(&Map.get(&1.details, :constructs, []))
          |> Enum.map(&("ash:" <> &1))
          |> Enum.uniq()
          |> Enum.sort()

        %{
          base
          | residue: [
              Residue.entry(s.id, :uncompiled_expression, %{
                expressions: 1,
                constructs: if(constructs == [], do: ["ash:uncompiled"], else: constructs)
              })
            ]
        }
    end
  end

  # With enforced policies (WTF-423), the fields a search's filter or sort
  # reads that some users may not view, as `<Resource>.<field>`, and the
  # gated relationships it follows (`<Resource>.<relationship>`): field
  # policies guard `filter_input` and reads, not a filter written in code,
  # so such a search would reveal what the rules hide. Empty otherwise.
  defp hidden_fields(%Expr{} = expr, %Project{privacy: :enforced} = project) do
    modules = Map.new(project.resources ++ project.joins, &{&1.module, &1})

    refs =
      expr_refs(expr.expr) ++ Enum.map(expr.sort, fn {attribute, _} -> {[], attribute} end)

    refs
    |> Enum.flat_map(fn {rels, attribute} ->
      hidden_path(expr.resource, rels, attribute, modules)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp hidden_fields(_expr, _project), do: []

  defp hidden_path(module, [], attribute, modules) do
    case modules[module] do
      nil -> []
      r -> if visible_to_all?(r, attribute), do: [], else: ["#{module}.#{attribute}"]
    end
  end

  defp hidden_path(module, [rel | rest], attribute, modules) do
    with %{} = r <- modules[module],
         %{} = relationship <- Enum.find(r.relationships, &(&1.name == rel)) do
      if relationship.gate == nil,
        do: hidden_path(relationship.destination, rest, attribute, modules),
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

  # The filter with its context inputs and actor reads as pinned variables.
  defp pin(s, base, expr, take, hoisted, ctx, fns) do
    {args, residue} =
      Enum.map_reduce(Enum.with_index(expr.arguments, 1), [], fn {arg, i}, acc ->
        var = "pin_#{i}"

        case pin_value(arg, hoisted, s, ctx, fns) do
          {:ok, value} -> {{arg.name, %{var: var, value: value, ref: ref_kind(arg.type)}}, acc}
          {:error, r} -> {nil, acc ++ r}
        end
      end)

    if residue != [] do
      %{base | residue: Residue.sort(Enum.uniq(residue))}
    else
      args = Map.new(args)
      {node, actors} = rewrite(expr.expr, args, %{})

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

      reads =
        pins
        |> Enum.flat_map(fn
          %{value: %{bindings: bindings}} -> data_reads(bindings)
          _ -> []
        end)
        |> Enum.uniq()

      %{base | read: {:query, query}, resource: expr.resource, reads: reads}
    end
  end

  # A pinned argument: a hoisted value, compiled in Elixir, or a context
  # input bound as a workflow's.
  defp pin_value(%{input: {:hoisted, %{"n" => n}}}, hoisted, s, ctx, fns),
    do: compile_pin(Map.fetch!(hoisted, n), s, ctx, fns)

  defp pin_value(%{input: {kind, ref}, type: type}, _hoisted, s, ctx, fns),
    do: compile_pin(IR.node(:input, [kind, ref], type), s, ctx, fns)

  defp compile_pin(ir, s, ctx, fns) do
    case fns.compile.(%Lowering.Expr{path: s.path, ir: ir}, s.id, ctx) do
      {%{} = compiled, []} -> {:ok, compiled}
      {_compiled, residue} -> {:error, residue}
    end
  end

  defp ref_kind(type) do
    case classify(type) do
      %Type{kind: :ref, cardinality: :one} -> :one
      %Type{kind: :ref, cardinality: :many} -> :many
      _ -> nil
    end
  end

  # Replaces `^arg(name)` with its pin and every `^actor(path)` with one
  # pin per path (`actor_<n>`).
  defp rewrite({:arg, name}, args, actors), do: {{:pin, args[name].var}, actors}

  defp rewrite({:actor, path}, _args, actors) do
    case actors[path] do
      nil ->
        var = "actor_#{map_size(actors) + 1}"
        {{:pin, var}, Map.put(actors, path, var)}

      var ->
        {{:pin, var}, actors}
    end
  end

  defp rewrite({:op, op, l, r}, args, actors) do
    {l, actors} = rewrite(l, args, actors)
    {r, actors} = rewrite(r, args, actors)
    {{:op, op, l, r}, actors}
  end

  defp rewrite({op, nodes}, args, actors) when op in [:and, :or] do
    {nodes, actors} = Enum.map_reduce(nodes, actors, &rewrite(&1, args, &2))
    {{op, nodes}, actors}
  end

  defp rewrite({:not, node}, args, actors) do
    {node, actors} = rewrite(node, args, actors)
    {{:not, node}, actors}
  end

  defp rewrite({:call, name, nodes}, args, actors) do
    {nodes, actors} = Enum.map_reduce(nodes, actors, &rewrite(&1, args, &2))
    {{:call, name, nodes}, actors}
  end

  defp rewrite(node, _args, actors), do: {node, actors}

  # Every maximal part of a search's constraints that does not read the
  # searched item and reads a context value through a field (which the
  # Ash filter cannot) is computed in Elixir and passed in as a hoisted
  # input.
  defp hoist(%IR{op: :sort, args: [inner | rest]} = ir) do
    {inner, hoisted} = hoist(inner)
    {%{ir | args: [inner | rest]}, hoisted}
  end

  defp hoist(%IR{op: :search, args: [type, pred]} = ir) when not is_nil(pred) do
    {pred, hoisted} = hoist_node(pred, %{})
    {%{ir | args: [type, pred]}, hoisted}
  end

  defp hoist(ir), do: {ir, %{}}

  defp hoist_node(%IR{} = ir, hoisted) do
    if hoistable?(ir) do
      n = Integer.to_string(map_size(hoisted) + 1)
      {IR.node(:input, [:hoisted, %{"n" => n}], ir.type), Map.put(hoisted, n, ir)}
    else
      {args, hoisted} =
        Enum.map_reduce(ir.args, hoisted, fn
          %IR{} = arg, acc -> hoist_node(arg, acc)
          other, acc -> {other, acc}
        end)

      {%{ir | args: args}, hoisted}
    end
  end

  # A field (or anything over one) of a context input, not of the item;
  # whether a context value is empty (a search ignoring empty constraints)
  # is known before the query, so it is computed first too.
  defp hoistable?(%IR{op: op} = ir) when op in [:field, :is_empty],
    do: not reads_item?(ir) and reads_input?(ir)

  defp hoistable?(_ir), do: false

  defp reads_item?(%IR{op: :this}), do: true
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
    wired = for b <- bound, b.residue == [], into: MapSet.new(), do: b.element
    wired = prune_fixpoint(wired, bound)

    Enum.map(bound, fn b ->
      if b.residue == [] and not MapSet.member?(wired, b.element),
        do: %{
          b
          | read: nil,
            residue: [Residue.entry(b.symbol, :unavailable_input, %{inputs: ["data_source"]})]
        },
        else: b
    end)
  end

  defp prune_fixpoint(wired, bound) do
    by_element = Map.new(bound, &{&1.element, &1})

    next =
      for b <- bound,
          MapSet.member?(wired, b.element),
          Enum.all?(b.reads, &read_wired?(&1, b, by_element, wired)),
          into: MapSet.new(),
          do: b.element

    if next == wired, do: wired, else: prune_fixpoint(next, bound)
  end

  # A read of the surface's own reusable-element thing is the instance's
  # (whatever it holds, possibly nothing).
  defp read_wired?({:data, %{path: [], element: e}}, %{surface: e}, by_element, wired),
    do: not Map.has_key?(by_element, e) or MapSet.member?(wired, e)

  defp read_wired?({:data, %{path: [instance]}}, _b, _by_element, wired),
    do: MapSet.member?(wired, instance)

  defp read_wired?({:data, %{element: e}}, _b, _by_element, wired), do: MapSet.member?(wired, e)

  defp read_wired?({kind, rg}, _b, _by, wired) when kind in [:cell, :cell_index],
    do: MapSet.member?(wired, rg)

  defp read_wired?({:cell_data, g}, _b, _by, wired), do: MapSet.member?(wired, g)

  # The order a surface reads its sources in: after those they read. The
  # ones reading each other in a cycle are residue.
  defp order(bound) do
    by_element = Map.new(bound, &{&1.element, &1})
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

    Enum.reverse(ordered) ++ Enum.sort_by(cyclic, & &1.element)
  end

  defp kahn(bound, by_element, ordered, done) do
    {ready, waiting} =
      bound
      |> Enum.reject(&MapSet.member?(done, &1.element))
      |> Enum.split_with(fn b ->
        Enum.all?(deps(b, by_element), &MapSet.member?(done, &1))
      end)

    case Enum.sort_by(ready, & &1.element) do
      [] ->
        {ordered, waiting}

      ready ->
        kahn(
          bound,
          by_element,
          Enum.reverse(ready) ++ ordered,
          Enum.into(Enum.map(ready, & &1.element), done)
        )
    end
  end

  # The sources of the same surface a source reads first.
  defp deps(b, by_element) do
    for read <- b.reads,
        e <- dep_element(read),
        Map.has_key?(by_element, e),
        e != b.element,
        uniq: true,
        do: e
  end

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
