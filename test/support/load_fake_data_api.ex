defmodule BubbleEx.Test.LoadFakeDataApi do
  @moduledoc false

  # An in-memory Bubble Data API (GET /version-test/api/1.1/obj/<path>
  # with cursor paging) and file storage, served through Req.Test: no
  # request leaves the VM. Records every request (method, host, path,
  # authorization) so tests can assert the exporter only reads and sends
  # the token only to the app's host.
  #
  # Options: `rows` (%{path => [row]}), `files` (%{url => %{body,
  # content_type} | status}), `token`, `script` ([{path_prefix, status}]
  # answered once each before the real handler).

  alias Plug.Conn

  @host "acme.bubbleapps.io"
  @token "fake-admin-token-0123456789"

  def host, do: @host
  def token, do: @token

  def start(opts) do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          rows: Keyword.get(opts, :rows, %{}),
          files: Keyword.get(opts, :files, %{}),
          token: Keyword.get(opts, :token, @token),
          script: Keyword.get(opts, :script, []),
          log: []
        }
      end)

    pid
  end

  def plug(pid), do: fn conn -> handle(pid, conn) end
  def log(pid), do: pid |> Agent.get(& &1.log) |> Enum.reverse()

  defp handle(pid, conn) do
    conn = Conn.fetch_query_params(conn)
    auth = conn |> Conn.get_req_header("authorization") |> List.first()

    Agent.update(pid, fn s ->
      entry = %{
        method: conn.method,
        host: conn.host,
        path: conn.request_path,
        query: conn.query_params,
        auth: auth
      }

      %{s | log: [entry | s.log]}
    end)

    state = Agent.get(pid, & &1)
    url = "https://#{conn.host}#{conn.request_path}"

    cond do
      conn.method != "GET" ->
        json(conn, 405, %{"status" => "METHOD"})

      canned = pop_script(pid, conn.request_path) ->
        json(conn, canned, %{"statusCode" => canned, "body" => %{"status" => "SCRIPTED"}})

      conn.host == @host and String.starts_with?(conn.request_path, "/version-test/api/1.1/obj/") ->
        data_api(conn, state, auth)

      Map.has_key?(state.files, url) ->
        file(conn, Map.fetch!(state.files, url), state, auth)

      true ->
        json(conn, 404, %{"status" => "NOT_FOUND"})
    end
  end

  defp pop_script(pid, path) do
    Agent.get_and_update(pid, &pop(&1, path))
  end

  defp pop(s, path) do
    case Enum.split_with(s.script, fn {prefix, _} -> String.starts_with?(path, prefix) end) do
      {[{_, status} | more], rest} -> {status, %{s | script: more ++ rest}}
      {[], _} -> {nil, s}
    end
  end

  defp data_api(conn, state, auth) do
    path = String.replace_prefix(conn.request_path, "/version-test/api/1.1/obj/", "")

    cond do
      auth != "Bearer " <> state.token ->
        json(conn, 401, %{"body" => %{"status" => "UNAUTHORIZED"}})

      not Map.has_key?(state.rows, path) ->
        json(conn, 404, %{"statusCode" => 404, "body" => %{"status" => "NOT_FOUND"}})

      true ->
        rows = Map.fetch!(state.rows, path)
        cursor = String.to_integer(conn.query_params["cursor"] || "0")
        limit = String.to_integer(conn.query_params["limit"] || "100")
        page = rows |> Enum.drop(cursor) |> Enum.take(limit)

        json(conn, 200, %{
          "response" => %{
            "cursor" => cursor,
            "results" => page,
            "count" => length(page),
            "remaining" => max(length(rows) - cursor - length(page), 0)
          }
        })
    end
  end

  defp file(conn, status, _state, _auth) when is_integer(status),
    do: Conn.send_resp(conn, status, "")

  defp file(conn, %{private: true} = f, state, auth) do
    if auth == "Bearer " <> state.token,
      do: send_file(conn, f),
      else: Conn.send_resp(conn, 401, "")
  end

  defp file(conn, f, _state, _auth), do: send_file(conn, f)

  defp send_file(conn, f) do
    conn
    |> Conn.put_resp_header("content-type", Map.get(f, :content_type, "application/octet-stream"))
    |> then(fn c ->
      case Map.get(f, :content_length) do
        nil -> c
        n -> Conn.put_resp_header(c, "content-length", Integer.to_string(n))
      end
    end)
    |> Conn.send_resp(200, f.body)
  end

  defp json(conn, status, body) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, Jason.encode!(body))
  end
end
