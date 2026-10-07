defmodule BubbleEx.Expression.Tree do
  @moduledoc """
  The element tree of an app's pages and reusable elements, reduced to what
  typing an expression needs (`BubbleEx.Expression.Typing`): each node's
  element type, its content type (a group's or repeating group's type of
  content, a page's type, a reusable's type), its parent, its custom states
  and, for reusables, its parameters.

  Pages, mobile views and reusable elements are nodes too (`kind: :page` or
  `:reusable`), so `GetElement` on a page reads its custom states and on a
  reusable its parameters. A reusable instance (`CustomElement`) records the
  reusable it instantiates in `instance_of`.

  Nodes are keyed by Bubble ID (the element's `id`; for a page or reusable
  its `id`, and its map key when that differs). Types are Bubble descriptors
  (`"custom.task"`, `"list.text"`, `"option.status"`), kept as supplied.
  Reads either key form for the members it uses.
  """

  alias BubbleEx.Workflows.Source

  defmodule Node do
    @moduledoc """
    One page, reusable element or element.

      * `kind` - `:page`, `:reusable` or `:element`
      * `type` - the element type (`"Group"`, `"RepeatingGroup"`,
        `"Input"`, `"CustomElement"`, a plugin element's ID, …); nil for
        pages and reusables
      * `content` - the type of content: `group_type` of a group, repeating
        group, popup or reusable, `page_item_type` of a page
      * `value` - the type of an input's or dropdown's value, when known
      * `parent` - the Bubble ID of the enclosing element, page or reusable
      * `owner` - the Bubble ID of the enclosing page or reusable
      * `states` - custom states: state ID => type descriptor
      * `defaults` - the custom states' default values as supplied
        (`default_val`: a literal or an expression), for those that have
        one
      * `params` - a reusable's parameters: parameter ID => type descriptor
      * `instance_of` - for a reusable instance, the reusable's Bubble ID
      * `page_size` - for a repeating group, the items a page of it shows
        (rows × columns; nil when it shows them all), see `page_size/1`;
        for a table, its repeated row's fixed number of rows (nil: all)
      * `repeats` - whether the element is repeated once per item of a
        list: a repeating group's cell, or a table's repeated row (a
        `TableCrossAxis` with `cross_axis_repeat`, whose content is its
        table's type of content), see `cell_holder/2`
    """
    defstruct [
      :id,
      :kind,
      :type,
      :content,
      :value,
      :parent,
      :owner,
      :instance_of,
      :page_size,
      repeats: false,
      states: %{},
      defaults: %{},
      params: %{}
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            kind: :page | :reusable | :element,
            type: String.t() | nil,
            content: String.t() | nil,
            value: String.t() | nil,
            parent: String.t() | nil,
            owner: String.t() | nil,
            instance_of: String.t() | nil,
            page_size: pos_integer() | nil,
            repeats: boolean(),
            states: %{String.t() => String.t()},
            defaults: %{String.t() => term()},
            params: %{String.t() => String.t()}
          }
  end

  defstruct nodes: %{}

  @type t :: %__MODULE__{nodes: %{String.t() => Node.t()}}

  @sections [
    {~w(pages %p3), :page},
    {["mobile_views"], :page},
    {~w(element_definitions %ed), :reusable}
  ]
  @children ~w(elements %el)

  # Input content formats (Bubble's "content format") and the value type.
  @input_formats %{
    "int_number" => "number",
    "float_number" => "number",
    "currency" => "number",
    "percentage" => "number",
    "date" => "date",
    "email" => "text",
    "password" => "text",
    "url" => "text",
    "text" => "text"
  }

  @doc "Builds the tree from decoded app JSON. Never fails: unusable nodes are skipped."
  @spec build(term()) :: t()
  def build(app) when is_map(app) do
    nodes =
      for {sections, kind} <- @sections,
          section <- sections,
          owners = Map.get(app, section),
          is_map(owners),
          {key, owner} <- Enum.sort(owners),
          is_map(owner),
          node <- owner(key, owner, kind),
          reduce: %{} do
        acc -> Map.put_new(acc, node.id, node)
      end

    %__MODULE__{nodes: nodes}
  end

  def build(_), do: %__MODULE__{}

  @doc "The node with Bubble ID `id`, or nil."
  @spec node(t(), String.t() | nil) :: Node.t() | nil
  def node(%__MODULE__{nodes: nodes}, id) when is_binary(id), do: Map.get(nodes, id)
  def node(_tree, _id), do: nil

  @doc "The enclosing nodes of `id`, innermost first (not including `id` itself)."
  @spec ancestors(t(), String.t() | nil) :: [Node.t()]
  def ancestors(tree, id) do
    case node(tree, id) do
      nil -> []
      %Node{parent: parent} -> chain(tree, parent, [], 0)
    end
  end

  # Guards against a malformed tree whose parents form a cycle.
  defp chain(_tree, nil, acc, _depth), do: Enum.reverse(acc)
  defp chain(_tree, _id, acc, depth) when depth > 256, do: Enum.reverse(acc)

  defp chain(tree, id, acc, depth) do
    case node(tree, id) do
      nil -> Enum.reverse(acc)
      node -> chain(tree, node.parent, [node | acc], depth + 1)
    end
  end

  # --- building ----------------------------------------------------------------

  defp owner(key, raw, kind) do
    id = text(Source.value(raw, ~w(id %id))) || key
    props = props(raw)

    content =
      if kind == :page,
        do: text(props["page_item_type"]),
        else: text(props["group_type"])

    node = %Node{
      id: id,
      kind: kind,
      content: content,
      owner: id,
      states: states(raw),
      defaults: defaults(raw),
      params: params(props)
    }

    aliases = if key != id, do: [%{node | id: key}], else: []
    [node | aliases] ++ children(raw, id, id)
  end

  defp children(raw, parent, owner) do
    raw
    |> Source.get(@children)
    |> case do
      {_key, elements} -> Source.entries(elements)
      nil -> []
    end
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, element} -> element(key, element, parent, owner) end)
  end

  defp element(key, raw, parent, owner) when is_map(raw) do
    id = text(Source.value(raw, ~w(id %id))) || to_string(key)
    type = text(Source.value(raw, ~w(type %x)))
    props = props(raw)

    node = %Node{
      id: id,
      kind: :element,
      type: type,
      content: text(props["group_type"]),
      value: value_type(type, props),
      parent: parent,
      owner: owner,
      states: states(raw),
      defaults: defaults(raw),
      instance_of: if(type == "CustomElement", do: text(props["custom_id"])),
      page_size: list_page_size(type, raw, props),
      repeats: repeats?(type, props)
    }

    [node | raw |> children(id, owner) |> rows(node)]
  end

  defp element(_key, _raw, _parent, _owner), do: []

  # A table's repeated row holds its table's thing, as a repeating
  # group's cell does ("Current row's thing").
  defp rows(children, %Node{type: "Table", id: table, content: content}) do
    Enum.map(children, fn
      %Node{type: "TableCrossAxis", repeats: true, parent: ^table} = row ->
        %{row | content: content}

      node ->
        node
    end)
  end

  defp rows(children, _node), do: children

  defp list_page_size("RepeatingGroup", _raw, props), do: page_size(props)

  # A table shows every item, one row each, unless its repeated row is
  # set to a fixed number of rows.
  defp list_page_size("Table", raw, _props) do
    raw
    |> Source.get(@children)
    |> case do
      {_key, elements} -> Source.entries(elements)
      nil -> []
    end
    |> Enum.find_value(fn {_key, row} ->
      props = if is_map(row), do: props(row), else: %{}

      if is_map(row) and Source.value(row, ~w(type %x)) == "TableCrossAxis" and
           props["cross_axis_repeat"] == true and props["fixed_number_repeating_axis"] == true,
         do: positive(props["fixed_number_repeating_axis_count"])
    end)
  end

  defp list_page_size(_type, _raw, _props), do: nil

  defp repeats?("RepeatingGroup", _props), do: true
  defp repeats?("TableCrossAxis", props), do: props["cross_axis_repeat"] == true
  defp repeats?(_type, _props), do: false

  @doc """
  The repeating group or table whose cell holds what is inside `node` (an
  element, or a map with its `type`, `repeats` and `parent`), given the
  node's Bubble ID, or nil: a repeating group holds its own cells, a
  table's repeated row its table's (one per item of the table's list). A
  table's other rows (a header) are rendered once, outside its cells.
  """
  @spec cell_holder(map(), String.t()) :: String.t() | nil
  def cell_holder(%{type: "RepeatingGroup"}, id), do: id
  def cell_holder(%{type: "TableCrossAxis", repeats: true, parent: table}, _id), do: table
  def cell_holder(_node, _id), do: nil

  @doc """
  The repeating group or table whose cell holds element `id` (or `id`
  itself when `self?`), searching its enclosing elements in its page or
  reusable element; nil outside one. See `cell_holder/2`.
  """
  @spec cell(t(), String.t() | nil, boolean()) :: String.t() | nil
  def cell(tree, id, self? \\ false) do
    self = if self?, do: List.wrap(node(tree, id)), else: []

    (self ++ ancestors(tree, id))
    |> Enum.take_while(&(&1.kind == :element))
    |> Enum.find_value(&cell_holder(&1, &1.id))
  end

  @doc """
  The items a page of a repeating group shows, from its properties: a
  fixed number of rows shows rows × columns; one showing all its items
  (or without rows) has none (nil).
  """
  @spec page_size(map()) :: pos_integer() | nil
  def page_size(props) when is_map(props) do
    rows = positive(props["rows"] || props["%rs"])
    columns = positive(props["columns"] || props["%cs"]) || 1

    if rows && props["show_all_items"] != true, do: rows * columns
  end

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(n) when is_float(n) and n >= 1, do: trunc(n)
  defp positive(_), do: nil

  defp value_type(type, props) when type in ~w(Input MultiLineInput),
    do: Map.get(@input_formats, props["content_format"] || "text")

  defp value_type("Dropdown", props), do: text(props["dynamic_type"]) || "text"
  defp value_type("Checkbox", _props), do: "boolean"
  defp value_type(_type, _props), do: nil

  defp states(raw) do
    case Map.get(raw, "custom_states") do
      states when is_map(states) ->
        for {id, %{"value" => type}} <- states, is_binary(type), into: %{}, do: {id, type}

      _ ->
        %{}
    end
  end

  defp defaults(raw) do
    case Map.get(raw, "custom_states") do
      states when is_map(states) ->
        for {id, %{"value" => type} = state} <- states,
            is_binary(type),
            Map.has_key?(state, "default_val"),
            into: %{},
            do: {id, state["default_val"]}

      _ ->
        %{}
    end
  end

  defp params(%{"parameters" => params}) when is_map(params) do
    for {_, %{"param_id" => id, "btype_id" => type} = param} <- params,
        is_binary(id) and is_binary(type),
        into: %{} do
      {id, if(param["is_list"] == true, do: listed(type), else: type)}
    end
  end

  defp params(_props), do: %{}

  defp listed("list." <> _ = type), do: type
  defp listed(type), do: "list." <> type

  defp props(raw) do
    case Source.value(raw, ~w(properties %p)) do
      props when is_map(props) -> props
      _ -> %{}
    end
  end

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_), do: nil
end
