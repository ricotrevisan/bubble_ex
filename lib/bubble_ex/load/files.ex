defmodule BubbleEx.Load.Files do
  @moduledoc """
  Bubble file URLs: recognizing them, their visibility, and moving the files
  from an export (`BubbleEx.Load.Export`) to a target's storage
  (`BubbleEx.Load.Storage`) with verified checksums.

  **Recognition.** A file or image field holds a URL. Bubble's storage is
  `appforest_uf` (on S3), `*.cdn.bubble.io` and the app's own
  `/fileupload/` path. Other URLs (a file hosted elsewhere) are not
  Bubble's to move: they load as given (`:load_file_not_bubble`).

  **Visibility.** A `/fileupload/` URL is a private Bubble file (served
  only to users allowed to see it); everything else is public, as Bubble
  served it (the design reference, Buildprint, does the same). A private
  file is stored private and its field gets the storage's private
  reference, never a public URL.

  **Checksums.** A file is copied only if its export blob still has the
  SHA-256 the export recorded, and it counts as copied only when the
  storage verifies the stored bytes against it. A failed file is reported
  (`:load_file_failed`) and its field keeps the Bubble URL.
  """

  alias BubbleEx.Error
  alias BubbleEx.Load.Export

  @doc """
  Bubble's protocol-relative `//host/…` becomes `https://host/…`; other
  text is returned trimmed.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(url) when is_binary(url) do
    url = String.trim(url)
    if String.starts_with?(url, "//"), do: "https:" <> url, else: url
  end

  @doc "Whether `url` (normalized) is in Bubble's file storage."
  @spec bubble?(String.t()) :: boolean()
  def bubble?(url) when is_binary(url) do
    case URI.new(normalize(url)) do
      {:ok, %URI{scheme: "https", host: host, path: path}} when is_binary(host) ->
        path = path || ""

        String.ends_with?(host, ".cdn.bubble.io") or
          String.contains?(path, "/appforest_uf/") or
          String.contains?(path, "/fileupload/")

      _ ->
        false
    end
  end

  def bubble?(_), do: false

  @doc "`:private` for a `/fileupload/` URL, else `:public`."
  @spec visibility(String.t()) :: :public | :private
  def visibility(url) do
    case URI.new(normalize(url)) do
      {:ok, %URI{path: path}} when is_binary(path) ->
        if String.contains?(path, "/fileupload/"), do: :private, else: :public

      _ ->
        :public
    end
  end

  @doc """
  A safe file name from the URL's last path segment: decoded, letters,
  digits, `.`, `_` and `-` only, at most 100 bytes; `"file"` when nothing
  is left.
  """
  @spec file_name(String.t()) :: String.t()
  def file_name(url) do
    segment =
      case URI.new(normalize(url)) do
        {:ok, %URI{path: path}} when is_binary(path) ->
          path |> String.split("/") |> List.last() |> URI.decode()

        _ ->
          ""
      end

    name =
      segment
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
      |> String.trim(".")
      |> binary_part_safe(100)

    if name in ["", "_"], do: "file", else: name
  end

  defp binary_part_safe(text, max) when byte_size(text) <= max, do: text
  defp binary_part_safe(text, max), do: binary_part(text, byte_size(text) - max, max)

  @doc "Every Bubble file URL in a text (for reporting URLs pasted into text fields)."
  @spec urls_in_text(String.t()) :: [String.t()]
  def urls_in_text(text) when is_binary(text) do
    ~r{(?:https?:)?//[^\s"'<>()]+}
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.filter(&bubble?/1)
  end

  def urls_in_text(_), do: []

  # --- copying to the target's storage ----------------------------------------------

  @doc """
  Copies the export's files to `storage` (`{module, config}` of a
  `BubbleEx.Load.Storage`), only those in `referenced` (normalized URLs),
  with at most `:concurrency` (default 8) at a time. `done` maps URLs a
  ledger already recorded as copied to their references; they are not
  copied again. `on_copied` is called with `{url, reference}` after each
  verified copy (the ledger records it).

  Returns `%{refs: %{url => reference}, failed: [%{url, reason}]}`:
  failures are collected, never fatal.
  """
  @spec copy(Export.t(), {module(), term()}, MapSet.t(String.t()), keyword()) :: %{
          refs: %{String.t() => String.t()},
          failed: [%{url: String.t(), reason: atom()}]
        }
  def copy(%Export{} = export, {mod, config}, referenced, opts \\ []) do
    done = Keyword.get(opts, :done, %{})
    on_copied = Keyword.get(opts, :on_copied, fn _ -> :ok end)

    entries =
      for %{"url" => url} = e <- Export.files(export),
          MapSet.member?(referenced, url),
          not Map.has_key?(done, url),
          do: e

    results =
      entries
      |> Task.async_stream(&copy_one(export, mod, config, &1),
        max_concurrency: Keyword.get(opts, :concurrency, 8),
        timeout: Keyword.get(opts, :timeout, 300_000),
        ordered: true
      )
      |> Enum.zip(entries)
      |> Enum.map(fn
        {{:ok, result}, _entry} -> result
        {{:exit, _}, entry} -> {:failed, entry["url"], :copy_crashed}
      end)

    Enum.reduce(results, %{refs: done, failed: []}, fn
      {:ok, url, ref}, acc ->
        on_copied.({url, ref})
        %{acc | refs: Map.put(acc.refs, url, ref)}

      {:failed, url, reason}, acc ->
        %{acc | failed: [%{url: url, reason: reason} | acc.failed]}
    end)
    |> Map.update!(:failed, &Enum.sort_by(&1, fn f -> f.url end))
  end

  defp copy_one(export, mod, config, %{"status" => "ok"} = entry) do
    url = entry["url"]
    sha = entry["sha256"]
    path = Export.blob_path(export, sha)

    meta = %{
      sha256: sha,
      bytes: entry["bytes"],
      name: entry["name"] || file_name(url),
      content_type: entry["content_type"],
      visibility: if(entry["visibility"] == "private", do: :private, else: :public)
    }

    with {:ok, ^sha} <- Export.file_sha256(path) |> blob_ok(),
         {:ok, ref} <- mod.put(config, meta, path),
         :ok <- mod.verify(config, ref, meta) do
      {:ok, url, ref}
    else
      {:ok, _other} -> {:failed, url, :export_checksum_mismatch}
      {:error, %Error{context: %{reason: reason}}} when is_atom(reason) -> {:failed, url, reason}
      {:error, _} -> {:failed, url, :storage_failed}
    end
  end

  defp copy_one(_export, _mod, _config, entry), do: {:failed, entry["url"], :not_exported}

  defp blob_ok({:ok, sha}), do: {:ok, sha}

  defp blob_ok({:error, _}),
    do: {:error, Error.new(:invalid_input, "blob missing", %{reason: :blob_missing})}
end
