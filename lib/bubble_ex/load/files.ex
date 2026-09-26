defmodule BubbleEx.Load.Files do
  @moduledoc """
  Bubble file URLs: recognizing them, their visibility, and moving the files
  from an export (`BubbleEx.Load.Export`) to a target's storage
  (`BubbleEx.Load.Storage`) with verified checksums.

  **Recognition.** A file or image field holds a URL. Only Bubble's own
  storage hosts are Bubble's (checked against the host shapes of a real
  app's definition): `*.cdn.bubble.io`, Bubble's S3 bucket
  (`s3.amazonaws.com/appforest_uf/…` or `appforest_uf.s3.amazonaws.com`),
  Bubble's CloudFront distribution (`dd7tel2830j4w.cloudfront.net/f<id>/…`)
  and the app's own hosts (`app_hosts`) for private `/fileupload/` files.
  Any other URL, whatever its path, is not Bubble's to move: it loads as
  given (`:load_file_not_bubble`) and is never fetched.

  **Visibility.** A `/fileupload/` URL on the app's host is a private
  Bubble file (served only to users allowed to see it); everything else is
  public, as Bubble served it (the design reference, Buildprint, does the
  same). A private file is stored private and its field gets the storage's
  private reference, never a public URL.

  **Checksums.** A file is copied only if its export blob still has the
  SHA-256 the export recorded, and it counts as copied only when the
  storage verifies the stored bytes against it. A failed file (a checksum
  mismatch, a storage error or crash, a timeout) is reported
  (`:load_file_failed`) and its field keeps the Bubble URL; it never stops
  the run.

  **Serving.** File names keep their extension (`.html`, `.svg` included):
  serve copied files from a separate origin, or with `Content-Disposition:
  attachment` and `X-Content-Type-Options: nosniff`, never inline from the
  app's own origin (stored XSS). See `BubbleEx.Load.Storage.Local`.
  """

  alias BubbleEx.Error
  alias BubbleEx.Load.Export

  @cloudfront "dd7tel2830j4w.cloudfront.net"

  @doc """
  Bubble's protocol-relative `//host/…` becomes `https://host/…`; other
  text is returned trimmed.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(url) when is_binary(url) do
    url = String.trim(url)
    if String.starts_with?(url, "//"), do: "https:" <> url, else: url
  end

  @doc """
  Whether `url` is in Bubble's file storage (see the moduledoc); `app_hosts`
  are the app's own hosts, where its private files live.
  """
  @spec bubble?(String.t(), [String.t()]) :: boolean()
  def bubble?(url, app_hosts \\ [])

  def bubble?(url, app_hosts) when is_binary(url) do
    case URI.new(normalize(url)) do
      {:ok, %URI{scheme: "https", host: host, path: path, userinfo: nil}}
      when is_binary(host) and is_binary(path) ->
        storage_host?(String.downcase(host), path, app_hosts)

      _ ->
        false
    end
  end

  def bubble?(_, _), do: false

  defp storage_host?("s3.amazonaws.com", path, _), do: String.starts_with?(path, "/appforest_uf/")
  defp storage_host?("appforest_uf.s3.amazonaws.com", _path, _), do: true
  defp storage_host?(@cloudfront, path, _), do: path =~ ~r{\A/f[0-9]+x[0-9]+/}

  defp storage_host?(host, path, app_hosts) do
    String.ends_with?(host, ".cdn.bubble.io") or
      (host in app_hosts and String.starts_with?(path, "/fileupload/"))
  end

  @doc "`:private` for a `/fileupload/` URL, else `:public`."
  @spec visibility(String.t()) :: :public | :private
  def visibility(url) do
    case URI.new(normalize(url)) do
      {:ok, %URI{path: "/fileupload/" <> _}} -> :private
      _ -> :public
    end
  end

  @doc """
  A safe file name from the URL's last path segment (see `safe_name/1`).
  """
  @spec file_name(String.t()) :: String.t()
  def file_name(url) do
    case URI.new(normalize(url)) do
      {:ok, %URI{path: path}} when is_binary(path) ->
        path |> String.split("/") |> List.last() |> decode() |> safe_name()

      _ ->
        "file"
    end
  end

  defp decode(segment) do
    URI.decode(segment)
  rescue
    ArgumentError -> segment
  end

  @doc """
  A safe file name: letters, digits, `.`, `_` and `-` only, no leading or
  trailing dot, at most 100 bytes (the end kept, so the extension stays);
  `"file"` when nothing is left. Applied again at load time to names read
  from an export.
  """
  @spec safe_name(term()) :: String.t()
  def safe_name(name) when is_binary(name) do
    name =
      name
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
      |> String.trim(".")
      |> keep_end(100)
      |> String.trim(".")

    if name in ["", "_"], do: "file", else: name
  end

  def safe_name(_), do: "file"

  defp keep_end(text, max) when byte_size(text) <= max, do: text
  defp keep_end(text, max), do: binary_part(text, byte_size(text) - max, max)

  @doc "Every Bubble file URL in a text (for reporting URLs pasted into text fields)."
  @spec urls_in_text(String.t(), [String.t()]) :: [String.t()]
  def urls_in_text(text, app_hosts \\ [])

  def urls_in_text(text, app_hosts) when is_binary(text) do
    ~r{(?:https?:)?//[^\s"'<>()]+}
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.filter(&bubble?(&1, app_hosts))
  end

  def urls_in_text(_, _), do: []

  # --- copying to the target's storage ----------------------------------------------

  @doc """
  Copies the export's files to `storage` (`{module, config}` of a
  `BubbleEx.Load.Storage`), only those in `referenced` (normalized URLs),
  with at most `:concurrency` (default 8) at a time, each within
  `:timeout` ms (default 300,000). `done` maps URLs a ledger already
  recorded as copied to their references; they are not copied again.

  `on_result` is called in the caller's process as each file finishes, in
  order, with `{:ok, url, reference}` or `{:failed, url, reason}`, and
  threads `acc` (the loader records each file in its ledger as it
  completes). A storage that raises, exits or times out fails that file
  only.

  Returns `{refs, failed, acc}`: `%{url => reference}` (including `done`)
  and `[%{url, reason}]`.
  """
  @spec copy(Export.t(), {module(), term()}, MapSet.t(String.t()), keyword()) ::
          {%{String.t() => String.t()}, [%{url: String.t(), reason: atom()}], term()}
  def copy(%Export{} = export, {mod, config}, referenced, opts \\ []) do
    done = Keyword.get(opts, :done, %{})
    on_result = Keyword.get(opts, :on_result, fn _result, acc -> acc end)

    entries =
      for %{"url" => url} = e <- Export.files(export),
          MapSet.member?(referenced, url),
          not Map.has_key?(done, url),
          do: e

    entries
    |> Task.async_stream(&copy_one(export, mod, config, &1),
      max_concurrency: Keyword.get(opts, :concurrency, 8),
      timeout: Keyword.get(opts, :timeout, 300_000),
      on_timeout: :kill_task,
      ordered: true
    )
    |> Stream.zip(entries)
    |> Enum.reduce({done, [], Keyword.get(opts, :acc)}, fn {result, entry}, {refs, failed, acc} ->
      result =
        case result do
          {:ok, result} -> result
          {:exit, :timeout} -> {:failed, entry["url"], :copy_timeout}
          {:exit, _} -> {:failed, entry["url"], :copy_crashed}
        end

      acc = on_result.(result, acc)

      case result do
        {:ok, url, ref} -> {Map.put(refs, url, ref), failed, acc}
        {:failed, url, reason} -> {refs, [%{url: url, reason: reason} | failed], acc}
      end
    end)
    |> then(fn {refs, failed, acc} -> {refs, Enum.sort_by(failed, & &1.url), acc} end)
  end

  # Never raises: a storage error, raise or exit fails this file only.
  defp copy_one(export, mod, config, %{"status" => "ok"} = entry) do
    url = entry["url"]

    try do
      copy_checked(export, mod, config, entry)
    rescue
      _ -> {:failed, url, :storage_crashed}
    catch
      _kind, _reason -> {:failed, url, :storage_crashed}
    end
  end

  defp copy_one(_export, _mod, _config, entry), do: {:failed, entry["url"], :not_exported}

  defp copy_checked(export, mod, config, entry) do
    url = entry["url"]
    sha = entry["sha256"]

    meta = %{
      sha256: sha,
      bytes: entry["bytes"],
      # Names from an export are sanitized again: the export is input.
      name: safe_name(entry["name"] || file_name(url)),
      content_type: entry["content_type"],
      visibility: if(entry["visibility"] == "private", do: :private, else: :public)
    }

    with {:ok, path} <- blob(export, sha),
         {:ok, ^sha} <- Export.file_sha256(path),
         {:ok, ref} <- mod.put(config, meta, path),
         :ok <- mod.verify(config, ref, meta) do
      {:ok, url, ref}
    else
      {:ok, _other} -> {:failed, url, :export_checksum_mismatch}
      {:error, %Error{context: %{reason: reason}}} when is_atom(reason) -> {:failed, url, reason}
      _ -> {:failed, url, :storage_failed}
    end
  end

  defp blob(export, sha) when is_binary(sha) do
    if sha =~ ~r/\A[0-9a-f]{64}\z/,
      do: {:ok, Export.blob_path(export, sha)},
      else: {:error, Error.new(:invalid_input, "invalid blob", %{reason: :invalid_blob})}
  end

  defp blob(_export, _sha),
    do: {:error, Error.new(:invalid_input, "invalid blob", %{reason: :invalid_blob})}
end
