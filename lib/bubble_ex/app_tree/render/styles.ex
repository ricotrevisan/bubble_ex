defmodule BubbleEx.AppTree.Render.Styles do
  @moduledoc "Layer 2: STYLES.md — style name → typography/color reference table."

  @spec render(term()) :: iodata()
  def render(styles) do
    rows =
      styles
      |> safe_map()
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(&row/1)

    [
      "# Styles\n\n_Generated from styles.json — do not edit._\n",
      if(rows == [],
        do: [],
        else: [
          "\n| Style | Element type | Display | Font | Size | Color |\n|---|---|---|---|---|---|\n",
          rows
        ]
      )
    ]
  end

  # `styles` may be a non-map value in a hostile export; treat that the same
  # as absent instead of crashing.
  defp safe_map(v) when is_map(v), do: v
  defp safe_map(_), do: %{}

  defp row({key, style}) when is_map(style) do
    props = style["properties"] || %{}

    cells = [
      key,
      style["type"] || "",
      style["display"] || "",
      to_cell(props["font_face"]),
      to_cell(props["font_size"]),
      to_cell(props["font_color"])
    ]

    ["| ", Enum.join(cells, " | "), " |\n"]
  end

  defp row({key, _}), do: ["| ", key, " |  |  |  |  |  |\n"]

  defp to_cell(nil), do: ""
  defp to_cell(value) when is_binary(value), do: value
  defp to_cell(value), do: to_string(value)
end
