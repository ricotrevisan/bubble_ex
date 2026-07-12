defmodule BubbleEx.AppTree do
  @moduledoc """
  Turns a `.bubble.json` export into a two-layer, agent-readable source tree.

  Layer 1 is a lossless mechanical split (see `BubbleEx.AppTree.Splitter` —
  round-trip guaranteed). Layer 2 is regenerated readable views (`OUTLINE.md`,
  `WORKFLOWS.md`, `API.md`, `STYLES.md`, `SETTINGS.md`, `data/schema.dbml`,
  plus root `README.md` / `AGENTS.md` / `MANIFEST.json`).

      {:ok, report} = BubbleEx.AppTree.generate("app.bubble.json", "out/")
  """

  alias BubbleEx.AppTree.{Coverage, Names, Splitter, Writer}
  alias BubbleEx.AppTree.Render
  alias BubbleEx.Error

  @spec generate(String.t(), String.t(), keyword()) ::
          {:ok, %{out_dir: String.t(), files: non_neg_integer(), coverage: Coverage.t()}}
          | {:error, Error.t()}
  def generate(json_path, out_dir, opts \\ []) do
    with {:ok, raw} <- read_file(json_path),
         {:ok, app} <- decode(raw, json_path),
         :ok <- Writer.precheck(out_dir, opts) do
      build_and_write(app, raw, json_path, out_dir, opts)
    end
  end

  # Everything past this point works on already-decoded, but not otherwise
  # validated, app data — a hostile/malformed export can still make any of
  # Layer 1 or Layer 2 raise despite their individual defensive guards. This
  # boundary keeps generate/3's public contract ({:ok, _} | {:error, %BubbleEx.Error{}})
  # true for any input. Processing (split/render) is protected by this function's
  # rescue; writing (Writer.write) is called after and handles its own errors
  # separately (disk failures return :invalid_input, not :parse_failed).
  defp build_and_write(app, raw, json_path, out_dir, opts) do
    source = %{
      "file" => Path.basename(json_path),
      "sha256" => Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
    }

    {:ok, %{entries: layer1, manifest: manifest}} = Splitter.split(app, source)
    {views, coverage, schema?} = render_views(app, manifest)
    root = Render.Readme.render(app, manifest, coverage, schema: schema?)

    entries = layer1 ++ views ++ root
    do_write(out_dir, entries, coverage, opts)
  rescue
    e ->
      {:error,
       Error.new(:parse_failed, "export contains shapes AppTree cannot process", %{
         error: Exception.message(e)
       })}
  end

  # Write is called outside the processing rescue so disk errors return
  # :invalid_input instead of being mislabeled as :parse_failed.
  defp do_write(out_dir, entries, coverage, opts) do
    case Writer.write(out_dir, entries, opts) do
      {:ok, files} -> {:ok, %{out_dir: out_dir, files: files, coverage: coverage}}
      {:error, _} = error -> error
    end
  rescue
    e ->
      {:error,
       Error.new(:invalid_input, "failed writing output", %{
         error: Exception.message(e),
         out_dir: out_dir
       })}
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, raw} ->
        {:ok, raw}

      {:error, reason} ->
        {:error, Error.new(:not_found, "cannot read #{path}", %{reason: reason})}
    end
  end

  defp decode(raw, path) do
    case Jason.decode(raw) do
      {:ok, app} when is_map(app) -> {:ok, app}
      {:ok, _} -> {:error, Error.new(:parse_failed, "export is not a JSON object", %{path: path})}
      {:error, _} -> {:error, Error.new(:parse_failed, "invalid JSON", %{path: path})}
    end
  end

  defp render_views(app, manifest) do
    element_names = Names.element_names(app)
    files_by_parent = workflow_files_by_parent(manifest)

    {container_views, coverage} =
      manifest["ids"]
      |> Enum.filter(fn {_, info} -> info["kind"] in ["page", "component"] end)
      |> Enum.reduce({[], Coverage.zero()}, fn {_composite, info}, {views, cov} ->
        key = info["key"]
        dir = Path.dirname(info["path"])
        container = container_for(app, info["kind"], key)
        title = info["name"] || key

        {outline, outline_cov} =
          Render.Outline.render(container, %{title: title, raw: Path.basename(info["path"])})

        ctx = %{
          title: title,
          element_names: element_names,
          files: Map.get(files_by_parent, key, %{})
        }

        {workflows_md, wf_cov} = Render.Workflows.render(container["workflows"], ctx)

        views =
          views ++
            [
              {Path.join(dir, "OUTLINE.md"), {:text, outline}},
              {Path.join(dir, "WORKFLOWS.md"), {:text, workflows_md}}
            ]

        {views, cov |> Coverage.merge(outline_cov) |> Coverage.merge(wf_cov)}
      end)

    api_ctx = %{
      title: "Backend workflows",
      element_names: element_names,
      files: api_files(manifest)
    }

    {api_md, api_cov} = Render.Workflows.render_api(app["api"], api_ctx)
    coverage = Coverage.merge(coverage, api_cov)
    schema_entries = schema_view(app)

    views =
      container_views ++
        [
          {"api/API.md", {:text, api_md}},
          {"styles/STYLES.md", {:text, Render.Styles.render(app["styles"])}},
          {"settings/SETTINGS.md", {:text, Render.Settings.render(app["settings"])}}
        ] ++ schema_entries

    {views, coverage, schema_entries != []}
  end

  defp container_for(app, "page", key), do: app["pages"][key]
  defp container_for(app, "component", key), do: app["element_definitions"][key]

  # Workflow renderer source-links are relative to the container dir for pages
  # and components, and to api/ for backend workflows.
  defp workflow_files_by_parent(manifest) do
    manifest["ids"]
    |> Enum.filter(fn {_, info} -> info["kind"] == "workflow" end)
    |> Enum.group_by(fn {_, info} -> info["parent"] end)
    |> Map.new(fn {parent, entries} ->
      parent_dir = Path.dirname(container_info!(manifest, parent)["path"])

      {parent,
       Map.new(entries, fn {_wf_composite, info} ->
         {info["key"], Path.relative_to(info["path"], parent_dir)}
       end)}
    end)
  end

  # A workflow's "parent" is a raw container key, unqualified by kind (it
  # could be a page or a component). Resolve it against the prefixed ids map.
  defp container_info!(manifest, parent) do
    manifest["ids"]["page:#{parent}"] || manifest["ids"]["component:#{parent}"]
  end

  defp api_files(manifest) do
    manifest["ids"]
    |> Enum.filter(fn {_, info} -> info["kind"] == "api_workflow" end)
    |> Map.new(fn {_composite, info} -> {info["key"], Path.basename(info["path"])} end)
  end

  # BubbleEx.Db.Reader.parse/1 raises (never returns an error tuple) on
  # hostile export shapes; treat any failure to build the schema view as
  # "no schema" rather than letting it take generate/3 down.
  defp schema_view(app) do
    {:ok, db_map} = BubbleEx.Db.Reader.parse(app)
    {:ok, dbml} = dbml(db_map)
    [{"data/schema.dbml", {:text, dbml}}]
  rescue
    _ -> []
  end

  defp dbml(db_map), do: BubbleEx.Db.Dbml.encode(db_map)
end
