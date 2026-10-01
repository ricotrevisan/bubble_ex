defmodule BubbleEx.Target.Phoenix.Manifest do
  @moduledoc """
  `.wtf/generated.json`: the manifest of a project rendered by
  `BubbleEx.Target.Phoenix` (WTF-359 Q1, WTF-352 D1).

      {
        "version": 1,
        "target": "phoenix",
        "app": "acme_import",
        "module": "AcmeImport",
        "inputs": {
          "bubble_ex_version": "0.3.0",
          "project_schema_version": 7,
          "project_sha256": "…",
          "decisions_sha256": null,
          "applied_sha256": null,
          "privacy": "omit",
          "frontend": {"bubble_id": "acme", "app_version": "live",
                       "normalized_schema_version": 3, "source_sha256": "…"}
        },
        "generated": {"lib/acme_import/invoice.ex": "<sha256>", …},
        "owned": {"mix.exs": "<sha256 as scaffolded>", …},
        "routes": {"router": "lib/acme_import_web/router.ex",
                   "call": "bubble_routes", "pages": ["bTGYf", …]},
        "extensions": {"repo": "lib/acme_import/repo.ex",
                       "call": "RepoExtensions", "needed": ["pg_trgm"]},
        "images": {"endpoint": "lib/acme_import_web/endpoint.ex",
                   "from": "priv/bubble_images",
                   "files": ["priv/bubble_images/<sha256>.png", …]}
      }

    * `inputs` - what the generated files are a function of:
      `project_sha256` is the SHA-256 of the canonical JSON of the
      `BubbleEx.Target.Ash.Project` (`Project.to_map/1`: resources, names,
      applied decisions, diagnostics…); `decisions_sha256` and
      `applied_sha256` are the Project's (nil without decisions);
      `frontend` identifies the normalized frontend the pages were
      rendered from (nil without one, WTF-370);
      `api_clients_sha256`, present when API clients were rendered, is the
      SHA-256 of the `BubbleEx.Target.ApiClients.Spec`'s canonical JSON;
      `phoenix_live_view`, present only when the render's LiveView was not
      the generator's pin (another patch release,
      `BubbleEx.Target.Phoenix.Formatter`), is the loaded version its
      HEEx was formatted with
    * `generated` - every generated file (path → SHA-256 of its content).
      Regeneration overwrites them; `check/2` finds hand edits. The
      manifest does not list itself
    * `owned` - every owned file (path → SHA-256 as scaffolded): written
      once, then the owner's; never overwritten, so their hashes are
      informational (did the owner change the scaffold?)
    * `extensions` - when the project needs PostgreSQL extensions (e.g.
      `pg_trgm`): the owned Repo, the call to the generated
      `RepoExtensions` it must make, and the extensions. `check/3` lists
      them as `extensions_unlisted` when the Repo lacks the call
      (scaffolded before WTF-406, or edited away): its migrations fail
    * `routes` - with Bubble pages (WTF-370): the owned router, the call to
      the generated routes it must make, and the pages (Bubble IDs) that
      call routes. `check/3` lists the pages as `unrouted` when the router
      lacks the call (scaffolded before WTF-370, or edited away)
    * `images` - with stored Bubble images (WTF-447): the owned endpoint,
      the directory its `/images/bubble` plug must serve them `from`, and
      the image files. `check/3` lists them as `images_unserved` when the
      endpoint does not name the directory (scaffolded before WTF-455,
      when the images lived under `priv/static/images/bubble`, or edited
      away): they are not served. It also lists, with or without images,
      any file left under `priv/static/images/bubble/`: the main static
      plug serves it there without the images' sandbox policy

  The JSON is canonical (sorted keys) and pretty-printed, so the same
  project gives the same bytes. It holds no secret: the plan content key
  (`.wtf/plan.key`, WTF-367) is never written here.
  """

  alias BubbleEx.{CanonicalJson, Error}
  alias BubbleEx.Target.ApiClients.Spec
  alias BubbleEx.Target.Ash.Project

  @path ".wtf/generated.json"
  @version 1

  @type t :: map()

  @type report :: %{
          clean?: boolean(),
          modified: [String.t()],
          missing: [String.t()],
          unchanged: [String.t()],
          stale: [String.t()],
          unrouted: [String.t()],
          extensions_unlisted: [String.t()],
          images_unserved: [String.t()]
        }

  # Where the Bubble page images are generated (and the owned endpoint's
  # `/images/bubble` plug serves them from), and where they were before
  # WTF-455: a file left there is served without their sandbox policy.
  @images_dir "priv/bubble_images"
  @legacy_images_dir "priv/static/images/bubble"

  @doc "The manifest's path in the project."
  @spec path() :: String.t()
  def path, do: @path

  @doc "The manifest format version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc false
  @spec build(Project.t(), map(), %{String.t() => binary()}, %{String.t() => binary()}) :: t()
  def build(%Project{} = project, ctx, generated, owned) do
    %{
      "version" => @version,
      "target" => "phoenix",
      "app" => ctx.app,
      "module" => ctx.module,
      "inputs" =>
        %{
          "bubble_ex_version" => ctx.bubble_ex_version,
          "project_schema_version" => project.schema_version,
          "project_sha256" => project |> Project.to_map() |> CanonicalJson.sha256(),
          "decisions_sha256" => project.decisions_sha256,
          "applied_sha256" => project.applied_sha256,
          "privacy" => Atom.to_string(project.privacy),
          "frontend" => Map.get(ctx, :frontend)
        }
        |> put_api_clients(Map.get(ctx, :api_clients))
        |> put_live_view(Map.get(ctx, :live_view)),
      "generated" => hashes(generated),
      "owned" => hashes(owned)
    }
    |> put_routes(ctx)
    |> put_extensions(project, ctx)
    |> put_images(ctx, generated)
  end

  defp put_images(manifest, ctx, generated) do
    case generated |> Map.keys() |> Enum.filter(&String.starts_with?(&1, @images_dir <> "/")) do
      [] ->
        manifest

      files ->
        Map.put(manifest, "images", %{
          "endpoint" => "lib/#{ctx.app}_web/endpoint.ex",
          "from" => @images_dir,
          "files" => Enum.sort(files)
        })
    end
  end

  defp put_live_view(inputs, nil), do: inputs
  defp put_live_view(inputs, loaded), do: Map.put(inputs, "phoenix_live_view", loaded)

  defp put_extensions(manifest, %Project{extensions: [_ | _] = extensions}, ctx) do
    Map.put(manifest, "extensions", %{
      "repo" => "lib/#{ctx.app}/repo.ex",
      "call" => "RepoExtensions",
      "needed" => extensions
    })
  end

  defp put_extensions(manifest, _project, _ctx), do: manifest

  defp put_routes(manifest, %{routes: [_ | _] = routes} = ctx) do
    Map.put(manifest, "routes", %{
      "router" => "lib/#{ctx.app}_web/router.ex",
      "call" => "bubble_routes",
      "pages" => routes |> Enum.map(& &1.id) |> Enum.sort()
    })
  end

  defp put_routes(manifest, _ctx), do: manifest

  defp put_api_clients(inputs, nil), do: inputs

  defp put_api_clients(inputs, %Spec{} = spec),
    do: Map.put(inputs, "api_clients_sha256", Spec.sha256(spec))

  @doc "Canonical, pretty-printed JSON text of a manifest."
  @spec encode(t()) :: String.t()
  def encode(manifest),
    do: (manifest |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"

  @doc "Decodes and validates manifest JSON (or an already decoded map)."
  @spec decode(String.t() | map()) :: {:ok, t()} | {:error, Error.t()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> decode(map)
      {:error, _} -> invalid("the manifest is not JSON")
    end
  end

  def decode(%{"version" => @version, "generated" => generated} = manifest)
      when is_map(generated) do
    if Enum.all?(generated, fn {path, hash} -> relative?(path) and sha256?(hash) end),
      do: {:ok, manifest},
      else: invalid("the manifest's generated entries must map relative paths to SHA-256 hashes")
  end

  def decode(%{"version" => version}) when version != @version,
    do: invalid("unsupported manifest version #{inspect(version)}")

  def decode(_), do: invalid("not a generated-file manifest")

  @doc """
  Compares the generated files a manifest lists with `files` (path →
  content, or the project's root directory): a file whose content no longer
  has its recorded SHA-256 is `modified` (a hand edit), an absent one
  `missing`. `clean?` is true when neither is found. Owned files are not
  checked.

  With `previous:` (the manifest the files were generated with, when
  `manifest` is a new generation's), `stale` lists the files the previous
  generation made that the new one no longer does and that are still
  present: a packager removes them (after checking them against the
  previous manifest). Otherwise `stale` is `[]`.

  `extensions_unlisted` lists the PostgreSQL extensions the project needs
  that the owned Repo neither installs through the generated
  `RepoExtensions` nor names (see `extensions` above): its migrations fail
  until it does.

  `images_unserved` lists the stored Bubble images the owned endpoint
  does not serve (its uncommented source does not name
  `priv/bubble_images`) and any file under `priv/static/images/bubble/`,
  which the main static plug would serve without the images' sandbox
  policy (see `images` above): point the endpoint's `/images/bubble`
  `Plug.Static` at `from: {:app, "priv/bubble_images"}` and remove those
  files.

  `unrouted` lists the Bubble pages (by Bubble ID) that have no route:
  the owned router exists but never calls the generated routes (see
  `routes` above). Such pages need their route before they are verified
  again (`<Web>.BubbleSurfacesTest` fails for them too).
  """
  @spec check(String.t() | map(), %{String.t() => binary()} | Path.t(), keyword()) ::
          {:ok, report()} | {:error, Error.t()}
  def check(manifest, files, opts \\ []) do
    with {:ok, manifest} <- decode(manifest),
         {:ok, read} <- reader(files),
         {:ok, list} <- lister(files),
         {:ok, previous} <- previous(Keyword.get(opts, :previous)) do
      stale =
        for {path, _hash} <- Enum.sort(previous),
            not Map.has_key?(manifest["generated"], path),
            read.(path) != nil,
            do: path

      statuses =
        for {path, hash} <- Enum.sort(manifest["generated"]),
            do: {status(read.(path), hash), path}

      by = Enum.group_by(statuses, &elem(&1, 0), &elem(&1, 1))

      {:ok,
       %{
         clean?: Map.keys(by) -- [:unchanged] == [],
         modified: Map.get(by, :modified, []),
         missing: Map.get(by, :missing, []),
         unchanged: Map.get(by, :unchanged, []),
         stale: stale,
         unrouted: unrouted(manifest, read),
         extensions_unlisted: extensions_unlisted(manifest, read),
         images_unserved: images_unserved(manifest, read) ++ list.(@legacy_images_dir)
       }}
    end
  end

  defp unrouted(%{"routes" => %{"router" => router, "call" => call, "pages" => pages}}, read)
       when is_binary(router) and is_binary(call) and is_list(pages) do
    case relative?(router) && read.(router) do
      content when is_binary(content) ->
        if String.contains?(uncommented(content), call), do: [], else: pages

      _ ->
        []
    end
  end

  defp unrouted(_manifest, _read), do: []

  defp extensions_unlisted(
         %{"extensions" => %{"repo" => repo, "call" => call, "needed" => needed}},
         read
       )
       when is_binary(repo) and is_binary(call) and is_list(needed) do
    case relative?(repo) && read.(repo) do
      content when is_binary(content) ->
        code = uncommented(content)

        if String.contains?(code, call),
          do: [],
          else: Enum.reject(needed, &String.contains?(code, &1))

      _ ->
        []
    end
  end

  defp extensions_unlisted(_manifest, _read), do: []

  defp images_unserved(
         %{"images" => %{"endpoint" => endpoint, "from" => from, "files" => files}},
         read
       )
       when is_binary(endpoint) and is_binary(from) and is_list(files) do
    case relative?(endpoint) && read.(endpoint) do
      content when is_binary(content) ->
        if String.contains?(uncommented(content), from), do: [], else: Enum.sort(files)

      _ ->
        []
    end
  end

  defp images_unserved(_manifest, _read), do: []

  # Elixir source without its `#` comments (a commented-out call is no
  # call). Approximate: a `#` inside a string also starts one here.
  defp uncommented(content), do: Regex.replace(~r/#.*$/m, content, "")

  defp previous(nil), do: {:ok, %{}}

  defp previous(manifest) do
    with {:ok, %{"generated" => generated}} <- decode(manifest), do: {:ok, generated}
  end

  defp status(nil, _hash), do: :missing

  defp status(content, hash),
    do: if(sha256(content) == hash, do: :unchanged, else: :modified)

  @doc "Lowercase hex SHA-256 of a file's content."
  @spec sha256(iodata()) :: String.t()
  def sha256(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  defp hashes(files), do: Map.new(files, fn {path, content} -> {path, sha256(content)} end)

  defp reader(files) when is_map(files), do: {:ok, &Map.get(files, &1)}

  defp reader(root) when is_binary(root) do
    if File.dir?(root) do
      {:ok,
       fn path ->
         case File.read(Path.join(root, path)) do
           {:ok, content} -> content
           {:error, _} -> nil
         end
       end}
    else
      invalid("#{inspect(root)} is not a directory")
    end
  end

  defp reader(other), do: invalid("expected a file map or a directory, got #{inspect(other)}")

  # The files under a project directory, as project paths (sorted).
  defp lister(files) when is_map(files) do
    {:ok,
     fn dir ->
       files |> Map.keys() |> Enum.filter(&String.starts_with?(&1, dir <> "/")) |> Enum.sort()
     end}
  end

  defp lister(root) when is_binary(root),
    do: {:ok, fn dir -> root |> walk(dir) |> Enum.sort() end}

  # Not Path.wildcard: the root may hold glob characters. A symlink is
  # listed, never followed (no loop).
  defp walk(root, path) do
    full = Path.join(root, path)

    case File.lstat(full) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(full) do
          {:ok, names} -> Enum.flat_map(names, &walk(root, Path.join(path, &1)))
          {:error, _} -> []
        end

      {:ok, _} ->
        [path]

      {:error, _} ->
        []
    end
  end

  # A project-relative path that stays inside the project.
  defp relative?(path) do
    is_binary(path) and path != "" and Path.type(path) == :relative and
      ".." not in Path.split(path)
  end

  defp sha256?(hash), do: is_binary(hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)

  defp invalid(message), do: {:error, Error.new(:invalid_input, message)}
end
