defmodule BubbleEx.AppTree.Splitter do
  @moduledoc """
  Layer 1: the lossless mechanical split of a decoded `.bubble.json` export.

  `split/2` never interprets content — it only relocates it. `reassemble/2`
  is the inverse and is driven by the manifest (page/component map keys are
  not recoverable from file contents: real exports have map key ≠ inner
  `"id"`). The round-trip `reassemble(split(app)) == app` (deep equality at
  the decoded-data level) is this module's contract.

  `manifest["ids"]` keys are `"<kind>:<raw_key>"` (not the bare raw key):
  different kinds can legitimately share a raw Bubble key (e.g. a user_type
  and an option_set both keyed `"status"`), and a shared raw key would
  otherwise silently overwrite one entry with the other. Every id entry also
  carries `"key" => raw_key` so callers can recover the map key they need.
  """

  alias BubbleEx.AppTree.Names

  @spec split(map(), map()) :: {:ok, %{entries: list(), manifest: map()}}
  def split(app, source) when is_map(app) and is_map(source) do
    element_names = Names.element_names(app)

    acc = %{entries: [], ids: %{}}

    acc =
      acc
      |> claim_section(app, "pages", fn acc, v ->
        split_containers(acc, v, "pages", "page", element_names)
      end)
      |> claim_section(app, "element_definitions", fn acc, v ->
        split_containers(acc, v, "components", "component", element_names)
      end)
      |> claim_section(app, "api", fn acc, v -> split_api(acc, v, element_names) end)
      |> claim_section(app, "user_types", fn acc, v ->
        split_keyed(acc, v, "data/types", "user_type")
      end)
      |> claim_section(app, "option_sets", fn acc, v ->
        split_keyed(acc, v, "data/option-sets", "option_set")
      end)
      |> split_whole(app, "styles", "styles/styles.json")
      |> split_whole(app, "settings", "settings/settings.json")
      |> split_meta(app)

    entries = Enum.reverse(acc.entries)
    assert_unique_paths!(entries)

    manifest = %{
      "version" => 1,
      "source" => source,
      "ids" => acc.ids,
      "sections" => present_sections(app)
    }

    {:ok, %{entries: entries, manifest: manifest}}
  end

  @claimed_keys ~w(pages element_definitions api user_types option_sets styles settings)
  @container_sections ~w(pages element_definitions api user_types option_sets)

  # A claimed section may be absent, a map (normal case), or present-but-not-a-map
  # (a hostile export). Non-map values are preserved verbatim under meta/ instead
  # of being interpreted, so nothing is dropped and nothing crashes.
  defp claim_section(acc, app, key, fun) do
    case Map.fetch(app, key) do
      :error -> acc
      {:ok, value} when is_map(value) -> fun.(acc, value)
      {:ok, value} -> add_entry(acc, "meta/#{key}.json", value)
    end
  end

  defp split_containers(acc, containers, root, "page", element_names) do
    dir_names = page_dir_names(containers)

    Enum.reduce(containers, acc, fn {key, value}, acc ->
      split_container(acc, key, value, root, "page", element_names, dir_names[key])
    end)
  end

  defp split_containers(acc, containers, root, "component", element_names) do
    Enum.reduce(containers, acc, fn {key, value}, acc ->
      split_container(acc, key, value, root, "component", element_names, nil)
    end)
  end

  # Deterministic page directory names, computed over the full page set before
  # any entry is emitted. A page uses its bare slug unless that slug is empty
  # (nil/emoji-only name) or collides with another page's slug, in which case
  # it falls back to `<slug>--<key>` (or the bare key).
  defp page_dir_names(containers) do
    named =
      containers
      |> Enum.filter(fn {_, v} -> is_map(v) end)
      |> Enum.map(fn {key, v} -> {key, v["name"], Names.slug(v["name"])} end)

    slug_counts = named |> Enum.map(fn {_, _, slug} -> slug end) |> Enum.frequencies()

    Map.new(named, fn {key, name, slug} ->
      dir_name =
        if slug == "" or slug_counts[slug] > 1, do: Names.entry_name(name, key), else: slug

      {key, dir_name}
    end)
  end

  # Malformed entry (real exports contain them): preserve as a raw file.
  defp split_container(acc, key, value, root, kind, _names, _dir_name) when not is_map(value) do
    path = "#{root}/#{key}.json"

    acc
    |> add_entry(path, value)
    |> add_id(key, %{"kind" => kind <> "_raw", "name" => nil, "path" => path})
  end

  defp split_container(acc, key, container, root, kind, element_names, dir_name) do
    dir =
      case kind do
        "page" -> "#{root}/#{dir_name}"
        "component" -> "#{root}/#{Names.entry_name(container["name"], key)}"
      end

    file = if kind == "page", do: "page.json", else: "component.json"
    workflows = container["workflows"]

    {rest, workflows_present} =
      if is_map(workflows) do
        {Map.delete(container, "workflows"), true}
      else
        {container, false}
      end

    path = "#{dir}/#{file}"

    acc =
      acc
      |> add_entry(path, rest)
      |> add_id(key, %{
        "kind" => kind,
        "name" => container["name"],
        "path" => path,
        "workflows_present" => workflows_present
      })

    Enum.reduce(if(workflows_present, do: workflows, else: %{}), acc, fn {wf_key, wf}, acc ->
      add_workflow(acc, dir, key, wf_key, wf, element_names)
    end)
  end

  # Malformed workflow entry (real exports contain them): preserve as a raw file.
  defp add_workflow(acc, dir, parent_key, wf_key, wf, _element_names) when not is_map(wf) do
    path = "#{dir}/workflows/#{wf_key}.json"

    acc
    |> add_entry(path, wf)
    |> add_id(wf_key, %{
      "kind" => "workflow_raw",
      "name" => nil,
      "path" => path,
      "parent" => parent_key
    })
  end

  defp add_workflow(acc, dir, parent_key, wf_key, wf, element_names) do
    path = "#{dir}/workflows/#{Names.workflow_file_name(wf_key, wf, element_names)}.json"

    acc
    |> add_entry(path, wf)
    |> add_id(wf_key, %{
      "kind" => "workflow",
      "name" => wf_name(wf),
      "path" => path,
      "parent" => parent_key
    })
  end

  # Malformed api entry (real exports contain them): preserve as a raw file.
  defp split_api(acc, api, element_names) do
    Enum.reduce(api, acc, fn
      {key, wf}, acc when not is_map(wf) ->
        path = "api/#{key}.json"

        acc
        |> add_entry(path, wf)
        |> add_id(key, %{"kind" => "api_workflow_raw", "name" => nil, "path" => path})

      {key, wf}, acc ->
        path = "api/#{Names.workflow_file_name(key, wf, element_names)}.json"

        acc
        |> add_entry(path, wf)
        |> add_id(key, %{"kind" => "api_workflow", "name" => wf_name(wf), "path" => path})
    end)
  end

  defp split_keyed(acc, items, root, kind) do
    Enum.reduce(items, acc, fn {key, value}, acc ->
      name = if is_map(value), do: value["display"], else: nil
      result_kind = if is_map(value), do: kind, else: kind <> "_raw"
      path = "#{root}/#{Names.entry_name(name, key)}.json"

      acc
      |> add_entry(path, value)
      |> add_id(key, %{"kind" => result_kind, "name" => name, "path" => path})
    end)
  end

  defp split_whole(acc, app, key, path) do
    case Map.fetch(app, key) do
      {:ok, value} -> add_entry(acc, path, value)
      :error -> acc
    end
  end

  defp split_meta(acc, app) do
    app
    |> Map.drop(@claimed_keys)
    |> Enum.reduce(acc, fn {key, value}, acc -> add_entry(acc, "meta/#{key}.json", value) end)
  end

  defp wf_name(%{"properties" => props}) when is_map(props),
    do: props["event_name"] || props["wf_name"]

  defp wf_name(_), do: nil

  defp add_entry(acc, path, value), do: %{acc | entries: [{path, {:json, value}} | acc.entries]}

  defp add_id(acc, key, info) do
    composite = "#{info["kind"]}:#{key}"
    %{acc | ids: Map.put(acc.ids, composite, Map.put(info, "key", key))}
  end

  defp present_sections(app) do
    Enum.filter(@container_sections, fn key ->
      case Map.fetch(app, key) do
        {:ok, value} -> is_map(value)
        :error -> false
      end
    end)
  end

  # Internal invariant: split/2 must never emit two entries at the same path.
  # A violation here means a naming rule upstream has a gap — surfaced as an
  # ArgumentError so it fails loudly during development; AppTree.generate/3's
  # rescue boundary turns it into an {:error, %BubbleEx.Error{}} at the public
  # surface.
  defp assert_unique_paths!(entries) do
    paths = Enum.map(entries, &elem(&1, 0))
    duplicates = paths -- Enum.uniq(paths)

    if duplicates != [] do
      raise ArgumentError,
            "BubbleEx.AppTree.Splitter: duplicate output paths: #{inspect(Enum.uniq(duplicates))}"
    end
  end

  @spec reassemble(list(), map()) :: {:ok, map()}
  def reassemble(entries, %{"ids" => ids} = manifest) do
    contents = Map.new(entries, fn {path, {:json, value}} -> {path, value} end)
    workflows_by_parent = group_workflows_by_parent(ids)

    app =
      ids
      |> put_ids(workflows_by_parent, contents)
      |> fold_meta(contents)
      |> ensure_sections(manifest["sections"])

    {:ok, app}
  end

  defp group_workflows_by_parent(ids) do
    ids
    |> Enum.filter(fn {_, info} -> info["kind"] in ["workflow", "workflow_raw"] end)
    |> Enum.group_by(fn {_, info} -> info["parent"] end)
  end

  defp put_ids(ids, workflows_by_parent, contents) do
    Enum.reduce(ids, %{}, fn
      {_composite, %{"kind" => kind}}, app when kind in ["workflow", "workflow_raw"] ->
        # workflow entries are folded in by put_container
        app

      {_composite, info}, app ->
        value = Map.fetch!(contents, info["path"])
        put_id(app, info["key"], value, info, workflows_by_parent, contents)
    end)
  end

  # Sections whose ids fold back in as a plain `put_in_section` (no nested
  # workflows to re-attach). "kind" and "kind_raw" both restore into the same
  # section — the "_raw" suffix only affected how the entry was named on disk.
  @section_by_kind %{
    "page_raw" => "pages",
    "component_raw" => "element_definitions",
    "api_workflow" => "api",
    "api_workflow_raw" => "api",
    "user_type" => "user_types",
    "user_type_raw" => "user_types",
    "option_set" => "option_sets",
    "option_set_raw" => "option_sets"
  }

  defp put_id(app, key, value, info, workflows_by_parent, contents) do
    case info["kind"] do
      "page" ->
        put_container(app, "pages", key, value, info, workflows_by_parent, contents)

      "component" ->
        put_container(
          app,
          "element_definitions",
          key,
          value,
          info,
          workflows_by_parent,
          contents
        )

      kind ->
        put_in_section(app, Map.fetch!(@section_by_kind, kind), key, value)
    end
  end

  defp fold_meta(app, contents) do
    Enum.reduce(contents, app, fn {path, value}, app ->
      case path do
        "styles/styles.json" -> Map.put(app, "styles", value)
        "settings/settings.json" -> Map.put(app, "settings", value)
        "meta/" <> file -> Map.put(app, String.replace_suffix(file, ".json", ""), value)
        _ -> app
      end
    end)
  end

  defp ensure_sections(app, sections) do
    Enum.reduce(sections || [], app, fn section, acc -> Map.put_new(acc, section, %{}) end)
  end

  defp put_container(app, section, key, value, info, workflows_by_parent, contents) do
    value =
      if info["workflows_present"] do
        workflows =
          workflows_by_parent
          |> Map.get(key, [])
          |> Map.new(fn {_wf_composite, wf_info} ->
            {wf_info["key"], Map.fetch!(contents, wf_info["path"])}
          end)

        Map.put(value, "workflows", workflows)
      else
        value
      end

    put_in_section(app, section, key, value)
  end

  defp put_in_section(app, section, key, value) do
    Map.update(app, section, %{key => value}, &Map.put(&1, key, value))
  end
end
