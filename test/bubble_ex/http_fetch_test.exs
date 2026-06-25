defmodule BubbleEx.HTTPFetchTest do
  @moduledoc """
  Offline tests for the high-level Bubble fetch helpers on BubbleEx.HTTP, using
  Req.Test plug stubs (no network). These functions return the unified
  BubbleEx.Error type.
  """
  use ExUnit.Case, async: false

  alias BubbleEx.Error
  alias BubbleEx.HTTP
  alias Plug.Conn

  @url "https://example.bubbleapps.io/"

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> HTTP.delete_process_options() end)
    :ok
  end

  describe "fetch_page/2" do
    test "returns page data on 200 with an x-bubble header" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Conn.put_resp_header("x-bubble-something", "1")
        |> Conn.put_resp_header(
          "set-cookie",
          "app123_live_xyz=val; domain=.bubbleapps.io; path=/"
        )
        |> Conn.resp(200, "<html>hi</html>")
      end)

      assert {:ok, page} = HTTP.fetch_page(@url)
      assert page.body == "<html>hi</html>"
      assert page.domain == ".bubbleapps.io"
      assert page.bubble_id == "app123"
    end

    test "returns :not_a_bubble_app on 200 without an x-bubble header" do
      Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 200, "<html>nope</html>") end)

      assert {:error, %Error{kind: :not_a_bubble_app}} = HTTP.fetch_page(@url)
    end

    test "returns :unauthorized on 401" do
      Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 401, "no") end)

      assert {:error, %Error{kind: :unauthorized, context: %{status: 401}}} =
               HTTP.fetch_page(@url)
    end

    test "returns :request_failed on a transport error" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %Error{kind: :request_failed}} =
               HTTP.fetch_page(@url, max_retries: 0)
    end

    test "retries a transient 503 and then succeeds" do
      Req.Test.expect(__MODULE__, fn conn -> Conn.resp(conn, 503, "busy") end)

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Conn.put_resp_header("x-bubble-something", "1")
        |> Conn.resp(200, "ok")
      end)

      assert {:ok, page} = HTTP.fetch_page(@url, retry_base_delay: 1)
      assert page.body == "ok"
      Req.Test.verify!(__MODULE__)
    end
  end

  describe "fetch_json/2" do
    test "decodes JSON and unwraps the response envelope" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "application/json")
        |> Conn.resp(200, Jason.encode!(%{"response" => %{"a" => 1}}))
      end)

      assert {:ok, %{"a" => 1}} = HTTP.fetch_json(@url)
    end

    test "returns :parse_failed on invalid JSON" do
      Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 200, "not json{") end)

      assert {:error, %Error{kind: :parse_failed}} = HTTP.fetch_json(@url)
    end

    test "returns an http error kind on non-200" do
      Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 404, "missing") end)

      assert {:error, %Error{kind: :not_found}} = HTTP.fetch_json(@url)
    end
  end

  describe "check_redirect/2" do
    test "reports a redirect when the server returns 3xx with a location" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Conn.put_resp_header("location", "https://elsewhere.example/")
        |> Conn.resp(301, "")
      end)

      assert {:ok, %{is_redirect: true, location: "https://elsewhere.example/"}} =
               HTTP.check_redirect("example", "live")
    end

    test "reports no redirect on 200" do
      Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 200, "") end)

      assert {:ok, %{is_redirect: false}} = HTTP.check_redirect("example", "live")
    end
  end

  describe "finch option passthrough" do
    test "resolve_finch/1 prefers the option, falls back to nil" do
      assert HTTP.resolve_finch(finch: MyApp.Finch) == MyApp.Finch
      assert HTTP.resolve_finch([]) == nil
    end

    test "high-level helpers carry a per-call :finch through build_http_options/1" do
      assert HTTP.build_http_options(finch: MyApp.Finch)[:finch] == MyApp.Finch
      refute Keyword.has_key?(HTTP.build_http_options([]), :finch)
    end
  end
end
