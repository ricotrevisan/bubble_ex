defmodule BubbleEx.Workflows.Source do
  @moduledoc false

  @collections ~w(workflows %wf)
  @owners ~w(pages %p3 element_definitions %ed mobile_views)

  @spec collections(map()) :: [map()]
  def collections(payload) do
    found = discover(payload, [])
    missing = missing_sections(payload) ++ missing_owners(payload)
    Enum.sort_by(found ++ missing, & &1.path)
  end

  defp discover(value, path) when is_map(value) do
    own =
      if candidate?(value, path),
        do: [%{path: path, value: value, present: true, single: true}],
        else: []

    own ++
      Enum.flat_map(value, fn {key, child} ->
        child_path = path ++ [key]

        if key in @collections or (path == [] and key == "api") do
          [%{path: child_path, value: child, present: true} | discover(child, child_path)]
        else
          discover(child, child_path)
        end
      end)
  end

  defp discover(value, path) when is_list(value) do
    value |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> discover(v, path ++ [i]) end)
  end

  defp discover(_, _), do: []

  # Retain action-bearing definitions in unfamiliar layouts as unclassified
  # candidates. Do not guess that a data/property object is a workflow.
  defp candidate?(value, path) do
    parent = path |> Enum.take(-2) |> List.first()

    Map.has_key?(value, "actions") and (Map.has_key?(value, "type") or Map.has_key?(value, "%x")) and
      parent not in (@collections ++ ["api"]) and
      not Enum.any?(path, &(&1 in ~w(properties %p actions)))
  end

  defp missing_sections(payload) do
    [~w(pages %p3), ~w(element_definitions %ed), ["mobile_views"], ["api"]]
    |> Enum.flat_map(fn keys ->
      if Enum.any?(keys, &Map.has_key?(payload, &1)),
        do: [],
        else: [%{path: [hd(keys)], value: nil, present: false}]
    end)
  end

  defp missing_owners(payload) do
    Enum.flat_map(@owners, &owner_scopes(Map.fetch(payload, &1), &1))
  end

  defp owner_scopes({:ok, owners}, section) when is_map(owners) do
    Enum.flat_map(entries(owners), fn {key, owner} -> missing_owner(owner, section, key) end)
  end

  defp owner_scopes({:ok, other}, section),
    do: [%{path: [section], value: other, present: false, malformed: true}]

  defp owner_scopes(:error, _), do: []

  defp missing_owner(owner, section, key) do
    if is_map(owner) and Enum.any?(@collections, &Map.has_key?(owner, &1)) do
      []
    else
      [
        %{
          path: if(is_map(owner), do: [section, key, "workflows"], else: [section, key]),
          value: owner,
          present: false,
          malformed: not is_map(owner)
        }
      ]
    end
  end

  @spec entries(term()) :: [{String.t() | non_neg_integer(), term()}]
  def entries(value) when is_map(value) do
    value |> Enum.reject(&metadata_entry?/1) |> Enum.sort_by(&elem(&1, 0))
  end

  def entries(value) when is_list(value),
    do: value |> Enum.with_index() |> Enum.map(fn {v, i} -> {i, v} end)

  def entries(_), do: []

  @spec metadata(term(), list()) :: [map()]
  def metadata(value, path) when is_map(value) do
    for {key, raw} <- value,
        metadata_entry?({key, raw}),
        do: %{path: pointer(path ++ [key]), raw: raw, kind: "collection_metadata"}
  end

  def metadata(_, _), do: []

  @spec owner_metadata(map()) :: [map()]
  def owner_metadata(payload) do
    Enum.flat_map(@owners, &metadata(Map.get(payload, &1), [&1]))
  end

  # Bubble's JSON object collections can carry an array-like length member.
  # Preserve it separately; it is neither a workflow nor an action definition.
  defp metadata_entry?({"length", n}) when is_integer(n) and n >= 0, do: true
  defp metadata_entry?(_), do: false

  @spec pointer(list()) :: String.t()
  def pointer(path), do: Enum.map_join(path, "", &("/" <> escape(to_string(&1))))
  defp escape(key), do: key |> String.replace("~", "~0") |> String.replace("/", "~1")

  @spec get(term(), [String.t()]) :: {String.t(), term()} | nil
  def get(value, keys) when is_map(value) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(value, key), do: {key, Map.fetch!(value, key)}
    end)
  end

  def get(_, _), do: nil

  @spec value(term(), [String.t()]) :: term()
  def value(value, keys) do
    case get(value, keys) do
      {_, v} -> v
      nil -> nil
    end
  end

  @spec diagnostic(String.t(), list(), String.t()) :: map()
  def diagnostic(code, path, message), do: %{code: code, path: pointer(path), message: message}
end
