defmodule BubbleEx.Frontend.Conditions do
  @moduledoc """
  An element's conditional states (Bubble's "Conditional" tab), as the
  normalized frontend keeps them: the payload of its `:condition` binding
  (`BubbleEx.Frontend.Normalized`), a map of states, each a condition and
  the properties it sets while true (WTF-477).

  States apply in Bubble's order: "States are applied in the order listed.
  If two states are active and modify the same property, the state listed
  last is the one used" (Bubble manual, Conditional formatting). The order
  is the states' keys: numeric keys by value, then any other key (Bubble
  also writes random five-letter keys) in text order.

  Targets lower visibility (`is_visible`, `visibility/1`), a button's
  "isn't clickable" (`disabled_states/2`) and a Text's or button's text
  (`property/2`, WTF-582); `other_properties/2` counts the states that set
  anything else, so the gap stays visible.
  """

  alias BubbleEx.Frontend.Payload

  @type state :: %{condition: term(), properties: map()}

  @doc "The states of a `:condition` binding's payload, in Bubble's order."
  @spec states(term()) :: [state()]
  def states(payload), do: payload |> keyed() |> Enum.map(&elem(&1, 1))

  @doc """
  The states of a `:condition` binding's payload with their keys in the
  payload, in Bubble's order: `{key, state}`.
  """
  @spec keyed(term()) :: [{term(), state()}]
  def keyed(payload) when is_map(payload) do
    payload
    |> Enum.sort_by(fn {key, _} -> order(key) end)
    |> Enum.flat_map(fn
      {key, state} when is_map(state) ->
        [{key, %{condition: state["condition"] || state["%c"], properties: properties(state)}}]

      _ ->
        []
    end)
  end

  def keyed(_payload), do: []

  @doc """
  The states that set visibility, in order: `{condition, visible?}`;
  `visible?` is nil when the state sets `is_visible` to anything but a
  yes/no literal (a target cannot lower it).
  """
  @spec visibility(term()) :: [{term(), boolean() | nil}]
  def visibility(payload) do
    for %{condition: condition, properties: props} <- states(payload),
        Map.has_key?(props, "is_visible") or Map.has_key?(props, "%iv") do
      value = Payload.prop(%{"properties" => props}, "is_visible")
      {condition, if(is_boolean(value), do: value)}
    end
  end

  @doc """
  Whether a state may hide the element: one sets `is_visible` to no, or
  to anything but a yes/no literal (fail closed: it might be no).
  """
  @spec may_hide?(term()) :: boolean()
  def may_hide?(payload), do: Enum.any?(visibility(payload), fn {_, v} -> v != true end)

  @doc """
  The states that set property `key` (the editor's name, its compact alias
  too), in order: `{condition, value}`, `value` as the state sets it.
  """
  @spec property(term(), String.t()) :: [{term(), term()}]
  def property(payload, key) do
    for %{condition: condition, properties: props} <- states(payload),
        {:ok, value} <- [fetch(props, key)],
        do: {condition, value}
  end

  defp fetch(props, key) do
    case Map.fetch(props, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case Payload.prop(%{"properties" => props}, key) do
          nil -> :error
          value -> {:ok, value}
        end
    end
  end

  @doc """
  The states that set a yes/no property `key`, in order: `{condition,
  value?}`; `value?` is nil when a state sets it to anything but a yes/no
  literal (a target cannot lower it).
  """
  @spec boolean_property(term(), String.t()) :: [{term(), boolean() | nil}]
  def boolean_property(payload, key),
    do: for({c, v} <- property(payload, key), do: {c, if(is_boolean(v), do: v)})

  @doc """
  The states of a button's "isn't clickable" (`button_disabled`) that can
  change it, in order, from its static value `initial` (WTF-520): those
  before the first that sets another value set the value it already has,
  whatever their condition, and are dropped. `[]` when no state can make
  it differ from `initial`.
  """
  @spec disabled_states(term(), boolean()) :: [{term(), boolean() | nil}]
  def disabled_states(payload, initial) do
    payload
    |> boolean_property("button_disabled")
    |> Enum.drop_while(fn {_condition, value} -> value == initial end)
  end

  @doc """
  The key a target keeps a button's compiled "isn't clickable"
  conditionals under (`BubbleEx.Target.Elixir.Frontend.compile/5`'s
  result), from its `:condition` binding's ID (WTF-520).
  """
  @spec disabled_id(String.t()) :: String.t()
  def disabled_id(condition_id), do: condition_id <> " :: disabled"

  @doc """
  The key a target keeps an element's compiled conditional text under
  (`BubbleEx.Target.Elixir.Frontend.compile/5`'s result: a Text's content,
  a button's label), from its `:condition` binding's ID (WTF-582).
  """
  @spec text_id(String.t()) :: String.t()
  def text_id(condition_id), do: condition_id <> " :: text"

  @doc """
  The `cond` of a compiled conditional text (`:text` of
  `BubbleEx.Target.Elixir.Frontend.compile/5`'s result, WTF-582): its
  `branches` (each a state's `condition` source, a yes/no clause, and its
  value) tested last first, else the content on page load (`base`), as
  while a variable in `guards` (the page's width) is nil. `value` prints
  a value (`%{source, shown}`: as compiled, and as shown text).
  """
  @spec text_source(map(), (map() -> String.t())) :: String.t()
  def text_source(%{base: base, branches: branches, guards: guards}, value) do
    base = value.(base)

    # With several states each condition is read first, as a yes/no of
    # its own (`bubble_state_<n>`): tried as clauses, a condition failing
    # would narrow what the later ones read, and Elixir's type checker
    # warns about one it then proves always true or false (`x == true`,
    # then `x != true`).
    {reads, tests} =
      case branches do
        [_] = [branch] ->
          {"", [{branch.condition, branch}]}

        _ ->
          numbered = Enum.with_index(branches, 1)

          {Enum.map_join(numbered, "", fn {b, n} -> "bubble_state_#{n} = #{b.condition}\n" end),
           Enum.map(numbered, fn {b, n} -> {"bubble_state_#{n}", b} end)}
      end

    clauses =
      Enum.map_join(guards, "", &"is_nil(#{&1}) -> #{base}\n") <>
        (tests
         |> Enum.reverse()
         |> Enum.map_join("", fn {test, branch} -> "#{test} -> #{value.(branch)}\n" end))

    "#{reads}cond do\n#{clauses}true -> #{base}\nend"
    |> Code.format_string!()
    |> IO.iodata_to_binary()
  end

  @doc """
  How many states set a property other than visibility, nor any of
  `lowered` (the properties a target lowers for this element, e.g. a
  Text's `"text"`, WTF-582).
  """
  @spec other_properties(term(), [String.t()]) :: non_neg_integer()
  def other_properties(payload, lowered \\ []) do
    Enum.count(states(payload), fn %{properties: props} ->
      props |> Map.drop(["is_visible", "%iv" | lowered]) |> map_size() > 0
    end)
  end

  defp properties(state) do
    case state["properties"] || state["%p"] do
      props when is_map(props) -> props
      _ -> %{}
    end
  end

  defp order(key) when is_binary(key) do
    case Integer.parse(key) do
      {index, ""} -> {0, index, key}
      _ -> {1, 0, key}
    end
  end

  defp order(key), do: {2, 0, inspect(key)}
end
