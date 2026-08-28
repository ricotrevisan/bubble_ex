defmodule BubbleEx.Frontend.SecurityExportTest do
  use ExUnit.Case, async: false

  alias BubbleEx.Frontend
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
  test "export_payload/3 omits executable link destinations and preserves safe links", %{
    tmp_dir: tmp
  } do
    payload = payload_with_links_and_styles()
    out = Path.join(tmp, "payload-package")

    assert {:ok, %Result{} = result} = Frontend.export_payload(payload, out, @scan)

    html = File.read!(Path.join(out, "pages/index/index.html"))
    {:ok, document} = Floki.parse_document(html)

    assert link_href(document, "safe-https") == "https://example.com/docs"
    assert link_href(document, "safe-mailto") == "mailto:security@example.com"
    assert link_href(document, "safe-relative") == "docs/getting-started"

    for id <- [
          "dangerous-js",
          "dangerous-obfuscated-js",
          "dangerous-vbscript",
          "dangerous-data",
          "dangerous-intent",
          "dangerous-shell"
        ] do
      assert link_href(document, id) == nil
    end

    unsafe_link_findings =
      Enum.filter(result.findings, &(&1["type"] == "unsafe_link_destination"))

    assert length(unsafe_link_findings) == 6
    assert Enum.all?(unsafe_link_findings, &(&1["severity"] == "warning"))
    refute Enum.any?(result.findings, &(&1["type"] == "link_to_non_exported_page"))
    assert Jason.decode!(File.read!(Path.join(out, "findings.json"))) == result.findings
  end

  @tag :tmp_dir
  test "export_frontend/3 omits hostile CSS values and preserves safe declarations", %{
    tmp_dir: tmp
  } do
    payload = payload_with_links_and_styles()

    Req.Test.stub(__MODULE__, fn conn -> respond_fetch(conn, payload) end)

    out = Path.join(tmp, "fetched-package")

    assert {:ok, %Result{} = result} =
             BubbleEx.export_frontend("s1app", out, @scan)

    css = File.read!(Path.join(out, "styles/pages/index.css"))
    assert css =~ "font-size: 18px;"
    assert css =~ "background: #ffffff;"
    refute css =~ "body {"
    refute css =~ "javascript:"
    refute css =~ "color: #fff;"
    refute css =~ "tracking.example.test"
    refute css =~ "127.0.0.1"

    unsafe_css_findings = Enum.filter(result.findings, &(&1["type"] == "unsafe_css_value"))
    assert length(unsafe_css_findings) == 3
    assert Enum.all?(unsafe_css_findings, &(&1["severity"] == "warning"))

    assert MapSet.new(Enum.map(unsafe_css_findings, & &1["payload"])) ==
             MapSet.new([
               %{"property" => "background"},
               %{"property" => "font_color"}
             ])

    assert Jason.decode!(File.read!(Path.join(out, "findings.json"))) == result.findings
  end

  @tag :tmp_dir
  test "native secret findings block export without returning the raw token", %{tmp_dir: tmp} do
    token = "ghp_0123456789abcdefABCDEF0123456789abcdef"

    payload =
      put_in(FrontendFixtures.modern_page(), ["pages", "home", "properties", "token"], token)

    out = Path.join(tmp, "secret-package")

    assert {:error, %BubbleEx.Error{kind: :export_blocked} = error} =
             Frontend.export_payload(payload, out, secret_scan_adapter: BubbleEx.Secrets.Native)

    refute File.exists?(out)
    refute :erlang.term_to_binary(error) =~ token
    assert inspect(error) =~ "github_pat"
  end

  defp payload_with_links_and_styles do
    links = %{
      "safe_https" => link("safe-https", "Safe HTTPS", "https://example.com/docs", 1),
      "safe_mailto" => link("safe-mailto", "Safe mail", "mailto:security@example.com", 2),
      "safe_relative" => link("safe-relative", "Safe relative", "docs/getting-started", 3),
      "dangerous_js" => link("dangerous-js", "JavaScript", "javascript:alert(1)", 4),
      "dangerous_obfuscated_js" =>
        link("dangerous-obfuscated-js", "Obfuscated JavaScript", " \tJaVa\nScRiPt:alert(1)", 5),
      "dangerous_vbscript" => link("dangerous-vbscript", "VBScript", "vbscript:msgbox(1)", 6),
      "dangerous_data" =>
        link("dangerous-data", "Data document", "data:text/html,<script>alert(1)</script>", 7),
      "dangerous_intent" => link("dangerous-intent", "Intent", "intent://launch", 8),
      "dangerous_shell" => link("dangerous-shell", "Shell", "shell:calculator", 9),
      "remote_css" => %{
        "id" => "remote-css",
        "type" => "Text",
        "properties" => %{
          "background" => "url(https://tracking.example.test/pixel)",
          "order" => 10,
          "text" => "No remote CSS"
        }
      },
      "private_css" => %{
        "id" => "private-css",
        "type" => "Text",
        "properties" => %{
          "background" => "url(http://127.0.0.1/metadata)",
          "order" => 11,
          "text" => "No private CSS"
        }
      },
      "styled" => %{
        "id" => "styled-text",
        "type" => "Text",
        "properties" => %{
          "background" => "#ffffff",
          "font_color" => "#fff; }\nbody { background: url(javascript:alert(1))",
          "font_size" => 18,
          "order" => 12,
          "text" => "Still styled"
        }
      }
    }

    put_in(FrontendFixtures.modern_page(), ["pages", "home", "elements"], links)
  end

  defp link(id, text, destination, order) do
    %{
      "id" => id,
      "type" => "Link",
      "properties" => %{"destination" => destination, "order" => order, "text" => text}
    }
  end

  defp link_href(document, bubble_id) do
    document
    |> Floki.find(~s([data-bubble-id="#{bubble_id}"]))
    |> Floki.attribute("href")
    |> List.first()
  end

  defp respond_fetch(conn, payload) do
    conn = Conn.put_resp_header(conn, "x-bubble-something", "1")
    path = conn.request_path || "/"

    if String.contains?(path, "dynamic_js") do
      json =
        payload
        |> Jason.encode!()
        |> String.replace("\\", "\\\\")
        |> String.replace("'", "\\'")

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
