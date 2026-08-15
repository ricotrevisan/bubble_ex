defmodule BubbleEx.ExportFrontendTest do
  use ExUnit.Case, async: false

  alias BubbleEx.Error
  alias BubbleEx.Frontend.Export.Result
  alias BubbleEx.FrontendFixtures
  alias BubbleEx.HTTP
  alias Plug.Conn

  @scan [secret_scan_adapter: FrontendFixtures.clean_scanner()]

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> HTTP.delete_process_options() end)
    :ok
  end

  @tag :tmp_dir
  test "fetches one named app version and writes the package", %{tmp_dir: tmp} do
    out = Path.join(tmp, "pkg")
    stub_fetch(FrontendFixtures.modern_page())

    assert {:ok, %Result{out_dir: ^out, files: files}} =
             BubbleEx.export_frontend("s1app", out, @scan)

    assert "MANIFEST.json" in files
    assert File.exists?(Path.join(out, "pages/index/index.html"))
  end

  @tag :tmp_dir
  test "requests the test version URL and does not fall back", %{tmp_dir: tmp} do
    out = Path.join(tmp, "pkg")
    pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(pid, {:fetched, conn.request_path, conn.host})
      respond_fetch(conn, FrontendFixtures.modern_page())
    end)

    assert {:ok, %Result{}} =
             BubbleEx.export_frontend("s1app", out, @scan ++ [app_version: "test"])

    paths =
      for _ <- 1..2 do
        assert_received {:fetched, path, "s1app.bubbleapps.io"}
        path
      end

    assert Enum.all?(paths, &(&1 =~ "version-test" or &1 =~ "dynamic_js"))
    assert Enum.any?(paths, &(&1 =~ "version-test"))
    refute_received {:fetched, _, _}
  end

  test "surfaces fetch failures as BubbleEx.Error" do
    Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 200, "<html>not bubble</html>") end)

    assert {:error, %Error{}} =
             BubbleEx.export_frontend("s1app", "unused", @scan)
  end

  defp stub_fetch(payload) do
    Req.Test.stub(__MODULE__, fn conn -> respond_fetch(conn, payload) end)
  end

  defp respond_fetch(conn, payload) do
    conn = Conn.put_resp_header(conn, "x-bubble-something", "1")
    path = conn.request_path || ""

    if String.contains?(path, "dynamic_js") do
      json = payload |> Jason.encode!() |> String.replace("'", "\\'")
      Conn.resp(conn, 200, "const app = JSON.parse('#{json}');\n")
    else
      Conn.resp(
        conn,
        200,
        "<html><script src='/package/dynamic_js/1/dynamic.js'></script></html>"
      )
    end
  end
end
