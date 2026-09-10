defmodule BubbleEx.Frontend.IconExportTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.Frontend.{Auth, Fetch}
  alias BubbleEx.FrontendFixtures

  @tag :tmp_dir
  test "exports an outlined Material label button with its authored icon styling", %{tmp_dir: tmp} do
    payload = payload("material outlined arrow_forward")
    sprite = Path.join(tmp, "outlined.svg")

    File.write!(
      sprite,
      ~s(<svg><symbol id="arrow_forward" viewBox="0 0 24 24"><path d="M4 11h16v2H4z" class="nc-icon-wrapper"/></symbol></svg>)
    )

    url = "https://example.test/static/icon_libraries/material-icons-4.0.0-outlined.svg"
    {:ok, _, auth} = Auth.prepare("https://example.test/", [])
    context = %Fetch.Context{page_url: "https://example.test/", auth: auth}

    assert {:ok, result} =
             Frontend.export_fetched(
               payload,
               Path.join(tmp, "export"),
               [
                 secret_scan_adapter: FrontendFixtures.clean_scanner(),
                 asset_files: %{url => sprite}
               ],
               context
             )

    button = hd(hd(result.model.pages).children)
    assert button.kind == :button
    assert button.variant == :label_icon
    html = File.read!(Path.join(result.out_dir, "pages/index/index.html"))
    assert html =~ ~s(data-icon-set="material")
    assert html =~ ~s(<symbol id="arrow_forward" viewBox="0 0 24 24">)
    assert html =~ ~r/Continue.*<svg/s
    css = File.read!(Path.join(result.out_dir, "styles/pages/index.css"))
    assert css =~ "--bubble-icon-color: #646464;"
    assert css =~ "--bubble-icon-size: 16px;"
    assert css =~ "--bubble-button-gap: 4px;"
    assert css =~ "color: #202020;"
    refute css =~ "  color: #646464;"
  end

  test "unrecognized Material libraries remain explicit placeholders" do
    for icon <- [
          "material unknown arrow_forward",
          "material outlined ../arrow",
          "material outlined arrow\" onclick=\"alert(1)"
        ] do
      assert {:ok, model} = Frontend.normalize(payload(icon))
      assert hd(hd(model.pages).children).placeholder?
    end
  end

  @tag :tmp_dir
  test "Phosphor outlines retain grouped fill and stroke geometry", %{tmp_dir: tmp} do
    payload = payload("phosphor bold arrow-right")
    sprite = Path.join(tmp, "phosphor.svg")

    File.write!(sprite, """
    <svg><symbol id="arrow-right" viewBox="0 0 256 256">
    <g fill="none" class="nc-icon-wrapper"><path d="M0 0h256v256H0z"/>
    <path stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"
    stroke-width="24" d="M40 128h176M144 56l72 72-72 72"/></g>
    </symbol></svg>
    """)

    url = "https://example.test/static/icon_libraries/phosphor-2.1.0-bold.svg"
    {:ok, _, auth} = Auth.prepare("https://example.test/", [])
    context = %Fetch.Context{page_url: "https://example.test/", auth: auth}

    assert {:ok, result} =
             Frontend.export_fetched(
               payload,
               Path.join(tmp, "export"),
               [
                 secret_scan_adapter: FrontendFixtures.clean_scanner(),
                 asset_files: %{url => sprite}
               ],
               context
             )

    assert hd(hd(result.model.pages).children).variant == :label_icon
    assert result.findings == []
    html = File.read!(Path.join(result.out_dir, "pages/index/index.html"))
    assert html =~ ~s(data-icon-set="phosphor")
    assert html =~ ~s(<g fill="none")
    assert html =~ ~s(stroke="currentColor")
    assert html =~ ~s(stroke-width="24")
    refute html =~ ~s(<path fill="currentColor" d="M0 0h256)
  end

  test "static icon links retain the authored trailing icon placement" do
    payload = payload("material outlined arrow_forward")

    payload =
      update_in(payload, ["pages", "index", "elements", "button"], fn node ->
        node
        |> Map.put("type", "Link")
        |> update_in(["properties"], &Map.put(&1, "show_icon", true))
      end)

    assert {:ok, model} = Frontend.normalize(payload)
    link = hd(hd(model.pages).children)
    assert link.variant == :label_icon
    assert link.attributes["icon_placement"] == "right"
  end

  @tag :tmp_dir
  test "shared text styles retain Bubble's default 14px font size", %{tmp_dir: tmp} do
    payload = payload("unsupported")

    payload =
      put_in(payload, ["pages", "index", "elements", "button"], %{
        "id" => "text",
        "type" => "Text",
        "style" => "body",
        "properties" => %{"text" => "Body"}
      })

    payload =
      Map.put(payload, "styles", %{
        "body" => %{"type" => "Text", "properties" => %{"line_height" => 1.43}}
      })

    assert {:ok, _} =
             Frontend.export_payload(payload, tmp,
               secret_scan_adapter: FrontendFixtures.clean_scanner()
             )

    css = File.read!(Path.join(tmp, "styles/shared.css"))
    assert css =~ "font-size: 14px;"
  end

  defp payload(icon) do
    %{
      "_id" => "icons",
      "pages" => %{
        "index" => %{
          "type" => "Page",
          "name" => "index",
          "properties" => %{"container_layout" => "column"},
          "elements" => %{
            "button" => %{
              "id" => "button",
              "type" => "Button",
              "properties" => %{
                "text" => "Continue",
                "button_type" => "label_icon",
                "icon" => icon,
                "icon_placement" => "right",
                "icon_size" => 16,
                "button_gap" => 4,
                "font_color" => "#202020",
                "icon_color" => "#646464",
                "fit_width" => true
              }
            }
          }
        }
      }
    }
  end
end
