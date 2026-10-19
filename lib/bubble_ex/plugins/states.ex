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
  headers. A state whose code is not a Bubble code or whose type is not a
  known form (bounded in length) is dropped, and `BubbleEx.Buildprint.V5`
  counts it in a `:buildprint_plugin_states_dropped` diagnostic. An app read from elsewhere (a `.bubble` file, `BubbleEx.fetch_app/2`)
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
  # Declared state types kept: the basic ones, `date_range` (kept, not
  # typed), a "type of content" field (`custom_data_<field code>`), and the
  # type descriptors an element's field may set. Anything else is dropped.
  @declared ~r/\A(?:text|number|boolean|date|date_range|user|custom_data_[A-Za-z0-9_]{1,32}|(?:custom|option|api)\.[A-Za-z0-9_.\-]{1,200})\z/
  @settable ~r/\A(?:text|number|boolean|date|user|(?:custom|option|api)\.[A-Za-z0-9_.\-]{1,200})\z/
  # Bubble codes (`AAB`, `ACx`) and plugin IDs (`<ms>x<n>`, a slug).
  @code ~r/\A[A-Za-z0-9_]{1,32}\z/
  @plugin_id ~r/\A[A-Za-z0-9_]{1,64}\z/

  @type t :: %{String.t() => %{String.t() => %{String.t() => term()}}}

  @doc "The app member holding the projection."
  @spec key() :: String.t()
  def key, do: @key

  @doc """
  The projection of plugin definitions keyed by plugin ID (Buildprint's
  `__bp_plugins__`: each `%{"plugin_id", "plugin_elements" => %{code =>
  %{"states" => ...}}}`), and how many declared states were dropped: a
  plugin ID, element or state code that is not a Bubble code (bounded
  length), or a type that is not a known form (`@declared`). A plugin or
  element that is not a JSON object, or has no states, is not a state and
  is skipped uncounted.
  """
  @spec from_definitions(term()) :: {t(), non_neg_integer()}
  def from_definitions(plugins) when is_map(plugins) do
    {entries, dropped} =
      for {key, plugin} <- plugins,
          is_map(plugin),
          {code, element} <- objects(plugin["plugin_elements"]),
          reduce: {[], 0} do
        {acc, dropped} ->
          id = text(plugin["plugin_id"]) || text(key)
          {states, bad} = element_states(element)

          if is_binary(id) and Regex.match?(@plugin_id, id) and Regex.match?(@code, code),
            do:
              {if(states == %{}, do: acc, else: [{id <> "-" <> code, states} | acc]),
               dropped + bad},
            else: {acc, dropped + bad + map_size(states)}
      end

    {Map.new(entries), dropped}
  end

  def from_definitions(_), do: {%{}, 0}

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
            is_binary(code) and is_map(state),
            base = state_type(state["value"], props),
            base != nil,
            into: %{},
            do: {"get_" <> code, if(state["is_list"] == true, do: listed(base), else: base)}

      _ ->
        %{}
    end
  end

  def element(_states, _type, _props), do: %{}

  @doc """
  Whether the plugin element type `type` declares states (typed or not):
  `false` for a type whose plugin is not defined, or that declares none.
  """
  @spec declares?(t(), String.t() | nil) :: boolean()
  def declares?(states, type) when is_map(states) and is_binary(type),
    do: match?(%{} = declared when map_size(declared) > 0, Map.get(states, unversioned(type)))

  def declares?(_states, _type), do: false

  defp element_states(element) do
    Enum.reduce(objects(element["states"]), {%{}, 0}, fn {code, state}, {kept, dropped} ->
      value = state["value"]

      if Regex.match?(@code, code) and is_binary(value) and Regex.match?(@declared, value),
        do:
          {Map.put(kept, code, %{"value" => value, "is_list" => state["is_list"] == true}),
           dropped},
        else: {kept, dropped + 1}
    end)
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
