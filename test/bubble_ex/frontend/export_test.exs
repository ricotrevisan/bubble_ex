defmodule BubbleEx.Frontend.ExportTest do
  use ExUnit.Case, async: false

  alias BubbleEx.Error
  alias BubbleEx.Frontend
  alias BubbleEx.Frontend.Export.Result
  alias BubbleEx.FrontendFixtures

  @scan [secret_scan_adapter: FrontendFixtures.clean_scanner()]

  describe "export_payload/3" do
    @tag :tmp_dir
    test "writes the package skeleton and returns a Result", %{tmp_dir: tmp} do
      out = Path.join(tmp, "pkg")

      assert {:ok, %Result{} = result} =
               Frontend.export_payload(FrontendFixtures.two_page_app(), out, @scan)

      assert result.out_dir == out
      assert result.files == Enum.sort(result.files)
      assert result.files == result.manifest["files"]
      assert result.manifest["package_version"] == 1
      assert result.manifest["normalized_schema_version"] == 1
      assert result.manifest["bubble_id"] == "s1app"
      assert result.manifest["app_version"] == "live"
      assert is_binary(result.manifest["source_sha256"])
      assert String.length(result.manifest["source_sha256"]) == 64
      assert result.manifest["bubble_ex_version"] == Mix.Project.config()[:version]

      for path <- [
            "MANIFEST.json",
            "model.json",
            "bindings.json",
            "findings.json",
            "coverage.json",
            "index.html",
            "pages/index/index.html",
            "pages/about/index.html",
            "styles/shared.css",
            "styles/pages/index.css",
            "styles/pages/about.css",
            "reusables/left-nav--cmpnav/fragment.html",
            "styles/reusables/left-nav--cmpnav.css"
          ] do
        assert path in result.files, "missing #{path}"
        assert File.exists?(Path.join(out, path)), "not on disk: #{path}"
      end

      manifest_raw = File.read!(Path.join(out, "MANIFEST.json"))
      assert String.ends_with?(manifest_raw, "\n")

      assert decode_key_order(manifest_raw) == [
               "package_version",
               "normalized_schema_version",
               "bubble_ex_version",
               "bubble_id",
               "app_version",
               "source_sha256",
               "options",
               "files"
             ]

      catalog = File.read!(Path.join(out, "index.html"))
      assert catalog =~ "<!DOCTYPE html>"
      assert catalog =~ "<title>s1app (live)</title>"
      assert catalog =~ ~s(href="pages/about/index.html")
      refute catalog =~ "stylesheet"

      home = File.read!(Path.join(out, "pages/index/index.html"))
      assert home =~ "<!DOCTYPE html>"
      assert home =~ "<title>Home</title>"
      assert home =~ ~s(href="../../styles/shared.css")
      assert home =~ ~s(href="../../styles/pages/index.css")
      refute home =~ "<script"
      refute home =~ "onClick"
      assert home =~ "data-exporter-id="

      fragment = File.read!(Path.join(out, "reusables/left-nav--cmpnav/fragment.html"))
      refute fragment =~ "<!DOCTYPE"
      refute fragment =~ "<html"
      assert fragment =~ "Nav"

      model_json = File.read!(Path.join(out, "model.json")) |> Jason.decode!()
      assert model_json["normalized_schema_version"] == 1
    end

    @tag :tmp_dir
    test "lowers S1 controls and keeps unsupported nodes as placeholders", %{tmp_dir: tmp} do
      out = Path.join(tmp, "pkg")

      assert {:ok, result} =
               Frontend.export_payload(FrontendFixtures.s1_elements_app(), out, @scan)

      html = File.read!(Path.join(out, "pages/index/index.html"))
      assert html =~ "<h1"
      assert html =~ "Hello"
      assert html =~ "<button"
      assert html =~ ~s(type="button")
      assert html =~ "Go"
      assert html =~ ~s(<input)
      assert html =~ ~s(type="email")
      assert html =~ ~s(aria-hidden="true")
      assert html =~ ~s(href="https://example.com")
      assert html =~ "data-placeholder-kind"

      css = File.read!(Path.join(out, "styles/pages/index.css"))
      assert css =~ "[data-exporter-id="
      refute css =~ ~r/#[A-Za-z_-][\w-]*\s*\{/
      assert css =~ "flex-direction: column"

      shared = File.read!(Path.join(out, "styles/shared.css"))
      assert shared =~ ".s-headline"

      assert Enum.any?(result.findings, &(&1["type"] == "unsupported_element"))
      assert result.coverage["overall"]["elements"]["placeholder"] >= 1
    end

    @tag :tmp_dir
    test "blocks the export and writes nothing when the secret scan finds a credential", %{
      tmp_dir: tmp
    } do
      out = Path.join(tmp, "blocked")

      assert {:error, %Error{kind: :export_blocked, context: %{findings: findings}}} =
               Frontend.export_payload(FrontendFixtures.modern_page(), out,
                 secret_scan_adapter: FrontendFixtures.leaky_scanner()
               )

      assert findings != []
      refute File.exists?(out)
    end

    @tag :tmp_dir
    test "refuses a non-empty out_dir without force", %{tmp_dir: tmp} do
      out = Path.join(tmp, "pkg")
      File.mkdir_p!(out)
      File.write!(Path.join(out, "keep.txt"), "stay")

      assert {:error, %Error{kind: :invalid_input}} =
               Frontend.export_payload(FrontendFixtures.modern_page(), out, @scan)

      assert File.read!(Path.join(out, "keep.txt")) == "stay"
      refute File.exists?(Path.join(out, "MANIFEST.json"))
    end

    @tag :tmp_dir
    test "filters pages by slug and records omitted pages in overall coverage", %{tmp_dir: tmp} do
      out = Path.join(tmp, "pkg")

      assert {:ok, result} =
               Frontend.export_payload(
                 FrontendFixtures.two_page_app(),
                 out,
                 @scan ++ [pages: ["index"]]
               )

      assert "pages/index/index.html" in result.files
      refute "pages/about/index.html" in result.files
      refute File.exists?(Path.join(out, "pages/about/index.html"))
      assert "reusables/left-nav--cmpnav/fragment.html" in result.files

      home = File.read!(Path.join(out, "pages/index/index.html"))
      # target page was filtered out: keep the original destination, do not rewrite
      assert home =~ ~s(href="about")
      assert Enum.any?(result.findings, &(&1["type"] == "link_to_non_exported_page"))

      assert result.coverage["overall"]["pages"]["not_exported"] == 1
    end

    test "rejects an unknown page ref or an empty inclusion list" do
      payload = FrontendFixtures.two_page_app()

      assert {:error, %Error{kind: :invalid_input}} =
               Frontend.export_payload(payload, "unused", @scan ++ [pages: ["nope"]])

      assert {:error, %Error{kind: :invalid_input}} =
               Frontend.export_payload(payload, "unused", @scan ++ [pages: []])
    end
  end

  describe "export/3" do
    @tag :tmp_dir
    test "accepts an already-normalized model", %{tmp_dir: tmp} do
      out = Path.join(tmp, "pkg")
      assert {:ok, model} = Frontend.normalize(FrontendFixtures.modern_page())
      assert {:ok, %Result{files: files}} = Frontend.export(model, out, @scan)
      assert "MANIFEST.json" in files
    end
  end

  defp decode_key_order(json) do
    json
    |> String.split("\n")
    |> Enum.filter(&String.match?(&1, ~r/^  "[a-z0-9_]+":/))
    |> Enum.map(fn line ->
      line
      |> String.trim()
      |> String.split(":", parts: 2)
      |> hd()
      |> String.trim("\"")
    end)
  end
end
