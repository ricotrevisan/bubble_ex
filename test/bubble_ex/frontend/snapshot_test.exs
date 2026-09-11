defmodule BubbleEx.Frontend.SnapshotTest do
  use ExUnit.Case, async: false
  import Mock
  alias BubbleEx.Frontend.Snapshot
  alias BubbleEx.Frontend.Snapshot.Runtime

  test "snapshot input rejects authentication, non-HTTP URLs and invalid viewport before browsing" do
    for url <- ["file:///tmp/page", "https://user:password@example.test", nil] do
      assert {:error, %{kind: :invalid_input}} = Snapshot.capture(url)
    end

    for opts <- [[width: 0], [height: 50], [locale: nil], [session_cookie: "private"]] do
      assert {:error, %{kind: :invalid_input}} = Snapshot.capture("https://example.test/", opts)
    end
  end

  test "snapshot mode reports missing optional backend without affecting app-data exports" do
    assert {:error, %{kind: :cli_missing}} =
             BubbleEx.export_frontend("https://example.test/", temp_path(),
               mode: :snapshot,
               snapshot_runtime: "/nonexistent/bubbleex-runtime"
             )

    assert {:error, %{kind: :invalid_input}} =
             BubbleEx.export_frontend("https://example.test/", temp_path(), mode: :unknown)
  end

  @tag :tmp_dir
  test "offline export publishes a local package and explicit snapshot provenance", %{
    tmp_dir: tmp
  } do
    package = package("<p>Captured page</p>")

    with_mock Runtime, run: fn _, _ -> {:ok, package} end do
      assert {:ok, result} = Snapshot.export(capture(), tmp)
      assert result.manifest.mode == "browser_snapshot"
      assert result.manifest.workflows == false
      assert File.read!(Path.join(tmp, "index.html")) == "<p>Captured page</p>"
      assert result.files == ["MANIFEST.json", "index.html"]
    end
  end

  @tag :tmp_dir
  test "decoded credentials block publication and are never included in errors", %{tmp_dir: tmp} do
    token = "xoxb-" <> "123456789012-123456789012-abcdefghijklmnopqrstuvwx"
    package = package(token)

    with_mock Runtime, run: fn _, _ -> {:ok, package} end do
      assert {:error, error} = Snapshot.export(capture(), tmp)
      assert error.kind == :export_blocked
      refute inspect(error) =~ token
      assert File.ls!(tmp) == []
    end
  end

  @tag :tmp_dir
  test "unsafe backend filenames cannot escape the output directory", %{tmp_dir: tmp} do
    package = put_in(package("hello"), ["entries", Access.at(0), "name"], "../outside.html")

    with_mock Runtime, run: fn _, _ -> {:ok, package} end do
      assert {:error, %{kind: :invalid_input}} = Snapshot.export(capture(), tmp)
      assert File.ls!(tmp) == []
    end
  end

  @tag :tmp_dir
  test "nonempty output is rejected before starting the backend", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "existing"), "keep")
    assert {:error, %{kind: :invalid_input}} = Snapshot.run("https://example.test/", tmp)
    assert File.read!(Path.join(tmp, "existing")) == "keep"
  end

  defp package(text) do
    %{
      "entries" => [%{"name" => "index.html", "body" => Base.encode64(text)}],
      "scan" => [text],
      "findings" => []
    }
  end

  defp capture do
    %{
      "schema" => 1,
      "archive" => "private captured archive",
      "url" => "https://example.test/",
      "viewport" => %{"width" => 1440, "height" => 900},
      "browser" => "140.0.7339.186"
    }
  end

  defp temp_path,
    do: Path.join(System.tmp_dir!(), "snapshot-#{System.unique_integer([:positive])}")
end
