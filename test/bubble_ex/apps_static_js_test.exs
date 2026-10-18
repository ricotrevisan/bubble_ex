defmodule BubbleEx.AppsStaticJsTest do
  use ExUnit.Case, async: true
  alias BubbleEx.{Error, HTTP}
  alias Plug.Conn

  @origin "https://app.example"
  @static_body ~s|window.plugins["1x1"] = {"human":"Fixture plugin"};\n|
  @landing ~s(<script src="/package/static_js/abc/app/live/static.js"></script>) <>
             ~s(<script src="/package/dynamic_js/abc/app/live/dynamic.js"></script>)

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    :ok
  end

  test "include_static_js fetches the page's static.js beside the app" do
    stub(fn conn -> bubble_response(conn, @static_body) end)

    assert {:ok, %{valid?: true, static_js: @static_body} = attrs} =
             BubbleEx.fetch_app(@origin, include_static_js: true, max_retries: 0)

    refute Map.has_key?(attrs, :static_js_error)
    assert_received :static_requested
  end

  test "static.js is not fetched unless asked for" do
    stub(fn _conn -> flunk("static.js requested") end)

    assert {:ok, attrs} = BubbleEx.fetch_app(@origin, max_retries: 0)
    refute Map.has_key?(attrs, :static_js)
  end

  test "a static.js that fails to load leaves the app fetch successful" do
    stub(fn conn -> Conn.send_resp(conn, 404, "gone") end)

    assert {:ok,
            %{valid?: true, bubble_id: "static-app", static_js: nil, static_js_error: %Error{}}} =
             BubbleEx.fetch_app(@origin, include_static_js: true, max_retries: 0)
  end

  test "a page naming no static.js reports it as not found" do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path || "/" do
        "/" ->
          bubble_response(conn, ~s(<script src="/package/dynamic_js/abc/dynamic.js"></script>))

        _ ->
          bubble_response(conn, script_body())
      end
    end)

    assert {:ok,
            %{
              static_js: nil,
              static_js_error: %Error{
                kind: :parse_failed,
                context: %{phase: :discover_static_js, reason: :static_js_script_not_found}
              }
            }} = BubbleEx.fetch_app(@origin, include_static_js: true, max_retries: 0)
  end

  test "static.js is fetched with the app's credentials on its origin" do
    basic = "Basic " <> Base.encode64("fixture-user:fixture-password")

    stub(fn conn ->
      assert Conn.get_req_header(conn, "authorization") == [basic]
      bubble_response(conn, @static_body)
    end)

    assert {:ok, %{static_js: @static_body}} =
             BubbleEx.fetch_app(@origin,
               include_static_js: true,
               username: "fixture-user",
               password: "fixture-password",
               max_retries: 0
             )
  end

  defp stub(static_fun) do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path || "/" do
        "/" ->
          bubble_response(conn, @landing)

        "/package/dynamic_js/" <> _ ->
          bubble_response(conn, script_body())

        "/package/static_js/" <> _ ->
          send(self(), :static_requested)
          static_fun.(conn)
      end
    end)
  end

  defp bubble_response(conn, body),
    do: conn |> Conn.put_resp_header("x-bubble-app", "yes") |> Conn.send_resp(200, body)

  defp script_body, do: ~s|const app = JSON.parse('{"_id":"static-app"}');|
end
