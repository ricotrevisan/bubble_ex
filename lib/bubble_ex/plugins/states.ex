defmodule BubbleEx.Plugins.States do
  @moduledoc """
  The types of the states marketplace plugin elements expose, from the
  plugins' definitions.

  Bubble's app JSON names a plugin element's type (`"<plugin id>-<element
  code>"`, the plugin ID possibly suffixed `_current` or `_test`) but not
  what its states hold. A Buildprint v5 workspace keeps each installed
  plugin's definition (`__bp_plugins__`); `BubbleEx.Buildprint.V5` keeps
  only this projection of it in the app, under `key/0`:

      %{"<plugin id>-<element code>" => %{"<state code>" => %{"value" => type, "is_list" => boolean}}}

  Declarative types only: no captions, names, documentation, code or
  headers. An app read from elsewhere (a `.bubble` file, `BubbleEx.fetch_app/2`)
  has none, and its plugin states stay untyped.

  `element/3` types one element's states as `BubbleEx.Expression.Tree`
  reads them, by accessor (`"get_<state code>"`): a declared `text`,
  `number`, `boolean` or `date`, or a type the element's own property sets
  (`custom_data_<field code>`, a "type of content" field: `custom.task`,
  `user`, `option.status`, `text`…). A list state is `list.<type>`. Any
  other declared type, or a type field the element leaves empty, is left
  out: the state stays untyped.
  """

  @key "__bubble_ex_plugin_states__"
  @basic ~w(text number boolean date)
  @settable ~r/\A(?:text|number|boolean|date|user|(?:custom|option|api)\..+)\z/

  @type t :: %{String.t() => %{String.t() => %{String.t() => term()}}}

  @doc "The app member holding the projection."
  @spec key() :: String.t()
  def key, do: @key

  @doc """
  The projection of plugin definitions keyed by plugin ID (Buildprint's
  `__bp_plugins__`: each `%{"plugin_id", "plugin_elements" => %{code =>
  %{"states" => ...}}}`). Malformed entries are skipped.
  """
  @spec from_definitions(term()) :: t()
  def from_definitions(plugins) when is_map(plugins) do
    for {key, plugin} <- plugins,
        is_map(plugin),
        id = text(plugin["plugin_id"]) || text(key),
        id != nil,
        {code, element} <- objects(plugin["plugin_elements"]),
        states = element_states(element),
        states != %{},
        into: %{} do
      {id <> "-" <> code, states}
    end
  end

  def from_definitions(_), do: %{}

  @doc "`app` with `states` under `key/0` (unchanged when there are none)."
  @spec put(map(), t()) :: map()
  def put(app, states) when is_map(app) and map_size(states) == 0, do: app
  def put(app, states) when is_map(app), do: Map.put(app, @key, states)

  @doc "The projection an app holds, or `%{}`."
  @spec get(term()) :: t()
  def get(%{@key => states}) when is_map(states), do: states
  def get(_app), do: %{}

  @doc "`app` without the projection (for hashing what a loader read)."
  @spec delete(map()) :: map()
  def delete(app) when is_map(app), do: Map.delete(app, @key)

  @doc """
  The typed states of an element of type `type` whose properties are
  `props`, by accessor (`"get_<state code>"` => type descriptor); `%{}`
  for an element that is not a plugin's or whose plugin is not defined.
  """
  @spec element(t(), String.t() | nil, map()) :: %{String.t() => String.t()}
  def element(states, type, props) when is_map(states) and is_binary(type) do
    case Map.get(states, unversioned(type)) do
      %{} = declared ->
        for {code, state} <- declared,
            base = state_type(state["value"], props),
            base != nil,
            into: %{},
            do: {"get_" <> code, if(state["is_list"] == true, do: listed(base), else: base)}

      _ ->
        %{}
    end
  end

  def element(_states, _type, _props), do: %{}

  defp element_states(element) do
    for {code, state} <- objects(element["states"]),
        value = text(state["value"]),
        value != nil,
        into: %{},
        do: {code, %{"value" => value, "is_list" => state["is_list"] == true}}
  end

  defp state_type(value, _props) when value in @basic, do: value

  defp state_type("custom_data_" <> field, props) when is_map(props) do
    case props[field] do
      type when is_binary(type) -> if Regex.match?(@settable, type), do: type
      _ -> nil
    end
  end

  defp state_type(_value, _props), do: nil

  # `<id>_current-<code>` and `<id>_test-<code>` are the same plugin's.
  defp unversioned(type), do: String.replace(type, ~r/_(?:current|test)(?=-)/, "", global: false)

  defp listed("list." <> _ = type), do: type
  defp listed(type), do: "list." <> type

  defp objects(map) when is_map(map),
    do: Enum.filter(map, fn {k, v} -> is_binary(k) and is_map(v) end)

  defp objects(_), do: []

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_), do: nil
end
