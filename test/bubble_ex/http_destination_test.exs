defmodule BubbleEx.HTTPDestinationTest do
  use ExUnit.Case, async: true
  alias BubbleEx.HTTP
  alias BubbleEx.HTTP.Destination

  test "conservative IANA policy covers special-purpose and transition ranges" do
    denied = ~w(0.1.2.3 10.0.0.1 100.64.0.1 127.0.0.1 169.254.169.254 172.16.0.1
      192.0.0.9 192.0.2.1 192.88.99.1 192.168.1.1 198.18.0.1 198.51.100.1 203.0.113.1
      224.0.0.1 240.0.0.1 255.255.255.255 :: ::1 ::ffff:8.8.8.8 ::ffff:127.0.0.1
      64:ff9b::808:808 100::1 2001::1 2001:20::1 2001:db8::1 2002:0808:0808::1
      3fff::1 5f00::1 fc00::1 fe80::1 ff00::1)

    for address <- denied do
      {:ok, ip} = :inet.parse_address(String.to_charlist(address))
      refute Destination.public_ip?(ip), address
    end

    for address <- ~w(8.8.8.8 93.184.216.34 1.1.1.1 2606:4700:4700::1111 2001:4860:4860::8888) do
      {:ok, ip} = :inet.parse_address(String.to_charlist(address))
      assert Destination.public_ip?(ip), address
    end
  end

  test "rejects malformed/ambiguous authority, credentials, schemes and ports before DNS" do
    for url <- [
          "http://127.1",
          "http://2130706433",
          "http://0177.0.0.1",
          "http://0x7f000001",
          "https://example.com:80",
          "http://example.com:443",
          "https://example.com:0443",
          "https://example.com:",
          "https://user:pass@example.com",
          "file:///etc/passwd",
          "ftp://example.com",
          "https://[fe80::1%25eth0]",
          "https://example.com\\@evil.com",
          "https://example.com./",
          "https://-bad.example",
          "https://a..example",
          "https://localhost",
          "https://example.com\n/path",
          "https://%65xample.com",
          "http://[8.8.8.8]"
        ] do
      assert {:error, :unsafe_destination} =
               Destination.pin(url, 100, fn _, _ -> flunk("DNS called for #{url}") end),
             url
    end
  end

  test "arbitrary public aliases work but ALL A and AAAA answers must be public" do
    assert {:ok, {{8, 8, 8, 8}, "custom.example"}} =
             Destination.pin("https://custom.example", 100, fn _, _ -> {:ok, [{8, 8, 8, 8}]} end)

    for private <- [{127, 0, 0, 1}, {0xFE80, 0, 0, 0, 0, 0, 0, 1}] do
      assert {:error, :unsafe_destination} =
               Destination.pin("https://custom.example", 100, fn _, _ ->
                 {:ok, [{8, 8, 8, 8}, private]}
               end)
    end

    # A resolver cannot replace a literal private address with a public one.
    assert {:error, :unsafe_destination} =
             Destination.pin("http://127.0.0.1", 100, fn _, _ -> {:ok, [{8, 8, 8, 8}]} end)
  end

  test "DNS timeouts terminate the resolver and transient errors retain their category" do
    parent = self()

    assert {:error, :dns_timeout} =
             Destination.pin("https://custom.example", 20, fn _, _ ->
               send(parent, {:resolver, self()})
               Process.sleep(:infinity)
             end)

    assert_received {:resolver, pid}
    refute Process.alive?(pid)

    assert {:error, :dns_error} =
             Destination.pin("https://custom.example", 100, fn _, _ -> {:error, :dns_error} end)
  end

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    :ok
  end

  test "private URLs and mixed DNS never invoke the fixture transport" do
    Req.Test.stub(__MODULE__, fn _ -> flunk("destination requested") end)
    assert {:error, %{reason: :unsafe_destination}} = HTTP.get("http://169.254.169.254/")

    HTTP.put_process_options(
      plug: {Req.Test, __MODULE__},
      resolver: fn _, _ -> {:ok, [{8, 8, 8, 8}, {10, 0, 0, 1}]} end
    )

    assert {:error, %{reason: :unsafe_destination}} =
             HTTP.fetch_page("https://custom.example") |> low_error()
  end

  test "relative redirects retain logical evidence and same-origin credentials" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "cookie") == ["session=fixture"]

      case conn.request_path do
        "/a" -> conn |> Plug.Conn.put_resp_header("location", "b") |> Plug.Conn.send_resp(302, "")
        "/b" -> Plug.Conn.send_resp(conn, 200, "ok")
      end
    end)

    assert {:ok, %{body: "ok", request_url: "https://custom.example/b"}} =
             HTTP.get("https://custom.example/a", [{"cookie", "session=fixture"}])
  end

  test "cross-origin redirects strip authorization and cookies even with redirect_trusted" do
    Req.Test.stub(__MODULE__, fn conn ->
      if conn.host == "custom.example" do
        conn
        |> Plug.Conn.put_resp_header("location", "https://cdn.example/b")
        |> Plug.Conn.send_resp(302, "")
      else
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        assert Plug.Conn.get_req_header(conn, "cookie") == []
        Plug.Conn.send_resp(conn, 200, "ok")
      end
    end)

    assert {:ok, _} =
             HTTP.get("https://custom.example/a", [{"cookie", "s=fixture"}],
               auth: {:basic, "user:pass"},
               redirect_trusted: true
             )
  end

  test "redirect policy, downgrade credentials and finite hop limits" do
    for {target, reason} <- [
          {"https://127.0.0.1/", :unsafe_destination},
          {"file:///etc/passwd", :unsafe_destination},
          {"https://u:p@custom.example", :unsafe_destination},
          {"https://custom.example:444", :unsafe_destination},
          {"//custom.example:0443/", :unsafe_destination},
          {"http://custom.example/", :unsafe_redirect}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_resp_header("location", target) |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, %{reason: ^reason}} =
               HTTP.get("https://custom.example", [{"cookie", "fixture"}])
    end

    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), :hop)
      conn |> Plug.Conn.put_resp_header("location", "/loop") |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, _} = HTTP.get("https://custom.example", [], max_redirects: 2)
    for _ <- 1..3, do: assert_received(:hop)
    refute_received :hop
  end

  test "each redirect revalidates DNS and policy rejection never retries" do
    {:ok, count} = Agent.start_link(fn -> 0 end)

    HTTP.put_process_options(
      plug: {Req.Test, __MODULE__},
      resolver: fn _, _ ->
        attempt = Agent.get_and_update(count, &{&1, &1 + 1})
        {:ok, [if(attempt == 0, do: {8, 8, 8, 8}, else: {127, 0, 0, 1})]}
      end
    )

    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), :public_hop)
      conn |> Plug.Conn.put_resp_header("location", "/next") |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, %{context: %{reason: :unsafe_destination}}} =
             HTTP.fetch_page("https://custom.example", retry_base_delay: 0)

    assert Agent.get(count, & &1) == 2
    assert_received :public_hop
    refute_received :public_hop
  end

  test "DNS transient retries remain finite" do
    {:ok, count} = Agent.start_link(fn -> 0 end)

    HTTP.put_process_options(
      resolver: fn _, _ ->
        Agent.update(count, &(&1 + 1))
        {:error, :dns_error}
      end
    )

    assert {:error, %{context: %{reason: :dns_error}}} =
             HTTP.fetch_page("https://custom.example", max_retries: 2, retry_base_delay: 0)

    assert Agent.get(count, & &1) == 3
  end

  test "non-streamed size and deadline failures also halt before redirects" do
    for kind <- [:size, :deadline] do
      opts =
        if kind == :size,
          do: [max_body_length: 1],
          else: [deadline: System.monotonic_time(:millisecond) + 100]

      Req.Test.stub(__MODULE__, fn conn ->
        send(self(), :budget_hop)
        if opts[:deadline], do: Process.sleep(125)

        conn
        |> Plug.Conn.put_resp_header("location", "/next")
        |> Plug.Conn.send_resp(302, "large")
      end)

      assert {:error, %{reason: reason}} = HTTP.get("https://custom.example", [], opts)
      assert reason in [:total_timeout, :body_too_large]
      assert_received :budget_hop
      refute_received :budget_hop
    end
  end

  test "POST redirect semantics preserve only 307/308 bodies" do
    for status <- [301, 302, 303, 307, 308] do
      Req.Test.stub(__MODULE__, fn conn ->
        if conn.request_path == "/a" do
          conn |> Plug.Conn.put_resp_header("location", "/b") |> Plug.Conn.send_resp(status, "")
        else
          assert conn.method == if(status in [307, 308], do: "POST", else: "GET")
          Plug.Conn.send_resp(conn, 200, "ok")
        end
      end)

      assert {:ok, _} = HTTP.post("https://custom.example/a", "fixture")
    end
  end

  test "a public page cannot discover a private script; JSON and metadata use the same policy" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "custom.example"

      conn
      |> Plug.Conn.put_resp_header("x-bubble-app", "yes")
      |> Plug.Conn.send_resp(200, ~s(<script src="http://127.0.0.1/package/dynamic_js"></script>))
    end)

    assert {:error, %{context: %{reason: :unsafe_destination}}} =
             BubbleEx.fetch_app("https://custom.example")

    assert {:error, %{context: %{reason: :unsafe_destination}}} =
             HTTP.fetch_json("http://169.254.169.254/")

    assert {:error, %{context: %{reason: :unsafe_destination}}} =
             HTTP.post_json("http://[::1]/", "{}")
  end

  defp low_error({:error, %{context: %{reason: reason}}}), do: {:error, %{reason: reason}}
end
