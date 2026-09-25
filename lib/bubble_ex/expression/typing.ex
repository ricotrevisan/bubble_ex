defmodule BubbleEx.Expression.Typing do
  @moduledoc """
  Resolves the static Bubble type of every node of an expression AST, using
  the app's `BubbleEx.Model` and element tree (`BubbleEx.Expression.Env`).

      {:ok, %{ast: typed, diagnostics: diagnostics}} = BubbleEx.Expression.Typing.type(ast, env)

  The parser types field chains from the schema alone; context values
  (elements, custom states, parent groups, repeating-group cells, previous
  steps, page things) reach it untyped, and so does every accessor after
  them. This pass types them from where the expression sits, bottom-up:

  | Node | Type |
  |------|------|
  | literal, current user, option value, all options, text, search | as parsed |
  | `This Thing` | the innermost binder's: the rule's data type, a search's or `:filtered` list's item type, or `env.this_type` |
  | parent group's / ancestor group's thing | the content type of the nearest enclosing group that has one (of `ancestor_type` for an ancestor) |
  | current cell's thing / index | the enclosing repeating group's content type / number; in a database-trigger workflow, the triggering record |
  | thing before change | the triggering record's type |
  | current page's thing | the page's type (unknown inside a reusable) |
  | result of step N | the step's result type (`env.steps`) |
  | workflow / API parameter | its declared `btype_id` |
  | page data, URL parameter | by name (`Current Date/Time` is a date, a URL parameter is text) |
  | `field` on a record, option or API type | the field's, option attribute's or external field's type; on a list, a list of it |
  | element state (`is visible`, `value`, `group's thing`, a reusable's parameter, a custom state) | from the element tree |
  | comparisons, `and`/`or`, checks, list predicates | yes/no |
  | arithmetic | the left operand's type |
  | list operators, `:filtered`, `defaulting to` | from their operands |

  A `Property` whose name turns out to be a field of its now-typed subject
  becomes a `Field`. An element state or a known text/number operator stays
  a `Property` with its `type` set. What cannot be typed keeps `type: nil`
  and gets a diagnostic (stage `:model`): `:expr_untyped_scope` for a context
  value, `:expr_unresolved_accessor` for an accessor. Typing never drops or
  reorders input, so `BubbleEx.Expression.to_bubble/1` still round-trips.
  """

  alias BubbleEx.AppTree.Expr.Explanation
  alias BubbleEx.{Diagnostic, Error}
  alias BubbleEx.Expression.{Ast, Env, Keys, Schema, Tree}
  alias BubbleEx.Model
  alias BubbleEx.Model.{DataType, ExternalType, OptionSet}

  alias BubbleEx.Expression.Ast.{
    AllOptions,
    ArbitraryText,
    Arithmetic,
    Check,
    Compare,
    Constraint,
    CurrentUser,
    DynamicText,
    Empty,
    Fallback,
    Field,
    Filter,
    ListOp,
    Literal,
    Logical,
    OptionValue,
    Property,
    Raw,
    Scope,
    Search,
    ThisThing
  }

  # Accessors Bubble applies to elements (their states), by result type.
  @element_booleans ~w(is_visible isnt_visible is_hovered is_focused is_pressed is_valid
                       isnt_valid is_checked is_disabled is_clickable isnt_clickable
                       is_first_page is_last_page)

  # Bubble operators without arguments that the parser's vocabulary does not
  # model, so they reach typing as `Property` nodes: name => result type
  # (`:same` keeps the operand's type).
  @operators %{
    "to_lowercase" => "text",
    "to_uppercase" => "text",
    "trim" => "text",
    "capitalized_words" => "text",
    "format_json_encode" => "text",
    "format_url_encode" => "text",
    "length" => "number",
    "number_of_characters" => "number",
    "is_email" => "boolean",
    "absolute_value" => :same,
    "rounded" => :same,
    "as_text" => "text",
    "convert_to_number" => "number",
    "format_date" => "text",
    "url" => "text"
  }

  @page_data %{
    "Current Date/Time" => "date",
    "AppVersion" => "text",
    "AppIsTest" => "boolean",
    "Current Page Name" => "text",
    "Current Page Width" => "number",
    "Current Page Height" => "number"
  }

  @repeating ~w(RepeatingGroup TableMainAxis TableCrossAxis Table)

  @type input :: {atom(), %{String.t() => term()}}
  @type context ::
          {:value, input(), String.t() | nil}
          | {:element, Tree.Node.t() | nil}
          | :unknown

  @doc """
  Types `ast` in `env`. Returns the typed AST and its diagnostics
  (normalized; stage `:model`, subject `env.subject`, pointers under
  `env.path`).
  """
  @spec type(Ast.t(), Env.t()) ::
          {:ok, %{ast: Ast.t(), diagnostics: [Diagnostic.t()]}} | {:error, Error.t()}
  def type(ast, %Env{} = env) do
    if Ast.node?(ast) do
      ctx = %{env: env, this_type: env.this_type, this_binder: env.this_binder}
      {typed, _path, diags} = t(ast, env.path, ctx)
      diags = diags |> Diagnostic.put_subject(env.subject) |> Diagnostic.normalize()
      {:ok, %{ast: typed, diagnostics: diags}}
    else
      {:error, Error.new(:invalid_input, "expected a BubbleEx.Expression.Ast node")}
    end
  end

  # --- context values -----------------------------------------------------------

  @doc """
  What a context source (`Ast.Scope`) denotes in `env`: a value supplied by
  context (`{:value, input, type}`, where `input` names it stack-neutrally,
  e.g. `{:element_state, %{"element" => id, "state" => "get_group_data"}}`),
  an element whose states are read by the accessor after it
  (`{:element, node}`), or `:unknown`.
  """
  @spec context(Scope.t(), Env.t()) :: context()
  def context(%Scope{kind: :element, ref: ref}, env) do
    {:element, Tree.node(env.tree, ref["element_id"])}
  end

  def context(%Scope{kind: :this_element}, env), do: {:element, Tree.node(env.tree, env.host)}

  def context(%Scope{kind: :parent_group}, env) do
    case Enum.find(Tree.ancestors(env.tree, env.host), & &1.content) do
      nil -> :unknown
      node -> {:value, group_data(node), node.content}
    end
  end

  def context(%Scope{kind: :ancestor_group, ref: ref}, env) do
    kind = ref["ancestor_type"]
    ancestors = Tree.ancestors(env.tree, env.host)

    case Enum.find(ancestors, &(&1.content && (is_nil(kind) or &1.type == kind))) do
      nil -> :unknown
      node -> {:value, group_data(node), node.content}
    end
  end

  def context(%Scope{kind: :current_cell_thing}, %Env{trigger_type: type}) when is_binary(type),
    do: {:value, {:trigger_thing, %{"state" => "now"}}, type}

  def context(%Scope{kind: :current_cell_thing}, env) do
    case cell(env) do
      nil -> :unknown
      node -> {:value, {:cell_thing, %{"element" => node.id}}, node.content}
    end
  end

  def context(%Scope{kind: :current_cell_index}, env) do
    case cell(env) do
      nil -> :unknown
      node -> {:value, {:cell_index, %{"element" => node.id}}, "number"}
    end
  end

  def context(%Scope{kind: :thing_before_change}, %Env{trigger_type: type})
      when is_binary(type),
      do: {:value, {:trigger_thing, %{"state" => "before"}}, type}

  def context(%Scope{kind: :current_page_thing}, env) do
    case page(env) do
      %Tree.Node{content: type} = page when is_binary(type) ->
        {:value, {:page_thing, %{"page" => page.id}}, type}

      _ ->
        :unknown
    end
  end

  def context(%Scope{kind: :previous_step, ref: %{"action_id" => action}}, env)
      when is_binary(action) do
    case Map.get(env.steps, action) do
      nil -> :unknown
      type -> {:value, {:step_result, %{"action" => action}}, type}
    end
  end

  def context(%Scope{kind: kind, ref: ref, type: type}, _env)
      when kind in [:workflow_parameter, :api_parameter] and is_binary(type),
      do: {:value, {:parameter, Map.delete(ref, "btype_id")}, type}

  def context(%Scope{kind: :page_data, ref: %{"name" => name}}, _env) do
    case Map.get(@page_data, name) do
      nil -> :unknown
      type -> {:value, {:page_data, %{"name" => name}}, type}
    end
  end

  def context(%Scope{kind: :url_parameter, ref: ref}, _env) do
    case static_text(ref["parameter_name"]) do
      nil -> :unknown
      name -> {:value, {:url_parameter, %{"name" => name}}, "text"}
    end
  end

  def context(%Scope{}, _env), do: :unknown

  # A text expression made of static strings only (e.g. a URL parameter's
  # name), else nil.
  defp static_text(text) when is_binary(text), do: text

  defp static_text(%{} = expr) do
    with "TextExpression" <- Keys.value(expr, :type),
         {:ok, ordered} <- Explanation.ordered(Keys.value(expr, :entries) || []),
         parts = Enum.map(ordered, &elem(&1, 1)),
         true <- Enum.all?(parts, &is_binary/1) do
      Enum.join(parts)
    else
      _ -> nil
    end
  end

  defp static_text(_), do: nil

  @doc """
  The type of element state `name` of element `node` (the accessor after a
  `GetElement` or `This element`): `{:ok, type}` or `:error`.
  """
  @spec element_state(Tree.Node.t() | nil, String.t(), Env.t()) :: {:ok, String.t()} | :error
  def element_state(nil, _name, _env), do: :error
  def element_state(_node, name, _env) when name in @element_booleans, do: {:ok, "boolean"}

  def element_state(node, "get_group_data", env),
    do: present(node.content || definition(node, env).content)

  def element_state(node, "get_list_data", env) do
    case node.content || definition(node, env).content do
      nil -> :error
      type -> {:ok, listed(type)}
    end
  end

  def element_state(node, "get_data", _env), do: present(node.value)
  def element_state(_node, "page_number", _env), do: {:ok, "number"}

  def element_state(node, "param_" <> param, env),
    do: present(Map.get(definition(node, env).params, param))

  def element_state(node, "custom." <> state, env) do
    present(Map.get(node.states, state) || Map.get(definition(node, env).states, state))
  end

  def element_state(_node, _name, _env), do: :error

  # A reusable instance reads its reusable's parameters, states and type.
  defp definition(%Tree.Node{instance_of: id}, env) when is_binary(id),
    do: Tree.node(env.tree, id) || %Tree.Node{}

  defp definition(node, _env), do: node

  defp group_data(node),
    do: {:element_state, %{"element" => node.id, "state" => "get_group_data"}}

  defp cell(env) do
    self = Tree.node(env.tree, env.host)
    Enum.find(List.wrap(self) ++ Tree.ancestors(env.tree, env.host), &(&1.type in @repeating))
  end

  defp page(env) do
    case Tree.node(env.tree, env.host) do
      %Tree.Node{kind: :page} = node -> node
      %Tree.Node{owner: owner} -> page_owner(Tree.node(env.tree, owner))
      nil -> nil
    end
  end

  defp page_owner(%Tree.Node{kind: :page} = node), do: node
  defp page_owner(_), do: nil

  # --- fields ------------------------------------------------------------------

  @doc """
  Resolves accessor `name` on a subject of Bubble type `type`: a data-type
  field (built-in fields included), an option attribute (`display` is the
  option's label) or an API type's field. On a list it maps over the items.
  Returns `{:ok, %{display, type, builtin}}` or `:error`.
  """
  @spec field(Env.t(), String.t() | nil, String.t()) ::
          {:ok, %{display: String.t() | nil, type: String.t() | nil, builtin: atom() | nil}}
          | :error
  def field(env, "list." <> item, name) do
    case field(env, item, name) do
      {:ok, f} -> {:ok, %{f | type: f.type && listed(f.type)}}
      :error -> :error
    end
  end

  def field(env, "option." <> set, name), do: option_attribute(env.model, set, name)

  def field(env, "api." <> _ = type, name), do: external_field(env.model, type, name)

  def field(env, type, name) when is_binary(type) do
    case Schema.field(env.schema, type, name) do
      {:ok, f} ->
        builtin = BubbleEx.Expression.Vocabulary.builtin_field(name)
        {:ok, %{display: f.display, type: f.value, builtin: builtin && elem(builtin, 0)}}

      _ ->
        model_field(env.model, type, name)
    end
  end

  def field(_env, _type, _name), do: :error

  # The Model also knows the synthesized User's built-in fields.
  defp model_field(%Model{} = model, type, name) do
    with id when is_binary(id) <- type_id(type),
         {:ok, f} <- Model.field(model, id, name) do
      {:ok, %{display: f.name, type: source(f.type.source), builtin: f.system}}
    else
      _ -> :error
    end
  end

  defp model_field(_model, _type, _name), do: :error

  defp option_attribute(%Model{} = model, set, "display") do
    case Model.option_set(model, set) do
      %OptionSet{} -> {:ok, %{display: "Display", type: "text", builtin: :display}}
      nil -> :error
    end
  end

  defp option_attribute(%Model{} = model, set, name) do
    with %OptionSet{attributes: attributes} <- Model.option_set(model, set),
         %{} = attr <- Enum.find(attributes, &(&1.id == name)) do
      {:ok, %{display: attr.name, type: source(attr.type.source), builtin: nil}}
    else
      _ -> :error
    end
  end

  defp option_attribute(_model, _set, _name), do: :error

  defp external_field(%Model{} = model, type, name) do
    with %ExternalType{fields: fields} <- Model.external_type(model, type),
         %{} = f <- Enum.find(fields, &(&1.id == name)) do
      {:ok, %{display: f.name, type: source(f.type.source), builtin: nil}}
    else
      _ -> :error
    end
  end

  defp external_field(_model, _type, _name), do: :error

  defp type_id("user"), do: "user"
  defp type_id("custom." <> id), do: id
  defp type_id(_), do: nil

  defp source(value) when is_binary(value), do: value
  defp source(_), do: nil

  @doc "Whether data type `type` (a Bubble descriptor) exists in the Model."
  @spec data_type?(Env.t(), String.t() | nil) :: boolean()
  def data_type?(env, type) do
    case type_id(type) do
      nil -> false
      id -> match?(%DataType{}, Model.data_type(env.model, id))
    end
  end

  @doc "The result type of Bubble operator `name` (a no-argument message) on `operand`, or nil."
  @spec operator_type(String.t(), String.t() | nil) :: String.t() | nil
  def operator_type(name, operand) do
    case Map.get(@operators, name) do
      :same -> operand
      type -> type
    end
  end

  # --- the walk ---------------------------------------------------------------------

  # Returns the typed node, its own source path, and diagnostics. A chain
  # operator's JSON object hangs off its subject's under the key it was
  # linked by (`next`/`%n`), so its path is the subject's plus that key.
  defp t(%Literal{} = n, base, _ctx), do: {n, base, []}
  defp t(%Empty{} = n, base, _ctx), do: {n, base, []}
  defp t(%CurrentUser{} = n, base, _ctx), do: {n, base, []}
  defp t(%OptionValue{} = n, base, _ctx), do: {n, base, []}
  defp t(%AllOptions{} = n, base, _ctx), do: {n, base, []}

  defp t(%ThisThing{} = n, base, ctx) do
    type = if ctx.this_binder == n.binder, do: ctx.this_type || n.type, else: n.type
    {%{n | type: type}, base, []}
  end

  defp t(%Scope{} = n, base, ctx) do
    case context(n, ctx.env) do
      {:value, _input, type} when is_binary(type) ->
        {%{n | type: type}, base, []}

      {:element, %Tree.Node{}} ->
        {n, base, []}

      _ ->
        {n, base, [untyped_scope(n, base)]}
    end
  end

  defp t(%DynamicText{parts: parts} = n, base, ctx) do
    keys = entry_keys(n)

    {parts, diags} =
      parts
      |> Enum.with_index()
      |> Enum.map_reduce([], fn
        {part, _i}, acc when is_binary(part) ->
          {part, acc}

        {part, i}, acc ->
          {typed, _p, d} = t(part, base ++ [key(n, :entries), Enum.at(keys, i, i)], ctx)
          {typed, acc ++ d}
      end)

    {%{n | parts: parts}, base, diags}
  end

  defp t(%ArbitraryText{text: text} = n, base, ctx) do
    {typed, _p, diags} = t(text, base ++ [key(n, :properties), "arbitrary_text"], ctx)
    {%{n | text: typed}, base, diags}
  end

  defp t(%Search{} = n, base, ctx) do
    item = %{ctx | this_type: n.data_type, this_binder: :filter_item}
    cbase = base ++ [key(n, :properties), n.meta[:prop_keys][:constraints] || "constraints"]
    {constraints, diags} = constraints(n, cbase, item)
    {%{n | constraints: constraints}, base, diags}
  end

  defp t(%Raw{subject: nil} = n, base, _ctx), do: {n, base, []}

  defp t(%Raw{subject: subject} = n, base, ctx) do
    {subject, spath, diags} = t(subject, base, ctx)
    {%{n | subject: subject}, spath ++ [link(n)], diags}
  end

  defp t(%Field{} = n, base, ctx) do
    {subject, spath, diags} = t(n.subject, base, ctx)
    path = spath ++ [link(n)]

    case field(ctx.env, subject.type, n.field) do
      {:ok, f} -> {%{n | subject: subject, type: f.type, display: f.display}, path, diags}
      :error -> {%{n | subject: subject, type: nil}, path, diags}
    end
  end

  defp t(%Property{} = n, base, ctx) do
    {subject, spath, diags} = t(n.subject, base, ctx)
    path = spath ++ [link(n)]
    n = %{n | subject: subject}

    case accessor(n, ctx.env) do
      {:field, f} ->
        field = %Field{
          subject: subject,
          field: n.name,
          builtin: f.builtin,
          display: f.display,
          type: f.type,
          meta: n.meta
        }

        {field, path, diags}

      {:typed, type} ->
        {%{n | type: type}, path, diags}

      # An accessor on a subject left untyped upstream is not reported
      # again: the diagnostic for the subject says why.
      :error ->
        if intrinsic?(subject, ctx.env),
          do: {n, path, diags ++ [unresolved_accessor(n, path)]},
          else: {n, path, diags}
    end
  end

  defp t(%Compare{} = n, base, ctx), do: binary(n, base, ctx, fn _, _ -> "boolean" end)
  defp t(%Logical{} = n, base, ctx), do: binary(n, base, ctx, fn _, _ -> "boolean" end)

  defp t(%Arithmetic{} = n, base, ctx),
    do: binary(n, base, ctx, fn l, r -> arithmetic_type(n.op, l.type, r.type) end)

  defp t(%Check{} = n, base, ctx) do
    {subject, spath, diags} = t(n.subject, base, ctx)
    {%{n | subject: subject}, spath ++ [link(n)], diags}
  end

  defp t(%ListOp{} = n, base, ctx) do
    {subject, spath, diags} = t(n.subject, base, ctx)
    path = spath ++ [link(n)]

    {arg, more} =
      case n.arg do
        nil ->
          {nil, []}

        arg ->
          {typed, _p, d} = t(arg, path ++ [key(n, :args)], ctx)
          {typed, d}
      end

    {%{n | subject: subject, arg: arg, type: list_type(n.op, subject)}, path, diags ++ more}
  end

  defp t(%Filter{} = n, base, ctx) do
    {subject, spath, diags} = t(n.subject, base, ctx)
    path = spath ++ [link(n)]
    item = %{ctx | this_type: item_type(subject.type), this_binder: :filter_item}
    cbase = path ++ [key(n, :properties), n.meta[:prop_keys][:constraints] || "constraints"]
    {constraints, more} = constraints(n, cbase, item)
    {%{n | subject: subject, constraints: constraints, type: subject.type}, path, diags ++ more}
  end

  defp t(%Fallback{} = n, base, ctx) do
    {subject, spath, diags} = t(n.subject, base, ctx)
    path = spath ++ [link(n)]
    {fallback, _p, more} = t(n.fallback, path ++ [key(n, :args)], ctx)
    type = subject.type || fallback.type
    {%{n | subject: subject, fallback: fallback, type: type}, path, diags ++ more}
  end

  defp binary(n, base, ctx, type_fun) do
    {left, spath, diags} = t(n.left, base, ctx)
    path = spath ++ [link(n)]
    {right, _p, more} = t(n.right, path ++ [key(n, :args)], ctx)
    {%{n | left: left, right: right, type: type_fun.(left, right)}, path, diags ++ more}
  end

  defp constraints(n, base, ctx) do
    keys = constraint_keys(n)

    n.constraints
    |> Enum.with_index()
    |> Enum.map_reduce([], fn
      {%Constraint{value: nil} = c, _i}, acc ->
        {c, acc}

      {%Constraint{value: value} = c, i}, acc ->
        vkey = get_in(c.meta, [:keys, :value]) || "value"
        {typed, _p, d} = t(value, base ++ [Enum.at(keys, i, i), vkey], ctx)
        {%{c | value: typed}, acc ++ d}
    end)
  end

  # --- accessors ---------------------------------------------------------------------

  defp intrinsic?(%Scope{} = scope, env) do
    case context(scope, env) do
      {:element, node} -> node != nil
      _ -> is_binary(scope.type)
    end
  end

  defp intrinsic?(subject, _env), do: is_binary(subject.type)

  defp accessor(%Property{subject: %Scope{} = scope, name: name} = n, env) do
    case context(scope, env) do
      {:element, node} ->
        case element_state(node, name, env) do
          {:ok, type} -> {:typed, type}
          :error -> :error
        end

      _ ->
        typed_accessor(n, env)
    end
  end

  defp accessor(n, env), do: typed_accessor(n, env)

  defp typed_accessor(%Property{subject: subject, name: name}, env) do
    case field(env, subject.type, name) do
      {:ok, f} ->
        {:field, f}

      :error ->
        case operator_type(name, subject.type) do
          nil -> :error
          type -> {:typed, type}
        end
    end
  end

  # --- types ---------------------------------------------------------------------

  @predicates [:contains, :not_contains, :contains_list, :is_contained_by, :is_not_contained_by]

  defp list_type(op, _) when op in @predicates, do: "boolean"
  defp list_type(:count, _), do: "number"
  defp list_type(:as_list, %{type: "list." <> _ = type}), do: type
  defp list_type(:as_list, %{type: type}) when is_binary(type), do: listed(type)

  defp list_type(op, subject) when op in [:first_item, :last_item, :item_number],
    do: item_type(subject.type)

  defp list_type(_, subject), do: subject.type

  defp arithmetic_type(op, "date", "date") when op == :minus, do: "dateinterval"
  defp arithmetic_type(_op, left, right), do: left || right

  defp item_type("list." <> type), do: type
  defp item_type(type), do: type

  defp listed("list." <> _ = type), do: type
  defp listed(type), do: "list." <> type

  defp present(value) when is_binary(value), do: {:ok, value}
  defp present(_), do: :error

  # --- source keys -------------------------------------------------------------------

  defp link(%{meta: meta}), do: Map.get(meta, :link) || "next"
  defp key(%{meta: meta}, name), do: get_in(meta, [:keys, name]) || Atom.to_string(name)

  defp entry_keys(%DynamicText{meta: meta, parts: parts}) do
    case Map.get(meta, :entry_keys) do
      keys when is_list(keys) -> keys
      _ -> Enum.to_list(0..max(length(parts) - 1, 0))
    end
  end

  defp constraint_keys(%{meta: meta, constraints: constraints}) do
    case Map.get(meta, :constraint_keys) do
      keys when is_list(keys) -> keys
      _ -> Enum.to_list(0..max(length(constraints) - 1, 0))
    end
  end

  # --- diagnostics -------------------------------------------------------------------

  defp untyped_scope(%Scope{kind: kind, source_type: source}, path) do
    Diagnostic.new(
      :expr_untyped_scope,
      path,
      "the type of #{source} cannot be determined from the app's element tree",
      details: %{scope: kind, source: source}
    )
  end

  defp unresolved_accessor(%Property{subject: subject, name: name}, path) do
    Diagnostic.new(
      :expr_unresolved_accessor,
      path,
      "#{inspect(name)} is neither a field, an element state nor a known operator " <>
        "of a subject of type #{inspect(subject.type)}",
      details: %{accessor: name, subject_type: subject.type}
    )
  end
end
