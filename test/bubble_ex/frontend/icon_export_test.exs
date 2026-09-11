defmodule BubbleEx.Frontend.IconExportTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.Frontend.{Auth, Fetch}
  alias BubbleEx.FrontendFixtures

  test "icon layout does not override initial visibility" do
    payload = payload("material outlined arrow_forward")

    payload =
      update_in(
        payload,
        ["pages", "index", "elements", "button", "properties"],
        &Map.put(&1, "is_visible", false)
      )

    assert {:ok, model} = Frontend.normalize(payload)
    css = BubbleEx.Frontend.Export.Css.page(hd(model.pages))
    assert css =~ "display: none;"
    refute css =~ "display: inline-flex;"
  end

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
    assert html =~ ~s(viewBox="0 0 24 24")
    assert html =~ ~s(<symbol id="bubbleex-icon-)
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

  @tag :tmp_dir
  test "Phosphor circles and rounded rectangles survive the complete export", %{tmp_dir: tmp} do
    sprite = Path.join(tmp, "phosphor.svg")

    File.write!(sprite, """
    <svg><symbol id="instagram-logo" viewBox="0 0 256 256"><g class="nc-icon-wrapper">
    <path fill="none" d="M0 0h256v256H0z"/>
    <circle cx="128" cy="128" r="36" fill="none" stroke="currentColor" stroke-width="24"/>
    <rect width="192" height="192" x="32" y="32" rx="48" fill="none" stroke="currentColor" stroke-width="24"/>
    <circle cx="180" cy="76" r="16"/></g></symbol></svg>
    """)

    url = "/static/icon_libraries/phosphor-2.1.0-bold.svg"

    assert {:ok, result} =
             Frontend.export_payload(
               payload("phosphor bold instagram-logo"),
               Path.join(tmp, "export"),
               secret_scan_adapter: FrontendFixtures.clean_scanner(),
               asset_files: %{url => sprite}
             )

    assert result.findings == []

    html =
      Path.join(result.out_dir, "pages/index/index.html")
      |> File.read!()
      |> Floki.parse_document!()

    assert length(Floki.find(html, "svg circle")) == 2
    assert Floki.find(html, "svg rect") |> Floki.attribute("rx") == ["48"]
    assert Floki.find(html, "svg rect") |> Floki.attribute("stroke") == ["currentColor"]
  end

  @tag :tmp_dir
  test "mixed icon weights keep their own symbol references in repeated reusables", %{
    tmp_dir: tmp
  } do
    base =
      get_in(payload("phosphor regular arrow-right"), ["pages", "index", "elements", "button"])

    icons =
      Map.new([{"regular", 16}, {"bold", 24}], fn {weight, order} ->
        node =
          base
          |> Map.put("id", weight)
          |> put_in(["properties", "icon"], "phosphor #{weight} arrow-right")
          |> put_in(["properties", "order"], order)

        {weight, node}
      end)

    definition = %{
      "type" => "CustomDefinition",
      "id" => "arrows",
      "elements" => icons,
      "properties" => %{"container_layout" => "row"}
    }

    instances =
      Map.new(["left", "right"], fn id ->
        {id,
         %{"type" => "CustomElement", "id" => id, "properties" => %{"definition" => "arrows"}}}
      end)

    app =
      payload("unused")
      |> Map.put("element_definitions", %{"arrows" => definition})
      |> put_in(["pages", "index", "elements"], instances)

    files =
      Map.new([{"regular", 16}, {"bold", 24}], fn {weight, stroke} ->
        file = Path.join(tmp, weight <> ".svg")

        File.write!(
          file,
          ~s(<svg><symbol id="arrow-right" viewBox="0 0 256 256"><path d="M40 128h176" stroke="currentColor" stroke-width="#{stroke}"/></symbol></svg>)
        )

        {"/static/icon_libraries/phosphor-2.1.0-#{weight}.svg", file}
      end)

    assert {:ok, result} =
             Frontend.export_payload(app, Path.join(tmp, "export"),
               secret_scan_adapter: FrontendFixtures.clean_scanner(),
               asset_files: files
             )

    assert result.findings == []

    html =
      Path.join(result.out_dir, "pages/index/index.html")
      |> File.read!()
      |> Floki.parse_document!()

    symbols = Floki.find(html, "symbol")
    ids = Floki.attribute(symbols, "id")
    assert length(ids) == 4
    assert length(Enum.uniq(ids)) == 4

    for svg <- Floki.find(html, "svg") do
      [id] = Floki.find(svg, "symbol") |> Floki.attribute("id")
      assert Floki.find(svg, "use") |> Floki.attribute("href") == ["#" <> id]
    end

    assert Enum.sort(Floki.find(html, "symbol path") |> Floki.attribute("stroke-width")) ==
             ["16", "16", "24", "24"]
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
