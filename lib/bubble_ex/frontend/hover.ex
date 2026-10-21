defmodule BubbleEx.Frontend.Hover do
  @moduledoc """
  An element's "is hovered" conditionals lowered to the browser's own
  hover (WTF-590), stack-neutrally: a state whose whole condition is
  "This element is hovered", another element's "is hovered", or an "or"
  of them, and that sets only what a stylesheet can set (paint and
  visibility), needs no server: the page's stylesheet applies it while
  the pointer is over the element read.

  `lower/3` moves each such state, or the part of it that can move, out
  of the element's `:condition` binding (`BubbleEx.Frontend.Conditions`)
  into the node's `hover` list, in Bubble's order:

      %{
        "state" => "0",
        "on" => [%{"element" => "self"} | %{"element" => id, "relation" => relation}],
        "paint" => %{...},
        "visible" => true | false | nil
      }

  `on` lists what is hovered (any of them); `relation` is where the
  element read is in the page's tree:

    * `"ancestor"` - it holds this element
    * `"descendant"` - this element holds it
    * `"within"` (with `"within" => common ancestor id`) - another
      branch of the element they both are in (a sibling, a cousin)

  `paint` is the paint the state sets, as the element's own paint keys
  (what differs from the element's paint with the state's properties
  applied), `visible` the visibility it sets, when it does (a yes/no
  literal).

  A state stays a conditional (as before: lowered by the server, or
  marked) when:

    * its condition reads anything else (`and`, a data value, another
      state), or an element that is not in the same page or reusable
      element, is the page or the reusable element itself (the reusable
      element's own box is its instance's), or is in a repeating group's
      cell, a runtime container or an overlay the reader is not in (the
      cells share element IDs: which one is read would be a guess), or a
      common ancestor that is one
    * it sets the visibility and a later state that stays sets it too
      (the last true state decides in Bubble; the hover's rule always
      comes last in the browser), or sets it to anything but a yes/no
      literal

  Properties a stylesheet does not set (a text, an icon, a size) stay in
  the state, which keeps its condition; the rest moves.

  Touch screens: the generated rule is the browser's `:hover`, which
  touch browsers emulate on a tap. What Bubble does on a tap is neither
  in the export nor replayed, so it is not claimed to match.
  """

  alias BubbleEx.Expression
  alias BubbleEx.Expression.Ast.{Logical, Property, Scope}
  alias BubbleEx.Frontend.{Conditions, Payload}
  alias BubbleEx.Frontend.Normalized.Node

  @type rule :: %{required(String.t()) => term()}

  # What a stylesheet sets: the element's paint (the properties
  # `BubbleEx.Frontend.Normalize` paints) and its visibility.
  @visibility ["is_visible", "%iv"]

  @roots [:page, :reusable_definition]

  @doc """
  The roots (pages or reusable elements, after their breakpoints) with
  their hover states lowered. `raw_roots` are their elements by map key
  (as `Payload.pages/1`); `paint` gives an element's paint with some
  properties applied, `(raw element, properties) -> paint`, and
  `paint_keys` are the properties it reads.
  """
  @spec lower([Node.t()], map(), (map(), map(), MapSet.t() -> map()), [String.t()]) ::
          [Node.t()]
  def lower(roots, raw_roots, paint, paint_keys) when is_list(roots) do
    Enum.map(roots, fn root ->
      index = index(root)
      raw = Map.get(raw_roots || %{}, root.map_key) || %{}
      env = %{index: index, paint: paint, paint_keys: paint_keys, root: root}
      walk(root, raw, env)
    end)
  end

  @doc "Whether a node's hover rules set its visibility."
  @spec visibility?(Node.t()) :: boolean()
  def visibility?(%Node{} = node),
    do: Enum.any?(Map.get(node, :hover) || [], &is_boolean(&1["visible"]))

  @doc """
  What a condition reads when it is only "is hovered" reads, joined by
  "or": `[:self | element id]`, else nil.
  """
  @spec targets(term()) :: [:self | String.t()] | nil
  def targets(condition) when is_map(condition) do
    case Expression.parse(condition) do
      {:ok, %{ast: ast}} -> ast_targets(ast)
      _ -> nil
    end
  end

  def targets(_condition), do: nil

  defp ast_targets(%Property{name: "is_hovered", subject: %Scope{kind: :this_element}}),
    do: [:self]

  defp ast_targets(%Property{
         name: "is_hovered",
         subject: %Scope{kind: :element, ref: %{"element_id" => id}}
       })
       when is_binary(id),
       do: [id]

  defp ast_targets(%Logical{op: :or, left: left, right: right}) do
    with [_ | _] = l <- ast_targets(left),
         [_ | _] = r <- ast_targets(right),
         do: Enum.uniq(l ++ r)
  end

  defp ast_targets(_ast), do: nil

  # Every node with a Bubble ID: its ancestors (nearest first) and kind.
  defp index(root) do
    root |> index_walk([], %{}) |> elem(1)
  end

  defp index_walk(%Node{} = node, ancestors, acc) do
    acc =
      case bid(node) do
        id when is_binary(id) -> Map.put_new(acc, id, %{node: node, ancestors: ancestors})
        _ -> acc
      end

    Enum.reduce(node.children, {node, acc}, fn child, {_, acc} ->
      {_, acc} = index_walk(child, [node | ancestors], acc)
      {node, acc}
    end)
  end

  defp walk(%Node{} = node, raw, env) do
    node = lower_node(node, raw, env)
    raw_children = Payload.elements(raw)

    children =
      Enum.map(node.children, fn child ->
        walk(child, Map.get(raw_children, child.map_key) || %{}, env)
      end)

    %{node | children: children}
  end

  defp lower_node(
         %Node{bindings: %{"condition" => %{payload: payload} = binding}} = node,
         raw,
         env
       )
       when is_map(payload) do
    keyed = Conditions.keyed(payload)

    candidates =
      for {{key, %{condition: condition}}, i} <- Enum.with_index(keyed),
          targets = targets(condition),
          targets != nil,
          {:ok, on} <- [resolve(targets, node, env.index)],
          into: %{},
          do: {key, {i, on}}

    if candidates == %{} do
      node
    else
      apply_rules(node, binding, payload, keyed, candidates, raw, env)
    end
  end

  defp lower_node(node, _raw, _env), do: node

  defp apply_rules(node, binding, payload, keyed, candidates, raw, env) do
    last_kept = last_kept(keyed, candidates)

    {payload, rules} =
      Enum.reduce(keyed, {payload, []}, fn {key, %{properties: props}}, acc ->
        case candidates[key] do
          {i, on} -> move(acc, key, props, on, i > last_kept, raw, env)
          nil -> acc
        end
      end)

    node = %{node | hover: (Map.get(node, :hover) || []) ++ Enum.reverse(rules)}

    if map_size(payload) == 0 do
      %{
        node
        | bindings: Map.delete(node.bindings, "condition"),
          content: node.content && Map.delete(node.content, "condition")
      }
    else
      %{node | bindings: Map.put(node.bindings, "condition", %{binding | payload: payload})}
    end
  end

  # The last state that keeps setting the visibility: hover states before
  # it keep theirs. -1 when none does.
  defp last_kept(keyed, candidates) do
    keyed
    |> Enum.with_index()
    |> Enum.filter(fn {{key, %{properties: props}}, _i} ->
      sets_visibility?(props) and
        not (Map.has_key?(candidates, key) and is_boolean(visibility(props)))
    end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.max(fn -> -1 end)
  end

  # A hover state's paint, and its visibility when `last?`, out of the
  # payload into a rule.
  #
  # The paint is what the state sets that differs from the element's own,
  # and whatever an earlier hover rule of the element sets too (a later
  # state putting a value back wins in Bubble). A state whose paint comes
  # out empty (it sets what the element already shows) keeps those
  # properties: there is nothing to apply, and nothing is dropped unseen.
  defp move({payload, rules}, key, props, on, last?, raw, env) do
    earlier = for rule <- rules, k <- Map.keys(rule["paint"]), into: MapSet.new(), do: k
    painted = Map.take(props, env.paint_keys)
    paint = if painted == %{}, do: %{}, else: env.paint.(raw, painted, earlier)
    painted = if paint == %{}, do: %{}, else: painted
    visible = if last?, do: visibility(props)
    moved = Map.keys(painted) ++ if(is_boolean(visible), do: @visibility, else: [])

    case moved do
      [] ->
        {payload, rules}

      _ ->
        rule = %{"state" => key, "on" => on, "paint" => paint, "visible" => visible}
        {drop_properties(payload, key, moved), [rule | rules]}
    end
  end

  defp sets_visibility?(props), do: Enum.any?(@visibility, &Map.has_key?(props, &1))

  defp visibility(props) do
    case Payload.prop(%{"properties" => props}, "is_visible") do
      value when is_boolean(value) -> value
      _ -> nil
    end
  end

  # The state without the properties that moved; a state left with none
  # is gone.
  defp drop_properties(payload, key, moved) do
    state = payload[key]
    prop_key = if Map.has_key?(state, "properties"), do: "properties", else: "%p"
    rest = Map.drop(state[prop_key] || %{}, moved)

    if map_size(rest) == 0,
      do: Map.delete(payload, key),
      else: Map.put(payload, key, Map.put(state, prop_key, rest))
  end

  # What is hovered, where it is: `{:ok, on}` when every element read can
  # be told apart in the page's tree, else :error.
  defp resolve(targets, %Node{} = node, index) do
    self = bid(node)

    targets
    |> Enum.reduce_while([], fn target, acc ->
      case relation(target, self, index) do
        {:ok, on} -> {:cont, [on | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      on -> {:ok, on |> Enum.reverse() |> Enum.uniq()}
    end
  end

  defp relation(_target, nil, _index), do: :error
  defp relation(:self, _self, _index), do: {:ok, %{"element" => "self"}}
  defp relation(self, self, _index), do: {:ok, %{"element" => "self"}}

  defp relation(target, self, index) do
    with %{node: target_node, ancestors: target_up} <- index[target],
         %{ancestors: self_up} <- index[self],
         false <- target_node.kind in @roots do
      place(target, target_up, self, self_up)
    else
      _ -> :error
    end
  end

  defp place(target, target_up, self, self_up) do
    cond do
      Enum.any?(self_up, &(bid(&1) == target)) ->
        {:ok, %{"element" => target, "relation" => "ancestor"}}

      Enum.any?(target_up, &(bid(&1) == self)) and clear_path?(target_up, self) ->
        {:ok, %{"element" => target, "relation" => "descendant"}}

      Enum.any?(target_up, &(bid(&1) == self)) ->
        :error

      true ->
        within(target, target_up, self_up)
    end
  end

  # The nearest element holding both, when it renders one box (not the
  # page or reusable element itself, not a repeating group or runtime
  # container, whose cells repeat it) and none on the way to the element
  # read does.
  defp within(target, target_up, self_up) do
    self_ids = MapSet.new(self_up, &bid/1)

    case Enum.find(target_up, &MapSet.member?(self_ids, bid(&1))) do
      %Node{} = common ->
        id = bid(common)

        if is_binary(id) and box?(common) and clear_path?(target_up, id),
          do: {:ok, %{"element" => target, "relation" => "within", "within" => id}},
          else: :error

      nil ->
        :error
    end
  end

  # No repeating group, runtime container or overlay between the element
  # read and `until` (its ancestor).
  defp clear_path?(target_up, until) do
    target_up
    |> Enum.take_while(&(bid(&1) != until))
    |> Enum.all?(&box?/1)
  end

  defp box?(%Node{kind: kind, runtime: runtime}),
    do: kind not in [:repeating_group | @roots] and not match?(%{"boundary" => _}, runtime)

  defp bid(%Node{source: %{bubble_id: id}}) when is_binary(id) and id != "", do: id
  defp bid(_node), do: nil
end
