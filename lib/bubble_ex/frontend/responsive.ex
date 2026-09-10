defmodule BubbleEx.Frontend.Responsive do
  @moduledoc false

  alias BubbleEx.Frontend.Payload

  @operators %{
    "less_than" => "<",
    "less_or_equal_than" => "<=",
    "greater_than" => ">",
    "greater_or_equal_than" => ">="
  }

  @spec breakpoint_states(map(), map()) :: [map()]
  def breakpoint_states(raw, breakpoints) do
    raw
    |> Map.get("%s", %{})
    |> states()
    |> Enum.flat_map(fn state ->
      with %{"%c" => condition, "%p" => overrides} when is_map(overrides) <- state,
           {:ok, media} <- breakpoint_condition(condition, breakpoints) do
        [%{media: media, overrides: overrides}]
      else
        _ -> []
      end
    end)
  end

  defp states(states) when is_map(states) do
    states
    |> Enum.sort_by(fn {key, _} ->
      case Integer.parse(key) do
        {index, ""} -> {0, index}
        _ -> {1, key}
      end
    end)
    |> Enum.map(&elem(&1, 1))
  end

  defp states(_), do: []

  defp breakpoint_condition(%{"%x" => "PageData", "%p" => props, "%n" => message}, breakpoints)
       when is_map(props) and is_map(message) do
    with "Current Page Width" <- props["%nm"],
         false <- Map.has_key?(message, "%n"),
         operator when is_binary(operator) <- @operators[message["%nm"]],
         %{"%x" => "Breakpoint", "%p" => %{"breakpoint_id" => id}} <- message["%a"],
         %{"size" => width} when is_number(width) and width >= 0 <- breakpoints[id] do
      {:ok, %{"operator" => operator, "width" => width}}
    else
      _ -> :error
    end
  end

  defp breakpoint_condition(_condition, _breakpoints), do: :error

  @spec breakpoints(map()) :: map()
  def breakpoints(payload) do
    case get_in(payload, ["settings", "client_safe", "responsive_breakpoints"]) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  @spec extra_lengths(map()) :: map()
  def extra_lengths(overrides) do
    raw = %{"properties" => overrides}

    Enum.reduce(length_properties(), %{}, fn property, acc ->
      case Payload.prop(raw, property) do
        value when is_number(value) -> Map.put(acc, css_name(property), "#{value}px")
        value when is_binary(value) -> Map.put(acc, css_name(property), value)
        _ -> acc
      end
    end)
  end

  @spec hidden_paint(map(), map()) :: map()
  def hidden_paint(raw, overrides) do
    case Payload.prop(%{"properties" => overrides}, "is_visible") do
      false -> hidden_declaration(Payload.prop(raw, "collapse_when_hidden"))
      _ -> %{}
    end
  end

  defp hidden_declaration(true), do: %{"display" => "none"}
  defp hidden_declaration(_), do: %{"visibility" => "hidden"}

  defp length_properties do
    for prefix <- ["padding", "margin"], side <- ["top", "right", "bottom", "left"] do
      "#{prefix}_#{side}"
    end ++
      ~w(row_gap column_gap min_width_css max_width_css min_height_css max_height_css min_width_px max_width_px min_height_px max_height_px)
  end

  defp css_name(property) do
    property |> String.replace(~r/_(css|px)$/, "") |> String.replace("_", "-")
  end
end
