defmodule BubbleEx.Editor.AnonymousRuntimeTest do
  use ExUnit.Case, async: false

  alias BubbleEx.Editor
  alias BubbleEx.Editor.Target
  alias BubbleEx.HTTP

  setup do
    previous = Application.fetch_env(:bubble_ex, :req_options)

    on_exit(fn ->
      case previous do
        {:ok, options} -> Application.put_env(:bubble_ex, :req_options, options)
        :error -> Application.delete_env(:bubble_ex, :req_options)
      end
    end)

    {:ok, target: elem(Target.readable("demo", "test", "editor-cookie"), 1)}
  end

  test "HTML and bundle GETs strip credentials and payloads from both default sources", %{
    target: target
  } do
    unsafe = [
      auth: {:basic, "private-user:private-password"},
      aws_sigv4: [
        access_key_id: "private-key",
        secret_access_key: "private-secret",
        token: "private-token",
        service: :s3,
        region: "us-east-1"
      ],
      headers: [{"x-amz-security-token", "private-token"}, {"x-api-key", "private-key"}],
      params: [token: "private-param"],
      body: "private-body",
      json: %{secret: "private-json"},
      form: [secret: "private-form"],
      form_multipart: [secret: "private-multipart"]
    ]

    for source <- [:application, :process], {key, value} <- unsafe do
      adapter = fn request ->
        assert request.method == :get
        assert request.url.query == nil
        assert request.body in [nil, ""]

        for header <- ["authorization", "cookie", "x-amz-security-token", "x-api-key"] do
          assert Req.Request.get_header(request, header) == []
        end

        for option <- [:auth, :aws_sigv4, :params, :body, :json, :form, :form_multipart] do
          refute request.options[option]
        end

        transport = Req.Request.get_private(request, :bubble_ex_transport)
        assert transport[:timeout] == 1234
        assert transport[:connect_options][:transport_opts] == [versions: [:"tlsv1.2"]]
        send(self(), {:anonymous_get, request.url.path})

        body =
          case request.url.path do
            "/version-test/index" ->
              "<script src='/package/dynamic_js/test/demo/index'></script>"

            "/package/dynamic_js/test/demo/index" ->
              app = %{"%p3" => %{"key" => %{"id" => "id", "%nm" => "index"}}}
              "const app = JSON.parse(#{Jason.encode!(Jason.encode!(app))});"
          end

        {request, %Req.Response{status: 200, body: body}}
      end

      defaults = [
        {key, value},
        {:timeout, 1234},
        {:connect_options, [transport_opts: [versions: [:"tlsv1.2"]]]}
      ]

      Application.put_env(
        :bubble_ex,
        :req_options,
        if(source == :application, do: defaults, else: [])
      )

      HTTP.put_process_options(
        [adapter: adapter] ++ if(source == :process, do: defaults, else: [])
      )

      assert {:ok, [_ref]} =
               Editor.discover_pages(target,
                 post_fun: fn _, _, _, _ -> {:ok, %{"test" => %{}}} end
               )

      assert_received {:anonymous_get, "/version-test/index"}
      assert_received {:anonymous_get, "/package/dynamic_js/test/demo/index"}
    end
  end
end
