defmodule BubbleEx.Frontend.SnapshotFidelityTest do
  use ExUnit.Case, async: false
  alias BubbleEx.Frontend.Snapshot
  @moduletag :fidelity
  @moduletag :tmp_dir

  test "archive and sanitization regressions run against the optional pinned backend" do
    {output, status} =
      System.cmd("node", ["--test", "test/support/snapshot/package.test.cjs"],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  @tag timeout: 150_000
  test "browser capture preserves state, stylesheet order, local frames and frozen initial pixels",
       %{
         tmp_dir: tmp
       } do
    {output, status} =
      System.cmd("node", ["test/support/snapshot/browser.cjs", Path.expand(tmp)],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  @tag timeout: 150_000
  test "stopping scripts keeps noscript fallbacks out of the reference pixels" do
    {output, status} =
      System.cmd("node", ["test/support/snapshot/noscript.cjs"], stderr_to_stdout: true)

    assert status == 0, output
  end

  test "real offline backend decodes HTML entities before the credential gate", %{tmp_dir: tmp} do
    token = "xoxb-" <> "123456789012-123456789012-abcdefghijklmnopqrstuvwx"

    encoded =
      token
      |> String.to_charlist()
      |> Enum.map_join(fn code -> "&#" <> Integer.to_string(code) <> ";" end)

    assert {:error, %{kind: :export_blocked}} =
             Snapshot.export(
               capture("<p>#{encoded}</p>"),
               Path.join(tmp, "blocked"),
               options(tmp)
             )

    refute File.exists?(Path.join(tmp, "blocked"))
  end

  test "real offline export publishes inert HTML with no optional scanner bypass", %{tmp_dir: tmp} do
    html = "<h1>Rendered data</h1><script>alert(1)</script><a href='/next'>Next</a>"
    assert {:ok, result} = Snapshot.export(capture(html), Path.join(tmp, "export"), options(tmp))
    output = File.read!(Path.join(result.out_dir, "index.html"))
    assert output =~ "<h1>Rendered data</h1>"
    assert output =~ "https://example.test/next"
    assert output =~ "Content-Security-Policy"
    refute output =~ "<script"
  end

  test "decoded asset bytes are checked without mistaking their base64 encoding for credentials",
       %{tmp_dir: tmp} do
    encoded = "AIza" <> String.duplicate("a", 35) <> "="

    resource = %{
      "url" => "https://example.test/image.avif",
      "mime" => "image/avif",
      "body" => encoded
    }

    safe = Map.put(capture("<p>Content</p>"), "resources", [resource])
    assert {:ok, _} = Snapshot.export(safe, Path.join(tmp, "binary"), options(tmp))

    token = "xoxb-" <> "123456789012-123456789012-abcdefghijklmnopqrstuvwx"
    resource = Map.put(resource, "body", Base.encode64(<<0, 255>> <> token <> <<0>>))
    unsafe = Map.put(capture("<p>Content</p>"), "resources", [resource])

    assert {:error, %{kind: :export_blocked}} =
             Snapshot.export(unsafe, Path.join(tmp, "blocked-binary"), options(tmp))

    refute File.exists?(Path.join(tmp, "blocked-binary"))
  end

  defp options(tmp) do
    [
      snapshot_runtime:
        System.get_env("BUBBLE_EX_SNAPSHOT_RUNTIME") || Path.expand("_build/snapshot-runtime"),
      snapshot_tmp_dir: Path.expand(tmp)
    ]
  end

  defp capture(html) do
    archive =
      "Content-Type: multipart/related; boundary=\"snapshot\"\r\n\r\n" <>
        "--snapshot\r\nContent-Type: text/html\r\n" <>
        "Content-Location: https://example.test/\r\nContent-Transfer-Encoding: base64\r\n\r\n" <>
        Base.encode64(html) <> "\r\n--snapshot--\r\n"

    %{
      "schema" => 1,
      "archive" => archive,
      "url" => "https://example.test/",
      "viewport" => %{"width" => 1440, "height" => 900}
    }
  end
end
