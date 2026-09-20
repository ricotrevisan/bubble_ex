defmodule BubbleEx.HTTPBudgetTest do
  use ExUnit.Case, async: true

  test "rejected redirect bodies never reach their destination" do
    for status <- [302, 307],
        {reason, headers, delay, opts} <- [
          {:body_too_large, "", 0, [max_body_length: 4]},
          {:unsupported_content_encoding, "Content-Encoding: gzip\r\n", 0, []},
          {:total_timeout, "", 100, [total_timeout: 50, recv_timeout: 500]}
        ] do
      {listener, port} = listen()
      {destination, destination_port} = listen()
      parent = self()
      marker = make_ref()

      target =
        Task.async(fn ->
          case :gen_tcp.accept(destination, 300) do
            {:ok, socket} ->
              send(parent, {:destination_requested, marker})
              {:ok, _} = :gen_tcp.recv(socket, 0, 1000)

              :gen_tcp.send(
                socket,
                "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nx-bubble-app: yes\r\n\r\nok"
              )

              :gen_tcp.close(socket)

            {:error, :timeout} ->
              :ok
          end
        end)

      source =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 1000)
          {:ok, _} = :gen_tcp.recv(socket, 0, 1000)

          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} Redirect\r\nLocation: http://127.0.0.1:#{destination_port}/\r\nContent-Length: 8\r\n#{headers}\r\n"
          )

          for chunk <- ["re", "je", "ct", "ed"] do
            Process.sleep(div(delay, 4))
            :gen_tcp.send(socket, chunk)
          end

          :gen_tcp.close(socket)
        end)

      result = BubbleEx.HTTP.fetch_page("http://127.0.0.1:#{port}/", opts ++ [max_retries: 0])
      Task.await(source)
      Task.await(target)
      refute_received {:destination_requested, ^marker}

      assert {:error, %BubbleEx.Error{kind: :request_failed, context: %{reason: ^reason}}} =
               result
    end
  end

  defp listen do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    {listener, port}
  end

  test "dedicated instance checks preserve transport and resource failures" do
    BubbleEx.HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> BubbleEx.HTTP.delete_process_options() end)

    for reason <- [:body_too_large, :unsupported_content_encoding, :timeout] do
      Req.Test.stub(__MODULE__, fn conn ->
        case reason do
          :body_too_large ->
            Plug.Conn.send_resp(conn, 200, String.duplicate("x", 5_000_001))

          :unsupported_content_encoding ->
            conn
            |> Plug.Conn.put_resp_header("content-encoding", "gzip")
            |> Plug.Conn.send_resp(200, "encoded")

          transport ->
            Req.Test.transport_error(conn, transport)
        end
      end)

      assert {:error, %BubbleEx.Error{kind: :request_failed, context: %{reason: ^reason}}} =
               BubbleEx.HTTP.check_redirect("valid-app", "live")

      assert {:error, %BubbleEx.Error{kind: :request_failed, context: %{reason: ^reason}}} =
               BubbleEx.Apps.dedicated?("valid-app", "live")
    end
  end

  test "GET and POST JSON reject oversized streams before JSON decoding" do
    for method <- [:get, :post] do
      {listener, port} = listen()
      parent = self()

      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 2000)
          {:ok, _} = :gen_tcp.recv(socket, 0, 2000)

          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n12345\r\n"
          )

          send(parent, {:json_closed, :gen_tcp.recv(socket, 0, 2000)})
          :gen_tcp.close(socket)
        end)

      url = "http://127.0.0.1:#{port}/"

      result =
        case method do
          :get -> BubbleEx.HTTP.fetch_json(url, max_body_length: 4)
          :post -> BubbleEx.HTTP.post_json(url, "{}", [], max_body_length: 4)
        end

      assert {:error, %BubbleEx.Error{kind: :request_failed, context: %{reason: :body_too_large}}} =
               result

      assert_receive {:json_closed, {:error, :closed}}, 2000
      Task.await(server)
    end
  end

  @tag timeout: 1000
  test "a retry delay within the delay cap but beyond the remaining deadline is not slept" do
    BubbleEx.HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> BubbleEx.HTTP.delete_process_options() end)

    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), :budget_requested)
      conn |> Plug.Conn.put_resp_header("retry-after", "1") |> Plug.Conn.send_resp(429, "wait")
    end)

    started = System.monotonic_time(:millisecond)

    assert {:error, %BubbleEx.Error{context: %{status: 429}}} =
             BubbleEx.HTTP.fetch_page("https://example.com",
               max_retry_delay: 10_000,
               total_timeout: 500
             )

    assert System.monotonic_time(:millisecond) - started < 500
    assert_received :budget_requested
    refute_received :budget_requested
  end

  test "numeric zero and past HTTP dates retry immediately instead of using backoff" do
    for value <- ["0", "Sun, 06 Nov 1994 08:49:37 GMT"] do
      assert_retry_after(value, :retried, retry_base_delay: 10_000, max_retry_delay: 0)
    end
  end

  @tag timeout: 5000
  test "a future HTTP date within both budgets is honored" do
    value = Req.Utils.format_http_date(DateTime.add(DateTime.utc_now(), 2, :second))
    started = System.monotonic_time(:millisecond)
    assert_retry_after(value, :retried, max_retry_delay: 3000, total_timeout: 4000)
    assert System.monotonic_time(:millisecond) - started >= 900
  end

  @tag timeout: 1000
  test "future dates and huge numeric delays exceeding either budget never sleep or retry" do
    future = Req.Utils.format_http_date(DateTime.add(DateTime.utc_now(), 60, :second))

    for {value, opts} <- [
          {future, [max_retry_delay: 10]},
          {future, [max_retry_delay: 120_000, total_timeout: 500]},
          {"999999999999999999999999999999", [max_retry_delay: 10]},
          {"Fri, 31 Dec 9999 23:59:59 GMT", [max_retry_delay: 10]}
        ] do
      started = System.monotonic_time(:millisecond)
      assert_retry_after(value, :not_retried, opts)
      assert System.monotonic_time(:millisecond) - started < 500
    end
  end

  test "malformed and overlong Retry-After values use bounded fallback backoff" do
    for value <- [
          "",
          "garbage",
          "-1",
          "+1",
          "1.5",
          "1junk",
          "Sun, 31 Feb 2026 08:49:37 GMT",
          "Sun, 06 Nov 1994 25:49:37 GMT",
          String.duplicate("9", 100_000),
          "Sun, 06 Nov 1994 08:49:37 GMT" <> String.duplicate(" ", 100_000)
        ] do
      assert_retry_after(value, :not_retried, retry_base_delay: 1000, max_retry_delay: 0)
      assert_retry_after(value, :retried, retry_base_delay: 0, max_retry_delay: 10)
    end
  end

  test "zero retries never sleeps for numeric or date Retry-After" do
    for value <- ["1", Req.Utils.format_http_date(DateTime.add(DateTime.utc_now(), 60, :second))] do
      started = System.monotonic_time(:millisecond)
      assert_retry_after(value, :not_retried, max_retries: 0, max_retry_delay: 120_000)
      assert System.monotonic_time(:millisecond) - started < 500
    end
  end

  defp assert_retry_after(value, expected, opts) do
    BubbleEx.HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> BubbleEx.HTTP.delete_process_options() end)
    marker = make_ref()

    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), {:retry_after_request, marker})
      conn |> Plug.Conn.put_resp_header("retry-after", value) |> Plug.Conn.send_resp(429, "wait")
    end)

    assert {:error, %BubbleEx.Error{context: %{status: 429}}} =
             BubbleEx.HTTP.fetch_page(
               "https://example.com",
               Keyword.put_new(opts, :max_retries, 1)
             )

    assert_received {:retry_after_request, ^marker}

    case expected do
      :retried -> assert_received {:retry_after_request, ^marker}
      :not_retried -> refute_received {:retry_after_request, ^marker}
    end

    refute_received {:retry_after_request, ^marker}
  end

  test "HTML and scripts have independent streaming budgets" do
    BubbleEx.HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> BubbleEx.HTTP.delete_process_options() end)

    Req.Test.stub(__MODULE__, fn conn ->
      body =
        if conn.request_path == "/package/dynamic_js",
          do: String.duplicate(" ", 200) <> ~s|const app = JSON.parse('{"_id":"budget-app"}');|,
          else: ~s(<script src="/package/dynamic_js"></script>)

      conn |> Plug.Conn.put_resp_header("x-bubble-app", "yes") |> Plug.Conn.send_resp(200, body)
    end)

    assert {:ok, %{valid?: true}} =
             BubbleEx.fetch_app("https://budget-app.bubbleapps.io",
               html_max_body_length: 100,
               script_max_body_length: 1000
             )

    assert {:error, %BubbleEx.Error{context: %{reason: :body_too_large}}} =
             BubbleEx.fetch_app("https://budget-app.bubbleapps.io",
               html_max_body_length: 100,
               script_max_body_length: 100
             )
  end

  test "encoded bodies are rejected before accumulating or decompressing them" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 2000)
        send(parent, {:request, request})

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Encoding: gzip\r\nx-bubble-app: yes\r\n\r\n1\r\nx\r\n"
        )

        send(parent, {:encoded_connection_end, :gen_tcp.recv(socket, 0, 2000)})
        :gen_tcp.close(socket)
      end)

    assert {:error, %BubbleEx.Error{context: %{reason: :unsupported_content_encoding}}} =
             BubbleEx.HTTP.fetch_page("http://127.0.0.1:#{port}/")

    assert_receive {:request, request}
    assert request =~ "accept-encoding: identity"
    assert_receive {:encoded_connection_end, {:error, :closed}}, 2000
    Task.await(server)
  end

  test "a named Finch pool supports the bounded high-level transport" do
    start_supervised!(
      {Finch, name: __MODULE__, pools: %{default: [conn_opts: [transport_opts: [timeout: 1000]]]}}
    )

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2000)
        {:ok, _} = :gen_tcp.recv(socket, 0, 2000)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nx-bubble-app: yes\r\n\r\nok"
        )

        :gen_tcp.close(socket)
      end)

    assert {:ok, %{body: "ok"}} =
             BubbleEx.HTTP.fetch_page("http://127.0.0.1:#{port}/",
               finch: __MODULE__,
               max_retries: 0
             )

    Task.await(server)
  end

  test "a slow trickle cannot reset the total response budget" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 3000)
        {:ok, _} = :gen_tcp.recv(socket, 0, 3000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nx-bubble-app: yes\r\n\r\n"
          )

        Enum.reduce_while(1..100, nil, fn _, _ ->
          Process.sleep(20)

          case :gen_tcp.send(socket, "1\r\nx\r\n") do
            :ok -> {:cont, nil}
            {:error, _} -> {:halt, nil}
          end
        end)

        send(parent, :stream_closed)
        :gen_tcp.close(socket)
      end)

    started = System.monotonic_time(:millisecond)

    assert {:error, %BubbleEx.Error{context: %{reason: :total_timeout}}} =
             BubbleEx.HTTP.fetch_page("http://127.0.0.1:#{port}/",
               total_timeout: 100,
               recv_timeout: 500,
               max_retries: 0
             )

    assert System.monotonic_time(:millisecond) - started < 1000
    assert_receive :stream_closed, 1000
    Task.await(server)
  end

  @tag timeout: 1000
  test "a Retry-After exceeding the retry budget never sleeps in the caller" do
    BubbleEx.HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> BubbleEx.HTTP.delete_process_options() end)

    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), :requested)

      conn
      |> Plug.Conn.put_resp_header("retry-after", "86400")
      |> Plug.Conn.send_resp(429, "wait")
    end)

    started = System.monotonic_time(:millisecond)

    assert {:error, %BubbleEx.Error{context: %{status: 429}}} =
             BubbleEx.HTTP.fetch_page("https://example.com", max_retry_delay: 10)

    assert System.monotonic_time(:millisecond) - started < 500
    assert_received :requested
    refute_received :requested
  end

  test "fetch_page stops a chunked response before the server finishes sending it" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 3000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 3000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nx-bubble-app: synthetic\r\n\r\n5\r\nabcde\r\n"
          )

        send(parent, {:connection_end, :gen_tcp.recv(socket, 0, 3000)})
        :gen_tcp.close(socket)
      end)

    assert {:error, %BubbleEx.Error{context: %{reason: :body_too_large}}} =
             BubbleEx.HTTP.fetch_page("http://127.0.0.1:#{port}/",
               max_body_length: 4
             )

    assert_receive {:connection_end, {:error, :closed}}, 3000
    Task.await(server)
  end
end
