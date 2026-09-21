defmodule BubbleEx.HTTPTransportTest do
  use ExUnit.Case, async: false
  alias BubbleEx.HTTP
  @fixtures "test/support/fixtures/public_destination"

  setup do
    previous = Application.get_env(:bubble_ex, :http_profiles, %{})
    on_exit(fn -> Application.put_env(:bubble_ex, :http_profiles, previous) end)
    :ok
  end

  test "a DNS swap cannot change the numeric socket address; TLS SNI, Host and evidence stay logical" do
    {listener, port} = tls_listener("public")
    parent = self()
    {:ok, answers} = Agent.start_link(fn -> [{8, 8, 8, 8}] end)
    server = serve_tls(listener, parent)

    HTTP.put_process_options(
      resolver: fn "public.example", _ ->
        {:ok, Agent.get_and_update(answers, &{&1, [{127, 0, 0, 1}]})}
      end,
      connect_options: [
        hostname: "wrong.example",
        transport_opts: [cacertfile: String.to_charlist("#{@fixtures}/ca.pem")]
      ],
      connect: fn :https, ip, 443, opts ->
        assert ip == {8, 8, 8, 8}
        assert Agent.get(answers, & &1) == [{127, 0, 0, 1}]
        assert opts[:hostname] == "public.example"
        assert opts[:transport_opts][:server_name_indication] == ~c"public.example"
        Mint.HTTP.connect(:https, {127, 0, 0, 1}, port, opts)
      end
    )

    assert {:ok, %{body: "ok", request_url: "https://public.example/path"}} =
             HTTP.get("https://public.example/path", [{"host", "attacker.example"}])

    Task.await(server)
    assert_received {:sni, ~c"public.example"}
    assert_received {:origin, request}
    assert request =~ "host: public.example\r\n"
    assert request =~ "GET /path HTTP/1.1"
    # A second request revalidates; the swapped private DNS result cannot connect.
    assert {:error, %{reason: :unsafe_destination}} = HTTP.get("https://public.example/path")
    refute_received {:origin, _}
  end

  test "wrong certificate fails even when caller requests verify_none" do
    {listener, port} = tls_listener("wrong")

    server =
      Task.async(fn ->
        {:ok, transport} = :ssl.transport_accept(listener, 2000)
        result = :ssl.handshake(transport, 2000)
        assert {:error, _} = result
      end)

    HTTP.put_process_options(
      resolver: fn _, _ -> {:ok, [{8, 8, 8, 8}]} end,
      connect_options: [
        transport_opts: [
          cacertfile: String.to_charlist("#{@fixtures}/ca.pem"),
          verify: :verify_none
        ]
      ],
      connect: fn scheme, {8, 8, 8, 8}, 443, opts ->
        Mint.HTTP.connect(scheme, {127, 0, 0, 1}, port, opts)
      end
    )

    assert {:error, %{reason: {:tls_alert, _}}} = HTTP.get("https://public.example/")
    Task.await(server)
  end

  test "HTTPS proxy CONNECT is numeric with proxy-only credentials and verified logical TLS identity" do
    {:ok, proxy} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(proxy)
    on_exit(fn -> :gen_tcp.close(proxy) end)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(proxy, 2000)
        {:ok, connect} = :gen_tcp.recv(socket, 0, 2000)
        send(parent, {:connect, connect})
        :gen_tcp.send(socket, "HTTP/1.1 200 Connection Established\r\n\r\n")
        {:ok, socket} = :ssl.handshake(socket, tls_options("public"), 2000)
        record_request(socket, parent)
      end)

    Application.put_env(:bubble_ex, :http_profiles, %{
      TestProxy => [
        proxy: {:http, "127.0.0.1", port, []},
        proxy_headers: [{"proxy-authorization", "Basic fixture"}],
        transport_opts: [cacertfile: String.to_charlist("#{@fixtures}/ca.pem")]
      ]
    })

    HTTP.put_process_options(resolver: fn _, _ -> {:ok, [{8, 8, 8, 8}]} end)
    assert {:ok, %{body: "ok"}} = HTTP.get("https://public.example/", [], finch: TestProxy)
    Task.await(server)
    assert_received {:connect, connect}
    assert connect =~ "CONNECT 8.8.8.8:443 HTTP/1.1"
    assert connect =~ "proxy-authorization: Basic fixture"
    assert_received {:sni, ~c"public.example"}
    assert_received {:origin, request}
    assert request =~ "host: public.example"
    refute request =~ "fixture"
    refute request =~ "proxy-authorization"

    assert {:error, %{reason: :unsafe_proxy}} =
             HTTP.get("http://public.example/", [], finch: TestProxy)

    assert {:error, %{reason: :unknown_http_profile}} =
             HTTP.get("https://public.example/", [], finch: UnknownProxy)
  end

  test "private literals cause zero target socket requests, even with a public injected resolver" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)

    HTTP.put_process_options(
      resolver: fn _, _ -> {:ok, [{8, 8, 8, 8}]} end,
      connect: fn _, _, _, _ -> flunk("connector called for private destination") end
    )

    for url <- ["http://127.0.0.1/", "http://169.254.169.254/", "https://[::1]/"] do
      assert {:error, %{reason: :unsafe_destination}} = HTTP.get(url)
    end

    assert {:error, :timeout} = :gen_tcp.accept(listener, 20)
  end

  test "the total deadline kills a stalled connection owner; no socket survives" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2000)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2000)
      end)

    HTTP.put_process_options(
      resolver: fn _, _ -> {:ok, [{8, 8, 8, 8}]} end,
      connect: fn _, {8, 8, 8, 8}, 443, _ ->
        {:ok, _} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
        send(parent, {:owner, self()})
        Process.sleep(:infinity)
      end
    )

    assert {:error, %{context: %{reason: :total_timeout}}} =
             HTTP.fetch_page("https://public.example", total_timeout: 100, max_retries: 0)

    assert_received {:owner, owner}
    refute Process.alive?(owner)
    Task.await(server)
  end

  defp tls_options(name),
    do: [
      certfile: String.to_charlist("#{@fixtures}/#{name}.pem"),
      keyfile: String.to_charlist("#{@fixtures}/#{name}.key"),
      active: false
    ]

  defp tls_listener(name) do
    {:ok, listener} = :ssl.listen(0, [:binary, ip: {127, 0, 0, 1}] ++ tls_options(name))
    {:ok, {_, port}} = :ssl.sockname(listener)
    on_exit(fn -> :ssl.close(listener) end)
    {listener, port}
  end

  defp serve_tls(listener, parent) do
    Task.async(fn ->
      {:ok, transport} = :ssl.transport_accept(listener, 2000)
      {:ok, socket} = :ssl.handshake(transport, 2000)
      record_request(socket, parent)
    end)
  end

  defp record_request(socket, parent) do
    {:ok, info} = :ssl.connection_information(socket, [:sni_hostname])
    send(parent, {:sni, info[:sni_hostname]})
    {:ok, request} = :ssl.recv(socket, 0, 2000)
    send(parent, {:origin, request})
    :ssl.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
    :ssl.close(socket)
  end
end
