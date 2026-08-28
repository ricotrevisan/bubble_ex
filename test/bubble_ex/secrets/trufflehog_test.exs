defmodule BubbleEx.Secrets.TrufflehogTest do
  use ExUnit.Case, async: false

  alias BubbleEx.Error
  alias BubbleEx.SampleHelper
  alias BubbleEx.Secrets.Trufflehog

  describe "scan/2 temporary-file safety (offline)" do
    test "attacker-controlled IDs cannot choose or escape the temporary path" do
      unique = System.unique_integer([:positive])
      test_root = Path.join(System.tmp_dir!(), "bubble_ex_trufflehog_test_#{unique}")
      bin_dir = Path.join(test_root, "bin")
      fake_cli = Path.join(bin_dir, "trufflehog")
      original_path = System.get_env("PATH")
      sentinel = Path.join(File.cwd!(), ".trufflehog_path_sentinel_#{unique}.json")

      File.mkdir_p!(bin_dir)
      File.write!(fake_cli, "#!/bin/sh\nexit 0\n")
      File.chmod!(fake_cli, 0o700)
      File.write!(sentinel, "must not be overwritten")
      System.put_env("PATH", bin_dir <> ":" <> original_path)

      on_exit(fn ->
        System.put_env("PATH", original_path)
        File.rm_rf!(test_root)
        File.rm(sentinel)
      end)

      id =
        sentinel
        |> Path.rootname(".json")
        |> Path.relative_to(System.tmp_dir!(), force: true)

      before_temp_dirs = trufflehog_temp_dirs()
      assert {:ok, []} = Trufflehog.scan(%{"_id" => id})
      assert File.read!(sentinel) == "must not be overwritten"
      assert trufflehog_temp_dirs() == before_temp_dirs

      assert {:error, %Error{kind: :cli_failed, context: %{}}} =
               Trufflehog.scan(%{"_id" => "unencodable", "pid" => self()})

      assert trufflehog_temp_dirs() == before_temp_dirs
    end
  end

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

  defp trufflehog_temp_dirs do
    System.tmp_dir!()
    |> Path.join("bubble_ex_trufflehog_*")
    |> Path.wildcard()
    |> Enum.sort()
  end
end
