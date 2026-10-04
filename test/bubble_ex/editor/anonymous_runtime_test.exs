defmodule BubbleEx.Editor.AnonymousRuntimeTest do
  use ExUnit.Case, async: false

  alias BubbleEx.Editor
  alias BubbleEx.Editor.Target
  alias BubbleEx.HTTP

  @unsafe_defaults [
    auth: {:basic, "private-user:private-password"},
    auth: {:bearer, "private-bearer"},
    aws_sigv4: [
      access_key_id: "private-key",
      secret_access_key: "private-secret",
      token: "private-token",
      service: :s3,
      region: "us-east-1"
    ],
    headers: [
      {"authorization", "Bearer private-header"},
      {"cookie", "private-cookie"},
      {"x-amz-security-token", "private-token"},
      {"x-api-key", "private-key"}
    ],
    params: [token: "private-param"],
    body: "private-body",
    json: %{secret: "private-json"},
    form: [secret: "private-form"],
    form_multipart: [secret: "private-multipart"]
  ]
  @safe_defaults [
    timeout: 1234,
    connect_options: [transport_opts: [versions: [:"tlsv1.2"]]]
  ]

  setup do
    previous = Application.fetch_env(:bubble_ex, :req_options)
    previous_req = Application.fetch_env(:req, :default_options)

    on_exit(fn ->
      restore_env(:bubble_ex, :req_options, previous)
      restore_env(:req, :default_options, previous_req)
    end)

    {:ok, target: elem(Target.readable("demo", "test", "editor-cookie"), 1)}
  end

  test "HTML and bundle GETs strip credentials and payloads from both default sources", %{
    target: target
  } do
    for source <- [:application, :process], {key, value} <- @unsafe_defaults do
      defaults = [{key, value} | @safe_defaults]

      Application.put_env(
        :bubble_ex,
        :req_options,
        if(source == :application, do: defaults, else: [])
      )

      assert_anonymous_discovery(target, if(source == :process, do: defaults, else: []))
    end
  end

  for {{key, value}, index} <- Enum.with_index(@unsafe_defaults) do
    test "HTML and bundle GETs ignore Req application default #{key} (#{index})", %{
      target: target
    } do
      Application.put_env(:req, :default_options, [unquote(Macro.escape({key, value}))])
      Application.put_env(:bubble_ex, :req_options, @safe_defaults)

      assert_anonymous_discovery(target)
    end
  end

  test "trusted Req.Test plug survives without inheriting Req credentials or adapters", %{
    target: target
  } do
    Application.put_env(:req, :default_options,
      auth: {:bearer, "private-bearer"},
      params: [token: "private-param"],
      json: %{secret: "private-json"},
      adapter: fn _ -> flunk("untrusted Req default adapter ran") end,
      plug: fn _ -> flunk("untrusted Req default plug ran") end
    )

    HTTP.put_process_options(plug: {Req.Test, __MODULE__})

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.query_string == ""
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      assert Plug.Conn.get_req_header(conn, "cookie") == []
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == ""
      send(self(), {:anonymous_get, conn.request_path})
      Req.Test.text(conn, runtime_body(conn.request_path))
    end)

    discover(target)
  end

  defp assert_anonymous_discovery(target, process_defaults \\ []) do
    adapter = fn request ->
      assert request.method == :get
      assert request.url.query == nil
      assert request.body in [nil, ""]

      for header <- ["authorization", "cookie", "x-amz-security-token", "x-api-key"] do
        assert Req.Request.get_header(request, header) == []
      end

      refute inspect(request.headers) =~ "private-"

      for option <- [:auth, :aws_sigv4, :params, :body, :json, :form, :form_multipart] do
        refute request.options[option]
      end

      transport = Req.Request.get_private(request, :bubble_ex_transport)
      assert transport[:timeout] == 1234
      assert transport[:connect_options][:transport_opts] == [versions: [:"tlsv1.2"]]
      send(self(), {:anonymous_get, request.url.path})
      {request, %Req.Response{status: 200, body: runtime_body(request.url.path)}}
    end

    HTTP.put_process_options([adapter: adapter] ++ process_defaults)
    discover(target)
  end

  defp discover(target) do
    assert {:ok, [_ref]} =
             Editor.discover_pages(target,
               post_fun: fn _, _, _, _ -> {:ok, %{"test" => %{}}} end
             )

    assert_received {:anonymous_get, "/version-test/index"}
    assert_received {:anonymous_get, "/package/dynamic_js/test/demo/index"}
  end

  defp runtime_body("/version-test/index"),
    do: "<script src='/package/dynamic_js/test/demo/index'></script>"

  defp runtime_body("/package/dynamic_js/test/demo/index") do
    app = %{"%p3" => %{"key" => %{"id" => "id", "%nm" => "index"}}}
    "const app = JSON.parse(#{Jason.encode!(Jason.encode!(app))});"
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
