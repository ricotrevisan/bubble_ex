defmodule BubbleEx.Test.FakeBubble do
  @moduledoc false

  # An in-memory stand-in for one Bubble app's replay branch, served through
  # Req.Test (no network): the Data API (search with `_id in` constraints and
  # cursor paging, get, create, patch, delete), the Workflow API (the replay
  # kit's sign-up and login, plus an `echo_now` workflow), `/meta`, bearer
  # tokens and a small privacy model:
  #
  #   * task: visible to its creator and to users whose Admin is true;
  #     `Secret` only to its creator
  #   * user: visible to itself
  #   * workspace: visible to everyone
  #
  # Every request is logged. `script` queues canned responses
  # (`{method, path_suffix, status, headers}`) served before the real
  # handler, for 429/5xx tests. Owner records (`owner_records`) stand for
  # the owner's own development data the driver must never touch.

  alias Plug.Conn

  @app "acme"
  @branch "wtfreplay"
  @admin "admin-token-0123456789abcdef"

  def app, do: @app
  def branch, do: @branch
  def admin_token, do: @admin

  def start(opts \\ []) do
    state = %{
      records: %{},
      users: %{},
      tokens: %{},
      n: 0,
      clock: 1_760_000_000_000,
      log: [],
      script: Keyword.get(opts, :script, []),
      exposed: Keyword.get(opts, :exposed, ~w(task user workspace)),
      workflows:
        Keyword.get(opts, :workflows, ~w(wtf_replay_signup wtf_replay_login echo_now leaky)),
      meta: Keyword.get(opts, :meta, true)
    }

    {:ok, pid} = Agent.start_link(fn -> state end)

    for r <- Keyword.get(opts, :owner_records, []) do
      Agent.update(pid, fn s -> elem(insert(s, r.type, r.fields, nil), 1) end)
    end

    pid
  end

  def plug(pid), do: fn conn -> handle(pid, conn) end
  def log(pid), do: pid |> Agent.get(& &1.log) |> Enum.reverse()
  def records(pid), do: Agent.get(pid, & &1.records)

  defp handle(pid, conn) do
    conn = Conn.fetch_query_params(conn)
    {:ok, raw, conn} = Conn.read_body(conn)
    body = if raw == "", do: nil, else: Jason.decode!(raw)
    auth = conn |> Conn.get_req_header("authorization") |> List.first()

    entry = %{
      method: conn.method,
      host: conn.host,
      path: conn.request_path,
      query: conn.query_params,
      auth: auth,
      body: body
    }

    Agent.update(pid, &%{&1 | log: [entry | &1.log]})
    prefix = "/version-#{@branch}/api/1.1/"

    cond do
      conn.host != "#{@app}.bubbleapps.io" or not String.starts_with?(conn.request_path, prefix) ->
        json(conn, 599, %{"error" => "outside the replay branch"})

      (canned = pop_script(pid, conn.method, conn.request_path)) != nil ->
        {status, headers} = canned

        headers
        |> Enum.reduce(conn, fn {k, v}, c -> Conn.put_resp_header(c, k, v) end)
        |> json(status, %{"statusCode" => status, "body" => %{"status" => "TOO_MANY"}})

      true ->
        path = conn.request_path |> String.replace_prefix(prefix, "") |> String.split("/")
        dispatch(pid, conn, path, body, viewer(pid, auth))
    end
  end

  defp pop_script(pid, method, path) do
    Agent.get_and_update(pid, fn s ->
      {hits, rest} = Enum.split_with(s.script, &scripted?(&1, method, path))

      case hits do
        [{_, _, status, headers} | more] -> {{status, headers}, %{s | script: more ++ rest}}
        [] -> {nil, s}
      end
    end)
  end

  defp scripted?({m, suffix, _, _}, method, path),
    do: m == method and String.ends_with?(path, suffix)

  defp dispatch(pid, conn, ["wf", name] = path, body, viewer) do
    if name in Agent.get(pid, & &1.workflows),
      do: route(pid, conn, conn.method, path, body, viewer),
      else: json(conn, 404, %{"body" => %{"status" => "NOT_FOUND"}})
  end

  defp dispatch(pid, conn, path, body, viewer),
    do: route(pid, conn, conn.method, path, body, viewer)

  defp viewer(_pid, nil), do: :none
  defp viewer(_pid, "Bearer " <> @admin), do: :admin

  defp viewer(pid, "Bearer " <> token) do
    case Agent.get(pid, &Map.get(&1.tokens, token)) do
      nil -> :invalid
      id -> {:user, id}
    end
  end

  defp viewer(_pid, _), do: :invalid

  defp route(_pid, conn, _method, _path, _body, :invalid),
    do: json(conn, 401, %{"body" => %{"status" => "UNAUTHORIZED"}})

  defp route(pid, conn, "GET", ["meta"], _body, :admin) do
    s = Agent.get(pid, & &1)

    if s.meta,
      do: json(conn, 200, %{"get" => s.exposed, "post" => s.workflows}),
      else: json(conn, 200, %{})
  end

  defp route(pid, conn, "POST", ["wf", "wtf_replay_signup"], body, :admin) do
    id =
      Agent.get_and_update(pid, fn s ->
        {id, s} = insert(s, "user", %{"email" => body["email"]}, nil)
        {id, %{s | users: Map.put(s.users, body["email"], {id, body["password"]})}}
      end)

    json(conn, 200, %{"status" => "success", "response" => %{"user_id" => id}})
  end

  defp route(pid, conn, "POST", ["wf", "wtf_replay_login"], body, :admin) do
    password = body["password"]

    case Agent.get(pid, &Map.get(&1.users, body["email"])) do
      {id, ^password} ->
        token = "user-token-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
        Agent.update(pid, &%{&1 | tokens: Map.put(&1.tokens, token, id)})

        json(conn, 200, %{
          "status" => "success",
          "response" => %{"token" => token, "user_id" => id, "expires" => 3600}
        })

      _ ->
        json(conn, 400, %{"body" => %{"status" => "INVALID_LOGIN"}})
    end
  end

  defp route(pid, conn, "POST", ["wf", "echo_now"], body, _viewer) do
    now = Agent.get_and_update(pid, &{&1.clock, %{&1 | clock: &1.clock + 1000}})
    json(conn, 200, %{"status" => "success", "response" => %{"now" => now, "echo" => body}})
  end

  # A careless app workflow that echoes the caller's credentials.
  defp route(_pid, conn, "POST", ["wf", "leaky"], _body, _viewer) do
    header = conn |> Conn.get_req_header("authorization") |> List.first()
    json(conn, 200, %{"status" => "success", "response" => %{"note" => "seen #{header}"}})
  end

  defp route(pid, conn, "GET", ["obj", type], _body, viewer) do
    if exposed?(pid, type) do
      s = Agent.get(pid, & &1)
      constraints = Jason.decode!(conn.query_params["constraints"] || "[]")
      cursor = String.to_integer(conn.query_params["cursor"] || "0")
      limit = String.to_integer(conn.query_params["limit"] || "100")

      all =
        s.records
        |> Enum.filter(fn {id, r} ->
          r.type == type and matches?(id, constraints) and visible?(s, r, viewer)
        end)
        |> Enum.sort()
        |> Enum.map(fn {id, r} -> view(s, id, r, viewer) end)

      page = all |> Enum.drop(cursor) |> Enum.take(limit)

      json(conn, 200, %{
        "response" => %{
          "cursor" => cursor,
          "results" => page,
          "count" => length(page),
          "remaining" => max(length(all) - cursor - length(page), 0)
        }
      })
    else
      json(conn, 404, %{"body" => %{"status" => "NOT_FOUND"}})
    end
  end

  defp route(pid, conn, "GET", ["obj", type, id], _body, viewer) do
    s = Agent.get(pid, & &1)

    case s.records[id] do
      %{type: ^type} = r ->
        if visible?(s, r, viewer),
          do: json(conn, 200, %{"response" => view(s, id, r, viewer)}),
          else: json(conn, 404, %{"body" => %{"status" => "NOT_FOUND"}})

      _ ->
        json(conn, 404, %{"body" => %{"status" => "NOT_FOUND"}})
    end
  end

  defp route(pid, conn, "POST", ["obj", type], body, viewer) when viewer != :none do
    creator = with {:user, id} <- viewer, do: id
    creator = if creator == :admin, do: nil, else: creator
    id = Agent.get_and_update(pid, &insert(&1, type, body, creator))
    json(conn, 201, %{"status" => "success", "id" => id})
  end

  defp route(pid, conn, "PATCH", ["obj", type, id], body, :admin) do
    found =
      Agent.get_and_update(pid, fn s ->
        case s.records[id] do
          %{type: ^type} = r ->
            r = %{r | fields: Map.merge(r.fields, body), modified: s.clock}
            {true, %{s | records: Map.put(s.records, id, r), clock: s.clock + 1000}}

          _ ->
            {false, s}
        end
      end)

    if found, do: Conn.send_resp(conn, 204, ""), else: json(conn, 404, %{})
  end

  defp route(pid, conn, "DELETE", ["obj", type, id], _body, :admin) do
    found =
      Agent.get_and_update(pid, fn s ->
        case s.records[id] do
          %{type: ^type} -> {true, %{s | records: Map.delete(s.records, id)}}
          _ -> {false, s}
        end
      end)

    if found, do: Conn.send_resp(conn, 204, ""), else: json(conn, 404, %{})
  end

  defp route(_pid, conn, _method, _path, _body, _viewer),
    do: json(conn, 404, %{"body" => %{"status" => "NOT_FOUND"}})

  defp exposed?(pid, type), do: type in Agent.get(pid, & &1.exposed)

  defp insert(s, type, fields, creator) do
    n = s.n + 1
    id = "#{1_760_000_000_000 + n}x#{100_000_000 + n * 7}"
    r = %{type: type, fields: fields, creator: creator, created: s.clock, modified: s.clock}
    {id, %{s | n: n, clock: s.clock + 1000, records: Map.put(s.records, id, r)}}
  end

  defp matches?(id, constraints) do
    Enum.all?(constraints, fn
      %{"key" => "_id", "constraint_type" => "in", "value" => ids} -> id in ids
      _ -> true
    end)
  end

  defp visible?(_s, _r, :admin), do: true
  defp visible?(_s, %{type: "workspace"}, _viewer), do: true
  defp visible?(_s, %{type: "user"}, {:user, _id}), do: true
  defp visible?(_s, %{type: "user"}, _), do: false

  defp visible?(s, %{type: "task"} = r, {:user, id}),
    do: r.creator == id or get_in(s.records, [id, :fields, "Admin"]) == true

  defp visible?(_s, _r, _viewer), do: false

  defp view(_s, id, r, viewer) do
    hidden =
      case {r.type, viewer} do
        {"task", {:user, uid}} when uid != r.creator -> ["Secret"]
        _ -> []
      end

    r.fields
    |> Map.drop(hidden)
    |> Map.reject(fn {_k, v} -> v in [nil, [], ""] end)
    |> Map.merge(%{
      "_id" => id,
      "Created Date" => iso(r.created),
      "Modified Date" => iso(r.modified)
    })
    |> then(fn m -> if r.creator, do: Map.put(m, "Created By", r.creator), else: m end)
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp json(conn, status, body) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, Jason.encode!(body))
  end
end
