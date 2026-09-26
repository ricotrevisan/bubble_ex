defmodule BubbleEx.Test.SplitExport do
  @moduledoc false

  # Test-only loader for private acceptance runs. Reassembles a split export
  # directory (one JSON file per data type, option set, page, element,
  # workflow, action and API Connector call) into one readable-key app map in
  # the `.bubble` shape:
  #
  #     app.json                                  -> top-level members
  #     data_types/<id>/type.json                 -> user_types
  #     option_sets/<id>/option-set.json          -> option_sets
  #     pages/<key>/page.json                     -> pages (+ elements/, workflows/)
  #     element-definitions/<key>/reusable.json   -> element_definitions
  #     mobile-views/<key>/mobile-view.json       -> mobile_views
  #     api/<key>/workflow.json                   -> api
  #     settings/client-safe.json                 -> settings.client_safe
  #     settings/api-connector/<g>/plugin.json    -> settings.client_safe.apiconnector2
  #     styles/<element type>/<key>.json          -> styles (keyed by the style's `id`)
  #
  # Workflow folders (`<folder>/config.json` plus workflow subdirectories) are
  # flattened; each workflow in one gets the folder's directory name (its
  # Bubble folder ID) back as `properties.wf_folder`, where the `.bubble`
  # export keeps it. Layout helper members (`children`, `bp_layout`, `__bp_*`
  # files) are dropped. A path that is a file is decoded as a `.bubble` JSON
  # export.

  @spec load(String.t()) :: map()
  def load(path) do
    if File.dir?(path), do: assemble(path), else: decode(path)
  end

  defp assemble(root) do
    base = optional(Path.join(root, "app.json")) || %{}

    base
    |> Map.put("user_types", singles(root, "data_types", "type.json"))
    |> Map.put("option_sets", singles(root, "option_sets", "option-set.json"))
    |> Map.put("pages", owners(root, "pages", "page.json"))
    |> Map.put("element_definitions", owners(root, "element-definitions", "reusable.json"))
    |> Map.put("mobile_views", owners(root, "mobile-views", "mobile-view.json"))
    |> Map.put("api", workflows(Path.join(root, "api")))
    |> Map.put("settings", settings(root))
    |> put_nonempty("styles", styles(Path.join(root, "styles")))
  end

  defp styles(dir) do
    for sub <- subdirs(dir),
        file <- dir |> Path.join(sub) |> Path.join("*.json") |> Path.wildcard() |> Enum.sort(),
        doc = decode(file),
        into: %{},
        do: {doc["id"] || Path.basename(file, ".json"), doc}
  end

  defp singles(root, dir, file) do
    for sub <- subdirs(Path.join(root, dir)),
        doc = optional(Path.join([root, dir, sub, file])),
        into: %{},
        do: {sub, doc}
  end

  defp owners(root, dir, file) do
    for sub <- subdirs(Path.join(root, dir)),
        doc = optional(Path.join([root, dir, sub, file])),
        into: %{} do
      owner_dir = Path.join([root, dir, sub])

      node =
        doc
        |> clean()
        |> put_nonempty("elements", elements(Path.join(owner_dir, "elements")))
        |> put_nonempty("workflows", workflows(Path.join(owner_dir, "workflows")))

      {sub, node}
    end
  end

  defp elements(dir) do
    for sub <- subdirs(dir), doc = optional(Path.join([dir, sub, "element.json"])), into: %{} do
      {sub, doc |> clean() |> put_nonempty("elements", elements(Path.join(dir, sub)))}
    end
  end

  defp workflows(dir, folder \\ nil) do
    Enum.reduce(subdirs(dir), %{}, fn sub, acc ->
      wf_dir = Path.join(dir, sub)

      case optional(Path.join(wf_dir, "workflow.json")) do
        nil -> Map.merge(acc, workflows(wf_dir, folder_of(wf_dir, sub, folder)))
        doc -> Map.put(acc, sub, workflow(doc, wf_dir, folder))
      end
    end)
  end

  # A directory with a `config.json` is a folder; its name is the folder ID.
  defp folder_of(dir, sub, folder),
    do: if(File.regular?(Path.join(dir, "config.json")), do: sub, else: folder)

  defp workflow(doc, dir, folder),
    do: doc |> clean() |> Map.put("actions", actions(dir)) |> in_folder(folder)

  defp in_folder(doc, nil), do: doc

  defp in_folder(doc, folder),
    do: Map.update(doc, "properties", %{"wf_folder" => folder}, &Map.put(&1, "wf_folder", folder))

  defp actions(wf_dir) do
    wf_dir
    |> Path.join("actions/*.json")
    |> Path.wildcard()
    |> Map.new(&{Path.basename(&1, ".json"), decode(&1)})
  end

  defp settings(root) do
    client_safe = optional(Path.join(root, "settings/client-safe.json")) || %{}
    connector_dir = Path.join(root, "settings/api-connector")

    groups =
      for group <- subdirs(connector_dir),
          plugin = optional(Path.join([connector_dir, group, "plugin.json"])),
          into: %{} do
        calls =
          Path.join([connector_dir, group, "calls/*.json"])
          |> Path.wildcard()
          |> Map.new(&{Path.basename(&1, ".json"), decode(&1)})

        {group, Map.put(plugin, "calls", calls)}
      end

    %{"client_safe" => put_nonempty(client_safe, "apiconnector2", groups)}
  end

  defp clean(doc), do: Map.drop(doc, ["children", "bp_layout"])

  defp put_nonempty(map, _key, value) when value == %{}, do: map
  defp put_nonempty(map, key, value), do: Map.put(map, key, value)

  defp subdirs(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names |> Enum.filter(&File.dir?(Path.join(dir, &1))) |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp optional(file), do: if(File.regular?(file), do: decode(file))
  defp decode(file), do: file |> File.read!() |> Jason.decode!()
end
