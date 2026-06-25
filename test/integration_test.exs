defmodule BubbleEx.IntegrationTest do
  use ExUnit.Case, async: false

  alias BubbleEx.Apps
  alias BubbleEx.Server

  @moduletag :integration

  setup do
    {:ok, pid} = Server.start_link(name: :integration_test_server)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{server_pid: pid}
  end

  test "scans a fetched app payload and streams output" do
    {:ok, %{payload: payload}} = Apps.fetch_app("example-app", include_payload: true)
    {:ok, ref} = Server.start_scan(payload, server: :integration_test_server)
    assert_receive {:scan_started, ^ref}, 1000

    {outputs, terminal_output} = collect_scan_outputs(ref, [])

    assert outputs != [], "expected at least one scan_output message"
    assert is_list(terminal_output)

    if terminal_output != [] do
      assert is_map(List.first(terminal_output))
    end
  end

  defp collect_scan_outputs(ref, acc) do
    receive do
      {:scan_output, ^ref, output} ->
        collect_scan_outputs(ref, [String.split(output, "\n") | acc])

      {:scan_completed, _ref, terminal_output} ->
        send(self(), {:scan_completed, ref, []})
        {acc |> Enum.reverse() |> List.flatten(), terminal_output}

      _other ->
        collect_scan_outputs(ref, acc)
    after
      10_000 -> {Enum.reverse(acc), nil}
    end
  end

  test "completes the full scan lifecycle" do
    payload = %{"_id" => "integration_test_app", "data" => "some test data for scanning"}

    {:ok, ref} = Server.start_scan(payload, server: :integration_test_server)
    assert is_reference(ref)
    assert_receive {:scan_started, ^ref}, 1000

    {:ok, status} = Server.scan_status(ref, server: :integration_test_server)
    assert status.status in [:pending, :running]
    assert status.payload_id == "integration_test_app"

    assert await_outcome(ref) in [:completed, :failed]

    {:ok, final_status} = Server.scan_status(ref, server: :integration_test_server)
    assert final_status.status in [:completed, :failed]
  end

  defp await_outcome(ref) do
    receive do
      {:scan_output, ^ref, _output} -> await_outcome(ref)
      {:scan_completed, ^ref, results} when is_list(results) -> :completed
      {:scan_error, ^ref, _error} -> :failed
    after
      10_000 -> flunk("scan did not complete within timeout")
    end
  end

  test "cancels a running scan" do
    payload = %{"_id" => "integration_cancel_test", "data" => "test data"}

    {:ok, ref} = Server.start_scan(payload, server: :integration_test_server)
    assert_receive {:scan_started, ^ref}, 1000

    assert :ok = Server.cancel_scan(ref, server: :integration_test_server)
    assert_receive {:scan_cancelled, ^ref}, 1000

    {:ok, status} = Server.scan_status(ref, server: :integration_test_server)
    assert status.status == :cancelled
  end

  test "exposes the public scan API" do
    assert function_exported?(BubbleEx, :start_scan_for_secrets, 1)
    assert function_exported?(BubbleEx, :scan_status, 1)
    assert function_exported?(BubbleEx, :cancel_scan, 1)
  end
end
