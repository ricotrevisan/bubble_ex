defmodule BubbleEx.Target.Phoenix.Overlays do
  @moduledoc """
  What a page renders only while it shows it (WTF-559), and the state
  rule both cases share: what holds state only the browser has, which the
  server could not render again.

  ## Overlays rendered only while open (`lazy/4`)

  A Popup or a Group Focus whose contents the server renders when it opens
  and drops when it closes, instead of rendering them hidden. Opening one
  is a round trip (`<Web>.Bubble`'s hook asks the page, which renders
  them, then shows it); its shell (the overlay element itself, with its
  `hidden` attribute, dismissal and dialog attributes) is always rendered,
  so steps, Escape and outside clicks find it.

  An overlay is rendered so when nothing inside it keeps state only the
  browser has:

    * it is a Popup or a Group Focus closed as the page loads, of a page,
      or of a reusable element with a Workflows module whose component
      takes a `scope` (`scoped`); not inside a runtime container (a
      repeating group's cell template), where it is rendered as before
    * no element step (show, hide, toggle, set focus, scroll to) of its
      surface targets an element inside it (the overlay itself may be
      targeted): a hidden element, or a focus, would be lost on closing,
      and a step right after opening would find nothing
    * every control inside it is a text or multiline input the page
      tracks (`inputs` and `cell_inputs` of the surface), whose value the
      page renders from what it keeps, so it comes back as the user left
      it. Any other control keeps the overlay as before: a checkbox or a
      dropdown (tracked or not, the page renders their first value), radio
      buttons, a date, a file, a slider, a search, or an input the page
      does not track (one whose first value is set by an expression that
      is not page data, `FrontendWorkflows`' `@dynamic_slots`)
    * every reusable instance inside it renders a reusable element (and
      nested ones) that has none of those either

  ## Elements hidden by their conditions (`hidden_contents/4`)

  A group (or a repeating group the page lays out statically) whose
  visibility only the server decides: the page renders its contents only
  while its compiled visibility conditionals show it (WTF-559, option c),
  as `<Bubble.contents :if={...}>` around them, with the same expression
  as its `hidden` attribute. A render that shows it brings them. Its own
  element is always rendered. Whether its conditionals compiled is decided
  where the page renders it (`BubbleEx.Target.Phoenix.Pages`); this
  module proves that nothing in the browser can show it, or needs what is
  inside it:

    * it has visibility conditionals, is not an overlay and is not inside
      a runtime container (a repeating group's cell template)
    * no step of any workflow (every surface and kind: events, custom
      events, reusable elements' workflows, disabled ones, and steps with
      residue or no lowering) names it, or an element inside it, with
      anything but a lowered server-side action (display data, display a
      list, set a state, trigger a reusable element's event, go to a
      page): a show, hide, toggle or animation would change its
      visibility in the browser, which would then show contents never
      rendered, and a focus, scroll or reset needs what is inside. A step
      this target does not lower (a plugin's action, an unknown one) may
      do any of those. The steps naming an ancestor do not matter: a
      show, hide, toggle or animation changes the ancestor's own `hidden`
      only, never this element's (the server's), and a focus, scroll or
      reset of it finds nothing inside this element while it is hidden,
      rendered or not
    * nothing inside it holds state only the browser has, as above, but
      with no control at all: a tracked text input would be rendered
      again from its kept value, but a reconnect mounts the page afresh
      (custom states and input values start over) and may hide and show
      the element, losing what was typed. Nor a plugin element whose
      type declares states (any plugin element when the app does not say,
      `BubbleEx.Plugins.States`): the page renders a placeholder, which
      holds none, but the plugin's own code would
    * nothing outside it reads what only the browser has of an element
      inside it, or what depends on its being rendered: no expression of
      another element, of the element itself (its conditionals) or of a
      workflow reads its "is visible", "is hovered", a size, a list's page,
      a plugin element's state, an untracked input's value, the element
      itself or a reusable element's property (`GetElement`,
      `element_reads/1`), and no overlay is placed next to one. A read of
      what the server keeps whether it is rendered or not is no obstacle:
      `Group X's thing` or a list (page data, read by source, or set by a
      "Display data" step), a custom state (`@bubble_states`), a tracked
      input's value (`@bubble_inputs`). An element inside it may read
      anything of another: it is rendered only with it

  The others are rendered as before: hidden, with their contents.
  """

  alias BubbleEx.Frontend.{Conditions, Normalized}
  alias BubbleEx.Frontend.Normalized.Node
  alias BubbleEx.Frontend.Payload
  alias BubbleEx.Plugins.States
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Target.Phoenix.FrontendWorkflows

  @element_ops [:show, :hide, :toggle, :focus, :scroll_to]

  # Steps naming an element that act on the server only: the page renders
  # what they set, whether the element is rendered then or later.
  @server_ops [:display_data, :display_list, :set_state, :call_reusable, :navigate]

  # Controls whose value or selection lives in the browser's DOM; of
  # them, those whose tracked value the page renders (`Pages.kept_value`).
  @controls [
    :input,
    :multiline_input,
    :checkbox,
    :dropdown,
    :radio_buttons,
    :file_input,
    :slider,
    :search
  ]

  @rendered_values [:input, :multiline_input]

  # The containers whose contents `hidden_contents/4` may leave out.
  @containers [:group, :repeating_group]

  @doc """
  The lazy overlays, by surface Bubble ID: a `MapSet` of their Bubble IDs.
  `surfaces` are `{id, root node, map key}` of the pages and reusable
  elements, `scoped` the reusable elements' map keys whose components take
  a `scope`, `bid` the emitter's Bubble ID of a node. Without workflows
  (`flows` nil) there are none.
  """
  @spec lazy(Spec.t() | nil, [{String.t(), Node.t(), String.t()}], [Node.t()], keyword()) ::
          %{String.t() => MapSet.t()}
  def lazy(nil, _surfaces, _reusables, _opts), do: %{}

  def lazy(%Spec{} = flows, surfaces, reusables, opts) do
    scoped = Keyword.fetch!(opts, :scoped)
    env = env(flows, reusables, opts, :tracked)

    for {id, root, map_key} <- surfaces,
        root.kind == :page or
          (MapSet.member?(scoped, map_key) and FrontendWorkflows.module?(flows, id)),
        into: %{} do
      {id, MapSet.new(overlays(root, id, env))}
    end
  end

  @doc """
  The elements whose contents the page may render only while their
  visibility conditionals show them, by surface Bubble ID: a `MapSet` of
  their Bubble IDs (see the module doc). Options as `lazy/4`'s (no
  `scoped`), plus `reads`: the Bubble IDs of the elements something reads
  (`element_reads/1`), and `payload`: the app's (the plugin states it
  declares). Without workflows (`flows` nil) there are none.
  """
  @spec hidden_contents(
          Spec.t() | nil,
          [{String.t(), Node.t(), String.t()}],
          [Node.t()],
          keyword()
        ) ::
          %{String.t() => MapSet.t()}
  def hidden_contents(flows, surfaces, reusables, opts) do
    flows
    |> hidden_contents_reasons(surfaces, reusables, opts)
    |> Enum.reduce(Map.new(surfaces, &{elem(&1, 0), MapSet.new()}), fn
      {{surface, id}, :ok}, acc -> Map.update(acc, surface, MapSet.new([id]), &MapSet.put(&1, id))
      _, acc -> acc
    end)
  end

  @doc """
  Every element with visibility conditionals that `hidden_contents/4`
  looks at, by `{surface, Bubble ID}`: `:ok`, or `{:keep, reason}`, why
  its contents are rendered as before (for reports and tests).
  """
  @spec hidden_contents_reasons(
          Spec.t() | nil,
          [{String.t(), Node.t(), String.t()}],
          [Node.t()],
          keyword()
        ) :: %{{String.t(), String.t()} => :ok | {:keep, String.t()}}
  def hidden_contents_reasons(nil, _surfaces, _reusables, _opts), do: %{}

  def hidden_contents_reasons(%Spec{} = flows, surfaces, reusables, opts) do
    env = env(flows, reusables, opts, :none)
    env = Map.merge(env, named(flows))

    for {id, root, _map_key} <- surfaces,
        node <- conditional(root),
        into: %{} do
      local = local(id, env)
      self = env.bid.(node)

      reason =
        if MapSet.member?(env.touched, self) or MapSet.member?(local.targets, self) do
          "a step shows, hides or acts on it in the browser"
        else
          env = %{env | inside: inside(node, env)}

          node.children
          |> Enum.flat_map(&nodes/1)
          |> Enum.find_value(&state_reason(&1, local, env, MapSet.new()))
        end

      {{id, self}, if(reason, do: {:keep, reason}, else: :ok)}
    end
  end

  @doc """
  The elements something reads by name, by Bubble ID: a `MapSet` of
  `{reader, state}`. `reader` is the Bubble ID of the element whose
  expression reads it, or `:workflow` (an event's or action's expression,
  or an overlay placed next to it); `state` what is read, Bubble's
  accessor (`"get_group_data"`, `"custom.<state>"`, `"get_data"`,
  `"is_visible"`, a plugin's `"get_<code>"`...), or nil (the element
  itself, or where an overlay is placed). It is every `GetElement` of the
  app's pages and reusable elements (their properties, conditions and
  states, their workflows) and of the normalized nodes' bindings, and the
  elements an overlay is placed next to.
  """
  @spec element_reads(Normalized.t()) :: %{String.t() => MapSet.t()}
  def element_reads(%Normalized{} = frontend) do
    payload = frontend.source && frontend.source.payload

    from_nodes =
      for root <- frontend.pages ++ frontend.reusables, node <- nodes(root), reduce: %{} do
        acc ->
          reader = node.source && Map.get(node.source, :bubble_id)
          {flows, bindings} = Map.split(node.bindings || %{}, ["workflow"])

          acc
          |> get_elements(bindings, reader)
          |> get_elements(flows, :workflow)
          |> placed_next_to(node)
      end

    if is_map(payload) do
      (Map.values(Payload.pages(payload)) ++
         Map.values(section(payload, "mobile_views")) ++
         Map.values(Payload.reusables(payload)))
      |> Enum.reduce(from_nodes, &surface_reads(&2, &1))
    else
      from_nodes
    end
  end

  defp section(payload, key) do
    case Map.get(payload, key) do
      %{} = section -> section
      _ -> %{}
    end
  end

  # A page's or reusable element's raw tree: each element reads for itself,
  # its workflows as workflows.
  defp surface_reads(acc, %{} = raw), do: get_elements(acc, raw, raw_id(raw))
  defp surface_reads(acc, _raw), do: acc

  defp raw_id(raw) do
    case Map.get(raw, "id") || Map.get(raw, "%id") do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp placed_next_to(acc, %Node{runtime: %{"placement" => %{"reference" => ref}}}) do
    case ref do
      %{"bubble_id" => id} when is_binary(id) -> add_read(acc, id, {:workflow, nil})
      _ -> acc
    end
  end

  defp placed_next_to(acc, _node), do: acc

  defp add_read(acc, id, reader),
    do: Map.update(acc, id, MapSet.new([reader]), &MapSet.put(&1, reader))

  defp get_elements(acc, term, reader) when is_map(term) and not is_struct(term) do
    acc =
      case get_element(term) do
        nil -> acc
        {id, state} -> add_read(acc, id, {reader || :workflow, state})
      end

    Enum.reduce(term, acc, &member_reads(&1, &2, reader))
  end

  defp get_elements(acc, term, reader) when is_struct(term),
    do: get_elements(acc, Map.from_struct(term), reader)

  defp get_elements(acc, term, reader) when is_list(term),
    do: Enum.reduce(term, acc, &get_elements(&2, &1, reader))

  defp get_elements(acc, term, reader) when is_tuple(term),
    do: get_elements(acc, Tuple.to_list(term), reader)

  defp get_elements(acc, _term, _reader), do: acc

  # The element a `GetElement` names and what it reads of it (the name of
  # the message that follows, nil when none does), or nil.
  defp get_element(term) do
    with "GetElement" <- Map.get(term, "type") || Map.get(term, "%x"),
         %{} = props <- Map.get(term, "properties") || Map.get(term, "%p"),
         id when is_binary(id) <- Map.get(props, "element_id") || Map.get(props, "%ei") do
      {id, accessor(Map.get(term, "next") || Map.get(term, "%n"))}
    else
      _ -> nil
    end
  end

  defp accessor(%{} = next) do
    case Map.get(next, "name") || Map.get(next, "%nm") do
      name when is_binary(name) -> name
      _ -> nil
    end
  end

  defp accessor(_next), do: nil

  # A child element reads for itself, a workflow as a workflow.
  defp member_reads({key, %{} = children}, acc, reader) when key in ["elements", "%el"] do
    Enum.reduce(children, acc, fn {_k, child}, acc ->
      get_elements(acc, child, (is_map(child) && raw_id(child)) || reader)
    end)
  end

  defp member_reads({key, flows}, acc, _reader) when key in ["workflows", "%wf", "%w"],
    do: get_elements(acc, flows, :workflow)

  defp member_reads({_key, value}, acc, reader), do: get_elements(acc, value, reader)

  # Every input a surface tracks, a cell's included.
  defp tracked(%Spec{surfaces: surfaces}) do
    for {_id, s} <- surfaces,
        id <- Map.keys(Map.get(s, :inputs, %{})) ++ Map.keys(Map.get(s, :cell_inputs, %{})),
        into: MapSet.new(),
        do: id
  end

  defp plugin_states(%{} = payload) do
    if Map.has_key?(payload, States.key()), do: States.get(payload), else: :unknown
  end

  defp plugin_states(_payload), do: :unknown

  defp env(flows, reusables, opts, controls) do
    surface_id = Keyword.fetch!(opts, :surface_id)

    by_ref =
      Enum.reduce(reusables, %{}, fn d, acc ->
        acc |> Map.put(d.map_key, d) |> Map.put(surface_id.(d), d)
      end)

    %{
      flows: flows,
      bid: Keyword.fetch!(opts, :bid),
      by_ref: by_ref,
      surface_id: surface_id,
      controls: controls,
      reads: Keyword.get(opts, :reads, %{}),
      tracked: tracked(flows),
      inside: MapSet.new(),
      touched: MapSet.new(),
      plugins: if(controls == :none, do: plugin_states(Keyword.get(opts, :payload)))
    }
  end

  # The elements a step of any workflow may act on in the browser
  # (`touched`): those any step names but the server-side ones. A step
  # whose effect is not known (an animation, a plugin's action, an action
  # with no lowering) is counted too, whatever it would do.
  defp named(%Spec{} = flows) do
    touched =
      for w <- Spec.workflows(flows),
          step <- w.steps,
          not (Map.get(step, :op) in @server_ops and Map.get(step, :residue, []) == []),
          name <- step_names(step),
          into: MapSet.new(),
          do: name

    %{touched: touched}
  end

  # The elements a step names: the action's own (`element`) and its
  # target's, with the reusable-element instances on the target's path.
  defp step_names(step) do
    target =
      case step do
        %{args: %{target: %{path: path, element: element}}} ->
          Enum.filter([element | path], &is_binary/1)

        %{args: %{element: element}} when is_binary(element) ->
          [element]

        _ ->
          []
      end

    own = if is_binary(Map.get(step, :element)), do: [step.element], else: []
    MapSet.new(own ++ target)
  end

  # The elements with visibility conditionals that could leave their
  # contents out: never below a runtime container, never an overlay.
  defp conditional(%Node{runtime: %{"boundary" => "container"}}), do: []

  defp conditional(%Node{} = node) do
    own =
      if node.kind in @containers and node.children != [] and not overlay?(node) and
           visibility?(node),
         do: [node],
         else: []

    own ++ Enum.flat_map(node.children, &conditional/1)
  end

  defp overlay?(%Node{runtime: %{"boundary" => "overlay"}}), do: true
  defp overlay?(_node), do: false

  defp visibility?(%Node{bindings: %{"condition" => %{payload: payload}}}),
    do: Conditions.visibility(payload) != []

  defp visibility?(_node), do: false

  # The lazy overlays of a surface's tree: never below a runtime container.
  defp overlays(root, id, env) do
    local = local(id, env)

    root
    |> candidates()
    |> Enum.filter(fn overlay ->
      inner = Enum.flat_map(overlay.children, &nodes/1)
      not Enum.any?(inner, &state_reason(&1, local, env, MapSet.new()))
    end)
    |> Enum.map(env.bid)
  end

  defp candidates(%Node{runtime: %{"boundary" => "container"}}), do: []

  defp candidates(%Node{} = node) do
    own =
      case node do
        %Node{kind: kind, runtime: %{"boundary" => "overlay", "initial" => "hidden"}}
        when kind in [:popup, :group_focus] ->
          [node]

        _ ->
          []
      end

    own ++ Enum.flat_map(node.children, &candidates/1)
  end

  # Every node of a subtree (runtime containers' templates included).
  defp nodes(%Node{} = node), do: [node | Enum.flat_map(node.children, &nodes/1)]

  # What a surface's own elements may hold in the browser: the elements its
  # steps target, and the inputs it tracks.
  defp local(id, env) do
    surface = env.flows.surfaces[id] || %{workflows: [], inputs: %{}}

    targets =
      for w <- surface.workflows,
          %{op: op, args: %{target: %{path: path, element: element}}} <- w.steps,
          op in @element_ops,
          into: MapSet.new() do
        case path do
          [instance | _] -> instance
          [] when is_binary(element) -> element
          [] -> {:root, id}
        end
      end

    tracked =
      MapSet.new(
        Map.keys(Map.get(surface, :inputs, %{})) ++
          Map.keys(Map.get(surface, :cell_inputs, %{}))
      )

    %{id: id, targets: targets, tracked: tracked}
  end

  # The Bubble IDs of what an element renders inside it, its reusable
  # elements' included (transitively): readers there are rendered with
  # what they read.
  defp inside(%Node{} = node, env), do: inside(node.children, env, MapSet.new(), MapSet.new())

  defp inside(nodes, env, acc, seen) do
    Enum.reduce(nodes, acc, fn n, acc ->
      acc = inside(n.children, env, MapSet.put(acc, env.bid.(n)), seen)

      case definition(n, env) do
        %Node{} = d -> if_unseen(d, seen, acc, &inside(d.children, env, acc, &1))
        nil -> acc
      end
    end)
  end

  defp if_unseen(d, seen, acc, fun),
    do: if(MapSet.member?(seen, d.map_key), do: acc, else: fun.(MapSet.put(seen, d.map_key)))

  defp definition(%Node{kind: :reusable_instance, definition_ref: ref}, env), do: env.by_ref[ref]
  defp definition(_node, _env), do: nil

  # A read from outside of what only the browser has, or what depends on
  # the element being rendered. The server keeps the others whether it is
  # rendered or not: an element's thing or list (page data, read by source
  # in `BubbleData.load`, or what a "Display data" step set), its custom
  # states (`@bubble_states`, from the surface's states at mount and the
  # steps that set them) and a tracked input's value (`@bubble_inputs`).
  # Anything else blocks: "is visible", "is hovered", sizes, a list's
  # page, a plugin element's states, an input the page does not track,
  # the element itself, a reusable element's property.
  defp read_outside?(id, env) do
    case env.reads do
      %{^id => reads} ->
        Enum.any?(reads, fn {reader, state} ->
          not MapSet.member?(env.inside, reader) and not server_kept?(id, state, env)
        end)

      _ ->
        false
    end
  end

  defp server_kept?(_id, state, _env) when state in ["get_group_data", "get_list_data"],
    do: true

  defp server_kept?(_id, "custom." <> _, _env), do: true
  defp server_kept?(id, "get_data", env), do: MapSet.member?(env.tracked, id)
  defp server_kept?(_id, _state, _env), do: false

  # Why a node inside keeps state only the browser has, or nil. Both rules
  # share it; `hidden_contents/4`'s also counts any control, plugin
  # elements, and what steps name and expressions read (`env`).
  defp state_reason(%Node{} = node, local, env, seen) do
    id = env.bid.(node)

    cond do
      MapSet.member?(local.targets, id) ->
        "a step shows, hides, focuses or scrolls to #{id}"

      MapSet.member?(env.touched, id) ->
        "a step names #{id}"

      read_outside?(id, env) ->
        "an expression outside it reads what only the browser has of #{id}"

      true ->
        kind_reason(node, local, env, seen)
    end
  end

  defp kind_reason(%Node{kind: :reusable_instance} = node, _local, env, seen) do
    case env.by_ref[node.definition_ref] do
      %Node{} = d -> definition_reason(d, env, seen)
      _ -> nil
    end
  end

  defp kind_reason(%Node{kind: kind, placeholder?: false} = node, local, env, _seen)
       when kind in @controls do
    cond do
      env.controls == :none -> "a control (#{kind})"
      kind not in @rendered_values -> "a control the page renders from its first value (#{kind})"
      not MapSet.member?(local.tracked, env.bid.(node)) -> "an input the page does not track"
      true -> nil
    end
  end

  # A plugin element whose type declares states (any plugin element when
  # the app does not say, `BubbleEx.Plugins.States`): the page renders a
  # placeholder, which holds none, but the plugin's own code would.
  defp kind_reason(%Node{kind: :placeholder} = node, _local, %{plugins: plugins}, _seen)
       when plugins != nil do
    type = node.attributes["data-placeholder-kind"]

    cond do
      not Payload.plugin_type?(type) -> nil
      plugins == :unknown or States.declares?(plugins, type) -> "a plugin element with states"
      true -> nil
    end
  end

  defp kind_reason(_node, _local, _env, _seen), do: nil

  # A reusable element (or one nested in it) whose own elements keep state
  # in the browser. A cycle keeps nothing more.
  defp definition_reason(%Node{} = d, env, seen) do
    if MapSet.member?(seen, d.map_key) do
      nil
    else
      seen = MapSet.put(seen, d.map_key)
      id = env.surface_id.(d)
      local = local(id, env)

      if MapSet.member?(local.targets, {:root, id}) do
        "a reusable element whose steps show or hide itself"
      else
        d.children
        |> Enum.flat_map(&nodes/1)
        |> Enum.find_value(&state_reason(&1, local, env, seen))
      end
    end
  end
end
