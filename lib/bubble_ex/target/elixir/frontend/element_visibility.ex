defmodule BubbleEx.Target.Elixir.Frontend.ElementVisibility do
  @moduledoc """
  Lowers an element's `is visible` / `isn't visible`, read by an
  expression on the same page or reusable element, into the visibility
  that element has there (WTF-578), for `BubbleEx.Target.Elixir.Frontend`.

  The page computes an element's visibility on the server: from its
  visibility on page load and the conditionals that set it, folded in
  Bubble's order (the last true state decides). Where that is all there
  is, a read of it is decided the same way: the read is replaced by the
  read element's own visibility folded from its states (`:if`, as a
  conditional state's value), and by that of each of its ancestors up to
  the one it shares with the reader. An element whose parent is hidden is
  not visible: the saved Bubble captures of a private app (the runtime's
  own `_is_visible`, three widths) report not visible all but 3 of about
  1,050 elements that are visible on page load with no conditional of
  their own, inside a hidden group. Ancestors shared with the reader are
  visible whenever the reader is shown, and when it is not, its own
  visibility does not matter; so an element that holds the reader, or the
  reader itself, is visible.

  A read stays as it is (the page marks it as a value it does not keep)
  when the browser may change what decides it:

    * the element or an ancestor on the way is shown, hidden, toggled or
      animated by a workflow step (`ShowElement`, `HideElement`,
      `ToggleElement`, `AnimateElement`), whose effect only the browser
      knows
    * it is a Floating Group a step shows or hides, or an ancestor on the
      way is one, or is a runtime container (the element is in a
      repeating group's cell, a table or a plugin container the reader is
      not in)
    * a breakpoint sets its display, or an ancestor's on the way
    * a hover conditional shows or hides it, or an ancestor on the way
      (WTF-590, `BubbleEx.Frontend.Hover`): the browser applies it
    * a conditional on the way sets the visibility to something other
      than a yes/no literal, or does not compile
    * it is on another page or reusable element, or not found
    * it reads itself back (the element's own visibility, directly, by
      a group reading its own contents, or through others), which Bubble
      settles at runtime

  A Popup or Group Focus (WTF-587) on the way, the element read
  included, is visible while it is open: the read becomes one of its
  `is visible`, which the page supplies from the open state it keeps for
  an overlay it renders only while open (`@bubble_open`) and marks for
  any other. A Floating Group no step shows or hides (nor a breakpoint
  or a hover rule, `decided_floating?/2`) is folded from its
  conditionals like a group: the page compiles them too.

  An element holding the reader is visible only while the reader is
  shown: the read is for what the reader shows (its visibility, text,
  "isn't clickable" and shown values), not for a value it hands on while
  hidden.

  The inlined conditions read their own inputs, so the page decides the
  reader with what it keeps, as for any other condition: an input it does
  not keep or load is marked there instead.
  """

  alias BubbleEx.Expression
  alias BubbleEx.Expression.{Compiler, IR}
  alias BubbleEx.Frontend.{Conditions, Hover, Normalized, Payload, Responsive}
  alias BubbleEx.Frontend.Normalized.Node

  @states ["is_visible", "isnt_visible"]
  @steps ~w(ShowElement HideElement ToggleElement AnimateElement)

  @type t :: %{
          nodes: %{String.t() => %{node: Node.t(), ancestors: [String.t()], root: String.t()}},
          touched: MapSet.t(),
          env: Expression.Env.t()
        }

  @doc """
  The index `inline/4` reads: every node of `frontend`'s pages and
  reusable elements by Bubble ID (with its ancestors, nearest first, and
  its root), the elements a workflow step of `app` shows, hides, toggles
  or animates, and the compiler's `env`.
  """
  @spec index(map(), Normalized.t(), Expression.Env.t()) :: t()
  def index(app, %Normalized{} = frontend, env) do
    nodes =
      for root <- frontend.pages ++ frontend.reusables,
          root_id = bid(root),
          is_binary(root_id),
          {id, entry} <- walk(root, [], root_id),
          into: %{},
          do: {id, entry}

    %{nodes: nodes, touched: touched(app), env: env}
  end

  defp walk(%Node{} = node, ancestors, root) do
    own =
      case bid(node) do
        id when is_binary(id) -> [{id, %{node: node, ancestors: ancestors, root: root}}]
        _ -> []
      end

    below = if is_binary(bid(node)), do: [bid(node) | ancestors], else: ancestors
    own ++ Enum.flat_map(node.children, &walk(&1, below, root))
  end

  defp bid(%Node{source: %{bubble_id: id}}) when is_binary(id), do: id
  defp bid(_node), do: nil

  # Every element a step names to show, hide, toggle or animate, on any
  # page or reusable element.
  defp touched(app), do: touched(app, MapSet.new())

  defp touched(term, acc) when is_map(term) and not is_struct(term) do
    acc =
      with type when type in @steps <- Payload.type(term),
           props when is_map(props) <- Map.get(term, "properties") || Map.get(term, "%p"),
           id when is_binary(id) <- Payload.prop(%{"properties" => props}, "element_id") do
        MapSet.put(acc, id)
      else
        _ -> acc
      end

    Enum.reduce(term, acc, fn {_key, value}, acc -> touched(value, acc) end)
  end

  defp touched(term, acc) when is_list(term), do: Enum.reduce(term, acc, &touched/2)
  defp touched(_term, acc), do: acc

  @doc """
  `ir` (compiled with `host` as its element) with each `is visible` /
  `isn't visible` read it can decide replaced by that visibility. `seen`
  holds the elements whose visibility is being compiled (the host's own,
  when `ir` is one of its visibility conditions): a read of one of them
  stays.
  """
  @spec inline(IR.t(), String.t() | nil, MapSet.t(), t() | nil) :: IR.t()
  def inline(ir, _host, _seen, nil), do: ir
  def inline(ir, nil, _seen, _index), do: ir
  def inline(%IR{} = ir, host, seen, index), do: rewrite(ir, host, seen, index)

  defp rewrite(
         %IR{op: :input, args: [:element_state, %{"state" => state} = ref]} = ir,
         host,
         seen,
         index
       )
       when state in @states do
    case visible(ref["element"], host, seen, index) do
      {:ok, visible} -> if state == "is_visible", do: visible, else: negate(visible)
      :error -> ir
    end
  end

  defp rewrite(%IR{args: args} = ir, host, seen, index),
    do: %{ir | args: Enum.map(args, &rewrite_arg(&1, host, seen, index))}

  defp rewrite_arg(%IR{} = ir, host, seen, index), do: rewrite(ir, host, seen, index)

  defp rewrite_arg(list, host, seen, index) when is_list(list),
    do: Enum.map(list, &rewrite_arg(&1, host, seen, index))

  defp rewrite_arg(other, _host, _seen, _index), do: other

  # Element `id`'s visibility read from `host`: `{:ok, ir}` or `:error`.
  defp visible(id, host, seen, index) when is_binary(id) do
    with %{root: root} = target <- index.nodes[id],
         %{root: ^root} = reader <- index.nodes[host] do
      holders = [host | reader.ancestors]

      cond do
        # Its visibility, or a holder's, is what is being compiled: it
        # reads itself back (a group reading its own child, say).
        Enum.any?([id | target.ancestors], &MapSet.member?(seen, &1)) -> :error
        id in holders -> {:ok, literal(true)}
        true -> path_visible(path(id, target, holders), seen, index)
      end
    else
      _ -> :error
    end
  end

  defp visible(_id, _host, _seen, _index), do: :error

  # The element and its ancestors below the first one the reader shares.
  defp path(id, target, holders),
    do: Enum.take_while([id | target.ancestors], &(&1 not in holders))

  defp path_visible([target | _] = path, seen, index) do
    path
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case own(id, id == target, seen, index) do
        {:ok, ir} -> {:cont, {:ok, [ir | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, all(Enum.reverse(parts))}
      :error -> :error
    end
  end

  # An element's own visibility on the server, or `:error` when the
  # browser may change it. `target?`: the element read (its own contents
  # may be a runtime container; an ancestor's may not).
  defp own(id, target?, seen, index) do
    %{node: node} = index.nodes[id]

    cond do
      MapSet.member?(seen, id) ->
        :error

      # A Popup or Group Focus is visible while it is open: the read is of
      # its open state, which the page keeps when it renders it only while
      # open (WTF-587); the page marks the read where it does not.
      opens?(node) ->
        {:ok, open_read(id)}

      # A Floating Group no step shows or hides (WTF-587) is a group whose
      # conditionals the page decides; `decided_floating?/2`.
      floating?(node) and decided_floating?(node, index.touched) ->
        fold(node, id, MapSet.put(seen, id), index)

      MapSet.member?(index.touched, id) ->
        :error

      match?(%{"boundary" => "overlay"}, node.runtime) ->
        :error

      not target? and match?(%{"boundary" => _}, node.runtime) ->
        :error

      breakpoint_display?(node) ->
        :error

      Hover.visibility?(node) ->
        :error

      true ->
        fold(node, id, MapSet.put(seen, id), index)
    end
  end

  defp fold(%Node{} = node, id, seen, index) do
    initial = literal(node.box[:hidden?] != true)

    payload =
      case node.bindings["condition"] do
        %{kind: :condition, payload: payload} -> payload
        _ -> nil
      end

    payload
    |> Conditions.visibility()
    |> Enum.reduce_while({:ok, initial}, fn
      {_condition, nil}, _acc ->
        {:halt, :error}

      {condition, visible?}, {:ok, acc} ->
        case condition(condition, id, seen, index) do
          {:ok, c} -> {:cont, {:ok, IR.node(:if, [c, literal(visible?), acc], "boolean")}}
          :error -> {:halt, :error}
        end
    end)
  end

  defp condition(condition, id, seen, index) when is_map(condition) do
    env = %{index.env | host: id}

    with {:ok, %{ast: ast}} <- Expression.parse(condition, schema: env.schema),
         {:ok, %{ir: %IR{type: "boolean"} = ir}} <- Compiler.compile(ast, env) do
      {:ok, rewrite(ir, id, seen, index)}
    else
      _ -> :error
    end
  end

  defp condition(_condition, _id, _seen, _index), do: :error

  @doc """
  Whether `node` is a Popup or a Group Focus: shown and hidden by
  workflows, the page's hook and the user (outside click, Escape), so
  its visibility is whether it is open.
  """
  @spec opens?(Node.t()) :: boolean()
  def opens?(%Node{runtime: %{"boundary" => "overlay", "overlay" => overlay}}),
    do: overlay in ["popup", "group_focus"]

  def opens?(_node), do: false

  @doc """
  Whether `node` is a Floating Group whose visibility its conditionals
  decide on the server: no workflow step (of `app`, as `index/3` finds
  them) shows, hides, toggles or animates it, a breakpoint does not set
  its display and no hover conditional shows or hides it (WTF-587).
  `touched` is `index/3`'s set of the elements steps name.
  """
  @spec decided_floating?(Node.t(), MapSet.t()) :: boolean()
  def decided_floating?(%Node{} = node, touched) do
    floating?(node) and not MapSet.member?(touched, bid(node)) and
      not breakpoint_display?(node) and not Hover.visibility?(node)
  end

  defp floating?(%Node{runtime: %{"boundary" => "overlay", "overlay" => "floating_group"}}),
    do: true

  defp floating?(_node), do: false

  # The open state of overlay `id`, as the read the page supplies.
  defp open_read(id),
    do: IR.node(:input, [:element_state, %{"element" => id, "state" => "is_visible"}], "boolean")

  # A breakpoint shows or hides the element at a width.
  defp breakpoint_display?(%Node{responsive: rules}), do: Responsive.visibility_rule?(rules)

  defp literal(value), do: IR.node(:literal, [value], "boolean")

  defp negate(%IR{op: :literal, args: [value]}), do: literal(not value)
  defp negate(ir), do: IR.node(:not, [ir], "boolean")

  # The visibilities on the way, all of them: an always hidden one hides
  # it, an always visible one says nothing.
  defp all(parts) do
    if Enum.any?(parts, &match?(%IR{op: :literal, args: [false]}, &1)) do
      literal(false)
    else
      case Enum.reject(parts, &match?(%IR{op: :literal, args: [true]}, &1)) do
        [] -> literal(true)
        [one] -> one
        many -> IR.node(:and, many, "boolean")
      end
    end
  end
end
