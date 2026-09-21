defmodule BubbleEx.AppsCredentialsTest do
  use ExUnit.Case, async: true
  alias BubbleEx.HTTP
  alias Plug.Conn

  @origin "https://app.example"
  @basic "Basic " <> Base.encode64("fixture-user:fixture-password")
  @credentials [username: "fixture-user", password: "fixture-password", max_retries: 0]

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    :ok
  end

  test "same-origin discovered scripts retain original authentication" do
    stub_script("/package/dynamic_js", [@basic])
    assert {:ok, %{valid?: true}} = BubbleEx.fetch_app(@origin, @credentials)
    assert_received :script_requested
  end

  test "independent cross-origin and downgrade script fetches receive no credentials" do
    for script <- [
          "https://cdn.example/package/dynamic_js",
          "http://app.example/package/dynamic_js"
        ] do
      stub_script(script, [])
      assert {:ok, %{valid?: true}} = BubbleEx.fetch_app(@origin, @credentials)
      assert_received :script_requested
    end
  end

  test "a landing redirect cannot re-scope original credentials to its new origin's script" do
    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.host, conn.request_path || "/"} do
        {"app.example", "/"} ->
          assert Conn.get_req_header(conn, "authorization") == [@basic]

          conn
          |> Conn.put_resp_header("location", "https://cdn.example/")
          |> Conn.send_resp(302, "")

        {"cdn.example", "/"} ->
          assert Conn.get_req_header(conn, "authorization") == []
          bubble_response(conn, ~s(<script src="/package/dynamic_js"></script>))

        {"cdn.example", "/package/dynamic_js"} ->
          assert Conn.get_req_header(conn, "authorization") == []
          assert Conn.get_req_header(conn, "cookie") == []
          send(self(), :script_requested)
          bubble_response(conn, script_body())
      end
    end)

    assert {:ok, %{valid?: true}} = BubbleEx.fetch_app(@origin, @credentials)
    assert_received :script_requested
  end

  test "the shared credential scope strips Cookie and configured Req auth only off-origin" do
    # Apps exposes Basic credentials; exercise the common HTTP scope with Cookie
    # and Req auth too, so independent callers/default options cannot bypass it.
    HTTP.put_process_options(
      plug: {Req.Test, __MODULE__},
      auth: {:basic, "fixture-user:fixture-password"}
    )

    for {url, authorized?} <- [
          {@origin <> "/script", true},
          {"https://cdn.example/script", false},
          {"http://app.example/script", false}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        assert Conn.get_req_header(conn, "authorization") ==
                 if(authorized?, do: [@basic], else: [])

        assert Conn.get_req_header(conn, "cookie") ==
                 if(authorized?, do: ["fixture=session"], else: [])

        Conn.send_resp(conn, 200, "ok")
      end)

      assert {:ok, _} = HTTP.get(url, [{"cookie", "fixture=session"}], credential_origin: @origin)
    end
  end

  defp stub_script(script, expected_auth) do
    Req.Test.stub(__MODULE__, fn conn ->
      if conn.request_path in [nil, "/"] do
        assert Conn.get_req_header(conn, "authorization") == [@basic]
        bubble_response(conn, ~s(<script src="#{script}"></script>))
      else
        assert Conn.get_req_header(conn, "authorization") == expected_auth
        assert Conn.get_req_header(conn, "cookie") == []
        send(self(), :script_requested)
        bubble_response(conn, script_body())
      end
    end)
  end

  defp bubble_response(conn, body),
    do: conn |> Conn.put_resp_header("x-bubble-app", "yes") |> Conn.send_resp(200, body)

  defp script_body, do: ~s|const app = JSON.parse('{"_id":"credential-app"}');|
end
