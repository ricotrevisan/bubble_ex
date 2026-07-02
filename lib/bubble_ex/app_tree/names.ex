defmodule BubbleEx.AppTree.Names do
  @moduledoc """
  Slugging and name resolution for AppTree output paths.

  Ids are the stable identity in a Bubble export; human names are decoration.
  File and directory names combine both as `<slug>--<id>` so paths are
  readable AND unambiguous. Pages are the one exception (slug only): page
  names are unique URL paths in Bubble.
  """

  @doc "Lowercase, accent-folded, emoji-stripped slug. Empty string when nothing survives."
  @spec slug(String.t() | nil) :: String.t()
  def slug(nil), do: ""

  def slug(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  @doc "`<slug>--<id>`, or the bare id when the slug is empty."
  @spec entry_name(String.t() | nil, String.t()) :: String.t()
  def entry_name(name, id) do
    case slug(name) do
      "" -> id
      s -> s <> "--" <> id
    end
  end

  @doc "Best display name for an element node: original_name || name || default_name."
  @spec element_name(term()) :: String.t() | nil
  def element_name(%{"properties" => %{"original_name" => n}}) when is_binary(n) and n != "",
    do: n

  def element_name(%{"name" => n}) when is_binary(n) and n != "", do: n
  def element_name(%{"default_name" => n}) when is_binary(n) and n != "", do: n
  def element_name(_), do: nil

  @doc "Map of element id => display name across all pages and element_definitions."
  @spec element_names(map()) :: %{optional(String.t()) => String.t()}
  def element_names(app) when is_map(app) do
    roots = values_if_map(app["pages"]) ++ values_if_map(app["element_definitions"])

    roots
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, &collect_names/2)
  end

  # A claimed top-level section (pages / element_definitions) may be a
  # non-map value in a hostile export; treat that the same as absent.
  defp values_if_map(m) when is_map(m), do: Map.values(m)
  defp values_if_map(_), do: []

  defp collect_names(node, acc) do
    acc =
      case {node["id"], element_name(node)} do
        {id, name} when is_binary(id) and is_binary(name) -> Map.put(acc, id, name)
        _ -> acc
      end

    values_if_map(node["elements"])
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(acc, &collect_names/2)
  end

  @doc """
  File base name (no extension) for a workflow: the event name, the backend
  wf_name, or `<event type> <target element name>` — always suffixed `--<key>`
  via entry_name/2 (bare key when nothing is nameable).
  """
  @spec workflow_file_name(String.t(), map(), map()) :: String.t()
  def workflow_file_name(key, wf, element_names) do
    props = wf["properties"] || %{}

    name =
      props["event_name"] || props["wf_name"] ||
        compose_trigger_name(wf["type"], props["element_id"], element_names)

    entry_name(name, key)
  end

  defp compose_trigger_name(nil, _element_id, _names), do: nil

  defp compose_trigger_name(type, element_id, names) do
    target = if element_id, do: names[element_id]
    # "ButtonClicked" -> "Button Clicked" so slug/1 yields button-clicked
    spaced = String.replace(type, ~r/(?<=[a-z])(?=[A-Z])/, " ")
    String.trim("#{spaced} #{target}")
  end
end
