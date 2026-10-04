defmodule BubbleEx.PageData do
  @moduledoc """
  Stack-neutral lowering of the data a Bubble page shows (WTF-420): the
  page's "Type of content" (its thing, from the page URL) and the data
  sources of its groups, repeating groups and reusable-element instances,
  each compiled to `BubbleEx.Expression.IR` by
  `BubbleEx.Expression.Compiler` in its element's environment, or kept as
  **residue** (`BubbleEx.Plan.Residue` entries) with a `:page_data_residue`
  diagnostic. Nothing is dropped silently.

      {:ok, model} = BubbleEx.Model.build(app)
      {:ok, page_data} = BubbleEx.PageData.build(app, model)

  There are no target names here: `BubbleEx.Target.Elixir.FrontendWorkflows`
  binds the sources to Ash reads and LiveView (`page_data:`), adding its
  own residue.

  ## Sources

  One `BubbleEx.PageData.Source` per page with a type of content and per
  element of a page or reusable element (not a mobile view) with a data
  source:

  | Bubble | `kind` | value |
  |--------|--------|-------|
  | a page's "Type of content" | `:page_thing` | none: the thing whose unique ID is the URL's path segment after the page name (`/<page>/<id>`) |
  | a Group's, Popup's, Floating Group's or Group Focus's data source | `:group` | the thing (or value) it holds |
  | a Repeating Group's data source | `:list` | its list (a search with constraints and sort, a list field, option values, …); `page_size` the items a page of it shows (rows × columns), nil when it shows them all |
  | a reusable-element instance's data source | `:instance` | the reusable element's thing, for that instance (`holder`: the reusable element) |
  | a property a reusable-element instance sets (WTF-493) | `:param` | its value, computed where the instance is (`holder`: the reusable element; `param`: `"param_<id>"`) |
  | a reusable element property's default value | `:param` | computed inside the reusable element (`element` and `holder` are the reusable element), for the instances that do not set it |

  An instance in a repeating group's cell lists every property its
  reusable element declares, with a nil `value` for one it does not set
  (the target cannot pass any of them there yet).

  A property set to a static value is that value as the property's type
  (`"true"` as a yes/no, `"1.5"` as a number); one the instance does not
  set, with no default, is empty. Bubble has no action that changes a
  property: workflows only read it.

  `cell` is the repeating group whose cell holds the element (nil outside
  one): its value is computed per cell. Other elements' data sources (a
  dropdown's choices, a table, a plugin's) are not group data and not
  listed.

  A search's constraint whose value is empty matches nothing unless the
  search states `ignore_empty_constraints: true`, which drops it (Bubble's
  page searches, replayed 2026-10-01; `BubbleEx.Expression.Compiler`). A
  `:filtered` list that does not state it, with a constraint value that
  may be empty, is residue (`:uncompiled_expression`, construct
  `ignore_empty_constraints`) unless the caller supplies a default
  (`:ignore_empty_constraints`).

  ## Residue

  On the element (`element:<id>`) or page (`page:<id>`) symbol:
  `:uncompiled_expression` (the data source does not compile to IR),
  `:unsupported_option` (`detail.options`: `["page_item_type"]` for a page
  whose type of content is not a data type) and `:search_field_restricted`
  (`detail.fields`: a search whose constraints or sort name fields a
  privacy rule of the searched type keeps out of searches, which Bubble
  limits per user and the generated page cannot).

  ## Coverage

  See `coverage/1`.
  """

  alias BubbleEx.{Diagnostic, Error, Model}
  alias BubbleEx.Expression.{Env, IR, Tree}
  alias BubbleEx.Index.Symbol
  alias BubbleEx.Model.Type
  alias BubbleEx.PageData.Source
  alias BubbleEx.Plan.Residue
  alias BubbleEx.Workflows.Lowering
  alias BubbleEx.Workflows.Source, as: Json

  defstruct sources: [], diagnostics: []

  @type t :: %__MODULE__{sources: [Source.t()], diagnostics: [Diagnostic.t()]}

  @holders %{
    "Group" => :group,
    "Popup" => :group,
    "FloatingGroup" => :group,
    "GroupFocus" => :group,
    "RepeatingGroup" => :list,
    "CustomElement" => :instance
  }

  @repeating ~w(RepeatingGroup Table)

  @doc """
  Lowers the page data of decoded app JSON. `model` must be built from the
  same app.

  ## Options

    * `:ignore_empty_constraints` - what a `:filtered` list that does not
      state Bubble's `ignore_empty_constraints` does with an empty
      constraint value (`BubbleEx.Expression.Env`): nil (unknown, the
      default: such a list is residue), `true` or `false`. Searches do not
      read it.
  """
  @spec build(map(), Model.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def build(app, model, opts \\ [])

  def build(app, %Model{} = model, opts)
      when is_map(app) and not is_struct(app) and is_list(opts) do
    tree = Tree.build(app)

    env =
      Env.new(model,
        tree: tree,
        searches: :page,
        ignore_empty_constraints: Keyword.get(opts, :ignore_empty_constraints)
      )

    ctx = %{model: model, env: env}

    sources =
      [{"pages", :page}, {"element_definitions", :reusable}]
      |> Enum.flat_map(fn {section, kind} ->
        for {key, raw} <- Json.entries(Map.get(app, section)),
            is_map(raw),
            source <- surface(raw, [section, key], kind, key, ctx),
            do: source
      end)
      |> Enum.sort_by(&{&1.surface, &1.element})

    diagnostics =
      sources
      |> Enum.flat_map(&diagnostics/1)
      |> Diagnostic.normalize()

    {:ok, %__MODULE__{sources: sources, diagnostics: diagnostics}}
  end

  def build(_app, _model, _opts),
    do: {:error, Error.new(:invalid_input, "expected app JSON, its Model and options")}

  @doc "Every residue entry, sorted (for `BubbleEx.Plan.build/5`'s `residue:`)."
  @spec residue(t()) :: [Residue.t()]
  def residue(%__MODULE__{sources: sources}),
    do: sources |> Enum.flat_map(& &1.residue) |> Residue.sort()

  @doc """
  Lowering coverage (IR level), with string keys:

    * `"sources"` - `total`, `native` (it lowers: a page's thing of a data
      type, or a data source that compiles to IR) and `residue`
    * `"by_kind"` - `{total, native}` per kind (`page_thing`, `group`,
      `list`, `instance`), `"in_cell"` the same for sources inside a
      repeating group's cell
    * `"residue_reasons"` - residue entries per reason

  The target adds its own (a query or value it cannot generate, an input
  the page does not provide); see
  `BubbleEx.Target.Elixir.FrontendWorkflows.Spec.data_coverage/1`.
  """
  @spec coverage(t()) :: map()
  def coverage(%__MODULE__{sources: sources}) do
    native = Enum.filter(sources, &Source.native?/1)

    %{
      "sources" => %{
        "total" => length(sources),
        "native" => length(native),
        "residue" => length(sources) - length(native)
      },
      "by_kind" => totals(sources, &Atom.to_string(&1.kind)),
      "in_cell" => totals(Enum.filter(sources, & &1.cell), &Atom.to_string(&1.kind)),
      "residue_reasons" =>
        sources
        |> Enum.flat_map(& &1.residue)
        |> Enum.frequencies_by(&Atom.to_string(&1.reason))
    }
  end

  defp totals(sources, key) do
    sources
    |> Enum.group_by(key)
    |> Map.new(fn {k, ss} ->
      {k, %{"total" => length(ss), "native" => Enum.count(ss, &Source.native?/1)}}
    end)
  end

  @doc """
  The context inputs a source's value reads (`{kind, ref}` of
  `BubbleEx.Expression.IR` `:input` nodes), sorted and unique.
  """
  @spec inputs(Source.t()) :: [{atom(), map()}]
  def inputs(%Source{value: %Lowering.Expr{ir: %IR{} = ir}}),
    do: ir |> input_nodes() |> Enum.uniq() |> Enum.sort()

  def inputs(%Source{}), do: []

  defp input_nodes(%IR{op: :input, args: [kind, ref]}), do: [{kind, ref}]
  defp input_nodes(%IR{args: args}), do: Enum.flat_map(args, &input_nodes/1)
  defp input_nodes(list) when is_list(list), do: Enum.flat_map(list, &input_nodes/1)
  defp input_nodes(_), do: []

  # --- surfaces --------------------------------------------------------------------

  defp surface(raw, path, kind, key, ctx) do
    id = text(Json.value(raw, ~w(id %id))) || to_string(key)
    props = props(raw)

    own =
      case kind do
        :page -> page_thing(id, props, path, ctx)
        :reusable -> defaults(id, props, path ++ [props_key(raw)], ctx)
      end

    own ++ elements(raw, path, %{surface: id, surface_kind: kind, cell: nil}, ctx)
  end

  defp page_thing(id, props, path, ctx) do
    case text(props["page_item_type"]) do
      nil ->
        []

      type ->
        symbol = Symbol.id(:page, id)
        key = Lowering.data_type_key(type)

        residue =
          if key && Model.data_type(ctx.model, key),
            do: [],
            else: [Residue.entry(symbol, :unsupported_option, %{options: ["page_item_type"]})]

        [
          %Source{
            id: symbol,
            element: id,
            surface: id,
            surface_kind: :page,
            kind: :page_thing,
            type: type,
            residue: residue,
            path: Diagnostic.pointer(path ++ ["properties", "page_item_type"])
          }
        ]
    end
  end

  defp elements(raw, path, at, ctx) do
    case Json.get(raw, ~w(elements %el)) do
      {elements_key, elements} ->
        elements
        |> Json.entries()
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.flat_map(fn {key, element} ->
          element(element, path ++ [elements_key, key], key, at, ctx)
        end)

      nil ->
        []
    end
  end

  defp element(raw, path, key, at, ctx) when is_map(raw) do
    id = text(Json.value(raw, ~w(id %id))) || to_string(key)
    type = Json.value(raw, ~w(type %x))
    props = props(raw)

    own =
      case {Map.get(@holders, type), data_source(props)} do
        {nil, _} ->
          []

        {_, :none} ->
          []

        {kind, {prop, value}} ->
          [source(kind, id, props, value, path ++ [props_key(raw), prop], at, ctx)]
      end

    params =
      if type == "CustomElement",
        do: instance_params(id, props, path ++ [props_key(raw)], at, ctx),
        else: []

    inner = if type in @repeating, do: %{at | cell: id}, else: at
    own ++ params ++ elements(raw, path, inner, ctx)
  end

  defp element(_raw, _path, _key, _at, _ctx), do: []

  defp data_source(props) do
    cond do
      Map.has_key?(props, "data_source") -> {"data_source", props["data_source"]}
      Map.has_key?(props, "%ds") -> {"%ds", props["%ds"]}
      true -> :none
    end
  end

  defp source(kind, id, props, value, vpath, at, ctx) do
    symbol = Symbol.id(:element, id)
    node = Tree.node(ctx.env.tree, id)
    content = node && node.content
    expr = Lowering.expr(value, vpath, %{ctx.env | host: id})

    %Source{
      id: symbol,
      element: id,
      surface: at.surface,
      surface_kind: at.surface_kind,
      kind: kind,
      holder: if(kind == :instance, do: node && node.instance_of),
      type: value_type(kind, content, expr),
      value: expr,
      cell: at.cell,
      page_size: if(kind == :list, do: page_size(props)),
      residue:
        Lowering.expr_residue(symbol, [expr]) ++ search_fields(symbol, expr, ctx.env.model),
      path: Diagnostic.pointer(vpath)
    }
  end

  # --- reusable element properties (WTF-493) ------------------------------------------

  # The properties an instance sets, each computed where the instance is
  # (its parent's scope, a cell's when in one).
  defp instance_params(id, props, ppath, at, ctx) do
    node = Tree.node(ctx.env.tree, id)
    holder = node && node.instance_of
    declared = declared(holder, ctx)

    # In a repeating group's cell the instance is not a surface of its own
    # yet: every property it declares is listed, set or not, so the
    # binding marks each one (none is passed there).
    for {param, type} <- Enum.sort(declared),
        key = "param_" <> param,
        props[key] != nil or at.cell != nil do
      param_source(%{
        element: id,
        holder: holder,
        param: key,
        type: type,
        raw: props[key],
        vpath: ppath ++ [key],
        symbol: Symbol.id(:element, id),
        env: %{ctx.env | host: id},
        at: at,
        model: ctx.model
      })
    end
  end

  # A reusable element's property defaults, computed inside it.
  defp defaults(id, props, ppath, ctx) do
    declared = declared(id, ctx)

    case props["parameters"] do
      params when is_map(params) ->
        for {key, %{"param_id" => param} = raw} <- Enum.sort(params),
            is_map_key(declared, param),
            raw["default_value"] != nil do
          param_source(%{
            element: id,
            holder: id,
            param: "param_" <> param,
            type: declared[param],
            raw: raw["default_value"],
            vpath: ppath ++ ["parameters", key, "default_value"],
            symbol: Symbol.id(:reusable, id),
            env: %{ctx.env | host: id},
            at: %{surface: id, surface_kind: :reusable, cell: nil},
            model: ctx.model
          })
        end

      _ ->
        []
    end
  end

  # A reusable element's properties: ID => type (a list's `list.` type).
  defp declared(nil, _ctx), do: %{}

  defp declared(id, ctx) do
    case Tree.node(ctx.env.tree, id) do
      %Tree.Node{params: params} -> params
      nil -> %{}
    end
  end

  defp param_source(p) do
    expr = if p.raw == nil, do: nil, else: param_value(p.raw, p.type, p.vpath, p.env)

    %Source{
      id: p.symbol,
      element: p.element,
      surface: p.at.surface,
      surface_kind: p.at.surface_kind,
      kind: :param,
      holder: p.holder,
      param: p.param,
      type: p.type,
      value: expr,
      cell: p.at.cell,
      residue: Lowering.expr_residue(p.symbol, [expr]) ++ search_fields(p.symbol, expr, p.model),
      path: Diagnostic.pointer(p.vpath)
    }
  end

  # A static value is the property's type: the editor keeps yes/no and
  # numbers as text.
  defp param_value(raw, type, vpath, env) when is_binary(raw) do
    case static(raw, type) do
      {:ok, value} -> Lowering.expr(value, vpath, env)
      :error -> %Lowering.Expr{path: Diagnostic.pointer(vpath), constructs: ["static_value"]}
    end
  end

  defp param_value(raw, _type, vpath, env), do: Lowering.expr(raw, vpath, env)

  defp static(raw, "text"), do: {:ok, raw}
  defp static("true", "boolean"), do: {:ok, true}
  defp static("false", "boolean"), do: {:ok, false}

  defp static(raw, "number") do
    raw = String.trim(raw)

    case {Integer.parse(raw), Float.parse(raw)} do
      {{n, ""}, _} -> {:ok, n}
      {_, {n, ""}} -> {:ok, n}
      _ -> :error
    end
  end

  defp static(_raw, _type), do: :error

  # A search whose constraints or sort name a field some privacy rule of
  # the searched type keeps out of searches (non-filterable): Bubble limits
  # it per user, which the generated page cannot tell, so it is residue.
  defp search_fields(symbol, %Lowering.Expr{ir: %IR{} = ir}, %Model{} = model) do
    fields =
      for {type, field} <- searched_fields(ir),
          field in non_filterable(model, type),
          uniq: true,
          do: field

    if fields == [],
      do: [],
      else: [Residue.entry(symbol, :search_field_restricted, %{fields: Enum.sort(fields)})]
  end

  defp search_fields(_symbol, _expr, _model), do: []

  # `{data type, field}` for each field a search's constraints read from
  # the searched item, and its sort field.
  defp searched_fields(%IR{op: :sort, args: [inner, field, _desc]} = ir) do
    sorted =
      case inner do
        %IR{op: :search, args: [type, _]} when is_binary(field) -> [{type, field}]
        _ -> []
      end

    sorted ++ Enum.flat_map(ir.args, &searched_fields/1)
  end

  defp searched_fields(%IR{op: :search, args: [type, pred]}),
    do: for(field <- item_fields(pred), do: {type, field}) ++ searched_fields(pred)

  defp searched_fields(%IR{args: args}), do: Enum.flat_map(args, &searched_fields/1)
  defp searched_fields(_other), do: []

  defp item_fields(%IR{op: :field, args: [%IR{op: :this, args: [:filter_item]}, _type, field]}),
    do: [field]

  defp item_fields(%IR{args: args}), do: Enum.flat_map(args, &item_fields/1)
  defp item_fields(_other), do: []

  defp non_filterable(model, type) do
    case Enum.find(model.data_types, &(&1.id == type)) do
      nil ->
        []

      data_type ->
        for %{permissions: %{} = p} <- data_type.rules,
            f <- p.non_filterable_fields || [],
            do: f
    end
  end

  # The value's type: the element's type of content (a list of it for a
  # repeating group), else what the expression compiled to.
  defp value_type(:list, content, _expr) when is_binary(content), do: listed(content)
  defp value_type(_kind, content, _expr) when is_binary(content), do: content
  defp value_type(_kind, _content, %Lowering.Expr{ir: %IR{type: type}}), do: type
  defp value_type(_kind, _content, _expr), do: nil

  defp listed(type), do: Type.listed(type)

  # A repeating group's page (rows × columns), as the element tree reads it.
  defp page_size(props), do: Tree.page_size(props)

  defp props_key(raw) do
    case Json.get(raw, ~w(properties %p)) do
      {key, _} -> key
      nil -> "properties"
    end
  end

  defp props(raw) do
    case Json.value(raw, ~w(properties %p)) do
      props when is_map(props) -> props
      _ -> %{}
    end
  end

  # --- diagnostics -----------------------------------------------------------------

  defp diagnostics(%Source{residue: residue} = source) do
    for %{subject: subject, reason: reason, detail: detail} <- residue do
      Diagnostic.new(
        :page_data_residue,
        source.path,
        "#{subject}'s #{kind_text(source.kind)} is not lowered (#{reason}); it is left for agent work",
        details: %{subject: subject, reason: Atom.to_string(reason), detail: detail}
      )
    end
  end

  defp kind_text(:page_thing), do: "type of content"
  defp kind_text(:param), do: "property value"
  defp kind_text(_kind), do: "data source"

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_), do: nil
end
