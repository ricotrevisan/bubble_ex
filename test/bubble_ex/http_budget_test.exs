defmodule BubbleEx.HTTPBudgetTest do
  use ExUnit.Case, async: true

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
