defmodule BubbleEx.Secrets.TrufflehogTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Error
  alias BubbleEx.SampleHelper
  alias BubbleEx.Secrets.Trufflehog

  describe "scan/2 input validation (offline)" do
    test "rejects a map without a string _id" do
      assert {:error, %Error{kind: :invalid_input}} = Trufflehog.scan(%{"no" => "id"})
    end

    test "rejects a JSON string without an _id" do
      assert {:error, %Error{kind: :invalid_input}} = Trufflehog.scan(~s({"no":"id"}))
    end
  end

  describe "collect_output/4 (offline)" do
    test "accumulates port data until the exit status arrives" do
      test_pid = self()

      spawn(fn ->
        send(test_pid, {:test_port, {:data, "data1"}})
        send(test_pid, {:test_port, {:data, "data2"}})
        send(test_pid, {:test_port, {:exit_status, 0}})
      end)

      assert {"data1data2", 0} = Trufflehog.collect_output(:test_port, "")
    end

    test "streams each chunk to a server pid when ref/pid are given" do
      ref = make_ref()
      test_pid = self()

      spawn(fn ->
        send(test_pid, {:test_port, {:data, "chunk"}})
        send(test_pid, {:test_port, {:exit_status, 0}})
      end)

      assert {"chunk", 0} = Trufflehog.collect_output(:test_port, "", ref, test_pid)
      assert_received {:scan_output, ^ref, "chunk"}
    end
  end

  describe "scan/2 (live, requires trufflehog CLI)" do
    @describetag :integration

    test "scans a real sample payload" do
      assert {:ok, results} =
               "synthetic_app"
               |> SampleHelper.load_json_sample()
               |> Trufflehog.scan(log_level: "2")

      assert is_list(results)
    end
  end
end
