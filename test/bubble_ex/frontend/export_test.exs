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
      assert result.manifest["normalized_schema_version"] == 2
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
      assert model_json["normalized_schema_version"] == 2
    end

    @tag :tmp_dir
    test "packages a public image whose source appends Current Page Width", %{tmp_dir: tmp} do
      out = Path.join(tmp, "pkg")
      source_file = Path.join(tmp, "hero.png")
      url = "https://cdn.example/hero.png?ignore_imgix=1&n="

      File.write!(
        source_file,
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )
      )

      expression = %{
        "%x" => "TextExpression",
        "%e" => %{
          "0" => url,
          "1" => %{
            "%x" => "PageData",
            "%p" => %{"%nm" => "Current Page Width"}
          }
        }
      }

      payload =
        FrontendFixtures.modern_page()
        |> put_in(["pages", "home", "elements"], %{
          "hero" => %{
            "id" => "imageWidth",
            "type" => "Image",
            "properties" => %{"src" => expression, "alt" => "Hero"}
          }
        })

      assert {:ok, result} =
               Frontend.export_payload(
                 payload,
                 out,
                 @scan ++ [asset_files: %{url => source_file}]
               )

      asset_path = Enum.find(result.files, &String.starts_with?(&1, "assets/"))
      assert is_binary(asset_path)
      assert File.read!(Path.join(out, asset_path)) == File.read!(source_file)

      html = File.read!(Path.join(out, "pages/index/index.html"))
      assert html =~ ~s(src="../../#{asset_path}")
      refute html =~ url

      assert Enum.any?(result.bindings, fn binding ->
               binding["slot"] == "src" and binding["payload"] == expression
             end)
    end

    @tag :tmp_dir
    test "lowers S1 controls and keeps unsupported nodes as placeholders", %{tmp_dir: tmp} do
      out = Path.join(tmp, "pkg")

      assert {:ok, result} =
               Frontend.export_payload(FrontendFixtures.s1_elements_app(), out, @scan)

      html = File.read!(Path.join(out, "pages/index/index.html"))
      assert html =~ "<h1"
      assert html =~ "Hello"
      assert html =~ ~s(<p data-bubble-id="elNormal")
      assert html =~ ">Body</p>"
      assert html =~ ~s(<h4 data-bubble-id="elH4")
      assert html =~ ">Heading four</h4>"
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
      assert shared =~ "p, h1, h2, h3, h4, fieldset, legend { margin: 0; font: inherit; }"

      assert Enum.any?(result.findings, &(&1["type"] == "unsupported_element"))
      assert result.coverage["overall"]["elements"]["placeholder"] >= 1
    end

    @tag :tmp_dir
    test "lowers Bubble Link navigation properties and rewrites a page id", %{tmp_dir: tmp} do
      out = Path.join(tmp, "pkg")

      payload =
        FrontendFixtures.two_page_app()
        |> put_in(["pages", "home", "elements"], %{
          "external" => %{
            "id" => "linkExternal",
            "type" => "Link",
            "properties" => %{
              "text" => "External",
              "linktype" => "externallink",
              "url" => "https://example.com/docs"
            }
          },
          "internal" => %{
            "id" => "linkInternal",
            "type" => "Link",
            "properties" => %{
              "text" => "Internal",
              "linktype" => "pagelink",
              "page" => "pgabout"
            }
          },
          "newtab" => %{
            "id" => "linkNewTab",
            "type" => "Link",
            "properties" => %{
              "text" => "New tab",
              "url" => "https://example.com/new-tab",
              "open_in_new_tab" => true,
              "nofollow" => true
            }
          },
          "disabled" => %{
            "id" => "linkDisabled",
            "type" => "Link",
            "properties" => %{
              "text" => "Disabled",
              "url" => "https://example.com/disabled",
              "link_disabled" => true
            }
          }
        })

      assert {:ok, _result} = Frontend.export_payload(payload, out, @scan)
      html = File.read!(Path.join(out, "pages/index/index.html"))
      {:ok, document} = Floki.parse_document(html)

      assert link_attr(document, "linkExternal", "href") == "https://example.com/docs"
      assert link_attr(document, "linkInternal", "href") == "../about/index.html"
      assert link_attr(document, "linkNewTab", "target") == "_blank"
      assert link_attr(document, "linkNewTab", "rel") == "nofollow noopener"
      assert link_attr(document, "linkDisabled", "href") == nil

      assert html =~
               ~s(data-bubble-id="linkDisabled")

      css = File.read!(Path.join(out, "styles/pages/index.css"))
      assert css =~ "display: block"
    end

    @tag :tmp_dir
    test "lowers Bubble Text and Password Input attributes", %{tmp_dir: tmp} do
      out = Path.join(tmp, "pkg")

      payload =
        FrontendFixtures.modern_page()
        |> put_in(["pages", "home", "elements"], %{
          "text" => %{
            "id" => "inputText",
            "type" => "Input",
            "properties" => %{
              "content_format" => "text",
              "placeholder" => "Text placeholder"
            }
          },
          "password" => %{
            "id" => "inputPassword",
            "type" => "Input",
            "properties" => %{
              "content_format" => "password",
              "content" => "BubbleEx mask demo",
              "placeholder" => "Password placeholder"
            }
          }
        })

      assert {:ok, _result} = Frontend.export_payload(payload, out, @scan)
      html = File.read!(Path.join(out, "pages/index/index.html"))
      {:ok, document} = Floki.parse_document(html)

      assert input_attr(document, "inputText", "type") == "text"
      assert input_attr(document, "inputText", "value") == nil
      assert input_attr(document, "inputText", "placeholder") == "Text placeholder"
      assert input_attr(document, "inputText", "aria-label") == "Text placeholder"

      assert input_attr(document, "inputPassword", "type") == "password"
      assert input_attr(document, "inputPassword", "value") == "BubbleEx mask demo"
      assert input_attr(document, "inputPassword", "placeholder") == "Password placeholder"
      assert input_attr(document, "inputPassword", "aria-label") == "Password placeholder"
    end

    @tag :tmp_dir
    test "lowers live compact input and choice-control aliases", %{tmp_dir: tmp} do
      out = Path.join(tmp, "pkg")

      payload =
        FrontendFixtures.modern_page()
        |> put_in(["pages", "home", "elements"], %{
          "email" => %{
            "id" => "compact-email",
            "%x" => "Input",
            "%p" => %{"%cf" => "email", "%ps" => "you@example.com"}
          },
          "multiline" => %{
            "id" => "compact-multiline",
            "%x" => "MultiLineInput",
            "%p" => %{
              "%c1" => "I32 multiline literal",
              "%ps" => "I32 multiline placeholder",
              "character_limit" => 120
            }
          },
          "password" => %{
            "id" => "compact-password",
            "%x" => "Input",
            "%p" => %{
              "%cf" => "password",
              "%c1" => "BubbleEx mask demo",
              "%ps" => "I37 password placeholder"
            }
          },
          "radios" => %{
            "id" => "compact-radios",
            "%x" => "RadioButtons",
            "%p" => %{"%ch" => "Narrow\nWide", "%d1" => "Wide"}
          },
          "select" => %{
            "id" => "compact-select",
            "%x" => "Dropdown",
            "%p" => %{
              "%ch" => "Alpha\nBeta\nGamma",
              "%d1" => "Beta",
              "%ps" => "Choose"
            }
          }
        })

      assert {:ok, _result} = Frontend.export_payload(payload, out, @scan)
      html = File.read!(Path.join(out, "pages/index/index.html"))
      {:ok, document} = Floki.parse_document(html)

      assert input_attr(document, "compact-email", "type") == "email"
      assert input_attr(document, "compact-email", "placeholder") == "you@example.com"
      assert input_attr(document, "compact-password", "type") == "password"
      assert input_attr(document, "compact-password", "value") == "BubbleEx mask demo"

      assert element_attr(
               document,
               ~s(textarea[data-bubble-id="compact-multiline"]),
               "placeholder"
             ) == "I32 multiline placeholder"

      assert Floki.find(document, ~s(textarea[data-bubble-id="compact-multiline"]))
             |> Floki.text() == "I32 multiline literal"

      assert Floki.find(document, ~s(select[data-bubble-id="compact-select"] option))
             |> Enum.map(&Floki.text/1) == ["Choose", "Alpha", "Beta", "Gamma"]

      assert element_attr(document, ~s(option[value="Beta"]), "selected") == "selected"

      assert Floki.find(
               document,
               ~s(fieldset[data-bubble-id="compact-radios"] input[type="radio"])
             )
             |> length() == 2

      assert element_attr(
               document,
               ~s(fieldset[data-bubble-id="compact-radios"] input[value="Wide"]),
               "checked"
             ) == "checked"
    end

    @tag :tmp_dir
    test "emits semantic HTML for the characterized S2 static-control slice", %{tmp_dir: tmp} do
      out = Path.join(tmp, "pkg")

      assert {:ok, result} =
               Frontend.export_payload(FrontendFixtures.s2_controls_app(), out, @scan)

      html = File.read!(Path.join(out, "pages/s2-static-controls/index.html"))
      {:ok, document} = Floki.parse_document(html)

      assert element_attr(document, ~s(textarea[data-bubble-id="control-multiline"]), "maxlength") ==
               "240"

      assert html =~ ">Line one&#10;Line two</textarea>"

      assert element_attr(
               document,
               ~s(label[data-bubble-id="control-checkbox"] input[type="checkbox"]),
               "checked"
             ) == "checked"

      assert Floki.find(document, ~s(label[data-bubble-id="control-checkbox"])) |> Floki.text() =~
               "Include static assets"

      assert element_attr(
               document,
               ~s(label[data-bubble-id="control-checkbox-unchecked"] input[type="checkbox"]),
               "checked"
             ) == nil

      assert element_attr(document, ~s(select[data-bubble-id="control-dropdown"]), "required") ==
               "required"

      assert Floki.find(document, ~s(select[data-bubble-id="control-dropdown"] option))
             |> Enum.map(&Floki.text/1) == ["Choose a target", "HTML", "React", "Vue"]

      assert element_attr(document, ~s(option[value="React"]), "selected") == "selected"

      assert element_attr(document, ~s(fieldset[data-bubble-id="control-radios"]), "aria-label") ==
               "radios"

      assert length(
               Floki.find(
                 document,
                 ~s(fieldset[data-bubble-id="control-radios"] input[type="radio"])
               )
             ) ==
               2

      assert element_attr(document, ~s(input[type="radio"][value="Wide"]), "checked") ==
               "checked"

      assert html =~ ~s(data-placeholder-kind="Dropdown")
      assert result.manifest["package_version"] == 1
      assert result.manifest["normalized_schema_version"] == 2
      assert result.coverage["overall"]["elements"]["native"] == 5
      assert result.coverage["overall"]["elements"]["placeholder"] == 1
      assert Enum.any?(result.findings, &(&1["type"] == "unsupported_element"))
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

    @tag :tmp_dir
    test "selects hydrated aliased pages by %nm and blocks metadata-only pages", %{tmp_dir: tmp} do
      payload = %{
        "_id" => "liveapp",
        "%p3" => %{
          "opaque" => %{
            "%el" => %{
              "text" => %{
                "%nm" => "Greeting",
                "%p" => %{"%3" => "Hello"},
                "%x" => "Text",
                "id" => "text"
              }
            },
            "%nm" => "target-page",
            "%p" => %{},
            "%x" => "Page",
            "id" => "opaque"
          },
          "metadata" => %{
            "%nm" => "",
            "name" => "other-page",
            "elements" => nil,
            "%p" => %{"%rf" => nil},
            "%x" => "Page",
            "id" => "metadata"
          }
        }
      }

      hydrated_out = Path.join(tmp, "hydrated")

      assert {:ok, result} =
               Frontend.export_payload(payload, hydrated_out, @scan ++ [pages: ["target-page"]])

      assert "pages/target-page/index.html" in result.files

      metadata_out = Path.join(tmp, "metadata")

      assert {:error, %Error{kind: :parse_failed}} =
               Frontend.export_payload(payload, metadata_out, @scan ++ [pages: ["other-page"]])

      refute File.exists?(metadata_out)
    end

    @tag :tmp_dir
    test "emits a semantic link for a single Go to page button and keeps workflow metadata", %{
      tmp_dir: tmp
    } do
      out = Path.join(tmp, "pkg")

      payload = %{
        "_id" => "s1app",
        "app_version" => "live",
        "pages" => %{
          "home" => %{
            "id" => "pghome",
            "type" => "Page",
            "name" => "index",
            "properties" => %{"container_layout" => "column", "title" => "Home"},
            "elements" => %{
              "go" => %{
                "id" => "elGo",
                "type" => "Button",
                "properties" => %{"text" => "About"}
              }
            },
            "workflows" => %{
              "wfGo" => %{
                "type" => "ButtonClicked",
                "properties" => %{"element_id" => "elGo"},
                "actions" => %{
                  "0" => %{"type" => "ChangePage", "properties" => %{"page" => "about"}}
                }
              }
            }
          },
          "about" => %{
            "id" => "pgabout",
            "type" => "Page",
            "name" => "about",
            "properties" => %{"container_layout" => "column"}
          }
        }
      }

      assert {:ok, result} = Frontend.export_payload(payload, out, @scan)
      home = File.read!(Path.join(out, "pages/index/index.html"))
      assert home =~ ~s(<a )
      assert home =~ ~s(href="../about/index.html")
      assert home =~ "About"
      refute home =~ "<button"
      assert Enum.any?(result.bindings, &(&1["kind"] == "workflow"))
    end

    test "rejects raw transport authentication without a fetched origin" do
      assert {:error, %Error{kind: :invalid_input}} =
               Frontend.export_payload(
                 FrontendFixtures.modern_page(),
                 "unused",
                 @scan ++ [session_cookie: "session=not-accepted-here"]
               )

      assert {:error, %Error{kind: :invalid_input}} =
               Frontend.export_payload(
                 FrontendFixtures.modern_page(),
                 "unused",
                 @scan ++ [asset_access: :same_origin]
               )
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

  defp link_attr(document, bubble_id, name),
    do: element_attr(document, ~s(a[data-bubble-id="#{bubble_id}"]), name)

  defp input_attr(document, bubble_id, name),
    do: element_attr(document, ~s(input[data-bubble-id="#{bubble_id}"]), name)

  defp element_attr(document, selector, name) do
    document
    |> Floki.find(selector)
    |> Floki.attribute(name)
    |> List.first()
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
