defmodule BubbleEx.Frontend.Export.FontsTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend.Export.Fonts

  test "discovers static Google WebFontConfig families and allowlisted stylesheet links" do
    html = """
    <html>
      <script>
        const WebFontConfig = {'google': { families: ["Inter:regular", "Inter:800"] },
          'custom': {families: ["Private Font"], urls: ["https://evil.example/font.css"]}};
      </script>
      <link rel="stylesheet" href="//fonts.googleapis.com/css2?family=Roboto:wght@400;700">
      <link rel="stylesheet" href="https://evil.example/site.css">
    </html>
    """

    sources = Fonts.discover(html, "https://app.example.test/page")

    assert "https://fonts.googleapis.com/css?family=Inter%3Aregular%7CInter%3A800" in sources
    assert "https://fonts.googleapis.com/css2?family=Roboto:wght@400;700" in sources
    refute Enum.any?(sources, &String.contains?(&1, "evil.example"))
  end

  test "rejects non-HTTPS and userinfo Google stylesheet URLs" do
    html = """
    <link rel="stylesheet" href="http://fonts.googleapis.com/css?family=Inter">
    <link rel="stylesheet" href="https://user:pass@fonts.googleapis.com/css?family=Inter">
    """

    assert Fonts.discover(html, "https://app.example.test") == []
  end

  test "collects Bubble family descriptors with independent normalized font weights" do
    alias BubbleEx.Frontend.{Auth, Fetch.Context}
    alias BubbleEx.Frontend.Normalized.{Node, Source}
    BubbleEx.HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> BubbleEx.HTTP.delete_process_options() end)

    Req.Test.stub(__MODULE__, fn conn ->
      if conn.host == "fonts.googleapis.com" do
        css = """
        @font-face {font-family: 'Roboto';font-weight: 400;src: url(https://fonts.gstatic.com/regular.woff2) format('woff2');}
        @font-face {font-family: 'Roboto';font-weight: 300;src: url(https://fonts.gstatic.com/light.woff2) format('woff2');}
        """

        conn |> Plug.Conn.put_resp_content_type("text/css") |> Plug.Conn.resp(200, css)
      else
        assert conn.request_path == "/regular.woff2"

        conn
        |> Plug.Conn.put_resp_content_type("font/woff2")
        |> Plug.Conn.resp(200, "wOF2fixture")
      end
    end)

    node = %Node{
      exporter_id: "text",
      kind: :text,
      map_key: "text",
      source: %Source{},
      style: %{resolved: %{"font_face" => "Roboto:::300", "font_weight" => 400}}
    }

    {:ok, url, auth} = Auth.prepare("https://example.bubbleapps.io/privacy", [])

    context = %Context{
      page_url: url,
      auth: auth,
      font_sources: ["https://fonts.googleapis.com/css?family=Roboto:300,400"]
    }

    {css, assets, findings} = Fonts.collect([node], [], fetch_context: context)
    assert css =~ ~s(font-family: "Roboto")
    assert css =~ "font-weight: 400"
    refute css =~ "font-weight: 300"
    assert length(assets) == 1
    assert findings == []
  end
end
