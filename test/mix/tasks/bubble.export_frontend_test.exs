defmodule Mix.Tasks.Bubble.ExportFrontendTest do
  use ExUnit.Case, async: false

  alias BubbleEx.FrontendFixtures
  alias BubbleEx.HTTP
  alias Plug.Conn

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    previous = Application.get_env(:bubble_ex, :secrets_adapter)

    env_names = [
      "BUBBLE_EX_FRONTEND_USERNAME",
      "BUBBLE_EX_FRONTEND_PASSWORD",
      "BUBBLE_EX_FRONTEND_SESSION_COOKIE"
    ]

    previous_env = Map.new(env_names, &{&1, System.get_env(&1)})
    Enum.each(env_names, &System.delete_env/1)
    Application.put_env(:bubble_ex, :secrets_adapter, FrontendFixtures.clean_scanner())

    on_exit(fn ->
      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

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
  test "accepts --version, --pages, --max-page-fetches, --fallback, and --force", %{tmp_dir: tmp} do
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
          "--max-page-fetches",
          "0",
          "--fallback",
          "--force"
        ])
      end)

    assert output =~ "Wrote"
    assert File.exists?(Path.join(out, "pages/index/index.html"))
    refute File.exists?(Path.join(out, "pages/about/index.html"))
  end

  @tag :tmp_dir
  test "--max-page-fetches fails closed before writing an over-bound export", %{tmp_dir: tmp} do
    payload = %{
      "_id" => "mix-hydration",
      "%p3" => %{
        "opaque" => %{
          "%nm" => "page-a",
          "%p" => %{"container_layout" => "column"},
          "%x" => "Page",
          "id" => "opaque"
        }
      }
    }

    stub_fetch(payload)
    out = Path.join(tmp, "pkg")

    assert_raise Mix.Error, ~r/max_page_fetches/, fn ->
      Mix.Tasks.Bubble.ExportFrontend.run([
        "https://app.example.test",
        "-o",
        out,
        "--max-page-fetches",
        "0"
      ])
    end

    refute File.exists?(out)
  end

  @tag :tmp_dir
  test "reads combined transport credentials from namespaced environment variables", %{
    tmp_dir: tmp
  } do
    username = "mix-user-33-unique"
    password = "mix-pass-33-unique"
    cookie = "session=mix-session-33-unique"
    basic = "Basic " <> Base.encode64(username <> ":" <> password)
    System.put_env("BUBBLE_EX_FRONTEND_USERNAME", username)
    System.put_env("BUBBLE_EX_FRONTEND_PASSWORD", password)
    System.put_env("BUBBLE_EX_FRONTEND_SESSION_COOKIE", cookie)
    pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(
        pid,
        {:auth, Conn.get_req_header(conn, "authorization"), Conn.get_req_header(conn, "cookie")}
      )

      respond_fetch(conn, FrontendFixtures.modern_page())
    end)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Bubble.ExportFrontend.run([
          "s1app",
          "-o",
          Path.join(tmp, "pkg"),
          "--authenticated-assets"
        ])
      end)

    assert_received {:auth, [^basic], [^cookie]}
    refute output =~ username
    refute output =~ password
    refute output =~ cookie

    manifest = Path.join([tmp, "pkg", "MANIFEST.json"]) |> File.read!() |> Jason.decode!()
    assert manifest["options"]["asset_access"] == "same_origin"
  end

  @tag :tmp_dir
  test "accepts Basic URL userinfo and never prints it", %{tmp_dir: tmp} do
    username = "url-user-33-unique"
    password = "url-pass-33-unique"
    raw_url = "https://#{username}:#{password}@app.example.test"
    basic = "Basic " <> Base.encode64(username <> ":" <> password)
    pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(pid, {:url_auth, conn.host, Conn.get_req_header(conn, "authorization")})
      respond_fetch(conn, FrontendFixtures.modern_page())
    end)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Bubble.ExportFrontend.run([raw_url, "-o", Path.join(tmp, "pkg")])
      end)

    assert_received {:url_auth, "app.example.test", [^basic]}
    refute output =~ raw_url
    refute output =~ username
    refute output =~ password
  end

  test "rejects a partial Basic environment pair without echoing it" do
    secret = "partial-user-33-unique"
    System.put_env("BUBBLE_EX_FRONTEND_USERNAME", secret)

    error =
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Bubble.ExportFrontend.run(["s1app", "-o", "unused"])
      end

    refute Exception.message(error) =~ secret
  end

  @tag :tmp_dir
  test "surfaces export errors as Mix errors", %{tmp_dir: tmp} do
    Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 200, "<html>not bubble</html>") end)

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Bubble.ExportFrontend.run(["s1app", "-o", Path.join(tmp, "out")])
    end
  end

  defp stub_fetch(payload) do
    Req.Test.stub(__MODULE__, &respond_fetch(&1, payload))
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
