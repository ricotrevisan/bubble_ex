defmodule BubbleEx.ScanBudgetTest do
  use ExUnit.Case, async: false
  alias BubbleEx.{Error, PayloadFile}
  alias BubbleEx.Secrets.Trufflehog

  setup do
    root = Path.join(System.tmp_dir!(), "scanner_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    old_path = System.fetch_env!("PATH")
    System.put_env("PATH", root <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp cli(root, body) do
    path = Path.join(root, "trufflehog")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o700)
  end

  test "file adapter preserves valid findings across fragments and final unterminated line", %{
    root: root
  } do
    cli(root, ~S"""
    printf '%s' '{"DecoderName":"PLAIN",'
    printf '%s\n' '"Raw":"synthetic"}'
    printf '%s\n' 'not-json' '{"level":"info","msg":"scanner log"}' '{"DecoderName":"BASE64","Raw":"hello"}'
    printf '%s\n' '{"DecoderName":"BASE64","Raw":"absent"}'
    printf '%s' '{"DecoderName":"PLAIN","Raw":"last"}'
    """)

    payload = %{"_id" => "synthetic", "encoded" => Base.encode64("hello")}
    assert {:ok, results} = Trufflehog.scan(payload)
    assert Enum.map(results, & &1["Raw"]) == ["synthetic", "hello", "last"]
    assert Enum.at(results, 1)["Encoded"] == "aGVsbG8="
    assert {:ok, ^results} = PayloadFile.with_file(payload, &Trufflehog.scan_file/1)
  end

  test "private artifact is removed on callback failure and supports boundary matches" do
    parent = self()

    assert_raise RuntimeError, fn ->
      PayloadFile.with_file(String.duplicate("x", 65_535) <> "needle", fn file ->
        send(parent, {:path, file.path})
        assert PayloadFile.contains?(file, "needle")
        assert File.stat!(Path.dirname(file.path)).mode |> Bitwise.band(0o777) == 0o700
        raise "synthetic"
      end)
    end

    assert_received {:path, path}
    refute File.exists?(path)
  end

  test "oversized input never starts the scanner", %{root: root} do
    cli(root, "touch '#{root}/started'\n")

    assert {:error, %Error{context: %{reason: :input_limit}}} =
             Trufflehog.scan(%{"_id" => "oversized", "value" => String.duplicate("x", 100)},
               max_input_bytes: 20
             )

    refute File.exists?(Path.join(root, "started"))
  end

  test "output and line budgets fail without returning partial findings", %{root: root} do
    cli(root, "printf '%s' '123456789012345678901234567890'\n")

    assert {:error, %Error{context: %{reason: :output_limit}}} =
             Trufflehog.scan(%{"_id" => "x"}, max_output_bytes: 10)

    assert {:error, %Error{context: %{reason: :line_limit}}} =
             Trufflehog.scan(%{"_id" => "x"}, max_line_bytes: 10)
  end

  test "timeout terminates a silent OS scanner and cleans its artifact", %{root: root} do
    cli(root, "echo $$ > '#{root}/pid'\nprintf '%s' \"$2\" > '#{root}/input'\nexec sleep 30\n")

    assert {:error, %Error{context: %{reason: :scan_timeout}}} =
             Trufflehog.scan(%{"_id" => "x"}, timeout_ms: 100)

    pid = root |> Path.join("pid") |> File.read!() |> String.trim()
    # Wait for OS reaping, not for the scanner's original 30-second deadline.
    Enum.reduce_while(1..50, nil, fn _, _ ->
      if File.exists?("/proc/#{pid}"),
        do:
          (
            Process.sleep(10)
            {:cont, nil}
          ),
        else: {:halt, :gone}
    end)

    refute File.exists?("/proc/#{pid}")
    refute File.exists?(File.read!(Path.join(root, "input")))
  end
end
