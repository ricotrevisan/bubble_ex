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

  def declarations(properties, opts \\ []) when is_map(properties) do
    properties
    |> Enum.flat_map(fn
      {"is_visible", visible} when is_boolean(visible) ->
        visibility = {"visibility", if(visible, do: "visible", else: "hidden")}

        if Keyword.get(opts, :collapse_when_hidden?, false) do
          [
            visibility,
            {"display", if(visible, do: Keyword.get(opts, :display, "block"), else: "none")}
          ]
        else
          [visibility]
        end

      {name, value} when name in ["margin_left", "margin_right"] and is_number(value) ->
        [{String.replace(name, "_", "-"), "#{value}px"}]

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
