defmodule BubbleEx.LogsTest do
  use ExUnit.Case, async: false

  alias BubbleEx.Error
  alias BubbleEx.HTTP
  alias BubbleEx.Logs
  alias Plug.Conn

  @cookie "bubble_session=test"

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> HTTP.delete_process_options() end)
    :ok
  end

  defp stub(status, body) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Conn.put_resp_header("content-type", "application/json")
      |> Conn.resp(status, body)
    end)
  end

  describe "fetch_logs/2 success" do
    test "parses the \"rows\" response shape" do
      stub(200, Jason.encode!(%{"rows" => [%{"message" => "log entry"}], "total" => 1}))

      assert {:ok, %{logs: logs, total: 1, has_more: false}} =
               Logs.fetch_logs("example-app", cookie: @cookie, app_version: "live")

      assert [%{"message" => "log entry"}] = logs
    end

    test "parses the \"logs\" response shape" do
      body = Jason.encode!(%{"logs" => [%{"message" => "a"}, %{"message" => "b"}], "total" => 2})
      stub(200, body)

      assert {:ok, %{logs: logs, total: 2}} = Logs.fetch_logs("app", cookie: @cookie)
      assert length(logs) == 2
    end

    test "parses a bare list response" do
      stub(200, Jason.encode!([%{"message" => "x"}]))

      assert {:ok, %{logs: [_], total: 1, has_more: false}} =
               Logs.fetch_logs("app", cookie: @cookie)
    end

    test "sends the expected url, headers, and body" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/appeditor/get_jetstream_logs"
        assert {"cookie", @cookie} in conn.req_headers

        body = conn |> Req.Test.raw_body() |> IO.iodata_to_binary() |> Jason.decode!()
        assert body["tags"]["appname"] == "app"
        assert body["tags"]["app_version"] == "test"
        assert body["ascending"] == false

        conn
        |> Conn.put_resp_header("content-type", "application/json")
        |> Conn.resp(200, Jason.encode!(%{"logs" => []}))
      end)

      assert {:ok, _} =
               Logs.fetch_logs("app", cookie: @cookie, app_version: "test", ascending: false)
    end
  end

  describe "fetch_logs/2 errors" do
    test "missing cookie" do
      assert {:error, %Error{kind: :invalid_input, context: %{reason: :missing_cookie}}} =
               Logs.fetch_logs("app", [])
    end

    test "empty cookie" do
      assert {:error, %Error{kind: :invalid_input, context: %{reason: :empty_cookie}}} =
               Logs.fetch_logs("app", cookie: "")
    end

    test "non-string cookie" do
      assert {:error, %Error{kind: :invalid_input, context: %{reason: :invalid_cookie}}} =
               Logs.fetch_logs("app", cookie: 123)
    end

    test "401 maps to :unauthorized" do
      stub(401, "Unauthorized")
      assert {:error, %Error{kind: :unauthorized}} = Logs.fetch_logs("app", cookie: @cookie)
    end

    test "403 maps to :forbidden" do
      stub(403, "Forbidden")
      assert {:error, %Error{kind: :forbidden}} = Logs.fetch_logs("app", cookie: @cookie)
    end

    test "404 maps to :not_found" do
      stub(404, "Not Found")
      assert {:error, %Error{kind: :not_found}} = Logs.fetch_logs("app", cookie: @cookie)
    end

    test "500 maps to :http_error with the status in context" do
      stub(500, "Internal Server Error")

      assert {:error, %Error{kind: :http_error, context: %{status: 500}}} =
               Logs.fetch_logs("app", cookie: @cookie)
    end

    test "transport failure maps to :request_failed" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %Error{kind: :request_failed, context: %{reason: :timeout}}} =
               Logs.fetch_logs("app", cookie: @cookie)
    end

    test "invalid JSON maps to :parse_failed" do
      stub(200, "not json{")
      assert {:error, %Error{kind: :parse_failed}} = Logs.fetch_logs("app", cookie: @cookie)
    end
  end

  describe "group_and_flatten/1" do
    test "groups entries by fiber and process" do
      entries = [
        %{"tags" => %{"fiber_id" => "f1"}, "data" => %{"process_id" => "p1"}, "created" => 1},
        %{"tags" => %{"fiber_id" => "f1"}, "data" => %{"process_id" => "p1"}, "created" => 3}
      ]

      assert [%{fiber_id: "f1", process_id: "p1", entry_count: 2, time_span: 2}] =
               Logs.group_and_flatten(entries)
    end
  end

  describe "preset_filter/3" do
    test "errors preset" do
      filter = Logs.preset_filter(:errors, "test-app", "live")
      assert filter.appname == "test-app"
      assert "failed because of error" in filter.message
    end

    test "all preset has many message tags" do
      assert length(Logs.preset_filter(:all, "test-app").message) > 10
    end
  end

  describe "time_range/1" do
    test "last hour" do
      {after_time, before_time} = Logs.time_range(:last_hour)
      assert before_time - after_time == 60 * 60 * 1000
    end

    test "custom minutes" do
      {after_time, before_time} = Logs.time_range({:minutes, 30})
      assert before_time - after_time == 30 * 60 * 1000
    end
  end
end
