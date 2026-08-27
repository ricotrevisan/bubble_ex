defmodule BubbleEx.PrivateFrontendExportTest do
  use ExUnit.Case, async: false

  alias BubbleEx.Error
  alias BubbleEx.FrontendFixtures
  alias BubbleEx.HTTP
  alias Plug.Conn

  @username "agency-user-33-unique"
  @password "agency-pass-33-unique"
  @cookie "session=session-33-unique; pref=pref-33-unique"
  @basic "Basic " <> Base.encode64(@username <> ":" <> @password)
  @scan [secret_scan_adapter: FrontendFixtures.clean_scanner()]

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> HTTP.delete_process_options() end)
    :ok
  end

  @tag :tmp_dir
  test "sends combined auth to page and same-origin dynamic bundle", %{tmp_dir: tmp} do
    pid = self()
    payload = FrontendFixtures.modern_page()
    stub_app(pid, payload)

    assert {:ok, result} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               Path.join(tmp, "pkg"),
               @scan ++ credentials()
             )

    assert_received {:request, "app.example.test", "/", [@basic], [@cookie]}

    assert_received {:request, "app.example.test", "/package/dynamic_js/1/dynamic.js", [@basic],
                     [@cookie]}

    assert_no_leak(result, Path.join(tmp, "pkg"))
  end

  @tag :tmp_dir
  test "keeps normal Req decompression for authenticated HTML and dynamic payloads", %{
    tmp_dir: tmp
  } do
    payload = FrontendFixtures.modern_page()

    Req.Test.stub(__MODULE__, fn conn ->
      body =
        if String.contains?(conn.request_path || "", "dynamic_js") do
          json = payload |> Jason.encode!() |> String.replace("'", "\'")
          "const app = JSON.parse('#{json}');
"
        else
          page_html()
        end

      conn
      |> Conn.put_resp_header("x-bubble-test", "1")
      |> Conn.put_resp_header("content-encoding", "gzip")
      |> Conn.resp(200, :zlib.gzip(body))
    end)

    assert {:ok, _} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               Path.join(tmp, "pkg"),
               @scan ++ credentials()
             )
  end

  @tag :tmp_dir
  test "imports a session cookie without attempting Basic auth", %{tmp_dir: tmp} do
    pid = self()
    stub_app(pid, FrontendFixtures.modern_page())

    assert {:ok, _} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               Path.join(tmp, "pkg"),
               @scan ++ [session_cookie: @cookie]
             )

    assert_received {:request, "app.example.test", "/", [], [@cookie]}

    assert_received {:request, "app.example.test", "/package/dynamic_js/1/dynamic.js", [],
                     [@cookie]}
  end

  @tag :tmp_dir
  test "absolute cross-origin dynamic bundle is fetched without credentials", %{tmp_dir: tmp} do
    pid = self()
    payload = FrontendFixtures.modern_page()

    Req.Test.stub(__MODULE__, fn conn ->
      record(conn, pid)
      conn = Conn.put_resp_header(conn, "x-bubble-test", "1")

      case {conn.host, conn.request_path || "/"} do
        {"app.example.test", "/"} ->
          Conn.resp(
            conn,
            200,
            "<script src='https://cdn.example.test/package/dynamic_js/foreign.js'></script>"
          )

        {"cdn.example.test", "/package/dynamic_js/foreign.js"} ->
          dynamic_response(conn, payload)
      end
    end)

    assert {:ok, _} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               Path.join(tmp, "pkg"),
               @scan ++ credentials()
             )

    assert_received {:request, "app.example.test", "/", [@basic], [@cookie]}
    assert_received {:request, "cdn.example.test", "/package/dynamic_js/foreign.js", [], []}
  end

  test "rejects userinfo in an absolute dynamic bundle before requesting it" do
    pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      record(conn, pid)
      conn = Conn.put_resp_header(conn, "x-bubble-test", "1")

      Conn.resp(
        conn,
        200,
        "<script src='https://evil-user:evil-pass@evil.example.test/package/dynamic_js/x.js'></script>"
      )
    end)

    assert {:error, %Error{kind: :parse_failed}} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               "unused",
               @scan ++ credentials()
             )

    assert_received {:request, "app.example.test", "/", [@basic], [@cookie]}
    refute_received {:request, "evil.example.test", _, _, _}
  end

  test "rejects an HTTP dynamic bundle downgrade before requesting it" do
    pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      record(conn, pid)
      conn = Conn.put_resp_header(conn, "x-bubble-test", "1")

      Conn.resp(
        conn,
        200,
        "<script src='http://cdn.example.test/package/dynamic_js/x.js'></script>"
      )
    end)

    assert {:error, %Error{kind: :parse_failed}} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               "unused",
               @scan ++ credentials()
             )

    assert_received {:request, "app.example.test", "/", [@basic], [@cookie]}
    refute_received {:request, "cdn.example.test", _, _, _}
  end

  test "rejects an output path containing a supplied credential" do
    stub_app(self(), FrontendFixtures.modern_page())

    assert {:error, %Error{kind: :export_blocked} = error} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               "/tmp/export-#{@password}",
               @scan ++ credentials()
             )

    assert_no_secret(inspect(error))
  end

  test "rejects a cross-origin payload redirect without forwarding auth" do
    pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      record(conn, pid)

      location =
        "https://evil.example.test/#{@password}?x=#{URI.encode_www_form(@cookie)}&u=#{@username}"

      Conn.put_resp_header(conn, "location", location)
      |> Conn.resp(302, "")
    end)

    assert {:error, %Error{kind: :request_failed} = error} =
             BubbleEx.export_frontend(
               "https://app.example.test/start",
               "unused",
               @scan ++ credentials()
             )

    assert_received {:request, "app.example.test", "/start", [@basic], [@cookie]}
    refute_received {:request, "evil.example.test", _, _, _}
    assert Exception.message(error) =~ "provide the final URL directly"
    assert_no_secret(inspect(error))
  end

  @tag :tmp_dir
  test "resolves a trusted dedicated instance without auth, then scopes auth to it", %{
    tmp_dir: tmp
  } do
    pid = self()
    payload = FrontendFixtures.modern_page()

    Req.Test.stub(__MODULE__, fn conn ->
      record(conn, pid)

      case {conn.host, conn.request_path || "/"} do
        {"dedicated.bubbleapps.io", "/"} ->
          Conn.put_resp_header(conn, "location", "https://d123.bubble.is/version-live")
          |> Conn.resp(302, "")

        {"d123.bubble.is", "/version-live"} ->
          conn |> Conn.put_resp_header("x-bubble-test", "1") |> Conn.resp(200, page_html())

        {"d123.bubble.is", "/package/dynamic_js/1/dynamic.js"} ->
          conn |> Conn.put_resp_header("x-bubble-test", "1") |> dynamic_response(payload)
      end
    end)

    assert {:ok, _} =
             BubbleEx.export_frontend(
               "https://dedicated.bubbleapps.io",
               Path.join(tmp, "pkg"),
               @scan ++ credentials()
             )

    assert_received {:request, "dedicated.bubbleapps.io", "/", [], []}
    assert_received {:request, "d123.bubble.is", "/version-live", [@basic], [@cookie]}

    assert_received {:request, "d123.bubble.is", "/package/dynamic_js/1/dynamic.js", [@basic],
                     [@cookie]}
  end

  @tag :tmp_dir
  test "authenticated same-origin assets download once and rewrite pages and fragments", %{
    tmp_dir: tmp
  } do
    pid = self()
    payload = asset_payload()
    stub_app_with_asset(pid, payload, :ok)
    out = Path.join(tmp, "pkg")

    assert {:ok, result} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               out,
               @scan ++ credentials() ++ [asset_access: :same_origin]
             )

    assert_received {:request, "app.example.test", "/private.png", [@basic], [@cookie]}
    refute_received {:request, "app.example.test", "/private.png", _, _}

    page = File.read!(Path.join(out, "pages/index/index.html"))
    fragment = File.read!(Path.join(out, "reusables/gallery--gallery/fragment.html"))
    refute page =~ "https://app.example.test"
    refute fragment =~ "https://app.example.test"
    assert page =~ "../../assets/"
    assert fragment =~ "../../assets/"
    assert result.manifest["options"]["asset_access"] == "same_origin"
    assert_no_leak(result, out)
  end

  @tag :tmp_dir
  test "public asset mode never sends configured auth", %{tmp_dir: tmp} do
    pid = self()
    stub_app_with_asset(pid, asset_payload(), :ok)

    assert {:ok, _} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               Path.join(tmp, "pkg"),
               @scan ++ credentials()
             )

    assert_received {:request, "app.example.test", "/private.png", [], []}
  end

  @tag :tmp_dir
  test "Google font requests never receive Bubble authentication", %{tmp_dir: tmp} do
    pid = self()
    font_url = "https://fonts.gstatic.com/s/inter/v20/private-test.woff2"

    payload =
      FrontendFixtures.modern_page()
      |> put_in(["pages", "home", "properties", "font_family"], "Inter")

    Req.Test.stub(__MODULE__, fn conn ->
      record(conn, pid)

      case {conn.host, conn.request_path || "/"} do
        {"app.example.test", "/"} ->
          conn
          |> Conn.put_resp_header("x-bubble-test", "1")
          |> Conn.resp(
            200,
            """
            <script>const WebFontConfig = {google: {families: ["Inter:regular"]}};</script>
            <script src="/package/dynamic_js/1/dynamic.js"></script>
            """
          )

        {"app.example.test", "/package/dynamic_js/1/dynamic.js"} ->
          conn
          |> Conn.put_resp_header("x-bubble-test", "1")
          |> dynamic_response(payload)

        {"fonts.googleapis.com", "/css"} ->
          conn
          |> Conn.put_resp_content_type("text/css")
          |> Conn.resp(
            200,
            """
            @font-face {
              font-family: 'Inter';
              font-style: normal;
              font-weight: 400;
              src: url(#{font_url}) format('woff2');
            }
            """
          )

        {"fonts.gstatic.com", "/s/inter/v20/private-test.woff2"} ->
          conn
          |> Conn.put_resp_content_type("font/woff2")
          |> Conn.resp(200, <<"wOF2", 0, 1, 2, 3>>)
      end
    end)

    assert {:ok, _} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               Path.join(tmp, "pkg"),
               @scan ++ credentials() ++ [asset_access: :same_origin]
             )

    assert_received {:request, "fonts.googleapis.com", "/css", [], []}
    assert_received {:request, "fonts.gstatic.com", "/s/inter/v20/private-test.woff2", [], []}
  end

  @tag :tmp_dir
  test "failed protected assets become findings and non-fetching HTML", %{tmp_dir: tmp} do
    pid = self()
    stub_app_with_asset(pid, asset_payload(), :html_login)
    out = Path.join(tmp, "pkg")

    assert {:ok, result} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               out,
               @scan ++ credentials() ++ [asset_access: :same_origin]
             )

    assert Enum.any?(result.findings, &(&1["type"] == "asset_failure"))
    page = File.read!(Path.join(out, "pages/index/index.html"))
    fragment = File.read!(Path.join(out, "reusables/gallery--gallery/fragment.html"))
    refute page =~ "/private.png"
    refute fragment =~ "/private.png"
    assert {:ok, doc} = Floki.parse_document(page)
    assert Floki.find(doc, "img") |> Floki.attribute("src") == []
  end

  @tag :tmp_dir
  test "oversize protected assets become findings and do not abort publishing", %{tmp_dir: tmp} do
    pid = self()
    stub_app_with_asset(pid, asset_payload(), :ok)
    out = Path.join(tmp, "pkg")

    assert {:ok, result} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               out,
               @scan ++ credentials() ++ [asset_access: :same_origin, max_asset_bytes: 4]
             )

    assert Enum.any?(result.findings, &(&1["message"] =~ "max_asset_bytes"))
    refute File.read!(Path.join(out, "pages/index/index.html")) =~ "/private.png"
  end

  @tag :tmp_dir
  test "a protected asset redirect cannot cross origins", %{tmp_dir: tmp} do
    pid = self()
    stub_app_with_asset(pid, asset_payload(), :foreign_redirect)
    out = Path.join(tmp, "pkg")

    assert {:ok, result} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               out,
               @scan ++ credentials() ++ [asset_access: :same_origin]
             )

    assert Enum.any?(result.findings, &(&1["message"] =~ "left the authenticated origin"))
    refute_received {:request, "cdn.example.test", _, _, _}
    refute File.read!(Path.join(out, "pages/index/index.html")) =~ "/private.png"
  end

  @tag :tmp_dir
  test "credential echo in an authenticated asset blocks all output", %{tmp_dir: tmp} do
    pid = self()
    stub_app_with_asset(pid, asset_payload(), :credential_echo)
    out = Path.join(tmp, "pkg")

    assert {:error, %Error{kind: :export_blocked} = error} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               out,
               @scan ++ credentials() ++ [asset_access: :same_origin]
             )

    refute File.exists?(out)
    assert_no_secret(inspect(error))
  end

  @tag :tmp_dir
  test "authentication failure is redacted and writes nothing", %{tmp_dir: tmp} do
    Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 401, "echo #{@password} #{@cookie}") end)
    out = Path.join(tmp, "pkg")

    assert {:error, %Error{kind: :unauthorized} = error} =
             BubbleEx.export_frontend("https://app.example.test", out, @scan ++ credentials())

    refute File.exists?(out)
    assert_no_secret(inspect(error))
  end

  @tag :tmp_dir
  test "rejects a credential-tainted page path before an extra request", %{tmp_dir: tmp} do
    pid = self()

    payload = %{
      "_id" => "private-hydration",
      "%p3" => %{
        "opaque" => %{
          "%nm" => @password,
          "%p" => %{"container_layout" => "column"},
          "%x" => "Page",
          "id" => "opaque"
        }
      }
    }

    stub_app(pid, payload)
    out = Path.join(tmp, "pkg")

    assert {:error, %Error{kind: :export_blocked} = error} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               out,
               @scan ++ credentials()
             )

    refute_received {:request, "app.example.test", "/#{@password}", _, _}
    refute File.exists?(out)
    assert_no_secret(inspect(error))
  end

  @tag :tmp_dir
  test "an extra page redirect cannot leave the authenticated origin", %{tmp_dir: tmp} do
    pid = self()
    handler = {__MODULE__, :hydration_http, System.unique_integer()}

    :telemetry.attach_many(
      handler,
      [[:bubble_ex, :http, :request, :start], [:bubble_ex, :http, :request, :stop]],
      fn name, measurements, metadata, test_pid ->
        send(test_pid, {:hydration_telemetry, name, measurements, metadata})
      end,
      pid
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    payload = %{
      "_id" => "private-hydration",
      "%p3" => %{
        "opaque" => %{
          "%nm" => "private-page",
          "%p" => %{"container_layout" => "column"},
          "%x" => "Page",
          "id" => "opaque"
        }
      }
    }

    Req.Test.stub(__MODULE__, fn conn ->
      record(conn, pid)

      case conn.request_path || "/" do
        "/" ->
          conn |> Conn.put_resp_header("x-bubble-test", "1") |> Conn.resp(200, page_html())

        "/package/dynamic_js/1/dynamic.js" ->
          conn |> Conn.put_resp_header("x-bubble-test", "1") |> dynamic_response(payload)

        "/private-page" ->
          conn
          |> Conn.put_resp_header("location", "https://evil.example.test/#{@password}")
          |> Conn.resp(302, "")
      end
    end)

    out = Path.join(tmp, "pkg")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(
          pid,
          {:hydration_result,
           BubbleEx.export_frontend(
             "https://app.example.test",
             out,
             @scan ++ credentials()
           )}
        )
      end)

    assert_received {:hydration_result, {:error, %Error{kind: :request_failed} = error}}
    assert_received {:request, "app.example.test", "/private-page", [@basic], [@cookie]}
    refute_received {:request, "evil.example.test", _, _, _}
    refute File.exists?(out)

    telemetry = collect_hydration_telemetry()
    assert telemetry != []
    assert_no_secret(inspect(error))
    assert_no_secret(log)
    assert_no_secret(inspect(telemetry))
  end

  defp collect_hydration_telemetry(acc \\ []) do
    receive do
      {:hydration_telemetry, name, measurements, metadata} ->
        collect_hydration_telemetry([{name, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp credentials, do: [username: @username, password: @password, session_cookie: @cookie]
  defp expected_basic, do: @basic

  defp stub_app(pid, payload) do
    Req.Test.stub(__MODULE__, fn conn ->
      record(conn, pid)
      conn = Conn.put_resp_header(conn, "x-bubble-test", "1")

      if String.contains?(conn.request_path || "", "dynamic_js"),
        do: dynamic_response(conn, payload),
        else: Conn.resp(conn, 200, page_html())
    end)
  end

  defp stub_app_with_asset(pid, payload, asset_mode) do
    Req.Test.stub(__MODULE__, fn conn ->
      record(conn, pid)
      respond_app_with_asset(conn, conn.request_path || "/", payload, asset_mode)
    end)
  end

  defp respond_app_with_asset(conn, "/private.png", _payload, asset_mode),
    do: asset_response(conn, asset_mode)

  defp respond_app_with_asset(conn, path, payload, _asset_mode) do
    conn = Conn.put_resp_header(conn, "x-bubble-test", "1")

    if String.contains?(path, "dynamic_js"),
      do: dynamic_response(conn, payload),
      else: Conn.resp(conn, 200, page_html())
  end

  defp asset_response(conn, :ok),
    do: conn |> Conn.put_resp_header("content-type", "image/png") |> Conn.resp(200, "PNG-BYTES")

  defp asset_response(conn, :html_login),
    do:
      conn
      |> Conn.put_resp_header("content-type", "text/html")
      |> Conn.resp(200, "<html>login</html>")

  defp asset_response(conn, :credential_echo),
    do: conn |> Conn.put_resp_header("content-type", "image/png") |> Conn.resp(200, @password)

  defp asset_response(conn, :foreign_redirect),
    do:
      conn
      |> Conn.put_resp_header("location", "https://cdn.example.test/private.png")
      |> Conn.resp(302, "")

  defp page_html, do: "<html><script src='/package/dynamic_js/1/dynamic.js'></script></html>"

  defp dynamic_response(conn, payload) do
    json = payload |> Jason.encode!() |> String.replace("'", "\\'")
    Conn.resp(conn, 200, "const app = JSON.parse('#{json}');\n")
  end

  defp record(conn, pid) do
    send(
      pid,
      {:request, conn.host, conn.request_path || "/", Conn.get_req_header(conn, "authorization"),
       Conn.get_req_header(conn, "cookie")}
    )
  end

  defp asset_payload do
    %{
      "_id" => "private-assets-app",
      "app_version" => "live",
      "pages" => %{
        "home" => %{
          "id" => "home",
          "type" => "Page",
          "name" => "index",
          "properties" => %{"container_layout" => "column"},
          "elements" => %{
            "photo" => %{
              "id" => "page-photo",
              "type" => "Image",
              "properties" => %{"src" => "https://app.example.test:443/private.png"}
            }
          }
        }
      },
      "element_definitions" => %{
        "gallery" => %{
          "id" => "gallery-inner",
          "name" => "Gallery",
          "type" => "CustomDefinition",
          "properties" => %{"container_layout" => "column"},
          "elements" => %{
            "photo" => %{
              "id" => "reusable-photo",
              "type" => "Image",
              "properties" => %{"src" => "https://app.example.test/private.png"}
            }
          }
        }
      }
    }
  end

  defp assert_no_leak(result, out) do
    assert_no_secret(inspect(result))

    out
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      assert_no_secret(path)
      if File.regular?(path), do: assert_no_secret(File.read!(path))
    end)
  end

  defp assert_no_secret(value) do
    for secret <- [
          @username,
          @password,
          expected_basic(),
          @cookie,
          "session-33-unique",
          "pref-33-unique"
        ] do
      refute value =~ secret
    end
  end
end
