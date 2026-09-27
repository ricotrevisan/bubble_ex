defmodule BubbleEx.Load.Export do
  @moduledoc """
  A Bubble data export on disk: what `BubbleEx.Load.DataApi` reads from
  Bubble and `BubbleEx.Load` loads into a target. The loader reads only
  the export, never Bubble.

      <dir>/manifest.json
      <dir>/rows/<type>.jsonl.gz    one Data API result object per line, verbatim
      <dir>/files.jsonl             one entry per Bubble file URL found in file fields
      <dir>/files/<sha256>          the file's bytes, named by their SHA-256

  `manifest.json` (canonical JSON):

      {"format": "bubble_ex.export", "version": 1,
       "app": "<Bubble app ID or null>", "model_sha256": "<BubbleEx.Model.sha256/1>",
       "source": {"kind": "data_api", "base_url": "https://<host>[/version-test]"},
       "created_at": "<ISO 8601>",
       "types": [{"type": "task", "path": "task", "status": "complete",
                  "rows": 3, "object": "rows/task.jsonl.gz", "sha256": "…"},
                 {"type": "log", "path": "log", "status": "failed", "error": "not_found"}],
       "files": {"object": "files.jsonl", "sha256": "…", "count": 2, "failed": 0}}

  A `files.jsonl` entry is `{"url", "status": "ok", "sha256", "bytes",
  "name", "content_type", "visibility": "public" | "private"}` or `{"url",
  "status": "failed", "error": "<code>"}`. URLs are normalized
  (`BubbleEx.Load.Files.normalize/1`).

  **Integrity.** `open/1` checks every rows object and `files.jsonl`
  against the manifest's SHA-256; blobs are checked when they are copied.
  The export's identity (`sha256`) is the SHA-256 of `manifest.json`.

  **Personal data.** An export holds the app's data, users' emails
  included. The directory is created `0700` and its files `0600`; no
  password material is ever read (`authentication` keeps only the email
  and its confirmed status, and the names of other sign-in methods).
  BubbleEx does not encrypt it: **keep exports on an encrypted disk**
  (FileVault, LUKS, an encrypted volume), never in a repository, a synced
  folder or a shared machine, and **delete them after the cutover** with
  `delete/1` (`mix bubble.export.delete DIR`). The loader's ledgers hold
  no stored values; the target storage holds the copied files, which are
  the app's data from then on.
  """

  alias BubbleEx.{CanonicalJson, Error}

  @format "bubble_ex.export"
  @version 1

  @enforce_keys [:dir, :manifest, :sha256]
  defstruct [:dir, :manifest, :sha256]

  @type t :: %__MODULE__{dir: String.t(), manifest: map(), sha256: String.t()}

  @doc "The manifest format name and version."
  @spec format() :: {String.t(), pos_integer()}
  def format, do: {@format, @version}

  @doc """
  Opens the export in `dir`: reads the manifest and checks every rows
  object and the file index against it.
  """
  @spec open(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def open(dir) do
    path = Path.join(dir, "manifest.json")

    with {:ok, text} <- read(path),
         {:ok, manifest} <- decode(text),
         :ok <- check_format(manifest),
         :ok <- check_objects(dir, manifest) do
      {:ok, %__MODULE__{dir: dir, manifest: manifest, sha256: sha256_hex(text)}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        {:error, Error.new(:invalid_input, "cannot read the export manifest", %{reason: reason})}
    end
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, Error.new(:parse_failed, "the export manifest is not a JSON object")}
    end
  end

  defp check_format(%{"format" => @format, "version" => @version, "types" => types})
       when is_list(types),
       do: :ok

  defp check_format(m),
    do:
      {:error,
       Error.new(:invalid_input, "not a bubble_ex export (or an unsupported version)", %{
         format: m["format"],
         version: m["version"]
       })}

  defp check_objects(dir, manifest) do
    objects =
      for(
        %{"status" => "complete", "object" => o, "sha256" => s} <- manifest["types"],
        do: {o, s}
      ) ++
        case manifest["files"] do
          %{"object" => o, "sha256" => s} -> [{o, s}]
          _ -> []
        end

    Enum.reduce_while(objects, :ok, fn {object, sha}, :ok ->
      case check_object(dir, object, sha) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_object(dir, object, sha) do
    with :ok <- safe_object(object),
         {:ok, ^sha} <- file_sha256(Path.join(dir, object)) do
      :ok
    else
      {:ok, _other} ->
        {:error,
         Error.new(:invalid_input, "an export object does not match its checksum", %{
           object: object
         })}

      error ->
        error
    end
  end

  # Objects live under the export directory.
  defp safe_object(object) when is_binary(object) do
    if object =~ ~r"\A(rows/[a-z0-9_]{1,64}(\.[0-9a-f]{12})?\.jsonl\.gz|files\.jsonl)\z",
      do: :ok,
      else:
        {:error, Error.new(:invalid_input, "an export object path is invalid", %{object: object})}
  end

  defp safe_object(_),
    do: {:error, Error.new(:invalid_input, "an export object path is invalid")}

  # The export's own entries, by subdirectory ("" is the export itself).
  defp own_entries do
    [
      {"", ~r/\A(manifest\.json|state\.json|files\.jsonl|files\.part\.jsonl)(\.tmp-[0-9]+)?\z/},
      {"rows", ~r/\A[a-z0-9_]{1,64}(\.[0-9a-f]{12})?\.(jsonl\.gz|part)(\.tmp-[0-9]+)?\z/},
      {"files", ~r/\A([0-9a-f]{64}(\.tmp-[0-9]+)?|\.fetch-[0-9]+)\z/}
    ]
  end

  @doc """
  Deletes the export in `dir` (after the cutover). `dir` must be a real
  directory (not a symbolic link) holding a bubble_ex export, finished
  (`manifest.json`) or interrupted (`state.json` and `rows/`). Only the
  export's own entries are deleted, and only regular files (never through
  a link): `manifest.json`, `state.json`, `files.jsonl`,
  `files.part.jsonl`, the rows objects and part files under `rows/`, the
  blobs and partial downloads (`.fetch-*`) under `files/`, and their
  temporary files. `rows/`, `files/` and `dir` are removed only when that
  leaves them empty; anything else is left in place and listed.

  Returns `{:ok, %{deleted: count, left: [relative paths]}}`. On an SSD or
  a copy-on-write file system deletion does not guarantee the bytes are
  gone, which is why the export belongs on an encrypted disk in the first
  place.
  """
  @spec delete(Path.t()) ::
          {:ok, %{deleted: non_neg_integer(), left: [String.t()]}} | {:error, Error.t()}
  def delete(dir) do
    cond do
      not match?({:ok, %File.Stat{type: :directory}}, File.lstat(dir)) ->
        {:error,
         Error.new(:invalid_input, "not a directory (or a symbolic link); nothing deleted")}

      not export_dir?(dir) ->
        {:error, Error.new(:invalid_input, "not a bubble_ex export directory; nothing deleted")}

      true ->
        deleted =
          for {sub, pattern} <- own_entries(),
              name <- list(Path.join(dir, sub)),
              name =~ pattern,
              path = Path.join([dir, sub, name]),
              match?({:ok, %File.Stat{type: :regular}}, File.lstat(path)),
              File.rm(path) == :ok,
              do: path

        for sub <- ["rows", "files", ""], do: rmdir_if_empty(Path.join(dir, sub))
        {:ok, %{deleted: length(deleted), left: left(dir)}}
    end
  end

  defp list(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} -> File.ls!(dir)
      _ -> []
    end
  end

  defp rmdir_if_empty(dir) do
    if list(dir) == [] and match?({:ok, %File.Stat{type: :directory}}, File.lstat(dir)),
      do: File.rmdir(dir)
  end

  # What is left, relative to `dir` (nothing when it is gone).
  defp left(dir) do
    if File.exists?(dir) do
      dir
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.map(&Path.relative_to(&1, dir))
      |> Enum.sort()
    else
      []
    end
  end

  defp export_dir?(dir) do
    case File.read(Path.join(dir, "manifest.json")) do
      {:ok, text} ->
        match?({:ok, %{"format" => @format}}, Jason.decode(text))

      {:error, _} ->
        File.regular?(Path.join(dir, "state.json")) and File.dir?(Path.join(dir, "rows"))
    end
  end

  @doc "The manifest's type entries."
  @spec types(t()) :: [map()]
  def types(%__MODULE__{manifest: m}), do: m["types"]

  @doc "The manifest entry of data type `type`, or nil."
  @spec type(t(), String.t()) :: map() | nil
  def type(%__MODULE__{} = e, type), do: Enum.find(types(e), &(&1["type"] == type))

  @doc "Whether every type exported completely."
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{} = e), do: Enum.all?(types(e), &(&1["status"] == "complete"))

  @doc """
  The rows of data type `type` as a stream of decoded maps, in export
  order ([] when the type has no complete rows object).
  """
  @spec rows(t(), String.t()) :: Enumerable.t()
  def rows(%__MODULE__{dir: dir} = e, type) do
    case type(e, type) do
      %{"status" => "complete", "object" => object} ->
        Path.join(dir, object)
        |> File.stream!(:line, [:compressed])
        |> Stream.map(&String.trim_trailing(&1, "\n"))
        |> Stream.reject(&(&1 == ""))
        |> Stream.map(&Jason.decode!/1)

      _ ->
        []
    end
  end

  @doc "The file index entries (`files.jsonl`)."
  @spec files(t()) :: [map()]
  def files(%__MODULE__{dir: dir, manifest: m}) do
    case m["files"] do
      %{"object" => object} ->
        Path.join(dir, object)
        |> File.stream!(:line)
        |> Stream.map(&String.trim_trailing(&1, "\n"))
        |> Stream.reject(&(&1 == ""))
        |> Enum.map(&Jason.decode!/1)

      _ ->
        []
    end
  end

  @doc "The path of the blob with SHA-256 `sha256`."
  @spec blob_path(t() | Path.t(), String.t()) :: Path.t()
  def blob_path(%__MODULE__{dir: dir}, sha256), do: blob_path(dir, sha256)

  def blob_path(dir, sha256) when is_binary(dir) do
    true = sha256 =~ ~r/\A[0-9a-f]{64}\z/
    Path.join([dir, "files", sha256])
  end

  # --- writing ---------------------------------------------------------------------

  @doc """
  Writes a complete export to `dir` (which must not hold one yet) from
  data in memory: fixtures, tests and small apps. `spec`:

    * `:types` - `[%{type: id, path: data_api_path, rows: [map]}]`, or
      `%{type: id, path: p, error: code}` for a type that failed to export
    * `:files` - `[%{url: url, content: binary, content_type: ct}]` or
      `%{url: url, error: code}`
    * `:app`, `:model_sha256`, `:source` (a map), `:created_at` (ISO text)
  """
  @spec write(Path.t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def write(dir, spec) do
    with :ok <- prepare_dir(dir) do
      types =
        Enum.map(Map.get(spec, :types, []), fn
          %{error: error} = t ->
            %{
              "type" => t.type,
              "path" => t.path,
              "status" => "failed",
              "error" => to_string(error)
            }

          t ->
            part = Path.join(dir, "rows/#{object_name(t.type)}.part")
            File.write!(part, Enum.map(t.rows, &[Jason.encode!(&1), "\n"]))
            complete_type(dir, t.type, t.path, part, length(t.rows))
        end)

      entries =
        Enum.map(Map.get(spec, :files, []), fn
          %{error: error, url: url} ->
            %{"url" => url, "status" => "failed", "error" => to_string(error)}

          %{url: url, content: content} = f ->
            sha = put_blob(dir, content)
            file_entry(url, sha, byte_size(content), Map.get(f, :content_type))
        end)

      File.write!(
        Path.join(dir, "files.jsonl"),
        Enum.map(entries, &[CanonicalJson.encode(&1), "\n"])
      )

      finish(dir, %{
        app: Map.get(spec, :app),
        model_sha256: Map.get(spec, :model_sha256),
        source: Map.get(spec, :source, %{"kind" => "fixture"}),
        created_at: Map.get(spec, :created_at),
        types: types,
        files: entries
      })
    end
  end

  @doc false
  # Creates the export directory (0700) with its subdirectories.
  @spec prepare_dir(Path.t()) :: :ok | {:error, Error.t()}
  def prepare_dir(dir) do
    if File.exists?(Path.join(dir, "manifest.json")) do
      {:error, Error.new(:invalid_input, "the directory already holds a finished export")}
    else
      for sub <- ["", "rows", "files"], do: File.mkdir_p!(Path.join(dir, sub))
      File.chmod!(dir, 0o700)
      :ok
    end
  end

  @doc false
  # The object name of a type: its ID when it is a plain identifier, else
  # a slug plus a hash of the ID.
  @spec object_name(String.t()) :: String.t()
  def object_name(type) do
    if type =~ ~r/\A[a-z0-9_]{1,64}\z/ do
      type
    else
      slug =
        type |> String.downcase() |> String.replace(~r/[^a-z0-9_]+/, "_") |> String.slice(0, 40)

      slug = if slug == "", do: "type", else: slug
      slug <> "." <> String.slice(sha256_hex(type), 0, 12)
    end
  end

  @doc false
  # Compresses a finished part file into the type's rows object.
  @spec complete_type(Path.t(), String.t(), String.t(), Path.t(), non_neg_integer()) :: map()
  def complete_type(dir, type, path, part, rows) do
    object = "rows/#{object_name(type)}.jsonl.gz"
    target = Path.join(dir, object)
    data = part |> File.read!() |> :zlib.gzip()
    write_private!(target, data)
    File.rm!(part)

    %{
      "type" => type,
      "path" => path,
      "status" => "complete",
      "rows" => rows,
      "object" => object,
      "sha256" => sha256_hex(data)
    }
  end

  @doc false
  # Stores `content` as a blob; returns its SHA-256.
  @spec put_blob(Path.t(), binary()) :: String.t()
  def put_blob(dir, content) do
    sha = sha256_hex(content)
    path = blob_path(dir, sha)
    unless File.exists?(path), do: write_private!(path, content)
    sha
  end

  @doc false
  @spec file_entry(String.t(), String.t(), non_neg_integer(), String.t() | nil) :: map()
  def file_entry(url, sha, bytes, content_type) do
    %{
      "url" => url,
      "status" => "ok",
      "sha256" => sha,
      "bytes" => bytes,
      "name" => BubbleEx.Load.Files.file_name(url),
      "content_type" => content_type,
      "visibility" => Atom.to_string(BubbleEx.Load.Files.visibility(url))
    }
  end

  @doc false
  # Writes the manifest (last: a directory with a manifest is finished).
  @spec finish(Path.t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def finish(dir, info) do
    files_object = Path.join(dir, "files.jsonl")
    unless File.exists?(files_object), do: write_private!(files_object, "")
    File.chmod!(files_object, 0o600)

    manifest = %{
      "format" => @format,
      "version" => @version,
      "app" => info.app,
      "model_sha256" => info.model_sha256,
      "source" => info.source,
      "created_at" => info.created_at,
      "types" => Enum.sort_by(info.types, & &1["type"]),
      "files" => %{
        "object" => "files.jsonl",
        "sha256" => files_object |> File.read!() |> sha256_hex(),
        "count" => length(info.files),
        "failed" => Enum.count(info.files, &(&1["status"] == "failed"))
      }
    }

    write_private!(Path.join(dir, "manifest.json"), CanonicalJson.encode(manifest))
    open(dir)
  end

  @doc false
  # Atomic write, readable by the owner only.
  @spec write_private!(Path.t(), iodata()) :: :ok
  def write_private!(path, data) do
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    File.write!(tmp, data)
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
  end

  @doc false
  @spec sha256_hex(iodata()) :: String.t()
  def sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  @doc false
  @spec file_sha256(Path.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def file_sha256(path) do
    hash =
      path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, hash}
  rescue
    _ in File.Error -> {:error, Error.new(:invalid_input, "an export object is missing")}
  end
end
