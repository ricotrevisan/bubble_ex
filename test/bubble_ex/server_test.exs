defmodule BubbleEx.ServerTest do
  use ExUnit.Case, async: false

  alias BubbleEx.Error
  alias BubbleEx.Server

  # A stub BubbleEx.Secrets adapter so the async server lifecycle can be tested
  # deterministically without the trufflehog CLI.
  defmodule StubScanner do
    @behaviour BubbleEx.Secrets

    @impl true
    def scan(%{"_id" => "fail"}, _opts), do: {:error, Error.new(:cli_failed, "boom", %{})}

    def scan(%{"_id" => "hang"}, _opts), do: Process.sleep(:infinity)

    def scan(_payload, opts) do
      ref = Keyword.get(opts, :ref)
      server_pid = Keyword.get(opts, :server_pid)
      if server_pid && ref, do: send(server_pid, {:scan_output, ref, "scanning"})
      {:ok, [%{"finding" => "x"}]}
    end
  end

  setup do
    {:ok, pid} = Server.start_link(name: :test_server, adapter: StubScanner)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{server: :test_server}
  end

  describe "start_scan/2" do
    test "returns a reference and notifies the client", %{server: server} do
      {:ok, ref} = Server.start_scan(%{"_id" => "ok"}, server: server)
      assert is_reference(ref)
      assert_receive {:scan_started, ^ref}, 1000
    end

    test "streams output and completes with the scanner's findings", %{server: server} do
      {:ok, ref} = Server.start_scan(%{"_id" => "ok"}, server: server)

      assert_receive {:scan_started, ^ref}, 1000
      assert_receive {:scan_output, ^ref, "scanning"}, 1000
      assert_receive {:scan_completed, ^ref, [%{"finding" => "x"}]}, 1000

      assert {:ok, %{status: :completed}} = Server.scan_status(ref, server: server)
    end

    test "reports scanner errors via :scan_error", %{server: server} do
      {:ok, ref} = Server.start_scan(%{"_id" => "fail"}, server: server)

      assert_receive {:scan_error, ^ref, %Error{kind: :cli_failed}}, 1000
      assert {:ok, %{status: :failed}} = Server.scan_status(ref, server: server)
    end
  end

  describe "scan_status/2" do
    test "returns :not_found for an unknown ref", %{server: server} do
      assert {:error, :not_found} = Server.scan_status(make_ref(), server: server)
    end

    test "reports the payload id and start time", %{server: server} do
      {:ok, ref} = Server.start_scan(%{"_id" => "hang"}, server: server)
      assert_receive {:scan_started, ^ref}, 1000

      assert {:ok, status} = Server.scan_status(ref, server: server)
      assert status.payload_id == "hang"
      assert is_integer(status.start_time)
    end
  end

  describe "cancel_scan/2" do
    test "cancels a running scan", %{server: server} do
      {:ok, ref} = Server.start_scan(%{"_id" => "hang"}, server: server)
      assert_receive {:scan_started, ^ref}, 1000

      assert :ok = Server.cancel_scan(ref, server: server)
      assert_receive {:scan_cancelled, ^ref}, 1000
      assert {:ok, %{status: :cancelled}} = Server.scan_status(ref, server: server)
    end

    test "returns :not_found for an unknown ref", %{server: server} do
      assert {:error, :not_found} = Server.cancel_scan(make_ref(), server: server)
    end
  end

  describe "isolation" do
    test "tracks multiple scans independently", %{server: server} do
      {:ok, ref1} = Server.start_scan(%{"_id" => "hang"}, server: server)
      {:ok, ref2} = Server.start_scan(%{"_id" => "hang"}, server: server)

      assert ref1 != ref2
      assert_receive {:scan_started, ^ref1}, 1000
      assert_receive {:scan_started, ^ref2}, 1000
    end
  end
end
