defmodule BubbleEx.Frontend.Payload do
  @moduledoc false

  # Dual-shape accessors for decoded app payloads. `parse_app_json/1` keeps
  # Bubble aliases (`%p3`, `%el`, `%x`); `.bubble.json` exports use readable
  # keys (`pages`, `elements`, `type`).

  @spec section(map(), String.t(), String.t()) :: map()
  def section(map, decoded, aliased) when is_map(map) do
    case Map.get(map, decoded) || Map.get(map, aliased) do
      inner when is_map(inner) -> inner
      _ -> %{}
    end
  end

  def section(_, _, _), do: %{}

  @spec pages(map()) :: map()
  def pages(payload), do: section(payload, "pages", "%p3")

  @spec reusables(map()) :: map()
  def reusables(payload), do: section(payload, "element_definitions", "%ed")

  @spec page_path(map()) :: String.t() | nil
  def page_path(page) when is_map(page) do
    Enum.find([Map.get(page, "%nm"), Map.get(page, "name")], fn
      name when is_binary(name) -> String.trim(name) != ""
      _ -> false
    end)
  end

  def page_path(_), do: nil

  @spec hydrated_page?(map()) :: boolean()
  def hydrated_page?(page) when is_map(page) do
    is_map(Map.get(page, "%el")) or is_map(Map.get(page, "elements"))
  end

  def hydrated_page?(_), do: false

  @spec unhydrated_page?(map()) :: boolean()
  def unhydrated_page?(page) when is_map(page) do
    is_binary(page_path(page)) and not hydrated_page?(page)
  end

  def unhydrated_page?(_), do: false

  @spec styles(map()) :: map()
  def styles(payload), do: section(payload, "styles", "%s")

  @spec elements(map()) :: map()
  def elements(node), do: section(node, "elements", "%el")

  @spec workflows(map()) :: map()
  def workflows(node) do
    case Map.get(node, "workflows") || Map.get(node, "%wf") || Map.get(node, "%w") do
      inner when is_map(inner) -> inner
      _ -> %{}
    end
  end

  @spec type(map()) :: String.t() | nil
  def type(node) when is_map(node) do
    case Map.get(node, "type") || Map.get(node, "%x") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  def type(_), do: nil

  @spec bubble_id(map()) :: String.t() | nil
  def bubble_id(node) when is_map(node) do
    case Map.get(node, "id") || Map.get(node, "_id") || Map.get(node, "%id") do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  def bubble_id(_), do: nil

  @property_aliases %{
    "background_gradient_direction" => ["%b4"],
    "background_gradient_from" => ["%bgf"],
    "background_gradient_to" => ["%bgt"],
    "background_style" => ["%bas"],
    "bgcolor" => ["%bgc"],
    "border_color" => ["%bc"],
    "border_roundness" => ["%br"],
    "border_style" => ["%bos"],
    "border_width" => ["%bw"],
    "boxshadow_blur" => ["%bsb"],
    "boxshadow_color" => ["%bsc"],
    "boxshadow_horizontal" => ["%bh"],
    "boxshadow_spread" => ["%bsp"],
    "boxshadow_style" => ["%bs"],
    "boxshadow_vertical" => ["%bv"],
    "choices" => ["%ch"],
    "content" => ["%c1", "%3"],
    "content_format" => ["%cf"],
    "contents" => ["%ct"],
    "default" => ["%d1"],
    "element_id" => ["%ei"],
    "font_color" => ["%fc"],
    "font_size" => ["%fs"],
    "is_visible" => ["%iv"],
    "label" => ["%lab"],
    "letter_spacing" => ["%ls"],
    "line_height" => ["%lh"],
    "mandatory" => ["%1m"],
    "placeholder" => ["%ps"],
    "run_mode" => ["%2f", "2f"],
    "style" => ["%s"],
    "text" => ["%3"],
    "text_align" => ["%fa"]
  }

  @spec prop(map(), String.t()) :: term()
  def prop(node, key) when is_map(node) and is_binary(key) do
    props = properties(node)

    case Map.fetch(props, key) do
      {:ok, value} ->
        value

      :error ->
        case fetch_alias(props, Map.get(@property_aliases, key, [])) do
          {:ok, value} -> value
          :error -> Map.get(node, key)
        end
    end
  end

  defp fetch_alias(_props, []), do: :error

  defp fetch_alias(props, [key | rest]) do
    case Map.fetch(props, key) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_alias(props, rest)
    end
  end

  @spec properties(map()) :: map()
  def properties(node) when is_map(node) do
    case Map.get(node, "properties") || Map.get(node, "%p") do
      props when is_map(props) -> props
      _ -> %{}
    end
  end

  def properties(_), do: %{}

  @spec name(map()) :: String.t() | nil
  def name(node) when is_map(node) do
    first_binary([
      prop(node, "original_name"),
      Map.get(node, "name"),
      Map.get(node, "%nm"),
      Map.get(node, "default_name"),
      prop(node, "name")
    ])
  end

  def name(_), do: nil

  @spec display_name(map()) :: String.t() | nil
  def display_name(node) when is_map(node) do
    first_binary([
      prop(node, "title"),
      Map.get(node, "display"),
      name(node)
    ])
  end

  def display_name(_), do: nil

  defp first_binary(values) do
    Enum.find(values, &(is_binary(&1) and &1 != ""))
  end
end
