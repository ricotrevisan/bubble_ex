defmodule BubbleEx.Frontend.Naming do
  @moduledoc false

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

  def slug(_), do: ""

  @spec exporter_id(map() | struct(), atom() | String.t(), [String.t()]) :: String.t()
  def exporter_id(identity, kind, path) do
    bubble_id = identity_field(identity, :bubble_id)
    app_version = identity_field(identity, :app_version)
    kind_name = kind |> to_string() |> String.replace_prefix("Elixir.", "")

    Enum.join([bubble_id, app_version, kind_name, Enum.join(path, "/")], "/")
  end

  @spec expanded_id(String.t(), map() | struct()) :: String.t()
  def expanded_id(prefix, node) when is_binary(prefix) do
    suffix =
      node
      |> source_path()
      |> relative_definition_path()
      |> case do
        [] -> [node_field(node, :map_key)]
        path -> path
      end
      |> Enum.reject(&(&1 in [nil, "", "elements"]))
      |> Enum.join("/")

    if suffix == "", do: prefix, else: prefix <> "/" <> suffix
  end

  defp source_path(node) do
    case node_field(node, :source) do
      source when is_map(source) -> node_field(source, :path) || []
      _ -> []
    end
  end

  defp relative_definition_path(path) when is_list(path) do
    case Enum.find_index(path, &(&1 == "element_definitions")) do
      index when is_integer(index) -> Enum.drop(path, index + 2)
      _ -> []
    end
  end

  defp relative_definition_path(_path), do: []

  defp node_field(%{__struct__: _} = struct, key), do: Map.get(struct, key)

  defp node_field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp node_field(_node, _key), do: nil

  @spec page_dirname(String.t() | nil, String.t(), MapSet.t()) :: {String.t(), MapSet.t()}
  def page_dirname(name, map_key, taken) do
    base =
      case slug(name) do
        "" -> slug(map_key)
        s -> s
      end

    base = if base == "", do: "page", else: base

    if MapSet.member?(taken, base) do
      unique = base <> "--" <> slug_or_key(map_key)
      {unique, MapSet.put(taken, unique)}
    else
      {base, MapSet.put(taken, base)}
    end
  end

  @spec reusable_dirname(String.t() | nil, String.t()) :: String.t()
  def reusable_dirname(name, map_key) do
    key = slug_or_key(map_key)

    case slug(name) do
      "" -> key
      s -> s <> "--" <> key
    end
  end

  @spec style_class(String.t() | nil, String.t(), MapSet.t()) :: {String.t(), MapSet.t()}
  def style_class(display, map_key, taken) do
    base =
      case slug(display) do
        "" -> slug_or_key(map_key)
        s -> s
      end

    class = "s-" <> base

    if MapSet.member?(taken, class) do
      unique = class <> "--" <> slug_or_key(map_key)
      {unique, MapSet.put(taken, unique)}
    else
      {class, MapSet.put(taken, class)}
    end
  end

  defp slug_or_key(map_key) do
    case slug(map_key) do
      "" -> "item"
      s -> s
    end
  end

  defp identity_field(%{bubble_id: id}, :bubble_id), do: id
  defp identity_field(%{app_version: v}, :app_version), do: v

  defp identity_field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))
end
