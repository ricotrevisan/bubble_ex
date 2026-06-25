defmodule BubbleEx.TelemetryTest do
  use ExUnit.Case, async: false

  alias BubbleEx.HTTP
  alias BubbleEx.Telemetry
  alias Plug.Conn

  setup do
    handler = {__MODULE__, System.unique_integer()}
    test_pid = self()

    :telemetry.attach_many(
      handler,
      [
        [:bubble_ex, :demo, :start],
        [:bubble_ex, :demo, :stop],
        [:bubble_ex, :demo, :exception]
      ],
      fn name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "span/3 emits start and stop with merged metadata and returns the result" do
    result = Telemetry.span([:demo], %{a: 1}, fn -> {:my_result, %{b: 2}} end)

    assert result == :my_result
    assert_received {:telemetry, [:bubble_ex, :demo, :start], %{system_time: _}, %{a: 1}}

    assert_received {:telemetry, [:bubble_ex, :demo, :stop], %{duration: _}, %{a: 1, b: 2}}
  end

  test "span/3 emits an exception event and re-raises" do
    assert_raise RuntimeError, "boom", fn ->
      Telemetry.span([:demo], %{a: 1}, fn -> raise "boom" end)
    end

    assert_received {:telemetry, [:bubble_ex, :demo, :exception], %{duration: _},
                     %{a: 1, kind: :error, reason: %RuntimeError{}}}
  end

  describe "HTTP request events" do
    setup do
      handler = {__MODULE__, :http, System.unique_integer()}
      test_pid = self()
      HTTP.put_process_options(plug: {Req.Test, __MODULE__})

      :telemetry.attach_many(
        handler,
        [[:bubble_ex, :http, :request, :start], [:bubble_ex, :http, :request, :stop]],
        fn name, m, meta, _ -> send(test_pid, {:telemetry, name, m, meta}) end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler)
        HTTP.delete_process_options()
      end)

      :ok
    end

    test "emits a request span with method, url, and status" do
      Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 200, "ok") end)

      assert {:ok, _} = HTTP.get("https://example.bubbleapps.io/")

      assert_received {:telemetry, [:bubble_ex, :http, :request, :start], _,
                       %{method: :get, url: "https://example.bubbleapps.io/"}}

      assert_received {:telemetry, [:bubble_ex, :http, :request, :stop], %{duration: _},
                       %{status: 200, error: nil}}
    end

    test "reports the error term on a transport failure" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, _} = HTTP.get("https://example.bubbleapps.io/", [], max_retries: 0)

      assert_received {:telemetry, [:bubble_ex, :http, :request, :stop], _,
                       %{status: nil, error: %HTTP.Error{}}}
    end
  end

  describe "fetch_app events" do
    alias BubbleEx.Apps

    @app_json ~S({"_id":"abacus","settings":{"client_safe":{"plugins":{}}}})

    setup do
      handler = {__MODULE__, :fetch, System.unique_integer()}
      test_pid = self()
      HTTP.put_process_options(plug: {Req.Test, __MODULE__})

      Req.Test.stub(__MODULE__, fn conn ->
        conn = Conn.put_resp_header(conn, "x-bubble-something", "1")
        path = conn.request_path || ""

        if String.contains?(path, "dynamic_js") do
          Conn.resp(conn, 200, "const app = JSON.parse('#{@app_json}');\n")
        else
          Conn.resp(conn, 200, "<html><script src='/package/dynamic_js/1/d.js'></script></html>")
        end
      end)

      :telemetry.attach_many(
        handler,
        [[:bubble_ex, :apps, :fetch_app, :stop]],
        fn name, m, meta, _ -> send(test_pid, {:telemetry, name, m, meta}) end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler)
        HTTP.delete_process_options()
      end)

      :ok
    end

    test "emits a fetch_app span with bubble_id and valid?" do
      assert {:ok, _} = Apps.fetch_app("abacus")

      assert_received {:telemetry, [:bubble_ex, :apps, :fetch_app, :stop], %{duration: _},
                       %{input: "abacus", bubble_id: "abacus", valid?: true, error: nil}}
    end
  end

  describe "secrets scan events" do
    alias BubbleEx.Secrets

    defmodule StubScanner do
      @behaviour BubbleEx.Secrets
      @impl true
      def scan(%{"_id" => "fail"}, _opts), do: {:error, BubbleEx.Error.new(:cli_failed, "x", %{})}
      def scan(_payload, _opts), do: {:ok, [%{"finding" => 1}, %{"finding" => 2}]}
    end

    setup do
      handler = {__MODULE__, :scan, System.unique_integer()}
      test_pid = self()

      :telemetry.attach_many(
        handler,
        [[:bubble_ex, :secrets, :scan, :stop]],
        fn name, m, meta, _ -> send(test_pid, {:telemetry, name, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "emits a scan span with adapter and finding_count" do
      assert {:ok, _} = Secrets.scan(%{"_id" => "ok"}, adapter: StubScanner)

      assert_received {:telemetry, [:bubble_ex, :secrets, :scan, :stop], %{duration: _},
                       %{adapter: StubScanner, finding_count: 2, error: nil}}
    end

    test "reports the error on a failed scan" do
      assert {:error, _} = Secrets.scan(%{"_id" => "fail"}, adapter: StubScanner)

      assert_received {:telemetry, [:bubble_ex, :secrets, :scan, :stop], _,
                       %{finding_count: 0, error: %BubbleEx.Error{}}}
    end
  end
end
