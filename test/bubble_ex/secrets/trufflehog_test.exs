defmodule BubbleEx.Secrets.TrufflehogTest do
  use ExUnit.Case, async: false

  alias BubbleEx.{Error, PayloadFile}
  alias BubbleEx.SampleHelper
  alias BubbleEx.Secrets.Trufflehog

  describe "scan/2 temporary-file safety (offline)" do
    test "attacker-controlled IDs cannot choose or escape the temporary path" do
      unique = "#{System.pid()}_#{System.unique_integer([:positive])}"
      test_root = Path.join(System.tmp_dir!(), "bubble_ex_trufflehog_test_#{unique}")
      bin_dir = Path.join(test_root, "bin")
      fake_cli = Path.join(bin_dir, "trufflehog")
      original_path = System.get_env("PATH")
      original_tmpdir = System.get_env("TMPDIR")
      sentinel = Path.join(File.cwd!(), ".trufflehog_path_sentinel_#{unique}.json")

      File.mkdir_p!(bin_dir)
      File.write!(fake_cli, "#!/bin/sh\nexit 0\n")
      File.chmod!(fake_cli, 0o700)
      File.write!(sentinel, "must not be overwritten")
      System.put_env("PATH", bin_dir <> ":" <> original_path)
      # A private TMPDIR: the leftover-directory check below globs the temp
      # dir, and a concurrent test run on this host (another worktree) creates
      # scan directories in the shared /tmp (WTF-395).
      File.mkdir_p!(Path.join(test_root, "tmp"))
      System.put_env("TMPDIR", Path.join(test_root, "tmp"))

      on_exit(fn ->
        System.put_env("PATH", original_path)

        if original_tmpdir,
          do: System.put_env("TMPDIR", original_tmpdir),
          else: System.delete_env("TMPDIR")

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

  describe "provider verification (offline, fake CLI)" do
    # The fake CLI records its arguments one per line and prints the finding a
    # `--no-verification` run prints: unverified, no verification error.
    @finding %{
      "DecoderName" => "PLAIN",
      "DetectorName" => "Github",
      "Raw" => "synthetic",
      "Verified" => false,
      "VerificationError" => nil
    }

    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "bubble_ex_trufflehog_args_#{System.pid()}_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      cli = Path.join(root, "trufflehog")

      File.write!(cli, """
      #!/bin/sh
      printf '%s\\n' "$@" > '#{root}/args'
      printf '%s\\n' '#{Jason.encode!(@finding)}'
      """)

      File.chmod!(cli, 0o700)
      original_path = System.get_env("PATH")
      System.put_env("PATH", root <> ":" <> original_path)

      on_exit(fn ->
        System.put_env("PATH", original_path)
        File.rm_rf!(root)
      end)

      %{
        args: fn ->
          root |> Path.join("args") |> File.read!() |> String.split("\n", trim: true)
        end
      }
    end

    test "the default asks providers and reports verified and unknown results only", %{
      args: args
    } do
      # Characterization of the behaviour before WTF-485: findings unchanged.
      assert {:ok, [@finding]} = Trufflehog.scan(%{"_id" => "x"})

      assert [
               "filesystem",
               _path,
               "--json",
               "--log-level=5",
               "--results=verified,unknown",
               "--no-update"
             ] = args.()

      default = args.()
      assert {:ok, [@finding]} = Trufflehog.scan(%{"_id" => "x"}, verify: true)
      assert Enum.drop(args.(), 2) == Enum.drop(default, 2)
    end

    test "verify: false contacts no provider and marks every result skipped", %{args: args} do
      assert {:ok, [finding]} = Trufflehog.scan(%{"_id" => "x"}, verify: false, log_level: "0")
      assert finding == Map.put(@finding, "Verification", "skipped")

      assert [
               "filesystem",
               _path,
               "--json",
               "--log-level=0",
               "--no-verification",
               "--results=verified,unknown,unverified",
               "--no-update"
             ] = args.()
    end

    test "scan_file/2 takes the same option", %{args: args} do
      assert {:ok, [%{"Verification" => "skipped"}]} =
               PayloadFile.with_file(%{"_id" => "x"}, &Trufflehog.scan_file(&1, verify: false))

      assert "--no-verification" in args.()

      assert {:ok, [@finding]} = PayloadFile.with_file(%{"_id" => "x"}, &Trufflehog.scan_file/1)
      refute "--no-verification" in args.()
    end

    test "the option reaches the adapter through the public entry points", %{args: args} do
      assert {:ok, [%{"Verification" => "skipped"}]} =
               BubbleEx.scan_payload_for_secrets(%{"_id" => "x"}, verify: false)

      assert "--no-verification" in args.()

      assert {:ok, [@finding]} = BubbleEx.scan_payload_for_secrets(%{"_id" => "x"})
      refute "--no-verification" in args.()
    end

    test "a non-boolean :verify is refused before the CLI starts", %{args: args} do
      for value <- [nil, "false", 0] do
        assert {:error, %Error{kind: :invalid_input}} =
                 Trufflehog.scan(%{"_id" => "x"}, verify: value)

        assert {:error, %Error{kind: :invalid_input}} =
                 PayloadFile.with_file(%{"_id" => "x"}, &Trufflehog.scan_file(&1, verify: value))
      end

      assert_raise File.Error, args
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
