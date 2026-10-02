defmodule BubbleEx.Editor.Client do
  @moduledoc false

  alias BubbleEx.Editor.{Snapshot, Target}
  alias BubbleEx.{Error, HTTP}

  @type post_fun ::
          (String.t(), iodata(), HTTP.headers(), keyword() ->
             {:ok, map()} | {:error, Error.t()})

  @spec plugin(Target.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def plugin(target, id, version, opts \\ []) do
    with :ok <- Target.validate(target) do
      get_plugin(target, id, version, opts)
    end
  end

  defp get_plugin(target, id, version, opts) do
    query = URI.encode_query(%{"plugin_id" => id, "version" => version})
    url = target.origin <> "/appeditor/get_raw_plugin?" <> query
    get = Keyword.get(opts, :get_fun, &HTTP.get/3)

    case get.(
           url,
           [
             {"cookie", target.cookie},
             {"referer", target.origin <> "/"},
             {"origin", target.origin}
           ],
           request_options(target.cookie)
         ) do
      {:ok, %HTTP.Response{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _ -> {:error, Error.new(:parse_failed, "plugin definition is not a JSON object")}
        end

      {:ok, %HTTP.Response{status_code: status}} ->
        {:error,
         Error.new(:request_failed, "plugin definition request failed", %{status: status})}

      {:error, _error} ->
        {:error, Error.new(:request_failed, "plugin definition request failed")}
    end
  end

  @spec versions(Target.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def versions(%Target{} = target, opts \\ []) do
    post(target, "/appeditor/get_versions", %{"appname" => target.appname}, opts)
  end

  @spec resolve_child(Target.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def resolve_child(%Target{} = target, opts \\ []) do
    with :ok <- Target.validate_child(target),
         {:ok, version} <- resolve_readable(target, opts),
         :ok <- validate_version(version, target) do
      {:ok, version}
    end
  end

  @spec resolve_readable(Target.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def resolve_readable(%Target{} = target, opts \\ []) do
    with {:ok, versions} <- versions(target, opts),
         {:ok, version} <- fetch_version(versions, target.version),
         :ok <- validate_active(version) do
      {:ok, version}
    end
  end

  defp validate_active(%{"deleted" => deleted}) when deleted not in [nil, false],
    do: {:error, Error.new(:invalid_input, "editor app version is deleted or invalid")}

  defp validate_active(_version), do: :ok

  @spec read(Target.t(), [Snapshot.path()], keyword()) ::
          {:ok, Snapshot.t()} | {:error, Error.t()}
  def read(%Target{} = target, paths, opts \\ []) when is_list(paths) do
    with :ok <- validate_paths(paths),
         {:ok, response} <-
           post(
             target,
             "/appeditor/load_multiple_paths/#{target.appname}/#{target.version}",
             %{"path_arrays" => paths, "no_chunking" => true},
             opts
           ) do
      decode_snapshot(response, target, paths)
    end
  end

  @spec write(Target.t(), [map()], keyword()) :: {:ok, map()} | {:error, Error.t()}
  def write(target, changes, opts \\ [])

  def write(%Target{} = target, changes, opts) when is_list(changes) and changes != [] do
    body = %{
      "v" => 1,
      "appname" => target.appname,
      "app_version" => target.version,
      "changes" => changes
    }

    case resolve_child(target, opts) do
      {:ok, _version} -> post(target, "/appeditor/write", body, opts)
      {:error, %Error{} = error} -> mutation_refused(error)
    end
  end

  def write(_target, _changes, _opts),
    do: {:error, Error.new(:invalid_input, "a non-empty change list is required")}

  @spec restore_history(Target.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def restore_history(%Target{} = target, opts \\ []) do
    post(
      target,
      "/appeditor/get_restore_history",
      %{"appname" => target.appname, "app_version" => target.version},
      opts
    )
  end

  @spec create_savepoint(Target.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_savepoint(%Target{} = target, message, session_id, opts \\ []) do
    case resolve_child(target, opts) do
      {:ok, _version} -> post_savepoint(target, message, session_id, opts)
      {:error, %Error{} = error} -> mutation_refused(error)
    end
  end

  defp mutation_refused(error),
    do: {:error, %{error | context: Map.put(error.context, :write_submitted, false)}}

  defp post_savepoint(target, message, session_id, opts) do
    post(
      target,
      "/appeditor/commit_test_version",
      %{
        "appname" => target.appname,
        "app_version" => target.version,
        "message" => message,
        "session_id" => session_id
      },
      opts
    )
  end

  defp post(target, path, body, opts) do
    with :ok <- Target.validate(target) do
      do_post(target, path, body, opts)
    end
  end

  defp do_post(target, path, body, opts) do
    url = "https://bubble.io" <> path
    headers = [{"content-type", "application/json"}, {"cookie", target.cookie}]
    encoded = Jason.encode!(body)
    post_fun = Keyword.get(opts, :post_fun, &post_json/4)

    case post_fun.(url, encoded, headers, request_options(target.cookie)) do
      {:ok, response} when is_map(response) ->
        {:ok, response}

      {:ok, response} ->
        {:error,
         Error.new(:parse_failed, "editor response is not a JSON object", %{
           response_type: type_of(response)
         })}

      {:error, %Error{} = error} ->
        {:error, Error.new(error.kind, "editor request failed", safe_status(error.context))}

      {:error, _reason} ->
        {:error, Error.new(:request_failed, "editor request failed")}
    end
  end

  defp fetch_version(versions, version) do
    case Map.fetch(versions, version) do
      {:ok, record} when is_map(record) ->
        {:ok, record}

      _ ->
        {:error,
         Error.new(:not_found, "editor child app version was not found", %{version: version})}
    end
  end

  defp validate_version(%{"deleted" => true}, target),
    do:
      {:error,
       Error.new(:invalid_input, "editor child app version is deleted", %{version: target.version})}

  defp validate_version(%{"parent_version" => "test"}, _target), do: :ok

  defp validate_version(version, target) do
    {:error,
     Error.new(:invalid_input, "editor writes require a child app version parented by test", %{
       version: target.version,
       parent_version: if(Map.get(version, "parent_version") == "live", do: "live", else: nil),
       reason: :untrusted_branch_identity
     })}
  end

  defp validate_paths([]),
    do: {:error, Error.new(:invalid_input, "at least one editor path is required")}

  defp validate_paths(paths) do
    if Enum.all?(paths, fn path ->
         is_list(path) and path != [] and Enum.all?(path, &is_binary/1)
       end) do
      :ok
    else
      {:error, Error.new(:invalid_input, "editor paths must be non-empty string arrays")}
    end
  end

  defp decode_snapshot(%{"last_change" => last_change, "data" => data}, target, paths)
       when is_list(data) and length(data) == length(paths) do
    with {:ok, revision} <- parse_revision(last_change),
         {:ok, entries} <- build_entries(paths, data) do
      {:ok,
       %Snapshot{
         appname: target.appname,
         version: target.version,
         last_change: revision,
         entries: entries
       }}
    end
  end

  defp decode_snapshot(_response, _target, _paths),
    do: {:error, Error.new(:parse_failed, "editor read response has an unexpected shape")}

  defp parse_revision(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_revision(value) when is_binary(value) do
    case Integer.parse(value) do
      {revision, ""} when revision >= 0 -> {:ok, revision}
      _ -> {:error, Error.new(:parse_failed, "editor revision is invalid")}
    end
  end

  defp parse_revision(_value),
    do: {:error, Error.new(:parse_failed, "editor revision is invalid")}

  defp build_entries(paths, data) do
    entries =
      paths
      |> Enum.zip(data)
      |> Enum.reduce_while(%{}, fn
        {path, %{"data" => value}}, acc ->
          {:cont, Map.put(acc, Snapshot.key(path), %{path: path, value: value})}

        {_path, _entry}, _acc ->
          {:halt, :error}
      end)

    case entries do
      :error -> {:error, Error.new(:parse_failed, "editor path response omitted inline data")}
      map -> {:ok, map}
    end
  end

  defp request_options(cookie) do
    [
      retry: false,
      max_retries: 0,
      follow_redirect: false,
      redirect: false,
      auth: nil,
      decode_body: false,
      credential_origin: "https://bubble.io",
      bounded_body: true,
      max_body_length: BubbleEx.Config.apps_max_body_length([]),
      redact_values: [cookie]
    ]
  end

  # Decode locally: HTTP.post_json's errors retain upstream body/parser data.
  defp post_json(url, body, headers, opts) do
    case HTTP.post(url, body, headers, opts) do
      {:ok, %HTTP.Response{status_code: 200, body: response}} ->
        case Jason.decode(response) do
          {:ok, decoded} -> {:ok, decoded}
          _ -> {:error, Error.new(:parse_failed, "editor response is not valid JSON")}
        end

      {:ok, %HTTP.Response{status_code: status}} ->
        error = Error.from_http(status, nil)
        {:error, %{error | context: %{status: status}}}

      {:error, _error} ->
        {:error, Error.new(:request_failed, "editor request failed")}
    end
  end

  defp safe_status(%{status: status}) when is_integer(status) and status in 100..599,
    do: %{status: status}

  defp safe_status(_context), do: %{}

  defp type_of(value) when is_list(value), do: :list
  defp type_of(value) when is_binary(value), do: :string
  defp type_of(value) when is_number(value), do: :number
  defp type_of(value) when is_boolean(value), do: :boolean
  defp type_of(nil), do: :null
  defp type_of(_value), do: :other
end
