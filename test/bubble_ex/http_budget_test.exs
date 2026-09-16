defmodule BubbleEx.HTTPBudgetTest do
  use ExUnit.Case, async: true

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
               max_body_length: 4,
               max_retries: 0
             )

    assert_receive {:connection_end, {:error, :closed}}, 3000
    Task.await(server)
  end
end
