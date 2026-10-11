defmodule BubbleEx.Frontend.Export.ConditionCss do
  @moduledoc "Safe paint declarations for a Bubble element condition's property diff."

  alias BubbleEx.Frontend.Export.Css

  @properties %{
    "background_color" => "background-color",
    "bgcolor" => "background-color",
    "font_color" => "color",
    "color" => "color",
    "border_color_left" => "border-left-color",
    "border_color_bottom" => "border-bottom-color",
    "border_color_right" => "border-right-color",
    "border_color_top" => "border-top-color"
  }

  def declarations(properties) when is_map(properties) do
    properties
    |> Enum.flat_map(fn
      {"is_visible", visible} when is_boolean(visible) ->
        [{"display", if(visible, do: "block", else: "none")}]

      {name, value} ->
        case @properties[name] do
          nil -> []
          css -> [{css, value}]
        end
    end)
    |> Map.new()
    |> Css.declarations()
  end
end
