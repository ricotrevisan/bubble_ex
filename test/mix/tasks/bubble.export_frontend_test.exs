defmodule Mix.Tasks.Bubble.ExportFrontendTest do
  use ExUnit.Case, async: false

  alias BubbleEx.FrontendFixtures
  alias BubbleEx.HTTP
  alias Plug.Conn

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    previous = Application.get_env(:bubble_ex, :secrets_adapter)
    Application.put_env(:bubble_ex, :secrets_adapter, FrontendFixtures.clean_scanner())

    on_exit(fn ->
      HTTP.delete_process_options()

      if previous do
        Application.put_env(:bubble_ex, :secrets_adapter, previous)
      else
        Application.delete_env(:bubble_ex, :secrets_adapter)
      end
    end)

    :ok
  end

  @tag :tmp_dir
  test "runs end-to-end and reports the written package", %{tmp_dir: tmp} do
    out = Path.join(tmp, "pkg")
    stub_fetch(FrontendFixtures.modern_page())

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Bubble.ExportFrontend.run(["s1app", "-o", out, "--force"])
      end)

    assert output =~ "Wrote"
    assert output =~ out
    assert File.exists?(Path.join(out, "MANIFEST.json"))
  end

  test "raises a usage error without arguments" do
    assert_raise Mix.Error, ~r/usage/, fn ->
      Mix.Tasks.Bubble.ExportFrontend.run([])
    end
  end

  test "does not accept credential flags" do
    assert_raise Mix.Error, ~r/usage/, fn ->
      Mix.Tasks.Bubble.ExportFrontend.run(["s1app", "-o", "out", "--username", "x"])
    end
  end

  @tag :tmp_dir
  test "accepts --version, --pages, --fallback, and --force", %{tmp_dir: tmp} do
    out = Path.join(tmp, "pkg")
    stub_fetch(FrontendFixtures.two_page_app())

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Bubble.ExportFrontend.run([
          "s1app",
          "-o",
          out,
          "--version",
          "live",
          "--pages",
          "index",
          "--fallback",
          "--force"
        ])
      end)

    assert output =~ "Wrote"
    assert File.exists?(Path.join(out, "pages/index/index.html"))
    refute File.exists?(Path.join(out, "pages/about/index.html"))
  end

  @tag :tmp_dir
  test "surfaces export errors as Mix errors", %{tmp_dir: tmp} do
    Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 200, "<html>not bubble</html>") end)

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Bubble.ExportFrontend.run(["s1app", "-o", Path.join(tmp, "out")])
    end
  end

  defp stub_fetch(payload) do
    Req.Test.stub(__MODULE__, fn conn ->
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
    end)
  end
end
