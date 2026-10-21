defmodule BubbleEx.Workarounds do
  @moduledoc """
  A catalog of workaround elements (WTF-586): elements a Bubble developer
  placed to work around Bubble's limits rather than to be seen. Tiny
  (0x0, 1x1) and never-visible elements fake page variables and keep
  plugins or events running; converting their markup copies the hack.

      {:ok, index} = BubbleEx.Index.build(app)
      entries = BubbleEx.Workarounds.catalog(app, index)

  Stack-neutral: it reads the app JSON and the `BubbleEx.Index`, names
  symbols by index ID, and says what an element is for, not how a target
  stack expresses it. `BubbleEx.Findings` turns each entry into a
  `:workaround_element` finding the owner may decide on.

  ## Candidates

  An element (on a page or in a reusable element; Popups and Group Focuses
  excluded, Bubble runs them as overlays) is a candidate when it is

    * **tiny** - both axes at most 1px: an axis fixed (`single_*`) at a min
      size of at most 1px, or with no min size in a Column, Row or
      Align-to-parent container (Bubble sizes it at its min, `0px` by
      default, `BubbleEx.Frontend.EditorGeometry`, WTF-583), or at a
      canvas size of at most 1px in a Fixed container; or an axis whose
      min and max sizes are both at most 1px. An element whose explicit
      min sizes are both at most 1px (a "1x1" element sized by its
      content) is a candidate too (`tiny: :min_only`)
    * **never visible** - hidden on page load, and neither a conditional
      nor a workflow step (show, toggle, animate) ever shows it

  ## Facts (evidence)

    * `setters` - the actions targeting it (`:targets_element`), with their
      type (`DisplayGroupData`, `SetCustomState`, `ShowElement`, …)
    * `readers` - the expression hosts reading it (`:reads_element`), with
      what they read (`reads`: `get_group_data`, `get_list_data`,
      `custom.<state>`, `is_visible`, `is_hovered`, a plugin state, …) and
      whether the host is inside the element (`inside`)
    * `events` - the workflows its events trigger (`:listens_to`)
    * `plugins` - the marketplace plugins of it and its contents
    * `data_source`, `custom_states`, `conditionals` (the properties its
      conditionals set), `contents` (counts of what it holds), `script`
      (an HTML element with a `<script>` or `<style>` tag, its own or in
      its contents)

  ## Classes

  | `class` | means | lowering (`option`) |
  |---------|-------|---------------------|
  | `:value_holder` | holds a value (its data source, a "Display data" step or custom states) that other elements read | `:page_state`: the value is page state, the element renders as its own empty element (`page_state/1`) |
  | `:keep_alive` | kept on the page only so its plugin or its events run | `:plugin_event`: the plugin's or event's own lowering |
  | `:spacer` | an empty, unreferenced tiny element that only adds its container's gap | `:css_gap` |
  | `:js_bridge` | runs the app author's code: a code plugin (Toolbox, `BubbleEx.Plugins.Catalog` `:hand_written_code`) or an HTML element with a script or style tag | `:hook`: a client hook |
  | `:unknown` | none of the above, or signals that disagree | `:keep`: keep the markup as Bubble has it |

  Every entry offers every lowering (`options`), its class's first, so an
  owner may also reclassify it; `:unknown` suggests `:keep`. A pure
  wrapper (it holds nothing, sets and reads nothing, nothing outside uses
  its contents, and it only contains candidates of one class) takes its
  contents' class. `held` lists the candidates inside an element: one
  lowered to page state renders without its contents only when every one
  of them is lowered to page state too (`page_state/1`), so an owner's
  `keep` on a content is never overridden by its wrapper's default. A
  held candidate that cannot lower to page state (a hidden Text or Input)
  keeps its holder's markup, though the holder's finding still applies
  `page_state`. The holder's type and `held` are part of its proposal: a
  candidate added inside it makes a decision about it stale.

  `confidence` is `:high` when every signal agrees (e.g. a tiny element
  with a data source that other elements read for its data, with no
  contents, events, plugins or visibility reads); `reason` says why.
  Entries are sorted by element ID.

  ## Owner decisions

  Each entry is a `:workaround_element` finding (`BubbleEx.Findings`,
  category `:default`), keyed by the element's ID (`subject: %{element:
  id}`). A `:high` confidence one applies by default (an `automatic`
  `BubbleEx.Decision.applicable/2` entry); any other is a question
  (`BubbleEx.Decision.Resolved` `undecided`, and a `decision:workaround/<id>`
  task in the plan). The owner answers or overrides with an ordinary
  finding decision in the app's decisions file: `accept` (the suggested
  option), `modify` with `{"option": …}` (one of the finding's `options`),
  or `reject` (keep the markup, as `"keep"` does):

  ```json
  {
    "schema_version": 1,
    "kind": "finding",
    "key": "finding:workaround_element:<hash>",
    "revision": 1,
    "subject": {"element": "bAbC0"},
    "choice": "modify",
    "params": {"option": "page_state"},
    "basis": {
      "finding_id": "workaround_element:<hash>",
      "proposal_sha256": "…",
      "basis_sha256": "…"
    },
    "rationale": "Only holds the meeting for the counters.",
    "author": {"kind": "owner", "id": "user:42", "via": "cli"}
  }
  ```

  The decision goes stale (and the question comes back) when the
  element's class or options change.
  """

  alias BubbleEx.Frontend.Payload
  alias BubbleEx.Index
  alias BubbleEx.Index.Symbol
  alias BubbleEx.Plugins.Catalog

  @classes [:value_holder, :keep_alive, :spacer, :js_bridge, :unknown]
  @options %{
    value_holder: :page_state,
    keep_alive: :plugin_event,
    spacer: :css_gap,
    js_bridge: :hook,
    unknown: :keep
  }

  @flow ["column", "row", "relative", "align_to_parent", "align-to-parent"]
  @overlays ["Popup", "GroupFocus"]
  @showing ~w(ShowElement ToggleElement AnimateElement)
  @value_reads ~w(get_group_data get_list_data get_data value)
  @holder_steps ~w(DisplayGroupData DisplayListData SetCustomState ResetGroup ListClear)
  # Steps on a wrapper that act on its contents' values.
  @wrapper_steps ~w(ResetGroup)
  @visibility_reads ~w(is_visible isnt_visible)
  @interaction_reads ~w(is_hovered is_pressed is_focused isnt_focused)
  # Conditionals setting these change an element's size: it is not tiny
  # all the time.
  @size_props ~w(width height min_width_css min_height_css min_width_px min_height_px
                 max_width_css max_height_css single_width single_height fit_width fit_height)

  @type class :: :value_holder | :keep_alive | :spacer | :js_bridge | :unknown
  @type option :: :page_state | :plugin_event | :css_gap | :hook | :keep

  @type entry :: %{
          element: String.t(),
          symbol: Symbol.id(),
          surface: Symbol.id() | nil,
          type: String.t() | nil,
          path: String.t(),
          signals: [:tiny | :never_visible],
          tiny: :fixed | :min_only | nil,
          inside: Symbol.id() | nil,
          setters: [%{action: Symbol.id(), workflow: Symbol.id() | nil, type: String.t()}],
          readers: [%{from: Symbol.id(), reads: [String.t()], inside: boolean()}],
          events: [%{workflow: Symbol.id(), event: String.t() | nil}],
          plugins: [Symbol.id()],
          data_source: boolean(),
          custom_states: [String.t()],
          conditionals: [String.t()],
          contents: %{
            elements: non_neg_integer(),
            candidates: non_neg_integer(),
            used: boolean()
          },
          held: [Symbol.id()],
          script: boolean(),
          class: class(),
          confidence: :high | :medium | :low,
          reason: String.t(),
          option: option(),
          options: [option()]
        }

  @doc "The classes, in table order."
  @spec classes() :: [class()]
  def classes, do: @classes

  @doc "The lowering a class proposes."
  @spec option(class()) :: option()
  def option(class), do: Map.fetch!(@options, class)

  @doc "Every lowering an entry may name, in class order (`:keep` last)."
  @spec options() :: [option()]
  def options, do: Enum.map(@classes, &option/1)

  @doc "See `BubbleEx.Workarounds.PageState.lowered/1`."
  defdelegate page_state(applied), to: BubbleEx.Workarounds.PageState, as: :lowered

  @doc "See `BubbleEx.Workarounds.PageState.type?/1`."
  defdelegate page_state_type?(type), to: BubbleEx.Workarounds.PageState, as: :type?

  @doc "The workaround elements of decoded app JSON, with their facts and class."
  @spec catalog(map(), Index.t()) :: [entry()]
  def catalog(app, %Index{} = index) when is_map(app) do
    elements = for %Symbol{kind: :element} = s <- index.symbols, into: %{}, do: {s.id, s}
    raws = Map.new(elements, fn {id, s} -> {id, pointer(app, s.path)} end)
    shown = shown_by_steps(index)

    candidates =
      for {id, s} <- elements,
          raw = raws[id],
          is_map(raw),
          Payload.type(raw) not in @overlays,
          signals = signals(raw, parent_raw(app, index, s), MapSet.member?(shown, id)),
          signals.list != [],
          into: %{},
          do: {id, signals}

    children = children_map(elements)

    facts =
      Map.new(candidates, fn {id, signals} ->
        {id, facts(app, index, elements[id], raws, children, candidates, signals)}
      end)

    facts
    |> classify_all(children, candidates)
    |> Map.values()
    |> Enum.sort_by(& &1.element)
  end

  # --- candidacy ----------------------------------------------------------

  defp signals(raw, parent, shown_by_step?) do
    props = Payload.properties(raw)
    flow? = is_map(parent) and Payload.prop(parent, "container_layout") in @flow
    tiny = tiny(props, flow?, Payload.plugin_type?(Payload.type(raw)))
    conditionals = conditional_props(raw)

    shown_by_condition? =
      Enum.any?(conditional_states(raw), &(get_in(&1, ["properties", "is_visible"]) == true))

    never_visible? =
      props["is_visible"] == false and not shown_by_step? and not shown_by_condition?

    list =
      if(tiny, do: [:tiny], else: []) ++ if(never_visible?, do: [:never_visible], else: [])

    %{list: list, tiny: tiny, conditionals: conditionals, shown_by_condition: shown_by_condition?}
  end

  defp tiny(props, flow?, plugin?) do
    w = axis(props, "width", flow?, plugin?)
    h = axis(props, "height", flow?, plugin?)

    cond do
      w == :tiny and h == :tiny -> :fixed
      tiny_min?(props, "width") and tiny_min?(props, "height") -> :min_only
      true -> nil
    end
  end

  # :tiny when the axis is at most 1px whatever its content: fixed at a
  # tiny size (in flow, a fixed axis without a min size is at Bubble's
  # default min, 0px; a plugin element keeps its canvas size), bounded by a
  # tiny max, or placed at a tiny canvas size in a Fixed container.
  defp axis(props, ax, flow?, plugin?) do
    # As EditorGeometry: an element keeping an aspect ratio keeps its
    # canvas size on a fixed axis.
    zero? = flow? and not plugin? and not aspect_ratio?(props)

    size =
      if props["single_#{ax}"] == true,
        do: min_size(props, ax) || if(zero?, do: 0, else: canvas(props, ax)),
        else: free_size(props, ax, flow?)

    if is_number(size) and size <= 1, do: :tiny
  end

  defp free_size(props, ax, flow?) do
    max = px(props["max_#{ax}_css"]) || px(props["max_#{ax}_px"])

    cond do
      max != nil and (min_size(props, ax) || 0) <= 1 -> max
      flow? -> nil
      true -> canvas(props, ax)
    end
  end

  defp aspect_ratio?(props) do
    props["use_aspect_ratio"] == true and is_number(props["aspect_ratio_width"]) and
      is_number(props["aspect_ratio_height"]) and props["aspect_ratio_width"] > 0 and
      props["aspect_ratio_height"] > 0
  end

  defp min_size(props, ax), do: px(props["min_#{ax}_css"]) || px(props["min_#{ax}_px"])
  defp canvas(props, ax), do: px(props[ax]) || px(props["%" <> String.first(ax)])

  # A min size the developer set at most 1px.
  defp tiny_min?(props, ax) do
    case min_size(props, ax) do
      n when is_number(n) -> n <= 1
      _ -> false
    end
  end

  defp px(n) when is_number(n), do: n

  defp px(s) when is_binary(s) do
    case Regex.run(~r/\A\s*(\d+(?:\.\d+)?)px\s*\z/, s) do
      [_, n] -> String.to_float(if String.contains?(n, "."), do: n, else: n <> ".0")
      _ -> nil
    end
  end

  defp px(_), do: nil

  defp conditional_states(raw) do
    case raw["states"] do
      states when is_map(states) -> states |> Map.values() |> Enum.filter(&is_map/1)
      states when is_list(states) -> Enum.filter(states, &is_map/1)
      _ -> []
    end
  end

  defp conditional_props(raw) do
    raw
    |> conditional_states()
    |> Enum.flat_map(fn s ->
      case s["properties"] do
        p when is_map(p) -> Map.keys(p)
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Elements a show, toggle or animate step targets.
  defp shown_by_steps(index) do
    for %{kind: :targets_element, from: from, to: to} <- index.references,
        match?(%{attrs: %{type: t}} when t in @showing, Index.symbol(index, from)),
        into: MapSet.new(),
        do: to
  end

  defp parent_raw(app, index, %Symbol{parent: parent}) do
    case parent && Index.symbol(index, parent) do
      %Symbol{path: path} -> pointer(app, path)
      _ -> nil
    end
  end

  # --- facts --------------------------------------------------------------

  defp facts(app, index, %Symbol{} = s, raws, children, candidates, signals) do
    raw = raws[s.id]
    props = Payload.properties(raw)
    descendants = descendants(children, s.id)
    within = MapSet.new([s.id | descendants])

    setters =
      index
      |> Index.references_to(s.id, [:targets_element])
      |> Enum.map(fn r ->
        action = Index.symbol(index, r.from)

        %{
          action: r.from,
          workflow: action && action.parent,
          type: action && to_string(action.attrs[:type])
        }
      end)
      |> Enum.uniq()
      |> Enum.sort_by(& &1.action)

    readers =
      index
      |> Index.references_to(s.id, [:reads_element])
      |> Enum.map(& &1.from)
      |> Enum.uniq()
      |> Enum.map(fn from ->
        host = Index.symbol(index, from)
        reads = if host, do: reads(pointer(app, host.path), s.bubble_id), else: []
        %{from: from, reads: reads, inside: MapSet.member?(within, from)}
      end)
      |> Enum.sort_by(& &1.from)

    events =
      index
      |> Index.references_to(s.id, [:listens_to])
      |> Enum.map(fn r ->
        w = Index.symbol(index, r.from)
        %{workflow: r.from, event: w && w.attrs[:event_type] && to_string(w.attrs[:event_type])}
      end)
      |> Enum.uniq()
      |> Enum.sort_by(& &1.workflow)

    plugins =
      [s.id | descendants]
      |> Enum.flat_map(
        &(index
          |> Index.references_from(&1, [:uses_plugin])
          |> Enum.map(fn r -> r.to end))
      )
      |> Enum.uniq()
      |> Enum.sort()

    %{
      element: s.bubble_id,
      symbol: s.id,
      surface: surface(index, s),
      type: Payload.type(raw),
      path: s.path,
      signals: signals.list,
      tiny: signals.tiny,
      inside: candidate_ancestor(index, s, candidates),
      setters: setters,
      readers: readers,
      events: events,
      plugins: plugins,
      own_plugin: own_plugin(Payload.type(raw)),
      data_source: props["data_source"] != nil or "data_source" in signals.conditionals,
      properties:
        props |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "param_")) |> Enum.sort(),
      shown_by_condition: signals.shown_by_condition,
      custom_states: custom_states(raw),
      conditionals: signals.conditionals,
      contents: %{
        elements: length(descendants),
        candidates: Enum.count(descendants, &Map.has_key?(candidates, &1)),
        used:
          used_from_outside?(
            index,
            Enum.reject(descendants, &Map.has_key?(candidates, &1)),
            within
          )
      },
      held: descendants |> Enum.filter(&Map.has_key?(candidates, &1)) |> Enum.sort(),
      script: Enum.any?([s.id | descendants], &script?(raws[&1])),
      child_ids: Map.get(children, s.id, [])
    }
  end

  # Whether something outside the element reads, sets or listens to one of
  # its contents that is no candidate itself (a candidate has its own class,
  # and `page_state/1` lowers a holder only with all it holds): they must
  # stay where they are.
  defp used_from_outside?(index, descendants, within) do
    Enum.any?(descendants, fn d ->
      index
      |> Index.references_to(d, [:reads_element, :targets_element, :listens_to])
      |> Enum.any?(&(not MapSet.member?(within, outside_host(index, &1.from))))
    end)
  end

  # The element an action's or workflow's reference comes from is not
  # inside; an element host is itself.
  defp outside_host(index, from) do
    case Index.symbol(index, from) do
      %Symbol{kind: :element} -> from
      _ -> nil
    end
  end

  defp children_map(elements) do
    elements
    |> Map.values()
    |> Enum.group_by(& &1.parent, & &1.id)
    |> Map.new(fn {k, v} -> {k, Enum.sort(v)} end)
  end

  defp descendants(children, id) do
    children
    |> Map.get(id, [])
    |> Enum.flat_map(&[&1 | descendants(children, &1)])
  end

  defp surface(_index, %Symbol{parent: nil}), do: nil

  defp surface(index, %Symbol{parent: parent}) do
    case Index.symbol(index, parent) do
      %Symbol{kind: kind} = p when kind in [:page, :reusable] -> p.id
      %Symbol{} = p -> surface(index, p)
      nil -> nil
    end
  end

  defp candidate_ancestor(_index, %Symbol{parent: nil}, _candidates), do: nil

  defp candidate_ancestor(index, %Symbol{parent: parent}, candidates) do
    cond do
      Map.has_key?(candidates, parent) -> parent
      p = Index.symbol(index, parent) -> candidate_ancestor(index, p, candidates)
      true -> nil
    end
  end

  defp own_plugin(type) do
    if Payload.plugin_type?(type) do
      case String.split(type, "-", parts: 2) do
        [plugin, code] -> %{plugin: plugin, code: code}
        _ -> nil
      end
    end
  end

  defp custom_states(raw) do
    case raw["custom_states"] do
      states when is_map(states) -> states |> Map.keys() |> Enum.sort()
      _ -> []
    end
  end

  defp script?(raw) when is_map(raw) do
    Payload.type(raw) == "HTML" and
      case Payload.prop(raw, "html") do
        html when is_binary(html) -> Regex.match?(~r/<\s*(script|style)\b/i, html)
        _ -> false
      end
  end

  defp script?(_raw), do: false

  # What a host's expressions read of `element` (`GetElement`): the name of
  # the step after it. A host's children and actions are hosts of their own.
  defp reads(%{} = json, element) do
    json
    |> Map.drop(["elements", "%el", "workflows", "actions"])
    |> reads_in(element, [])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp reads(_json, _element), do: []

  defp reads_in(%{} = node, element, acc) do
    acc =
      case node do
        %{"type" => "GetElement", "properties" => %{"element_id" => ^element}} ->
          [read_name(node["next"]) | acc]

        _ ->
          acc
      end

    node
    |> Map.values()
    |> Enum.reduce(acc, &reads_in(&1, element, &2))
  end

  defp reads_in(list, element, acc) when is_list(list),
    do: Enum.reduce(list, acc, &reads_in(&1, element, &2))

  defp reads_in(_value, _element, acc), do: acc

  defp read_name(%{"name" => name}) when is_binary(name), do: name
  defp read_name(_), do: "element"

  # --- classes ------------------------------------------------------------

  # Bottom-up, so a wrapper sees its contents' classes.
  defp classify_all(facts, _children, _candidates) do
    order = Enum.sort_by(Map.values(facts), &(-depth(facts, &1)))

    Enum.reduce(order, %{}, fn f, done ->
      Map.put(done, f.symbol, finish(f, classify(f, done)))
    end)
  end

  defp depth(facts, f) do
    case f.inside && facts[f.inside] do
      nil -> 0
      parent -> 1 + depth(facts, parent)
    end
  end

  defp finish(f, {class, confidence, reason}) do
    f
    |> Map.drop([:own_plugin, :child_ids, :shown_by_condition])
    |> Map.merge(%{
      class: class,
      confidence: confidence,
      reason: reason,
      option: option(class),
      options: [option(class) | List.delete(options(), option(class))]
    })
  end

  # The first rule that matches decides; a reason says why.
  @rules [:grows, :dom_reads, :js_bridge, :plugin_element, :triggered, :value_holder, :wrapper] ++
           [:events, :plugins_inside, :unread, :spacer]

  defp classify(f, done) do
    reads = f.readers |> Enum.reject(& &1.inside) |> Enum.flat_map(& &1.reads) |> Enum.uniq()
    instance? = f.type == "CustomElement"

    g = %{
      value_reads: Enum.filter(reads, &value_read?/1),
      dom_reads: Enum.filter(reads, &(&1 in @visibility_reads or &1 in @interaction_reads)),
      grows: Enum.filter(f.conditionals, &(&1 in @size_props)),
      instance?: instance?,
      holds?:
        f.data_source or f.custom_states != [] or (instance? and f.properties != []) or
          Enum.any?(f.setters, &holder_step?/1),
      done: done
    }

    Enum.find_value(@rules, fn rule -> rule(rule, f, g) end) ||
      {:unknown, :low, unknown_reason(f)}
  end

  defp rule(:grows, _f, %{grows: [_ | _] = grows}),
    do:
      {:unknown, :low,
       "a conditional changes its size, so it is not tiny all the time (#{Enum.join(grows, ", ")})"}

  defp rule(:dom_reads, _f, %{dom_reads: [_ | _] = reads}),
    do:
      {:unknown, :low,
       "other elements read how it shows (#{Enum.join(reads, ", ")}): it may be a hover or visibility target"}

  defp rule(:js_bridge, f, g) do
    if code_plugin?(f.own_plugin) or (f.script and f.own_plugin == nil and not g.holds?),
      do: js_bridge(f)
  end

  defp rule(:plugin_element, %{own_plugin: %{}} = f, g), do: plugin_element(f, g.value_reads)

  defp rule(:triggered, f, %{instance?: true}) do
    if Enum.any?(f.setters, &(&1.type == "TriggerCustomEventFromReusable")),
      do:
        {:keep_alive, :medium,
         "a reusable element instance that steps trigger custom events on: its workflows run inside it"}
  end

  defp rule(:value_holder, f, %{holds?: true, value_reads: [_ | _] = reads}),
    do: value_holder(f, reads)

  defp rule(:wrapper, f, g), do: wrapped_class(f, g.done)

  defp rule(:events, %{events: [_ | _] = events} = f, _g) do
    if :never_visible not in f.signals,
      do:
        {:keep_alive, :medium,
         "its events trigger #{length(events)} workflow#{plural(events)} " <>
           "(#{events |> Enum.map(& &1.event) |> Enum.uniq() |> Enum.join(", ")}) and nothing reads it: " <>
           "something other than a person may trigger them (a script clicking it)"}
  end

  defp rule(:plugins_inside, %{plugins: [_ | _] = plugins} = f, _g) do
    if :never_visible not in f.signals,
      do: {:keep_alive, :medium, "it holds plugin elements (#{Enum.join(plugins, ", ")})"}
  end

  defp rule(:unread, _f, %{holds?: true}),
    do: {:unknown, :low, "it holds a value, but no other element reads it"}

  defp rule(:spacer, f, %{instance?: false}) do
    if :tiny in f.signals and f.contents.elements == 0 and f.setters == [] and f.readers == [] and
         f.events == [],
       do: {:spacer, :high, "an empty tiny element that nothing reads, sets or listens to"}
  end

  defp rule(_rule, _f, _g), do: nil

  # Plugin elements that draw something (icons, charts, inputs): a hidden or
  # tiny one is not kept for its plugin to run.
  @visual ~w(icon_set chart calendar date_time_input select_input autocomplete_input
             markdown_renderer sortable_list)a

  defp plugin_element(f, value_reads) do
    %{plugin: plugin, code: code} = f.own_plugin
    equivalent = Catalog.equivalent(plugin, code)

    cond do
      equivalent in @visual ->
        {:unknown, :low,
         "a plugin element that draws something (#{equivalent}), #{signals_text(f)}"}

      equivalent != nil and value_reads == [] ->
        {:keep_alive, :high,
         "a plugin element (#{equivalent}, #{plugin}) kept on the page so the plugin runs"}

      true ->
        {:keep_alive, :medium,
         "a plugin element (#{plugin}) kept on the page so the plugin runs" <>
           if(value_reads == [],
             do: "; the plugin is not in the catalog",
             else: "; its states are read (#{Enum.join(value_reads, ", ")})"
           )}
    end
  end

  defp signals_text(f) do
    if :never_visible in f.signals, do: "never visible", else: "tiny"
  end

  defp plural([_]), do: ""
  defp plural(_), do: "s"

  defp value_holder(f, value_reads) do
    concerns = for {true, text} <- holder_concerns(f), do: text

    reason =
      "it holds a value (#{holder_sources(f)}) that other elements read (#{Enum.join(value_reads, ", ")})"

    if concerns == [],
      do: {:value_holder, :high, reason},
      else: {:value_holder, :medium, reason <> "; but " <> Enum.join(concerns, ", ")}
  end

  defp holder_concerns(f) do
    [
      {f.type == "CustomElement",
       "it is a reusable element instance (its contents and workflows run inside it)"},
      {f.contents.elements > f.contents.candidates and :never_visible not in f.signals,
       "it has contents that may show"},
      {f.contents.used, "other elements use its contents"},
      {f.events != [], "its events trigger workflows"},
      {f.plugins != [], "it holds plugin elements"},
      {f.script, "it holds a script"},
      {f.shown_by_condition, "a conditional shows it"},
      {f.tiny == :min_only, "only its min size is tiny"}
    ]
  end

  defp holder_sources(f) do
    displayed? = Enum.any?(f.setters, &(&1.type in ~w(DisplayGroupData DisplayListData)))
    states? = f.custom_states != [] or Enum.any?(f.setters, &(&1.type == "SetCustomState"))
    properties? = f.type == "CustomElement" and f.properties != []

    sources = [
      {f.data_source, "its data source"},
      {displayed?, "a display data step"},
      {states?, "custom states"},
      {properties?, "its reusable properties"}
    ]

    Enum.join(for({true, text} <- sources, do: text), ", ")
  end

  defp js_bridge(f) do
    code? = code_plugin?(f.own_plugin)

    what =
      if code?,
        do: "a code plugin element (#{f.own_plugin.plugin})",
        else: "a script or style tag"

    if code? or (f.events == [] and f.readers == []),
      do: {:js_bridge, :high, "it runs the app author's code: #{what}"},
      else:
        {:js_bridge, :medium,
         "it runs the app author's code (#{what}), and other elements use it"}
  end

  # A wrapper that holds, sets, reads and listens to nothing itself takes
  # the class of its contents when they are all candidates of one class.
  defp wrapped_class(f, done) do
    kids = Enum.map(f.child_ids, &done[&1])

    if wrapper?(f) and Enum.all?(kids, & &1),
      do: kids |> Enum.map(& &1.class) |> Enum.uniq() |> wrapped(kids)
  end

  defp wrapper?(f) do
    f.child_ids != [] and f.readers == [] and f.events == [] and not f.data_source and
      not f.contents.used and
      f.custom_states == [] and f.type != "CustomElement" and
      Enum.all?(f.setters, &(&1.type in @wrapper_steps))
  end

  defp wrapped([class], kids) when class != :unknown do
    confidence = kids |> Enum.map(& &1.confidence) |> Enum.min_by(&rank/1)

    {class, confidence,
     "it only wraps #{length(kids)} #{class} element#{plural(kids)} (" <>
       Enum.map_join(kids, ", ", & &1.element) <> ")"}
  end

  defp wrapped(_classes, _kids), do: nil

  defp rank(:low), do: 0
  defp rank(:medium), do: 1
  defp rank(:high), do: 2

  defp unknown_reason(f) do
    cond do
      f.shown_by_condition ->
        "a conditional may show it"

      f.readers != [] ->
        "other elements read it, but not for a value it holds"

      f.setters != [] ->
        "steps target it (#{f.setters |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.join(", ")})"

      :never_visible in f.signals ->
        "never visible, and nothing reads, sets or listens to it"

      true ->
        "tiny, with contents (#{f.contents.elements} elements)"
    end
  end

  defp value_read?("custom." <> _), do: true
  defp value_read?(name), do: name in @value_reads or String.starts_with?(name, "param_")

  defp holder_step?(%{type: t}), do: t in @holder_steps

  defp code_plugin?(%{plugin: plugin, code: code}),
    do: Catalog.equivalent(plugin, code) == :hand_written_code

  defp code_plugin?(_), do: false

  # --- JSON ---------------------------------------------------------------

  defp list_at(list, key) do
    case Integer.parse(key) do
      {i, ""} when i >= 0 -> Enum.at(list, i)
      _ -> nil
    end
  end

  defp pointer(app, "" <> path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
    |> Enum.reduce_while(app, fn key, acc ->
      case acc do
        %{^key => v} -> {:cont, v}
        list when is_list(list) -> {:cont, list_at(list, key)}
        _ -> {:halt, nil}
      end
    end)
  end
end
