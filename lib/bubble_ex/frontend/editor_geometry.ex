defmodule BubbleEx.Frontend.EditorGeometry do
  @moduledoc """
  Reads the geometry of Bubble's editor JSON the way Bubble's runtime does
  (WTF-446).

  The editor JSON (a Buildprint v5 workspace, a `.bubble` export) writes an
  element's canvas box as `left`/`top`/`width`/`height` on every element,
  also inside Column, Row and Align-to-parent containers where Bubble
  ignores it, and leaves out the sizing flags (`fit_*`, `single_*`) that
  are off. Bubble's runtime payload, which `BubbleEx.Frontend.normalize/2`
  was calibrated on, serves the same values as `%l`/`%t`/`%w`/`%h`. The
  editor JSON cannot be told apart from a readable payload by its shape,
  so its loader marks it (`mark/1`: `BubbleEx.Buildprint.V5.merge/2`, and a
  caller that decodes a `.bubble` export) and `normalize/2` converts a
  marked app with `runtime_shape/2` before it reads it. An unmarked app is
  read as before, byte for byte.

  The conversion, inside a Column, Row or Align-to-parent container (a
  page's or reusable definition's `container_layout`, down the tree):

    * **Elements.** `left`/`top`/`width`/`height` become `%l`/`%t`/`%w`/
      `%h`: no canvas offsets in flow, a size only on a fixed axis. A
      missing sizing flag is off, so an element that is neither fixed nor
      fit on an axis fills it between its min and max. Plugin elements
      (rendered as dimension-preserving placeholders) keep their canvas
      `width`/`height` and flags as written; only their offsets go.
    * **Height of an element neither fixed nor fit, without a min height.**
      Its canvas height becomes its `min_height_css`. *Assumption*, not
      yet calibrated by a Bubble capture (on the WTF-358 replay list): it
      keeps such an element from collapsing without clipping content.
    * **Reusable definitions.** Their `width`/`height` are the canvas size
      (`%w`/`%h`).
    * **Pages.** Their canvas offsets and height are dropped: the page
      grows with its content from `min_height_px`. It keeps its width when
      marked `fixed_width`, and fills the viewport otherwise.

  Children of Fixed or layout-less (legacy) containers keep their canvas
  box: there, Bubble places them at it.
  """

  alias BubbleEx.Frontend.Payload

  @mark "__bubble_ex_geometry__"
  @canvas %{"left" => "%l", "top" => "%t", "width" => "%w", "height" => "%h"}
  @flow ["column", "row", "relative", "align_to_parent", "align-to-parent"]
  @plugin_type ~r/^\d+x\d+-[A-Za-z0-9]+$/

  @doc "Marks a decoded app as Bubble editor JSON."
  @spec mark(map()) :: map()
  def mark(app) when is_map(app), do: Map.put(app, @mark, "editor")

  @doc "The app without its mark (for hashing what the loader read)."
  @spec unmark(map()) :: map()
  def unmark(app) when is_map(app), do: Map.delete(app, @mark)

  @doc """
  Whether `app` is read as editor JSON: `opts[:geometry]` (`:editor` or
  `:runtime`) when given, else the app's mark.
  """
  @spec editor?(map(), keyword()) :: boolean()
  def editor?(app, opts \\ []) do
    case Keyword.get(opts, :geometry) do
      :editor -> true
      :runtime -> false
      _ -> is_map(app) and app[@mark] == "editor"
    end
  end

  @doc "`app` with editor geometry in its runtime shape; unchanged unless `editor?/2`."
  @spec runtime_shape(map(), keyword()) :: map()
  def runtime_shape(app, opts \\ []) do
    if editor?(app, opts) do
      app
      |> update_section("pages", &container(&1, &2, :page))
      |> update_section("element_definitions", &container(&1, &2, :reusable_definition))
    else
      app
    end
  end

  defp update_section(app, key, fun) do
    case app[key] do
      section when is_map(section) ->
        Map.put(app, key, Map.new(section, fn {k, v} -> {k, fun.(k, v)} end))

      _ ->
        app
    end
  end

  defp container(_key, raw, kind) when is_map(raw) do
    flow? = flow?(raw)
    raw = if flow?, do: update_props(raw, &container_props(&1, kind)), else: raw
    update_children(raw, flow?)
  end

  defp container(_key, raw, _kind), do: raw

  defp update_children(raw, parent_flow?) do
    case raw["elements"] do
      elements when is_map(elements) ->
        Map.put(
          raw,
          "elements",
          Map.new(elements, fn {k, child} -> {k, element(child, parent_flow?)} end)
        )

      _ ->
        raw
    end
  end

  defp element(raw, parent_flow?) when is_map(raw) do
    flow? = flow?(raw)
    raw = if parent_flow?, do: update_props(raw, &element_props(&1, Payload.type(raw))), else: raw
    update_children(raw, flow?)
  end

  defp element(raw, _parent_flow?), do: raw

  defp flow?(raw), do: Payload.prop(raw, "container_layout") in @flow

  defp update_props(raw, fun) do
    case raw["properties"] do
      props when is_map(props) -> Map.put(raw, "properties", fun.(props))
      _ -> raw
    end
  end

  defp container_props(props, :page) do
    props
    |> Map.drop(["left", "top", "height"])
    |> Map.put_new("single_width", props["fixed_width"] == true)
    |> Map.put_new("single_height", false)
  end

  defp container_props(props, :reusable_definition), do: compact(props)

  defp element_props(props, type) do
    if plugin?(type) do
      compact(props, ["left", "top"])
    else
      props
      |> compact()
      |> put_flags()
      |> put_canvas_min_height()
    end
  end

  defp plugin?(type), do: is_binary(type) and Regex.match?(@plugin_type, type)

  defp compact(props, keys \\ Map.keys(@canvas)) do
    Enum.reduce(Map.take(@canvas, keys), props, fn {readable, compact}, acc ->
      case acc do
        %{^readable => value} when is_number(value) and not is_map_key(acc, compact) ->
          acc |> Map.delete(readable) |> Map.put(compact, value)

        _ ->
          acc
      end
    end)
  end

  defp put_flags(props) do
    Enum.reduce(~w(fit_width single_width fit_height single_height), props, fn flag, acc ->
      Map.put_new(acc, flag, false)
    end)
  end

  defp put_canvas_min_height(props) do
    height = props["%h"]

    if props["fit_height"] != true and props["single_height"] != true and
         is_nil(props["min_height_css"]) and is_nil(props["min_height_px"]) and
         is_number(height) and height > 0 do
      Map.put(props, "min_height_css", px(height))
    else
      props
    end
  end

  defp px(value) when is_integer(value), do: "#{value}px"

  defp px(value) when is_float(value) do
    if value == Float.round(value), do: "#{trunc(value)}px", else: "#{value}px"
  end
end
