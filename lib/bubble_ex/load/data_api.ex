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
  the host and version, not the token).

  **Paging.** Each type is read in pages of up to 100, sorted by Created
  Date, following Bubble's cursor until `remaining` is 0. Pages are
  appended to a part file and the cursor recorded in `state.json` after
  each page, so an interrupted export resumes where it stopped (rerun the
  same call). The Data API does not snapshot: records created or changed
  during the export can shift pages, so a record may appear twice (the
  loader keeps the latest copy) or be missed. Export during a write freeze
  for the final load, and load again (a delta sync) at cutover.

  **Users.** A user's `authentication` keeps only the email, its confirmed
  status and the names of other sign-in methods (their contents are
  dropped). No password material exists in the Data API or the export.

  **Files.** After the rows, every Bubble file URL in a file or image field
  (`BubbleEx.Load.Files.bubble?/1`) is fetched once (`GET`, at most
  `:file_concurrency` at a time, default 8), checked against its
  `Content-Length`, hashed with SHA-256 and stored as a blob. Public files
  are fetched without credentials. A private file (`/fileupload/`) is
  fetched with the token only when its host is the app's host (unverified
  against Bubble: how Bubble serves private files to an admin token has
  not been confirmed); failures are recorded, not fatal.

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
  alias BubbleEx.Load.{Export, Files, Scan}
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
      state = read_state(dir)
      types = types(model, opts)

      with {:ok, state} <- export_types(c, dir, types, state),
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
          do: {:ok, t},
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

  defp read_state(dir) do
    case File.read(Path.join(dir, "state.json")) do
      {:ok, text} -> Jason.decode!(text)
      {:error, :enoent} -> %{"types" => %{}, "files" => []}
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
        lines = Enum.map(results, &[Jason.encode!(sanitize(&1)), "\n"])
        File.write!(part, lines, [:append])

        progress = %{
          "status" => "running",
          "path" => path,
          "cursor" => progress["cursor"] + length(results),
          "rows" => progress["rows"] + length(results),
          "bytes" => File.stat!(part).size
        }

        state = put_in(state, ["types", type], progress)
        save_state(dir, state)

        if results == [] or remaining(response) == 0 do
          entry = Export.complete_type(dir, type, path, part, progress["rows"])
          state = put_in(state, ["types", type], Map.put(entry, "status", "complete"))
          save_state(dir, state)
          {:ok, state}
        else
          page(c, dir, type, path, part, progress, state)
        end

      {:ok, _other} ->
        failed(dir, type, path, state, "unexpected_response")

      {:error, %Error{kind: kind} = error} when kind in [:unauthorized, :forbidden] ->
        {:stop, {:error, error}}

      {:error, %Error{context: %{reason: :budget_exhausted}} = error} ->
        {:stop, {:error, error}}

      {:error, %Error{kind: :not_found}} ->
        failed(dir, type, path, state, "not_found")

      {:error, %Error{context: context}} ->
        failed(dir, type, path, state, to_string(Map.get(context, :reason, "request_failed")))
    end
  end

  defp remaining(%{"remaining" => r}) when is_integer(r), do: r
  defp remaining(_), do: 0

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
    {:ok, state} =
      if Keyword.get(opts, :files, true),
        do: files(c, dir, model, state, opts),
        else: {:ok, state}

    types =
      for {type, entry} <- Enum.sort(state["types"]) do
        case entry do
          %{"status" => "complete"} = e -> e
          e -> %{"type" => type, "path" => e["path"], "status" => "failed", "error" => e["error"]}
        end
      end

    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    entries = state["files"]

    File.write!(
      Path.join(dir, "files.jsonl"),
      Enum.map(entries, &[BubbleEx.CanonicalJson.encode(&1), "\n"])
    )

    result =
      Export.finish(dir, %{
        app: model.bubble_id,
        model_sha256: Model.sha256(model),
        source: %{
          "kind" => "data_api",
          "base_url" => String.trim_trailing(c.base, "/api/1.1/obj/")
        },
        created_at: DateTime.to_iso8601(now),
        types: types,
        files: entries
      })

    File.rm(Path.join(dir, "state.json"))
    result
  end

  defp files(c, dir, model, state, opts) do
    done = MapSet.new(state["files"], & &1["url"])

    urls =
      state["types"]
      |> Enum.filter(fn {_t, e} -> e["status"] == "complete" end)
      |> Enum.flat_map(fn {type, e} -> file_urls(dir, model, type, e["object"]) end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(done, &1))
      |> Enum.sort()

    max = Keyword.get(opts, :max_file_bytes, 100_000_000)

    entries =
      urls
      |> Task.async_stream(&fetch_file(c, dir, &1, max),
        max_concurrency: Keyword.get(opts, :file_concurrency, 8),
        timeout: 600_000,
        ordered: true
      )
      |> Enum.zip(urls)
      |> Enum.map(fn
        {{:ok, entry}, _url} -> entry
        {{:exit, _}, url} -> %{"url" => url, "status" => "failed", "error" => "crashed"}
      end)

    state = Map.update!(state, "files", &(&1 ++ entries))
    save_state(dir, state)
    {:ok, state}
  end

  # The Bubble file URLs in the file and image fields of a type's rows.
  defp file_urls(dir, model, type, object) do
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
      {fields, _, _} = line |> Jason.decode!() |> Scan.fields(keys)

      fields
      |> Map.take(MapSet.to_list(file_fields))
      |> Map.values()
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Files.normalize/1)
      |> Enum.filter(&Files.bubble?/1)
    end)
    |> Enum.uniq()
  end

  defp fetch_file(c, dir, url, max) do
    %URI{host: host} = URI.parse(url)
    # The token goes only to the app's own host, for its private files.
    auth = if Files.visibility(url) == :private and host == c.host, do: :token, else: :none

    case get(c, url, auth, max) do
      {:ok, %HTTP.Response{status_code: 200, headers: headers, body: body}} ->
        body = IO.iodata_to_binary(body)

        case content_length(headers) do
          n when is_integer(n) and n != byte_size(body) ->
            %{"url" => url, "status" => "failed", "error" => "length_mismatch"}

          _ ->
            sha = Export.put_blob(dir, body)
            Export.file_entry(url, sha, byte_size(body), content_type(headers))
        end

      {:ok, %HTTP.Response{status_code: status}} ->
        %{"url" => url, "status" => "failed", "error" => "http_#{status}"}

      {:error, %Error{context: context}} ->
        %{
          "url" => url,
          "status" => "failed",
          "error" => to_string(Map.get(context, :reason, "request_failed"))
        }
    end
  end

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
    case get(c, url, auth, 50_000_000) do
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
  defp get(c, url, auth, max, n \\ 0) do
    if :counters.get(c.calls, 1) >= c.max_calls do
      {:error,
       Error.new(:request_failed, "the export's request budget is exhausted", %{
         reason: :budget_exhausted
       })}
    else
      :counters.add(c.calls, 1, 1)

      headers =
        [{"accept", "application/json, */*"}] ++
          if(auth == :token, do: [{"authorization", "Bearer " <> c.token}], else: [])

      result =
        HTTP.request(
          :get,
          url,
          nil,
          headers,
          Keyword.merge(
            [
              follow_redirect: false,
              redact_values: [c.token],
              timeout: 10_000,
              recv_timeout: 60_000,
              max_body_length: max,
              bounded_body: true,
              deadline: System.monotonic_time(:millisecond) + 300_000
            ],
            c.http
          )
        )

      case retry(c, result, n) do
        nil ->
          normalize(result)

        delay ->
          c.sleep.(delay)
          get(c, url, auth, max, n + 1)
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
