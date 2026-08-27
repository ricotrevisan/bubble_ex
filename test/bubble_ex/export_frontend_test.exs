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
  test "packages used Google WebFonts as local deduplicated WOFF2 assets", %{tmp_dir: tmp} do
    out = Path.join(tmp, "pkg")
    pid = self()
    payload = inter_payload()
    font_url = "https://fonts.gstatic.com/s/inter/v20/inter-latin.woff2"
    font = <<"wOF2", 0, 1, 2, 3, 4, 5, 6, 7>>

    Req.Test.stub(__MODULE__, fn conn ->
      send(pid, {:font_request, conn.host, conn.request_path})

      case {conn.host, conn.request_path || "/"} do
        {"s1app.bubbleapps.io", "/"} ->
          conn
          |> Conn.put_resp_header("x-bubble-test", "1")
          |> Conn.resp(200, webfont_page_html())

        {"s1app.bubbleapps.io", "/package/dynamic_js/1/dynamic.js"} ->
          conn
          |> Conn.put_resp_header("x-bubble-test", "1")
          |> Conn.resp(200, dynamic_script(payload))

        {"fonts.googleapis.com", "/css"} ->
          conn
          |> Conn.put_resp_content_type("text/css")
          |> Conn.resp(200, inter_font_css(font_url))

        {"fonts.gstatic.com", "/s/inter/v20/inter-latin.woff2"} ->
          conn
          |> Conn.put_resp_content_type("font/woff2")
          |> Conn.resp(200, font)
      end
    end)

    assert {:ok, %Result{files: files}} = BubbleEx.export_frontend("s1app", out, @scan)

    font_paths = Enum.filter(files, &String.ends_with?(&1, ".woff2"))
    assert [font_path] = font_paths
    assert File.read!(Path.join(out, font_path)) == font

    shared = File.read!(Path.join(out, "styles/shared.css"))

    for weight <- [400, 500, 600, 700, 800] do
      assert shared =~ "font-weight: #{weight};"
    end

    assert shared =~ "url(\"../#{font_path}\")"
    refute shared =~ "fonts.googleapis.com"
    refute shared =~ "fonts.gstatic.com"

    manifest = File.read!(Path.join(out, "MANIFEST.json")) |> Jason.decode!()
    assert font_path in manifest["files"]

    assert_received {:font_request, "fonts.googleapis.com", "/css"}
    assert_received {:font_request, "fonts.gstatic.com", "/s/inter/v20/inter-latin.woff2"}
    refute_received {:font_request, "fonts.gstatic.com", _, _}
  end

  @tag :tmp_dir
  test "font download failures become findings without remote font CSS", %{tmp_dir: tmp} do
    out = Path.join(tmp, "pkg")
    payload = inter_payload()
    font_url = "https://fonts.gstatic.com/s/inter/v20/inter-latin.woff2"

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.host, conn.request_path || "/"} do
        {"s1app.bubbleapps.io", "/"} ->
          conn
          |> Conn.put_resp_header("x-bubble-test", "1")
          |> Conn.resp(200, webfont_page_html())

        {"s1app.bubbleapps.io", "/package/dynamic_js/1/dynamic.js"} ->
          conn
          |> Conn.put_resp_header("x-bubble-test", "1")
          |> Conn.resp(200, dynamic_script(payload))

        {"fonts.googleapis.com", "/css"} ->
          conn
          |> Conn.put_resp_content_type("text/css")
          |> Conn.resp(200, inter_font_css(font_url))

        {"fonts.gstatic.com", "/s/inter/v20/inter-latin.woff2"} ->
          conn
          |> Conn.put_resp_content_type("text/html")
          |> Conn.resp(200, "login")
      end
    end)

    assert {:ok, %Result{findings: findings, files: files}} =
             BubbleEx.export_frontend("s1app", out, @scan)

    assert Enum.any?(findings, &(&1["message"] =~ "unexpected content type"))
    refute Enum.any?(files, &String.ends_with?(&1, ".woff2"))

    shared = File.read!(Path.join(out, "styles/shared.css"))
    refute shared =~ "@font-face"
    refute shared =~ "fonts.gstatic.com"

    page_css = File.read!(Path.join(out, "styles/pages/index.css"))
    assert page_css =~ ~s(font-family: "Inter", Helvetica, Arial, sans-serif;)
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

  @tag :tmp_dir
  test "hydrates multiple selected aliased pages from their versioned page URLs", %{tmp_dir: tmp} do
    pid = self()
    payload = aliased_metadata_app([{"opaque-a", "page-a"}, {"opaque-b", "page-b"}])

    Req.Test.stub(__MODULE__, fn conn ->
      send(pid, {:fetched, conn.request_path || "/"})
      respond_hydration_fetch(conn, payload)
    end)

    out = Path.join(tmp, "pkg")

    assert {:ok, %Result{} = result} =
             BubbleEx.export_frontend(
               "https://app.example.test/version-test",
               out,
               @scan ++ [pages: ["page-a", "page-b"]]
             )

    assert File.read!(Path.join(out, "pages/page-a/index.html")) =~ "Hydrated page-a"
    assert File.read!(Path.join(out, "pages/page-b/index.html")) =~ "Hydrated page-b"
    assert result.coverage["overall"]["elements"]["native"] == 2

    assert get_in(result.model.source.payload, ["_index", "id_to_path"]) == %{
             "existing" => "pages.existing",
             "opaque-a-text" => "pages.opaque-a.elements.text",
             "opaque-b-text" => "pages.opaque-b.elements.text"
           }

    assert_received {:fetched, "/version-test"}
    assert_received {:fetched, "/package/dynamic_js/root/dynamic.js"}
    assert_received {:fetched, "/version-test/page-a"}
    assert_received {:fetched, "/package/dynamic_js/page-a/dynamic.js"}
    assert_received {:fetched, "/version-test/page-b"}
    assert_received {:fetched, "/package/dynamic_js/page-b/dynamic.js"}
    refute_received {:fetched, _}
  end

  @tag :tmp_dir
  test "preserves a custom Bubble branch in selected-page hydration URLs", %{tmp_dir: tmp} do
    pid = self()
    payload = aliased_metadata_app([{"opaque-a", "page-a"}])

    Req.Test.stub(__MODULE__, fn conn ->
      path = conn.request_path || "/"
      send(pid, {:fetched, path})
      conn = Conn.put_resp_header(conn, "x-bubble-something", "1")

      case path do
        "/version-13iti" ->
          Conn.resp(conn, 200, page_html("/package/dynamic_js/root/dynamic.js"))

        "/package/dynamic_js/root/dynamic.js" ->
          Conn.resp(conn, 200, dynamic_script(payload))

        "/version-13iti/page-a" ->
          Conn.resp(conn, 200, page_html("/package/dynamic_js/page-a/dynamic.js"))

        "/package/dynamic_js/page-a/dynamic.js" ->
          Conn.resp(conn, 200, dynamic_script(payload, "opaque-a", "page-a"))
      end
    end)

    assert {:ok, %Result{}} =
             BubbleEx.export_frontend(
               "https://app.example.test/version-13iti",
               Path.join(tmp, "pkg"),
               @scan ++ [pages: ["page-a"]]
             )

    assert_received {:fetched, "/version-13iti/page-a"}
    refute_received {:fetched, "/page-a"}
  end

  @tag :tmp_dir
  test "deduplicates identical normalized page URLs", %{tmp_dir: tmp} do
    pid = self()
    payload = aliased_metadata_app([{"opaque-a", "same-page"}, {"opaque-b", "same-page"}])

    Req.Test.stub(__MODULE__, fn conn ->
      path = conn.request_path || "/"
      send(pid, {:fetched, path})
      conn = Conn.put_resp_header(conn, "x-bubble-something", "1")

      case path do
        "/version-test" ->
          Conn.resp(conn, 200, page_html("/package/dynamic_js/root/dynamic.js"))

        "/package/dynamic_js/root/dynamic.js" ->
          Conn.resp(conn, 200, dynamic_script(payload))

        "/version-test/same-page" ->
          Conn.resp(conn, 200, page_html("/package/dynamic_js/same-page/dynamic.js"))

        "/package/dynamic_js/same-page/dynamic.js" ->
          Conn.resp(
            conn,
            200,
            dynamic_script(payload, [
              {"opaque-a", "same-page-a"},
              {"opaque-b", "same-page-b"}
            ])
          )
      end
    end)

    assert {:ok, %Result{}} =
             BubbleEx.export_frontend(
               "https://app.example.test/version-test",
               Path.join(tmp, "pkg"),
               @scan
             )

    assert_received {:fetched, "/version-test/same-page"}
    refute_received {:fetched, "/version-test/same-page"}
  end

  @tag :tmp_dir
  test "fails closed when a page-specific bundle does not hydrate the selected page", %{
    tmp_dir: tmp
  } do
    pid = self()
    payload = aliased_metadata_app([{"opaque-a", "page-a"}, {"opaque-b", "page-b"}])

    Req.Test.stub(__MODULE__, fn conn ->
      path = conn.request_path || "/"
      send(pid, {:fetched, path})
      conn = Conn.put_resp_header(conn, "x-bubble-something", "1")

      case path do
        "/version-test" ->
          Conn.resp(conn, 200, page_html("/package/dynamic_js/root/dynamic.js"))

        "/package/dynamic_js/root/dynamic.js" ->
          Conn.resp(conn, 200, dynamic_script(payload, "opaque-a", "page-a"))

        "/version-test/page-b" ->
          Conn.resp(conn, 200, page_html("/package/dynamic_js/page-b/dynamic.js"))

        "/package/dynamic_js/page-b/dynamic.js" ->
          Conn.resp(conn, 200, dynamic_script(payload, "opaque-a", "page-a"))
      end
    end)

    out = Path.join(tmp, "pkg")

    assert {:error, %Error{kind: :parse_failed, context: %{pages: ["page-b"]}}} =
             BubbleEx.export_frontend(
               "https://app.example.test/version-test",
               out,
               @scan ++ [pages: ["page-b"]]
             )

    assert_received {:fetched, "/version-test/page-b"}
    refute File.exists?(out)
  end

  @tag :tmp_dir
  test "validates every page ref before making extra requests", %{tmp_dir: tmp} do
    pid = self()
    payload = aliased_metadata_app([{"opaque-a", "page-a"}])

    Req.Test.stub(__MODULE__, fn conn ->
      send(pid, {:fetched, conn.request_path || "/"})
      respond_hydration_fetch(conn, payload)
    end)

    out = Path.join(tmp, "pkg")

    assert {:error, %Error{kind: :invalid_input, message: "unknown page ref"}} =
             BubbleEx.export_frontend(
               "https://app.example.test/version-test",
               out,
               @scan ++ [pages: ["page-a", "unknown"]]
             )

    assert_received {:fetched, "/version-test"}
    assert_received {:fetched, "/package/dynamic_js/root/dynamic.js"}
    refute_received {:fetched, "/version-test/" <> _}
    refute File.exists?(out)
  end

  @tag :tmp_dir
  test "fails before extra requests when page hydration exceeds its bound", %{tmp_dir: tmp} do
    pid = self()

    payload =
      aliased_metadata_app([
        {"opaque-a", "page-a"},
        {"opaque-b", "page-b"},
        {"opaque-c", "page-c"}
      ])

    Req.Test.stub(__MODULE__, fn conn ->
      send(pid, {:fetched, conn.request_path || "/"})
      respond_hydration_fetch(conn, payload)
    end)

    out = Path.join(tmp, "pkg")

    assert {:error,
            %Error{
              kind: :invalid_input,
              context: %{max_page_fetches: 2, page_fetches: 3}
            }} =
             BubbleEx.export_frontend(
               "https://app.example.test/version-test",
               out,
               @scan ++ [max_page_fetches: 2]
             )

    assert_received {:fetched, "/version-test"}
    assert_received {:fetched, "/package/dynamic_js/root/dynamic.js"}
    refute_received {:fetched, "/version-test/" <> _}
    refute File.exists?(out)
  end

  @tag :tmp_dir
  test "does not hydrate already-readable pages", %{tmp_dir: tmp} do
    pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(pid, {:fetched, conn.request_path || "/"})
      respond_fetch(conn, FrontendFixtures.modern_page())
    end)

    assert {:ok, %Result{}} =
             BubbleEx.export_frontend(
               "https://app.example.test",
               Path.join(tmp, "pkg"),
               @scan
             )

    assert_received {:fetched, "/"}
    assert_received {:fetched, "/package/dynamic_js/1/dynamic.js"}
    refute_received {:fetched, _}
  end

  defp webfont_page_html do
    """
    <html>
      <script>
        const WebFontConfig = {google: {families: ["Inter:regular", "Inter:500", "Inter:600", "Inter:700", "Inter:800"]}};
      </script>
      <script src="/package/dynamic_js/1/dynamic.js"></script>
    </html>
    """
  end

  defp inter_payload do
    FrontendFixtures.modern_page()
    |> put_in(["pages", "home", "properties", "font_family"], "Inter")
    |> put_in(["pages", "home", "elements"], %{
      "regular" => %{
        "id" => "regular",
        "type" => "Text",
        "properties" => %{"text" => "Regular", "font_weight" => "400"}
      },
      "medium" => %{
        "id" => "medium",
        "type" => "Text",
        "properties" => %{"text" => "Medium", "font_weight" => "500"}
      },
      "semibold" => %{
        "id" => "semibold",
        "type" => "Text",
        "properties" => %{"text" => "Semibold", "font_weight" => "600"}
      },
      "bold" => %{
        "id" => "bold",
        "type" => "Text",
        "properties" => %{"text" => "Bold", "font_weight" => "700"}
      },
      "extra" => %{
        "id" => "extra",
        "type" => "Text",
        "properties" => %{"text" => "Extra", "font_weight" => "800"}
      }
    })
  end

  defp inter_font_css(font_url) do
    Enum.map_join([400, 500, 600, 700, 800], "\n", fn weight ->
      """
      @font-face {
        font-family: 'Inter';
        font-style: normal;
        font-weight: #{weight};
        src: url(#{font_url}) format('woff2');
        unicode-range: U+0000-00FF;
      }
      """
    end)
  end

  defp stub_fetch(payload) do
    Req.Test.stub(__MODULE__, fn conn -> respond_fetch(conn, payload) end)
  end

  defp respond_hydration_fetch(conn, payload) do
    path = conn.request_path || "/"
    conn = Conn.put_resp_header(conn, "x-bubble-something", "1")

    case path do
      "/version-test" ->
        Conn.resp(conn, 200, page_html("/package/dynamic_js/root/dynamic.js"))

      "/version-test/" <> page_name ->
        Conn.resp(conn, 200, page_html("/package/dynamic_js/#{page_name}/dynamic.js"))

      "/package/dynamic_js/root/dynamic.js" ->
        Conn.resp(conn, 200, dynamic_script(payload))

      "/package/dynamic_js/" <> page_script ->
        page_name = String.trim_trailing(page_script, "/dynamic.js")

        Conn.resp(conn, 200, dynamic_script(payload, page_key(page_name), page_name))
    end
  end

  defp page_key("page-a"), do: "opaque-a"
  defp page_key("page-b"), do: "opaque-b"
  defp page_key(_page_name), do: "opaque-c"

  defp aliased_metadata_app(pages) do
    %{
      "_id" => "live-hydration-app",
      "app_version" => "test",
      "%p3" =>
        Map.new(pages, fn {key, name} ->
          {key,
           %{
             "%nm" => name,
             "%p" => %{"container_layout" => "column"},
             "%x" => "Page",
             "id" => key
           }}
        end),
      "_index" => %{"id_to_path" => %{"existing" => "pages.existing"}}
    }
  end

  defp dynamic_script(payload) do
    "const app = JSON.parse('#{js_json(payload)}');\n"
  end

  defp dynamic_script(payload, key, page_name) do
    dynamic_script(payload, [{key, page_name}])
  end

  defp dynamic_script(payload, page_patches) when is_list(page_patches) do
    Enum.reduce(page_patches, dynamic_script(payload), fn {key, page_name}, script ->
      patch = %{
        "%el" => %{
          "text" => %{
            "%nm" => "Hydrated #{page_name}",
            "%p" => %{"%3" => "Hydrated #{page_name}"},
            "%x" => "Text",
            "id" => "#{key}-text"
          }
        }
      }

      script <>
        "app['%p3']['#{key}'] = Object.assign(app['%p3']['#{key}'] || {}, JSON.parse('#{js_json(patch)}'));\n" <>
        "app['_index']['id_to_path'] = Object.assign(app['_index']['id_to_path'] || {}, JSON.parse('#{js_json(%{"#{key}-text" => "pages.#{key}.elements.text"})}'));\n"
    end)
  end

  defp js_json(value), do: value |> Jason.encode!() |> String.replace("'", "\\'")

  defp page_html(dynamic_path) do
    "<html><script src='#{dynamic_path}'></script></html>"
  end

  defp respond_fetch(conn, payload) do
    conn = Conn.put_resp_header(conn, "x-bubble-something", "1")
    path = conn.request_path || "/"

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
