defmodule BubbleEx.Plugins.Inventory do
  @moduledoc """
  The marketplace plugins of an app and where it uses them, from the
  `BubbleEx.Index` (WTF-376).

      {:ok, index} = BubbleEx.Index.build(app)
      BubbleEx.Plugins.Inventory.build(index)

  One entry per `:plugin` symbol (installed, or named by a type), sorted by
  plugin ID:

    * `plugin` - the symbol ID (`"plugin:<plugin id>"`), `bubble_id`
    * `installed`, `version` - from the app's plugin settings
    * `name` - the public marketplace name when `BubbleEx.Plugins.Catalog`
      lists the plugin, else nil (the app JSON does not name plugins)
    * `members` - the plugin's element, action and event types and data
      types the app uses: `%{role, code, count}` (`role` is `:element`,
      `:action`, `:event` or `:data_type`), sorted by role and code
    * `features` - the set of features used, `%{role, code}`: the members'
      plus `%{role: :state, code: element code}` for element types whose
      value or states are read (no counts: what a decision is about)
    * `elements`, `actions`, `events` - symbol IDs of the plugin's elements,
      actions and the workflows its events trigger; `data_types` - symbols
      whose JSON names one of the plugin's data types
      (`api.<plugin id>.plugin_api.<code>`)
    * `state_reads` - `:reads_element` references reading a plugin
      element's value or states; `step_reads` - `:reads_step` references
      reading a plugin action's result
    * `surfaces` - pages and reusables holding a use (an element, a
      workflow or an expression reading a plugin element), `workflows` - the
      workflows holding one
    * `references` - the `:uses_plugin`, state-read and step-read references
    * `counts` - how many of each

  IDs only: no display names beyond the public catalog name.
  """

  alias BubbleEx.Index
  alias BubbleEx.Index.Reference
  alias BubbleEx.Plugins.Catalog

  @type role :: :element | :action | :event | :data_type
  @type member :: %{role: role(), code: String.t(), count: pos_integer()}
  @type feature :: %{role: role() | :state, code: String.t()}

  @type entry :: %{
          plugin: String.t(),
          bubble_id: String.t(),
          installed: boolean(),
          version: String.t() | nil,
          name: String.t() | nil,
          members: [member()],
          features: [feature()],
          elements: [String.t()],
          actions: [String.t()],
          events: [String.t()],
          data_types: [String.t()],
          state_reads: [Reference.t()],
          step_reads: [Reference.t()],
          surfaces: [String.t()],
          workflows: [String.t()],
          references: [Reference.t()],
          counts: %{atom() => non_neg_integer()}
        }

  @role_order %{element: 0, action: 1, event: 2, state: 3, data_type: 4}

  @doc "The plugin inventory of `index`."
  @spec build(Index.t()) :: [entry()]
  def build(%Index{} = index) do
    index
    |> Index.symbols(:plugin)
    |> Enum.map(&entry(index, &1))
  end

  @doc "The entry of plugin symbol `id` in `index`, or nil."
  @spec entry(Index.t(), String.t()) :: entry() | nil
  def entry(%Index{} = index, "plugin:" <> _ = id) do
    case Index.symbol(index, id) do
      %{kind: :plugin} = symbol -> entry(index, symbol)
      _ -> nil
    end
  end

  def entry(%Index{} = index, %{kind: :plugin} = symbol) do
    uses = Index.references_to(index, symbol.id, [:uses_plugin])
    by_role = Enum.group_by(uses, & &1.attrs.role, & &1.from)
    elements = sorted(Map.get(by_role, :element, []))

    state_reads =
      elements
      |> Enum.flat_map(&Index.references_to(index, &1, [:reads_element]))
      |> Enum.uniq()
      |> Enum.sort_by(&Reference.sort_key/1)

    actions = sorted(Map.get(by_role, :action, []))

    step_reads =
      actions
      |> Enum.flat_map(&Index.references_to(index, &1, [:reads_step]))
      |> Enum.uniq()
      |> Enum.sort_by(&Reference.sort_key/1)

    users = Enum.map(uses, & &1.from) ++ Enum.map(state_reads ++ step_reads, & &1.from)

    entry = %{
      plugin: symbol.id,
      bubble_id: symbol.bubble_id,
      installed: symbol.attrs[:installed] == true,
      version: symbol.attrs[:version],
      name: name(symbol.bubble_id),
      members: members(uses),
      features: features(uses, state_reads),
      elements: elements,
      actions: actions,
      events: sorted(Map.get(by_role, :event, [])),
      data_types: sorted(Map.get(by_role, :data_type, [])),
      state_reads: state_reads,
      step_reads: step_reads,
      surfaces: users |> Enum.map(&surface(index, &1)) |> Enum.reject(&is_nil/1) |> sorted(),
      workflows: users |> Enum.map(&workflow(index, &1)) |> Enum.reject(&is_nil/1) |> sorted(),
      references: Enum.sort_by(uses ++ state_reads ++ step_reads, &Reference.sort_key/1)
    }

    Map.put(entry, :counts, %{
      elements: length(entry.elements),
      actions: length(entry.actions),
      events: length(entry.events),
      data_types: length(entry.data_types),
      state_reads: length(state_reads),
      step_reads: length(step_reads),
      surfaces: length(entry.surfaces),
      workflows: length(entry.workflows)
    })
  end

  @doc "Whether an inventory entry has any use."
  @spec used?(entry()) :: boolean()
  def used?(entry), do: entry.references != []

  defp name(id) do
    case Catalog.fetch(id) do
      {:ok, %{name: name}} -> name
      :error -> nil
    end
  end

  # The set of plugin features the app uses: `%{role, code}` of every
  # member used, plus `%{role: :state, code: <element code>}` for element
  # types whose value or states are read.
  defp features(uses, state_reads) do
    code_of = for %{attrs: %{role: :element, code: c}, from: e} <- uses, into: %{}, do: {e, c}

    states = for r <- state_reads, c = code_of[r.to], uniq: true, do: %{role: :state, code: c}

    (Enum.map(uses, &%{role: &1.attrs.role, code: &1.attrs.code}) ++ states)
    |> Enum.uniq()
    |> Enum.sort_by(&{@role_order[&1.role], &1.code})
  end

  defp members(uses) do
    uses
    |> Enum.frequencies_by(&{&1.attrs.role, &1.attrs.code})
    |> Enum.map(fn {{role, code}, n} -> %{role: role, code: code, count: n} end)
    |> Enum.sort_by(&{@role_order[&1.role], &1.code})
  end

  # The page or reusable holding symbol `id` (itself, when it is one).
  defp surface(index, id) do
    case Index.symbol(index, id) do
      %{kind: kind, id: id} when kind in [:page, :reusable] ->
        id

      nil ->
        nil

      _ ->
        Enum.find_value([:page, :reusable], &ancestor_id(index, id, &1))
    end
  end

  defp ancestor_id(index, id, kind) do
    case Index.ancestor(index, id, kind) do
      %{id: ancestor} -> ancestor
      nil -> nil
    end
  end

  defp workflow(index, id) do
    case Index.symbol(index, id) do
      %{kind: :workflow, id: id} -> id
      nil -> nil
      _ -> ancestor_id(index, id, :workflow)
    end
  end

  defp sorted(list), do: list |> Enum.uniq() |> Enum.sort()
end
