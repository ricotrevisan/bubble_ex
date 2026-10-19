defmodule BubbleEx.Target.Phoenix.Overlays do
  @moduledoc """
  The overlays a page renders only while they are open (WTF-559): a
  Popup or a Group Focus whose contents the server renders when it opens
  and drops when it closes, instead of rendering them hidden. Opening
  one is a round trip (`<Web>.Bubble`'s hook asks the page, which renders
  them, then shows it); its shell (the overlay element itself, with its
  `hidden` attribute, dismissal and dialog attributes) is always
  rendered, so steps, Escape and outside clicks find it.

  An overlay is rendered so (`lazy/4`) when nothing inside it keeps state
  only the browser has, state the server could not render again on the
  next opening:

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

  The others are rendered as before: hidden, opened and closed in the
  browser.
  """

  alias BubbleEx.Frontend.Normalized.Node
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Target.Phoenix.FrontendWorkflows

  @element_ops [:show, :hide, :toggle, :focus, :scroll_to]

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
    bid = Keyword.fetch!(opts, :bid)
    scoped = Keyword.fetch!(opts, :scoped)
    surface_id = Keyword.fetch!(opts, :surface_id)

    by_ref =
      Enum.reduce(reusables, %{}, fn d, acc ->
        acc |> Map.put(d.map_key, d) |> Map.put(surface_id.(d), d)
      end)

    env = %{flows: flows, bid: bid, by_ref: by_ref, surface_id: surface_id}

    for {id, root, map_key} <- surfaces,
        root.kind == :page or
          (MapSet.member?(scoped, map_key) and FrontendWorkflows.module?(flows, id)),
        into: %{} do
      {id, MapSet.new(overlays(root, id, env))}
    end
  end

  # The lazy overlays of a surface's tree: never below a runtime container.
  defp overlays(root, id, env) do
    local = local(id, env)

    root
    |> candidates()
    |> Enum.filter(fn overlay ->
      inner = Enum.flat_map(overlay.children, &nodes/1)
      not Enum.any?(inner, &keeps_state?(&1, local, env, MapSet.new()))
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

  defp keeps_state?(%Node{kind: :reusable_instance} = node, local, env, seen) do
    MapSet.member?(local.targets, env.bid.(node)) or
      case env.by_ref[node.definition_ref] do
        %Node{} = d -> definition_keeps_state?(d, env, seen)
        _ -> false
      end
  end

  defp keeps_state?(%Node{kind: kind, placeholder?: false} = node, local, env, _seen)
       when kind in @controls do
    id = env.bid.(node)

    MapSet.member?(local.targets, id) or kind not in @rendered_values or
      not MapSet.member?(local.tracked, id)
  end

  defp keeps_state?(%Node{} = node, local, env, _seen),
    do: MapSet.member?(local.targets, env.bid.(node))

  # A reusable element (or one nested in it) whose own elements keep state
  # in the browser. A cycle keeps nothing more.
  defp definition_keeps_state?(%Node{} = d, env, seen) do
    if MapSet.member?(seen, d.map_key) do
      false
    else
      seen = MapSet.put(seen, d.map_key)
      id = env.surface_id.(d)
      local = local(id, env)

      MapSet.member?(local.targets, {:root, id}) or
        d.children
        |> Enum.flat_map(&nodes/1)
        |> Enum.any?(&keeps_state?(&1, local, env, seen))
    end
  end
end
