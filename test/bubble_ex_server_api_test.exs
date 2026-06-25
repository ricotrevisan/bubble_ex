defmodule BubbleExServerApiTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  doctest BubbleEx

  setup do
    # Start the server for testing with default name
    {:ok, pid} = BubbleEx.Server.start_link()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{server_pid: pid}
  end

  describe "BubbleEx.start_scan_for_secrets/1" do
    test "starts an asynchronous scan and returns reference" do
      payload = %{"_id" => "api_test_123", "data" => "test content"}

      assert {:ok, ref} = BubbleEx.start_scan_for_secrets(payload)
      assert is_reference(ref)

      # Should receive scan started message
      assert_receive {:scan_started, ^ref}, 1000
    end

    test "starts scan but fails asynchronously with invalid payload" do
      payload = %{"invalid" => "no _id field"}

      assert {:ok, ref} = BubbleEx.start_scan_for_secrets(payload)
      assert is_reference(ref)

      assert_receive {:scan_started, ^ref}, 1000
      assert_receive {:scan_error, ^ref, %BubbleEx.Error{kind: :invalid_input}}, 5000
    end
  end

  describe "BubbleEx.scan_status/1" do
    test "returns status for running scan" do
      payload = %{"_id" => "api_status_test", "data" => "test content"}

      {:ok, ref} = BubbleEx.start_scan_for_secrets(payload)
      assert_receive {:scan_started, ^ref}, 1000

      assert {:ok, status_info} = BubbleEx.scan_status(ref)
      assert status_info.status in [:pending, :running]
      assert status_info.payload_id == "api_status_test"
      assert is_integer(status_info.start_time)
    end

    test "returns error for non-existent scan" do
      fake_ref = make_ref()

      assert {:error, :not_found} = BubbleEx.scan_status(fake_ref)
    end
  end

  describe "BubbleEx.cancel_scan/1" do
    test "cancels running scan" do
      payload = %{"_id" => "api_cancel_test", "data" => "test content"}

      {:ok, ref} = BubbleEx.start_scan_for_secrets(payload)
      assert_receive {:scan_started, ^ref}, 1000

      assert :ok = BubbleEx.cancel_scan(ref)
      assert_receive {:scan_cancelled, ^ref}, 1000

      # Status should show cancelled
      {:ok, status_info} = BubbleEx.scan_status(ref)
      assert status_info.status == :cancelled
    end

    test "returns error for non-existent scan" do
      fake_ref = make_ref()

      assert {:error, :not_found} = BubbleEx.cancel_scan(fake_ref)
    end
  end

  describe "full workflow" do
    test "complete scan lifecycle with messages" do
      payload = %{"_id" => "api_workflow_test", "data" => "some test content to scan"}

      # Start scan
      {:ok, ref} = BubbleEx.start_scan_for_secrets(payload)

      # Receive start notification
      assert_receive {:scan_started, ^ref}, 1000

      # Check initial status
      {:ok, status} = BubbleEx.scan_status(ref)
      assert status.status in [:pending, :running]

      # The scan might complete quickly or we might receive output messages
      # Let's wait for some kind of completion
      receive do
        {:scan_output, ^ref, _output} ->
          # Received some output, scan is progressing
          :ok

        {:scan_completed, ^ref, _results} ->
          # Scan completed successfully
          {:ok, final_status} = BubbleEx.scan_status(ref)
          assert final_status.status == :completed

        {:scan_error, ^ref, _error} ->
          # Scan failed (might happen if trufflehog not installed properly)
          {:ok, final_status} = BubbleEx.scan_status(ref)
          assert final_status.status == :failed
      after
        5000 ->
          # If no completion message received, cancel the scan
          :ok = BubbleEx.cancel_scan(ref)
          assert_receive {:scan_cancelled, ^ref}, 1000
      end
    end
  end
end
