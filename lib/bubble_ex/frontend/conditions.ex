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

  Visibility (`is_visible`) is the one property targets lower so far
  (`visibility/1`); `other_properties/1` counts the states that set
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

  @doc "How many states set a property other than visibility."
  @spec other_properties(term()) :: non_neg_integer()
  def other_properties(payload) do
    Enum.count(states(payload), fn %{properties: props} ->
      props |> Map.drop(["is_visible", "%iv"]) |> map_size() > 0
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
