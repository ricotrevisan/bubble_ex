defmodule BubbleEx.Load.DataApi do
  @moduledoc """
  Exports a Bubble app's data through its Data API into a
  `BubbleEx.Load.Export` (WTF-357). **Read-only**: it sends only `GET`
  requests, to the app's Data API (`/api/1.1/obj/<type>`) and to Bubble's
  file storage, and never writes to Bubble.

      {:ok, export} =
        BubbleEx.Load.DataApi.export(model, "exports/acme",
          app_url: "https://acme.bubbleapps.io",
          version: "live"
        )

  **Token.** The Data API returns every record only to the app's admin API
  token (other callers get what the privacy rules show them, which would
  make a silently partial export). The token comes from `:token` or from
  the environment variable `:token_env` (default `BUBBLE_API_TOKEN`) and
  nowhere else; it is sent only to the app's own host, never logged, and
  redacted from errors, telemetry and the export (the manifest records
  the host and version, not the token). It is held as a
  `BubbleEx.Load.Secret`, which never inspects to its value.

  **Paging.** Each type is read in pages of up to 100, sorted by Created
  Date, following Bubble's cursor until `remaining` is 0. Pages are
  appended to a part file and the cursor recorded in `state.json` after
  each page, so an interrupted export resumes where it stopped (rerun the
  same call; it refuses to resume an export of another app or version). A
  non-empty page without `remaining` fails the type rather than
  completing it. The Data API does not snapshot: records created or changed
  during the export can shift pages, so a record may appear twice (the
  loader keeps the latest copy) or be missed. Export during a write freeze
  for the final load, and load again (a delta sync) at cutover.

  **Users.** A user's `authentication` keeps only the email, its confirmed
  status and the names of other sign-in methods (their contents are
  dropped). No password material exists in the Data API or the export.

  **Files.** After the rows, every Bubble file URL in a file or image field
  (`BubbleEx.Load.Files.bubble?/2`: Bubble's storage hosts, and the app's
  own hosts for `/fileupload/`) is fetched once (`GET`, at most
  `:file_concurrency` at a time, default 8, each within `:file_timeout`,
  default 10 minutes). A file is streamed to disk and hashed with SHA-256
  as it arrives (never held in memory), checked against its
  `Content-Length` and at most `:max_file_bytes` (default 5 GB), then
  stored as a blob; each result is appended (and synced) to a journal as
  it finishes, so a rerun does not fetch it again. Public files are
  fetched without credentials. A private file (`/fileupload/`) is fetched
  with the token only when its host is the app's host (unverified against
  Bubble: how Bubble serves private files to an admin token has not been
  confirmed). A failure, a timeout or a crash fails that file only.

  **Retries.** 429 and 5xx answers and transport failures are retried with
  exponential backoff (or `Retry-After`), at most `:max_retries` times
  (default 3). 401 and 403 stop the export. `:max_calls` (default 100,000)
  bounds the requests of one call. Redirects are never followed: a
  redirect is an error naming the status (pass the app's final host).

  **Types.** By default every live data type (and User); `:types` narrows
  it. A type the Data API does not expose answers 404 and is recorded as
  failed; the loader refuses an export with a failed type unless told
  otherwise. Data API paths and keys come from `:names`
  (`BubbleEx.Verify.Replay.Names`, default `Names.from_model/1`: the
  display name lowercased without spaces, unverified against Bubble).
  """

  alias BubbleEx.{Error, HTTP, Model}
  alias BubbleEx.Load.{Export, Files, Scan, Secret}
  alias BubbleEx.Model.{DataType, Type}
  alias BubbleEx.Verify.Replay.Names

  @transient [429, 500, 502, 503, 504]

  @type option ::
          {:app_url, String.t()}
          | {:version, String.t()}
          | {:token, String.t()}
          | {:token_env, String.t()}
          | {:names, Names.t()}
          | {:types, [String.t()]}
          | {:files, boolean()}
          | {:page_size, pos_integer()}
          | {:max_calls, pos_integer()}
          | {:max_retries, non_neg_integer()}
          | {:retry_base_delay, non_neg_integer()}
          | {:file_concurrency, pos_integer()}
          | {:file_timeout, pos_integer()}
          | {:app_hosts, [String.t()]}
          | {:max_file_bytes, pos_integer()}
          | {:sleep, (non_neg_integer() -> any())}
          | {:now, DateTime.t()}
          | {:http, keyword()}

  @doc """
  Exports the data of `model`'s app to `dir` (see the moduledoc).

  Required: `:app_url` (`https://<host>`, the app's own host, no path) and
  `:version` (`"live"`, `"test"` or a branch's short ID). Returns the
  opened export. `:http` passes request options to every request (tests
  inject a `Req.Test` plug with it).
  """
  @spec export(Model.t(), Path.t(), [option()]) :: {:ok, Export.t()} | {:error, Error.t()}
  def export(%Model{} = model, dir, opts) do
    with {:ok, c} <- client(model, opts),
         :ok <- Export.prepare_dir(dir) do
      types = types(model, opts)

      with {:ok, state} <- read_state(dir, c),
           {:ok, state} <- export_types(c, dir, types, state),
           do: finish(c, dir, model, state, opts)
    end
  end

  # --- the client --------------------------------------------------------------------

  defp client(model, opts) do
    with {:ok, host, base} <- base_url(Keyword.get(opts, :app_url), Keyword.get(opts, :version)),
         {:ok, token} <- token(opts),
         {:ok, names} <- names(model, opts) do
      {:ok,
       %{
         host: host,
         base: base,
         source: String.replace_suffix(base, "/api/1.1/obj/", ""),
         app_hosts:
           Enum.uniq([host | Enum.map(Keyword.get(opts, :app_hosts, []), &String.downcase/1)]),
         token: token,
         names: names,
         page_size: min(Keyword.get(opts, :page_size, 100), 100),
         max_retries: Keyword.get(opts, :max_retries, 3),
         retry_base_delay: Keyword.get(opts, :retry_base_delay, 500),
         sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
         http: Keyword.get(opts, :http, []),
         calls: :counters.new(1, [:atomics]),
         max_calls: Keyword.get(opts, :max_calls, 100_000)
       }}
    end
  end

  defp base_url(url, version) when is_binary(url) and is_binary(version) do
    with {:ok,
          %URI{scheme: "https", host: host, path: path, query: nil, userinfo: nil, port: 443}}
         when is_binary(host) and host != "" and path in [nil, "", "/"] <- URI.new(url),
         {:ok, prefix} <- version_prefix(version) do
      {:ok, host, "https://#{host}#{prefix}/api/1.1/obj/"}
    else
      {:error, %Error{}} = error -> error
      _ -> invalid("app_url must be https://<the app's host>, with no path, query or credentials")
    end
  end

  defp base_url(_url, _version), do: invalid("app_url and version are required")

  defp version_prefix("live"), do: {:ok, ""}
  defp version_prefix("test"), do: {:ok, "/version-test"}

  defp version_prefix(branch) do
    if branch =~ ~r/\A[a-z0-9]{1,32}\z/,
      do: {:ok, "/version-" <> branch},
      else: invalid("version must be live, test or a branch's short ID")
  end

  defp token(opts) do
    env = Keyword.get(opts, :token_env, "BUBBLE_API_TOKEN")

    case Keyword.get(opts, :token) || System.get_env(env) do
      t when is_binary(t) and byte_size(t) >= 8 ->
        if String.match?(t, ~r/\A[\x21-\x7e]+\z/),
          do: {:ok, Secret.new(t)},
          else: invalid("the API token has invalid characters")

      _ ->
        invalid("an admin API token is required (the :token option or $#{env})")
    end
  end

  defp names(model, opts) do
    case Keyword.get(opts, :names) do
      %Names{} = names -> {:ok, names}
      nil -> Names.from_model(model)
      _ -> invalid("names must be BubbleEx.Verify.Replay.Names")
    end
  end

  defp invalid(message), do: {:error, Error.new(:invalid_input, message)}

  defp types(model, opts) do
    live =
      for %DataType{deleted: false, raw: nil} = t <- model.data_types, do: t.id

    case Keyword.get(opts, :types) do
      nil -> live
      list when is_list(list) -> Enum.filter(live, &(&1 in list))
    end
  end

  # --- state -----------------------------------------------------------------------------

  # An interrupted export resumes only from the same app and version.
  defp read_state(dir, c) do
    case File.read(Path.join(dir, "state.json")) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"source" => source} = state} when source == c.source ->
            {:ok, state}

          {:ok, %{"source" => _}} ->
            invalid("the directory holds an interrupted export of another app or version")

          _ ->
            invalid("the export state is unreadable")
        end

      {:error, :enoent} ->
        {:ok, %{"source" => c.source, "types" => %{}}}
    end
  end

  defp save_state(dir, state),
    do: Export.write_private!(Path.join(dir, "state.json"), Jason.encode!(state))

  # --- rows ------------------------------------------------------------------------------

  defp export_types(c, dir, types, state) do
    types
    |> Enum.reject(&(get_in(state, ["types", &1, "status"]) == "complete"))
    |> Enum.reduce_while({:ok, state}, fn type, {:ok, state} ->
      case export_type(c, dir, type, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:stop, error} -> {:halt, error}
      end
    end)
  end

  defp export_type(c, dir, type, state) do
    {:ok, path} = Names.type_path(c.names, Type.record(type))
    part = Path.join(dir, "rows/#{Export.object_name(type)}.part")
    progress = get_in(state, ["types", type]) || %{"cursor" => 0, "rows" => 0, "bytes" => 0}
    truncate(part, progress["bytes"])
    page(c, dir, type, path, part, progress, state)
  end

  # Drops what a crash wrote after the last recorded page.
  defp truncate(part, bytes) do
    case File.stat(part) do
      {:ok, %File.Stat{size: size}} when size > bytes ->
        {:ok, io} = :file.open(part, [:read, :write, :binary])
        {:ok, _} = :file.position(io, bytes)
        :ok = :file.truncate(io)
        :file.close(io)

      {:ok, _} ->
        :ok

      {:error, :enoent} ->
        File.write!(part, "")
        File.chmod!(part, 0o600)
    end
  end

  defp page(c, dir, type, path, part, progress, state) do
    url =
      c.base <>
        URI.encode(path, &URI.char_unreserved?/1) <>
        "?" <>
        URI.encode_query(%{
          "cursor" => progress["cursor"],
          "limit" => c.page_size,
          "sort_field" => "Created Date"
        })

    case get_json(c, url, :token) do
      {:ok, %{"response" => %{"results" => results} = response}} when is_list(results) ->
        {progress, state} = store_page(dir, type, path, part, progress, state, results)

        case {results, remaining(response)} do
          {[_ | _], :missing} -> failed(dir, type, path, state, "no_remaining")
          {[], _} -> complete(dir, type, path, part, progress, state)
          {_, 0} -> complete(dir, type, path, part, progress, state)
          _ -> page(c, dir, type, path, part, progress, state)
        end

      {:ok, _other} ->
        failed(dir, type, path, state, "unexpected_response")

      {:error, error} ->
        page_error(dir, type, path, state, error)
    end
  end

  # 401, 403 and an exhausted budget stop the export; other errors fail
  # the type (a rerun retries it).
  defp page_error(_dir, _type, _path, _state, %Error{kind: kind} = error)
       when kind in [:unauthorized, :forbidden],
       do: {:stop, {:error, error}}

  defp page_error(_dir, _type, _path, _state, %Error{context: %{reason: :budget_exhausted}} = e),
    do: {:stop, {:error, e}}

  defp page_error(dir, type, path, state, %Error{kind: :not_found}),
    do: failed(dir, type, path, state, "not_found")

  defp page_error(dir, type, path, state, %Error{context: context}),
    do: failed(dir, type, path, state, to_string(Map.get(context, :reason, "request_failed")))

  defp store_page(dir, type, path, part, progress, state, results) do
    append_synced(part, Enum.map(results, &[Jason.encode!(sanitize(&1)), "\n"]))

    progress = %{
      "status" => "running",
      "path" => path,
      "cursor" => progress["cursor"] + length(results),
      "rows" => progress["rows"] + length(results),
      "bytes" => File.stat!(part).size
    }

    state = put_in(state, ["types", type], progress)
    save_state(dir, state)
    {progress, state}
  end

  # Without `remaining` the end of the type is unknown: a non-empty page
  # without it fails the type rather than marking it complete.
  defp remaining(%{"remaining" => r}) when is_integer(r) and r >= 0, do: r
  defp remaining(_), do: :missing

  defp complete(dir, type, path, part, progress, state) do
    entry = Export.complete_type(dir, type, path, part, progress["rows"])
    state = put_in(state, ["types", type], Map.put(entry, "status", "complete"))
    save_state(dir, state)
    {:ok, state}
  end

  # Appends and syncs, so the state never records rows the disk lacks.
  defp append_synced(path, data) do
    {:ok, io} = :file.open(path, [:append, :raw, :binary])

    try do
      :ok = :file.write(io, data)
      :ok = :file.datasync(io)
    after
      :file.close(io)
    end
  end

  defp failed(dir, type, path, state, error) do
    progress =
      (get_in(state, ["types", type]) || %{"cursor" => 0, "rows" => 0, "bytes" => 0})
      |> Map.merge(%{"status" => "failed", "path" => path, "error" => error})

    state = put_in(state, ["types", type], progress)
    save_state(dir, state)
    {:ok, state}
  end

  # A user's `authentication` keeps the email, its confirmed status and
  # the names of other sign-in methods, nothing else.
  defp sanitize(%{"authentication" => %{} = auth} = row) do
    kept =
      Map.new(auth, fn
        {"email", %{} = e} -> {"email", Map.take(e, ["email", "email_confirmed"])}
        {provider, _} -> {provider, %{}}
      end)

    Map.put(row, "authentication", kept)
  end

  defp sanitize(%{"authentication" => _} = row), do: Map.delete(row, "authentication")
  defp sanitize(row), do: row

  # --- files -----------------------------------------------------------------------------------

  defp finish(c, dir, model, state, opts) do
    if Keyword.get(opts, :files, true), do: files(c, dir, model, state, opts)

    types =
      for {type, entry} <- Enum.sort(state["types"]) do
        case entry do
          %{"status" => "complete"} = e -> e
          e -> %{"type" => type, "path" => e["path"], "status" => "failed", "error" => e["error"]}
        end
      end

    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    entries = journal(dir)

    File.write!(
      Path.join(dir, "files.jsonl"),
      Enum.map(entries, &[BubbleEx.CanonicalJson.encode(&1), "\n"])
    )

    result =
      Export.finish(dir, %{
        app: model.bubble_id,
        model_sha256: Model.sha256(model),
        source: %{"kind" => "data_api", "base_url" => c.source},
        created_at: DateTime.to_iso8601(now),
        types: types,
        files: entries
      })

    File.rm(Path.join(dir, "state.json"))
    File.rm(journal_path(dir))
    result
  end

  # Fetched files, one entry per line, appended and synced as each file
  # finishes, so an interrupted export resumes without fetching them again
  # (a torn last line is ignored).
  defp journal_path(dir), do: Path.join(dir, "files.part.jsonl")

  defp journal(dir) do
    case File.read(journal_path(dir)) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&journal_entry/1)
        |> Enum.uniq_by(& &1["url"])

      {:error, _} ->
        []
    end
  end

  defp journal_entry(line) do
    case Jason.decode(line) do
      {:ok, %{"url" => _} = entry} -> [entry]
      _ -> []
    end
  end

  defp files(c, dir, model, state, opts) do
    done = dir |> journal() |> MapSet.new(& &1["url"])

    urls =
      state["types"]
      |> Enum.filter(fn {_t, e} -> e["status"] == "complete" end)
      |> Enum.flat_map(fn {type, e} -> file_urls(c, dir, model, type, e["object"]) end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(done, &1))
      |> Enum.sort()

    max = Keyword.get(opts, :max_file_bytes, 5_000_000_000)

    urls
    |> Task.async_stream(&fetch_file(c, dir, &1, max),
      max_concurrency: Keyword.get(opts, :file_concurrency, 8),
      timeout: Keyword.get(opts, :file_timeout, 600_000),
      on_timeout: :kill_task,
      ordered: true
    )
    |> Stream.zip(urls)
    |> Enum.each(fn {result, url} ->
      entry =
        case result do
          {:ok, entry} -> entry
          {:exit, :timeout} -> %{"url" => url, "status" => "failed", "error" => "timeout"}
          {:exit, _} -> %{"url" => url, "status" => "failed", "error" => "crashed"}
        end

      append_synced(journal_path(dir), [BubbleEx.CanonicalJson.encode(entry), "\n"])
    end)
  end

  # The Bubble file URLs in the file and image fields of a type's rows.
  defp file_urls(c, dir, model, type, object) do
    data_type = Model.data_type(model, type)
    keys = Scan.keys(data_type, %{})

    file_fields =
      for f <- data_type.system_fields ++ data_type.fields,
          f.type.kind == :file_ref,
          into: MapSet.new(),
          do: f.id

    Path.join(dir, object)
    |> File.stream!(:line, [:compressed])
    |> Stream.reject(&(&1 in ["", "\n"]))
    |> Stream.flat_map(fn line ->
      {fields, _, _, _} = line |> Jason.decode!() |> Scan.fields(keys)

      fields
      |> Map.take(MapSet.to_list(file_fields))
      |> Map.values()
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Files.normalize/1)
      |> Enum.filter(&Files.bubble?(&1, c.app_hosts))
    end)
    |> Enum.uniq()
  end

  # Streams the file to a temporary file in `files/`, hashing as it goes,
  # then renames it to its blob. Never raises: a failure is an entry.
  defp fetch_file(c, dir, url, max) do
    tmp =
      Path.join([
        dir,
        "files",
        ".fetch-" <> Integer.to_string(System.unique_integer([:positive]))
      ])

    try do
      fetch_to(c, dir, url, max, tmp)
    rescue
      _ -> failed_file(url, "crashed")
    catch
      _kind, _reason -> failed_file(url, "crashed")
    after
      File.rm(tmp)
    end
  end

  defp fetch_to(c, dir, url, max, tmp) do
    %URI{host: host} = URI.parse(url)
    # The token goes only to the app's own host, for its private files.
    auth = if Files.visibility(url) == :private and host == c.host, do: :token, else: :none
    {:ok, io} = :file.open(tmp, [:write, :read, :raw, :binary])
    File.chmod!(tmp, 0o600)

    # A fresh sink (the file emptied, a new hash) for every attempt.
    sink = fn ->
      {:ok, 0} = :file.position(io, 0)
      :ok = :file.truncate(io)
      [sink: {%{io: io, hash: :crypto.hash_init(:sha256), size: 0}, &write_chunk/2}]
    end

    result = request(c, url, auth, max, sink)
    :file.close(io)

    case result do
      {:ok, %HTTP.Response{status_code: 200, headers: headers, body: body}} ->
        stored(dir, url, tmp, sink_result(body, tmp), headers)

      {:ok, %HTTP.Response{status_code: status}} ->
        failed_file(url, "http_#{status}")

      {:error, %Error{context: context}} ->
        failed_file(url, to_string(Map.get(context, :reason, "request_failed")))
    end
  end

  defp write_chunk(data, %{io: io} = acc) do
    case :file.write(io, data) do
      :ok ->
        {:ok,
         %{acc | hash: :crypto.hash_update(acc.hash, data), size: acc.size + byte_size(data)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A body the sink never saw (an empty one) is written as is.
  defp sink_result(%{hash: hash, size: size}, _tmp),
    do: {Base.encode16(:crypto.hash_final(hash), case: :lower), size}

  defp sink_result(body, tmp) do
    body = IO.iodata_to_binary(body)
    File.write!(tmp, body)
    {Export.sha256_hex(body), byte_size(body)}
  end

  defp stored(dir, url, tmp, {sha, size}, headers) do
    case content_length(headers) do
      n when is_integer(n) and n != size ->
        failed_file(url, "length_mismatch")

      _ ->
        blob = Export.blob_path(dir, sha)
        if File.exists?(blob), do: File.rm(tmp), else: File.rename!(tmp, blob)
        Export.file_entry(url, sha, size, content_type(headers))
    end
  end

  defp failed_file(url, error), do: %{"url" => url, "status" => "failed", "error" => error}

  defp content_length(headers) do
    with v when v != nil <- header(headers, "content-length"),
         {n, ""} <- Integer.parse(v) do
      n
    else
      _ -> nil
    end
  end

  defp header(headers, name),
    do: Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: to_string(v) end)

  defp content_type(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == "content-type",
        do: v |> to_string() |> String.split(";") |> hd() |> String.trim()
    end)
  end

  # --- HTTP ------------------------------------------------------------------------------------

  defp get_json(c, url, auth) do
    case request(c, url, auth, 50_000_000, fn -> [] end) do
      {:ok, %HTTP.Response{status_code: 200, body: body}} ->
        case Jason.decode(IO.iodata_to_binary(body)) do
          {:ok, json} ->
            {:ok, json}

          {:error, _} ->
            {:error,
             Error.new(:parse_failed, "the Data API answered invalid JSON", %{
               reason: :invalid_json
             })}
        end

      {:ok, %HTTP.Response{status_code: status, body: body}} ->
        {:error, status_error(status, body)}

      {:error, _} = error ->
        error
    end
  end

  defp status_error(status, body) when status in 300..399,
    do:
      Error.new(
        :http_error,
        "the Data API redirected; redirects are not followed (pass the app's final host)",
        %{status: status, reason: :redirect_refused, bubble: bubble_code(body)}
      )

  defp status_error(status, body) do
    kind =
      case status do
        401 -> :unauthorized
        403 -> :forbidden
        404 -> :not_found
        _ -> :http_error
      end

    Error.new(kind, "the Data API answered #{status}", %{
      status: status,
      reason: :"http_#{status}",
      bubble: bubble_code(body)
    })
  end

  # Bubble error bodies carry a short code; keep only that.
  defp bubble_code(body) do
    with {:ok, %{} = json} <- Jason.decode(IO.iodata_to_binary(body)),
         code when is_binary(code) <- get_in(json, ["body", "status"]) || json["status"],
         true <- code =~ ~r/\A[A-Z_]{1,40}\z/ do
      code
    else
      _ -> nil
    end
  end

  # One GET with retries on 429, 5xx and transport failures.
  # One GET with retries on 429, 5xx and transport failures. `extra` gives
  # each attempt's own options (a fresh sink for a file).
  defp request(c, url, auth, max, extra_fun, n \\ 0) do
    if :counters.get(c.calls, 1) >= c.max_calls do
      {:error,
       Error.new(:request_failed, "the export's request budget is exhausted", %{
         reason: :budget_exhausted
       })}
    else
      :counters.add(c.calls, 1, 1)
      token = Secret.value(c.token)
      extra = extra_fun.()

      headers =
        [{"accept", "application/json, */*"}] ++
          if(auth == :token, do: [{"authorization", "Bearer " <> token}], else: [])

      # A file may take long; a Data API page may not.
      wall = if extra == [], do: 300_000, else: 3_600_000

      options =
        [
          follow_redirect: false,
          redact_values: [token],
          timeout: 10_000,
          recv_timeout: 60_000,
          max_body_length: max,
          bounded_body: true,
          deadline: System.monotonic_time(:millisecond) + wall
        ]
        |> Keyword.merge(extra)
        |> Keyword.merge(c.http)

      result = HTTP.request(:get, url, nil, headers, options)

      case retry(c, result, n) do
        nil ->
          normalize(result)

        delay ->
          c.sleep.(delay)
          request(c, url, auth, max, extra_fun, n + 1)
      end
    end
  end

  defp retry(c, result, n) do
    transient =
      case result do
        {:ok, %HTTP.Response{status_code: s}} -> s in @transient
        {:error, _} -> true
      end

    if transient and n < c.max_retries, do: backoff(c, result, n)
  end

  defp backoff(c, {:ok, %HTTP.Response{headers: headers}}, n) do
    Enum.find_value(headers, c.retry_base_delay * Integer.pow(2, n), fn {k, v} ->
      with "retry-after" <- String.downcase(k),
           {s, ""} when s >= 0 and s < 3600 <- Integer.parse(to_string(v)) do
        s * 1000
      else
        _ -> nil
      end
    end)
  end

  defp backoff(c, _result, n), do: c.retry_base_delay * Integer.pow(2, n)

  defp normalize({:ok, %HTTP.Response{}} = ok), do: ok

  defp normalize({:error, %HTTP.Error{reason: reason}}) do
    reason = if is_atom(reason), do: reason, else: :transport_failure
    {:error, Error.new(:request_failed, "the request failed", %{reason: reason})}
  end
end
