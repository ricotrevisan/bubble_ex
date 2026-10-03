defmodule BubbleEx.Editor.IsolatedTransportTest do
  use ExUnit.Case, async: false

  alias BubbleEx.Editor
  alias BubbleEx.Editor.{Client, Target}
  alias BubbleEx.HTTP

  @unsafe_defaults [
    auth: {:basic, "ambient-user:ambient-password"},
    auth: {:bearer, "ambient-bearer"},
    aws_sigv4: [
      access_key_id: "ambient-key",
      secret_access_key: "ambient-secret",
      token: "ambient-token",
      service: :s3,
      region: "us-east-1"
    ],
    headers: [{"cookie", "ambient-cookie"}, {"x-api-key", "ambient-key"}],
    params: [secret: "ambient-param"],
    body: "ambient-body",
    json: %{secret: "ambient-json"},
    form: [secret: "ambient-form"],
    form_multipart: [secret: "ambient-multipart"]
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

  test "native POSTs preserve only deliberate credentials and body across all default scopes", %{
    target: target
  } do
    for source <- [:application, :process, :req_global], {key, value} <- @unsafe_defaults do
      Application.delete_env(:bubble_ex, :req_options)
      Application.delete_env(:req, :default_options)
      defaults = [{key, value}]

      case source do
        :application -> Application.put_env(:bubble_ex, :req_options, defaults)
        :process -> :ok
        :req_global -> Application.put_env(:req, :default_options, defaults)
      end

      Application.put_env(
        :bubble_ex,
        :req_options,
        Application.get_env(:bubble_ex, :req_options, []) ++
          [timeout: 1234, connect_options: [transport_opts: [versions: [:"tlsv1.2"]]]]
      )

      adapter = fn request ->
        assert request.method == :post
        assert request.url.query == nil
        assert Jason.decode!(request.body) == %{"appname" => "demo"}
        assert Req.Request.get_header(request, "cookie") == ["editor-cookie"]
        assert Req.Request.get_header(request, "content-type") == ["application/json"]
        assert Req.Request.get_header(request, "authorization") == []
        refute inspect(request.headers) =~ "ambient-"

        for option <- [:auth, :aws_sigv4, :params, :json, :form, :form_multipart] do
          refute request.options[option]
        end

        transport = Req.Request.get_private(request, :bubble_ex_transport)
        assert transport[:timeout] == 1234
        assert transport[:connect_options][:transport_opts] == [versions: [:"tlsv1.2"]]
        {request, %Req.Response{status: 200, body: ~s({"test":{}})}}
      end

      HTTP.put_process_options(
        [adapter: adapter] ++ if(source == :process, do: defaults, else: [])
      )

      assert {:ok, %{"test" => %{}}} = Editor.versions(target)
    end
  end

  test "native GETs ignore Req defaults/plugins while retaining deliberate cookie and query", %{
    target: target
  } do
    Application.put_env(:req, :default_options,
      auth: {:bearer, "ambient-bearer"},
      json: %{secret: "ambient-json"},
      params: [secret: "ambient-query"],
      plugins: [fn _request -> flunk("Req default plugin ran") end],
      adapter: fn _request -> flunk("Req default adapter ran") end
    )

    HTTP.put_process_options(
      adapter: fn request ->
        assert request.method == :get
        assert request.body in [nil, ""]

        assert URI.decode_query(request.url.query) == %{
                 "plugin_id" => "plugin",
                 "version" => "v1"
               }

        assert Req.Request.get_header(request, "cookie") == ["editor-cookie"]
        assert Req.Request.get_header(request, "authorization") == []
        {request, %Req.Response{status: 200, body: "{}"}}
      end
    )

    assert {:ok, %{}} = Client.plugin(target, "plugin", "v1")
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
