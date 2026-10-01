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
      flag or a min height: 41 rendered shorter than their canvas height
      (36 sized to their content, with a computed min height of `0px` or
      `auto`), 7 taller (stretched or aligned to their parent), 1 alike.
      The sample was nearly all Row children; Column children follow the
      same rules, untested.
    * **Images that keep their aspect ratio** (`use_aspect_ratio`, not
      fixed height; WTF-458). Their height follows their width
      (`fit_height`, as Bubble serves a fit-height aspect image): no
      height, min or max height, and no fill, so the `aspect-ratio` sets
      their height from their width.
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
    raw = if flow?(raw), do: update_props(raw, &container_props(&1, kind)), else: raw
    update_children(raw, parent(raw))
  end

  defp container(_key, raw, _kind), do: raw

  # How a container lays out its children: nil (Fixed or no layout: the
  # canvas box stands) or :flow.
  defp parent(raw), do: if(flow?(raw), do: :flow)

  defp update_children(raw, parent) do
    case raw["elements"] do
      elements when is_map(elements) ->
        Map.put(
          raw,
          "elements",
          Map.new(elements, fn {k, child} -> {k, element(child, parent)} end)
        )

      _ ->
        raw
    end
  end

  defp element(raw, parent) when is_map(raw) do
    raw =
      if parent,
        do: update_props(raw, &element_props(&1, Payload.type(raw))),
        else: raw

    update_children(raw, parent(raw))
  end

  defp element(raw, _parent), do: raw

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
    cond do
      Payload.plugin_type?(type) ->
        compact(props, ["left", "top"])

      type == "Image" ->
        props |> compact() |> put_width_flags() |> put_aspect_fit_height()

      true ->
        props |> compact() |> put_width_flags()
    end
  end

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
  # like the fit-height aspect image Bubble serves.
  defp put_aspect_fit_height(props) do
    if props["use_aspect_ratio"] == true and props["single_height"] != true,
      do: Map.put(props, "fit_height", true),
      else: props
  end
end
