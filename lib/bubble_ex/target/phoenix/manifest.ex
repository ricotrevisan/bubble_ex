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
          "project_schema_version": 4,
          "project_sha256": "…",
          "decisions_sha256": null,
          "applied_sha256": null,
          "privacy": "omit"
        },
        "generated": {"lib/acme_import/invoice.ex": "<sha256>", …},
        "owned": {"mix.exs": "<sha256 as scaffolded>", …}
      }

    * `inputs` - what the generated files are a function of:
      `project_sha256` is the SHA-256 of the canonical JSON of the
      `BubbleEx.Target.Ash.Project` (`Project.to_map/1`: resources, names,
      applied decisions, diagnostics…); `decisions_sha256` and
      `applied_sha256` are the Project's (nil without decisions);
      `api_clients_sha256`, present when API clients were rendered, is the
      SHA-256 of the `BubbleEx.Target.ApiClients.Spec`'s canonical JSON
    * `generated` - every generated file (path → SHA-256 of its content).
      Regeneration overwrites them; `check/2` finds hand edits. The
      manifest does not list itself
    * `owned` - every owned file (path → SHA-256 as scaffolded): written
      once, then the owner's; never overwritten, so their hashes are
      informational (did the owner change the scaffold?)

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
          stale: [String.t()]
        }

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
          "privacy" => Atom.to_string(project.privacy)
        }
        |> put_api_clients(Map.get(ctx, :api_clients)),
      "generated" => hashes(generated),
      "owned" => hashes(owned)
    }
  end

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
  """
  @spec check(String.t() | map(), %{String.t() => binary()} | Path.t(), keyword()) ::
          {:ok, report()} | {:error, Error.t()}
  def check(manifest, files, opts \\ []) do
    with {:ok, manifest} <- decode(manifest),
         {:ok, read} <- reader(files),
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
         stale: stale
       }}
    end
  end

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

  # A project-relative path that stays inside the project.
  defp relative?(path) do
    is_binary(path) and path != "" and Path.type(path) == :relative and
      ".." not in Path.split(path)
  end

  defp sha256?(hash), do: is_binary(hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)

  defp invalid(message), do: {:error, Error.new(:invalid_input, message)}
end
