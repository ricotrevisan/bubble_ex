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
  so its loader marks it (`mark/1`: `BubbleEx.Buildprint.V5.merge/2`,
  `BubbleEx.Frontend.read_bubble_export/1`) and `normalize/2` converts a
  marked app with `runtime_shape/2` before it reads it. An unmarked app is
  read as before, byte for byte.

  The conversion, inside a Column, Row or Align-to-parent container (a
  page's or reusable definition's `container_layout`, down the tree):

    * **Elements.** `left`/`top`/`width`/`height` become `%l`/`%t`/`%w`/
      `%h`: no canvas offsets in flow, a size only on a fixed axis. Plugin
      elements (`BubbleEx.Frontend.Payload.plugin_type?/1`: marketplace and
      Bubble's own plugins, rendered as dimension-preserving placeholders)
      keep their canvas `width`/`height` and flags as written; only their
      offsets go.
    * **Width.** A missing width flag (`fit_width`, `single_width`) is off,
      so an element that is neither fixed nor fit on its width fills it
      between its min and max.
    * **Height** (WTF-468). The height flags are left as written, as
      Bubble's runtime payload serves them (it leaves them out too), so an
      element's height follows the same rules as a runtime payload's:
        - `single_height` set: fixed, at its min height (else `%h`);
        - `fit_height` set, or no height flag at all: sized to its
          content, from its own min height if it has one (the canvas height
          is not a min height);
        - `single_height` written `false` without `fit_height`: fills
          between its min and max;
        - a Row child with `vert_alignment: "stretch"` stretches to the
          row, and a Group without a height flag in an Align-to-parent
          container fills it (`BubbleEx.Frontend.normalize/2`).
      The 2026-10-01 replay measured 49 rendered elements without a height
      flag or a min height, nearly all Row children: 41 rendered shorter
      than their canvas height (36 sized to their content, with a computed
      min height of `0px` or `auto`), 7 taller and 1 alike. The 7 taller
      ones are content-sized too: 4 images whose width sets their height,
      2 texts wrapping in a Row, 1 Group taller with its content. None of
      them fills its parent.
      *Inferred, not calibrated by the replay:* that a Row child without
      a height flag no longer stretches to the row (as missing flags read
      as off made it), from the runtime payload, which leaves the flags
      out and is read that way. Column children follow the same rules,
      untested.
    * **An element with nothing to size it**, neither fixed nor fit and
      without a min height, keeps its canvas height: a Shape without a
      height flag (Bubble's Shapes have no content) as a fixed height,
      unless it keeps an aspect ratio (`aspect_ratio_width`/`_height`);
      an empty Group or Floating group with a visible background or
      border (its own or its style's) as a min height; an element lowered
      to an empty placeholder as a min height (`canvas_height/1`). Other
      empty elements are content-sized.
    * **Images that keep their aspect ratio** (`use_aspect_ratio`, not
      fixed height; WTF-458). Their height follows their width: they are
      read as fit height, as Bubble serves a fit-height aspect image, so
      they get no height, min or max height, and no fill, and the
      `aspect-ratio` sets their height from their width. This overrides
      a written `fit_height: false`: fit off and fixed off would make the
      image fill its parent's height, and a filled height (`flex-grow`,
      `align-self: stretch`) overrides the aspect ratio in CSS, while the
      replay measured such images at the height their width gives them.
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
  @canvas_height "__bubble_ex_canvas_height__"
  @flow ["column", "row", "relative", "align_to_parent", "align-to-parent"]

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
      styles = Payload.styles(app)

      app
      |> update_section("pages", &container(&1, :page, styles))
      |> update_section("element_definitions", &container(&1, :reusable_definition, styles))
    else
      app
    end
  end

  @doc """
  The canvas height of an editor element in flow that is neither fixed
  nor fit and has no min height (WTF-468), or nil. Only `runtime_shape/2` sets it,
  so a runtime payload never has one; `BubbleEx.Frontend.normalize/2`
  keeps it as the min height of an empty placeholder.
  """
  @spec canvas_height(map()) :: number() | nil
  def canvas_height(raw) when is_map(raw), do: raw[@canvas_height]
  def canvas_height(_raw), do: nil

  @doc "The element key `canvas_height/1` reads."
  @spec canvas_height_key() :: String.t()
  def canvas_height_key, do: @canvas_height

  defp update_section(app, key, fun) do
    case app[key] do
      section when is_map(section) ->
        Map.put(app, key, Map.new(section, fn {k, v} -> {k, fun.(v)} end))

      _ ->
        app
    end
  end

  defp container(raw, kind, styles) when is_map(raw) do
    raw = if flow?(raw), do: update_props(raw, &container_props(&1, kind)), else: raw
    update_children(raw, parent(raw), styles)
  end

  defp container(raw, _kind, _styles), do: raw

  # How a container lays out its children: nil (Fixed or no layout: the
  # canvas box stands) or :flow.
  defp parent(raw), do: if(flow?(raw), do: :flow)

  defp update_children(raw, parent, styles) do
    case raw["elements"] do
      elements when is_map(elements) ->
        Map.put(
          raw,
          "elements",
          Map.new(elements, fn {k, child} -> {k, element(child, parent, styles)} end)
        )

      _ ->
        raw
    end
  end

  defp element(raw, parent, styles) when is_map(raw) do
    raw = if parent, do: flow_element(raw, styles), else: raw
    update_children(raw, parent(raw), styles)
  end

  defp element(raw, _parent, _styles), do: raw

  defp flow_element(raw, styles) do
    type = Payload.type(raw)

    if Payload.plugin_type?(type) do
      update_props(raw, &compact(&1, ["left", "top"]))
    else
      raw = update_props(raw, &(&1 |> compact() |> put_width_flags()))
      flow_height(raw, type, Payload.properties(raw), styles)
    end
  end

  defp flow_height(raw, "Image", %{"use_aspect_ratio" => true}, _styles),
    do: update_props(raw, &put_aspect_fit_height/1)

  defp flow_height(raw, type, props, styles) do
    cond do
      not guessed_height?(props) ->
        raw

      type == "Shape" and not flagged_height?(props) and not aspect_ratio?(props) ->
        update_props(raw, &Map.put(&1, "single_height", true))

      type in ["Group", "FloatingGroup"] and no_children?(raw) and painted?(raw, styles) ->
        update_props(raw, &Map.put(&1, "min_height_css", px(props["%h"])))

      true ->
        Map.put(raw, @canvas_height, props["%h"])
    end
  end

  # Neither fixed nor fit, without a min height, with a canvas height: the
  # height the editor JSON leaves to be guessed.
  defp guessed_height?(props) do
    props["fit_height"] != true and props["single_height"] != true and
      is_nil(props["min_height_css"]) and is_nil(props["min_height_px"]) and
      is_number(props["%h"]) and props["%h"] > 0
  end

  defp flagged_height?(props),
    do: is_map_key(props, "fit_height") or is_map_key(props, "single_height")

  # A ratio the element keeps (as `Frontend.normalize/2` reads it).
  defp aspect_ratio?(props) do
    props["use_aspect_ratio"] == true and positive?(props["aspect_ratio_width"]) and
      positive?(props["aspect_ratio_height"])
  end

  defp positive?(value), do: is_number(value) and value > 0

  defp no_children?(raw) do
    case raw["elements"] do
      elements when is_map(elements) -> map_size(elements) == 0
      _ -> true
    end
  end

  # A visible background or border, set on the element or by its style.
  defp painted?(raw, styles) do
    style =
      case styles[raw["style"]] do
        style when is_map(style) -> Payload.properties(style)
        _ -> %{}
      end

    props = Map.merge(style, Payload.properties(raw))
    background?(props) or border?(props)
  end

  defp background?(props) do
    case props["background_style"] do
      nil -> is_binary(props["bgcolor"])
      style -> style != "none"
    end
  end

  defp border?(props) do
    sides =
      if props["four_border_style"] == false,
        do: [],
        else: Enum.map(~w(top right bottom left), &props["border_style_#{&1}"])

    Enum.any?([props["border_style"] | sides], &(is_binary(&1) and &1 != "none"))
  end

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

  defp put_width_flags(props) do
    props |> Map.put_new("fit_width", false) |> Map.put_new("single_width", false)
  end

  # An image that keeps its aspect ratio takes its height from its width,
  # like the fit-height aspect image Bubble serves. This overrides a
  # written `fit_height: false`: with fit off and fixed off the image
  # would fill its parent's height, and a filled height overrides the
  # aspect ratio (`align-self: stretch` or `flex-grow` in CSS). The replay
  # measured such images at their width's height.
  defp put_aspect_fit_height(props) do
    if props["single_height"] == true, do: props, else: Map.put(props, "fit_height", true)
  end

  defp px(value) when is_integer(value), do: "#{value}px"

  defp px(value) when is_float(value) do
    if value == Float.round(value), do: "#{trunc(value)}px", else: "#{value}px"
  end
end
