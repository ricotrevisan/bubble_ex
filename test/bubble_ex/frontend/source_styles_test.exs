defmodule BubbleEx.Frontend.SourceStylesTest do
  use ExUnit.Case, async: false

  alias BubbleEx.{FrontendFixtures, HTTP}
  alias Plug.Conn

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> HTTP.delete_process_options() end)
    :ok
  end

  test "style media attributes and incomplete rules stay outside unconditional CSS" do
    alias BubbleEx.Frontend.Export.SourceStyles

    styles =
      SourceStyles.discover("""
      <html><head>
      <style media="print">body { display: none; }</style>
      <style media="(width < 500px)">#panel { width: 99px; }</style>
      <style type="text/less">body { color: red; }</style>
      <style media="screen">body { overflow-x: hidden; } #panel { width: 50px;</style>
      </head></html>
      """)

    assert {css, 4} = SourceStyles.compile(styles)
    assert css =~ "overflow-x: hidden;"
    refute css =~ "display"
    refute css =~ "width"
    refute css =~ "color"
  end

  test "an unterminated comment cannot promote its contents into active rules" do
    alias BubbleEx.Frontend.Export.SourceStyles

    styles =
      SourceStyles.discover("""
      <html><head><style>
      body { overflow-x: hidden; }
      /* ignored { height: 20px; } #panel { display: none; }
      </style></head></html>
      """)

    assert {css, 1} = SourceStyles.compile(styles)
    assert css =~ "overflow-x: hidden;"
    refute css =~ "display"
    refute css =~ "height"
  end

  @tag :tmp_dir
  test "fetched page styles retain authored IDs and apply only to their source page", %{
    tmp_dir: tmp
  } do
    stub("body { overflow-x: hidden; } #panel { overflow: hidden !important; }")

    assert {:ok, result} =
             BubbleEx.export_frontend("s1app", tmp,
               secret_scan_adapter: FrontendFixtures.clean_scanner()
             )

    html = File.read!(Path.join(tmp, "pages/index/index.html")) |> Floki.parse_document!()
    assert [_] = Floki.find(html, "[data-bubble-id=panel-node]#panel")
    css = File.read!(Path.join(tmp, "styles/pages/index.css"))
    assert css =~ "body {"
    assert css =~ "overflow-x: hidden;"
    assert css =~ "#panel {"
    assert css =~ "overflow: hidden !important;"
    refute File.read!(Path.join(tmp, "styles/pages/about.css")) =~ "overflow-x: hidden;"
    assert result.model.source.payload == payload()
  end

  @tag :tmp_dir
  test "unsupported selectors and nested rules cannot become unconditional page styles", %{
    tmp_dir: tmp
  } do
    stub("""
    /* { fake } */
    @media (width < 500px) { #panel { height: 999px; } }
    @supports (display: grid) { #panel { width: 777px; } }
    .foreign-class { opacity: 0.123; }
    #panel {
      content: "} #panel { color: red; }";
      background-image: url(https://example.invalid/unwanted);
      overflow: hidden !important;
    }
    """)

    assert {:ok, result} =
             BubbleEx.export_frontend("s1app", tmp,
               secret_scan_adapter: FrontendFixtures.clean_scanner()
             )

    css = File.read!(Path.join(tmp, "styles/pages/index.css"))
    assert css =~ "overflow: hidden !important;"
    refute css =~ "999px"
    refute css =~ "777px"
    refute css =~ "0.123"
    refute css =~ "example.invalid"
    refute css =~ "color: red"
    assert Enum.any?(result.findings, &(&1["type"] == "unsupported_source_css"))
  end

  @tag :tmp_dir
  test "credential findings in fetched CSS block the export before any files are written", %{
    tmp_dir: tmp
  } do
    token = "ghp_" <> String.duplicate("a", 36)
    stub("#panel { font-family: \"#{token}\"; }")

    assert {:error, %BubbleEx.Error{kind: :export_blocked} = error} =
             BubbleEx.export_frontend("s1app", tmp, secret_scan_adapter: BubbleEx.Secrets.Native)

    refute inspect(error) =~ token
    assert File.ls!(tmp) == []
  end

  @tag :tmp_dir
  test "hydration retains the additional page's own styles", %{tmp_dir: tmp} do
    root = update_in(payload(), ["pages", "about"], &Map.delete(&1, "elements"))

    Req.Test.stub(__MODULE__, fn conn ->
      conn = Conn.put_resp_header(conn, "x-bubble-test", "1")

      case conn.request_path || "/" do
        "/" -> Conn.resp(conn, 200, source_html("root", "body { overflow-x: hidden; }"))
        "/about" -> Conn.resp(conn, 200, source_html("about", "#panel { border-radius: 13px; }"))
        "/package/dynamic_js/root/dynamic.js" -> Conn.resp(conn, 200, script(root))
        "/package/dynamic_js/about/dynamic.js" -> Conn.resp(conn, 200, script(payload()))
      end
    end)

    assert {:ok, _} =
             BubbleEx.export_frontend("s1app", tmp,
               secret_scan_adapter: FrontendFixtures.clean_scanner()
             )

    index = File.read!(Path.join(tmp, "styles/pages/index.css"))
    about = File.read!(Path.join(tmp, "styles/pages/about.css"))
    assert index =~ "overflow-x: hidden;"
    refute index =~ "border-radius: 13px;"
    assert about =~ "border-radius: 13px;"
    refute about =~ "overflow-x: hidden;"
  end

  @tag :tmp_dir
  test "dynamic and malformed IDs are retained as input but cannot inject HTML attributes", %{
    tmp_dir: tmp
  } do
    raw = payload()

    raw =
      put_in(
        raw,
        ["pages", "index", "elements", "panel", "%p", "unique_id"],
        "panel\" onclick=\"alert(1)"
      )

    raw =
      put_in(raw, ["pages", "about", "elements", "panel", "%p", "unique_id"], %{"%x" => "Search"})

    assert {:ok, result} =
             BubbleEx.Frontend.export_payload(raw, tmp,
               secret_scan_adapter: FrontendFixtures.clean_scanner()
             )

    for page <- ["index", "about"] do
      html = File.read!(Path.join(tmp, "pages/#{page}/index.html")) |> Floki.parse_document!()
      assert Floki.attribute(Floki.find(html, "[data-bubble-id=panel-node]"), "id") == []
      assert Floki.find(html, "[onclick]") == []
    end

    assert Enum.any?(
             result.bindings,
             &(&1["slot"] == "html_id" and &1["payload"] == %{"%x" => "Search"})
           )
  end

  defp payload do
    panel = %{
      "%x" => "Group",
      "id" => "panel-node",
      "%p" => %{
        "container_layout" => "column",
        "unique_id" => %{"%x" => "TextExpression", "%e" => %{"0" => "panel"}}
      }
    }

    %{
      "_id" => "s1app",
      "pages" =>
        Map.new(["index", "about"], fn name ->
          {name, %{"type" => "Page", "name" => name, "elements" => %{"panel" => panel}}}
        end)
    }
  end

  defp stub(css) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn = Conn.put_resp_header(conn, "x-bubble-test", "1")

      case conn.request_path || "/" do
        "/" ->
          Conn.resp(conn, 200, """
          <html><head><style>#{css}</style>
          <script src="/package/dynamic_js/1/dynamic.js"></script></head><body></body></html>
          """)

        "/package/dynamic_js/1/dynamic.js" ->
          json = payload() |> Jason.encode!() |> String.replace("'", "\\'")
          Conn.resp(conn, 200, "const app = JSON.parse('#{json}');")
      end
    end)
  end

  defp source_html(name, css),
    do:
      "<html><head><style>#{css}</style><script src=\"/package/dynamic_js/#{name}/dynamic.js\"></script></head></html>"

  defp script(payload),
    do: "const app = JSON.parse('#{payload |> Jason.encode!() |> String.replace("'", "\\'")}');"
end
