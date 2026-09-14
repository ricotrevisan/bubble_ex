defmodule BubbleEx.Editor.Client do
  @moduledoc false

  alias BubbleEx.Editor.{Snapshot, Target}
  alias BubbleEx.{Error, HTTP}

  @type post_fun ::
          (String.t(), iodata(), HTTP.headers(), keyword() ->
             {:ok, map()} | {:error, Error.t()})

  @spec versions(Target.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def versions(%Target{} = target, opts \\ []) do
    post(target, "/appeditor/get_versions", %{"appname" => target.appname}, opts)
  end

  @spec resolve_child(Target.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def resolve_child(%Target{} = target, opts \\ []) do
    with {:ok, versions} <- versions(target, opts),
         {:ok, version} <- fetch_version(versions, target.version),
         :ok <- validate_version(version, target) do
      {:ok, version}
    end
  end

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

    post(target, "/appeditor/write", body, Keyword.put(opts, :write?, true))
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
    post(
      target,
      "/appeditor/commit_test_version",
      %{
        "appname" => target.appname,
        "app_version" => target.version,
        "message" => message,
        "session_id" => session_id
      },
      Keyword.put(opts, :write?, true)
    )
  end

  defp post(target, path, body, opts) do
    url = target.origin <> path
    headers = [{"content-type", "application/json"}, {"cookie", target.cookie}]
    encoded = Jason.encode!(body)
    request_opts = [max_retries: 0, redact_values: [target.cookie]]
    post_fun = Keyword.get(opts, :post_fun, &HTTP.post_json/4)

    case post_fun.(url, encoded, headers, request_opts) do
      {:ok, response} when is_map(response) ->
        {:ok, response}

      {:ok, response} ->
        {:error,
         Error.new(:parse_failed, "editor response is not a JSON object", %{
           url: url,
           response_type: type_of(response)
         })}

      {:error, %Error{} = error} ->
        {:error, redact_error(error, target.cookie)}

      {:error, reason} ->
        {:error,
         Error.new(:request_failed, "editor request failed", %{url: url, reason: inspect(reason)})}
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
       parent_version: Map.get(version, "parent_version"),
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

  defp redact_error(%Error{} = error, cookie) do
    text = fn value -> String.replace(to_string(value), cookie, "[REDACTED]") end
    %{error | message: text.(error.message), context: redact_term(error.context, cookie)}
  end

  defp redact_term(value, secret) when is_binary(value),
    do: String.replace(value, secret, "[REDACTED]")

  defp redact_term(value, secret) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, redact_term(v, secret)} end)

  defp redact_term(value, secret) when is_list(value),
    do: Enum.map(value, &redact_term(&1, secret))

  defp redact_term(value, _secret), do: value

  defp type_of(value) when is_list(value), do: :list
  defp type_of(value) when is_binary(value), do: :string
  defp type_of(value) when is_number(value), do: :number
  defp type_of(value) when is_boolean(value), do: :boolean
  defp type_of(nil), do: :null
  defp type_of(_value), do: :other
end
