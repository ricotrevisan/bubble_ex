defmodule BubbleEx.Frontend.FidelityTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Error
  alias BubbleEx.Frontend.Fidelity

  describe "cases/0" do
    test "lists the frozen S1 layout, Image, Link, and Input cases" do
      ids = Fidelity.cases()
      assert "bpmkbvvo" in ids
      assert "bprkyexk" in ids
      assert "bptaixqv" in ids
      assert "bpewigqu" in ids
      assert ids == Enum.sort(ids)
    end
  end

  describe "load_case/1" do
    test "loads the frozen bpewigqu Text/Password Input pin" do
      assert {:ok, case_} = Fidelity.load_case("bpewigqu")
      assert case_.id == "bpewigqu"
      assert case_.browser.playwright == "1.55.0"
      assert case_.browser.chromium == "140.0.7339.16"
      assert case_.source.page_id == "bpewigqu"
      assert case_.source.page_path == "bubbleex-i37-text-password-input"
      assert case_.viewports == [390, 1440]
    end

    test "loads the frozen bptaixqv text-only Link pin" do
      assert {:ok, case_} = Fidelity.load_case("bptaixqv")
      assert case_.id == "bptaixqv"
      assert case_.browser.playwright == "1.55.0"
      assert case_.browser.chromium == "140.0.7339.16"
      assert case_.source.page_id == "bptaixqv"
      assert case_.source.page_path == "bubbleex-i36-text-only-link"
      assert case_.viewports == [390, 1440]
    end

    test "loads the frozen bprkyexk image-mode pin" do
      assert {:ok, case_} = Fidelity.load_case("bprkyexk")
      assert case_.id == "bprkyexk"
      assert case_.browser.playwright == "1.55.0"
      assert case_.browser.chromium == "140.0.7339.16"
      assert case_.source.page_id == "bprkyexk"
      assert case_.source.page_path == "bubbleex-i35-image-modes"
      assert 390 in case_.viewports
      assert 1440 in case_.viewports
    end

    test "loads the frozen bpmkbvvo pin and viewport matrix" do
      assert {:ok, case_} = Fidelity.load_case("bpmkbvvo")
      assert case_.id == "bpmkbvvo"
      assert case_.browser.playwright == "1.55.0"
      assert case_.browser.chromium == "140.0.7339.16"
      assert case_.browser.dpr == 1
      assert case_.browser.locale == "en-US"
      assert case_.browser.reduced_motion == "reduce"
      assert case_.browser.viewport_height == 900

      assert case_.font.sha256 ==
               "3100e775e8616cd2611beecfa23a4263d7037586789b43f035236a2e6fbd4c62"

      assert case_.source.page_payload_sha256 ==
               "706f73ef49c170ab077bfe680403782f5dea94ba36ea5cae3c3878079340701b"

      assert 390 in case_.viewports
      assert 1440 in case_.viewports
      assert 768 in case_.viewports
    end

    test "rejects an unknown case as :not_found" do
      assert {:error, %Error{kind: :not_found}} = Fidelity.load_case("nope")
    end
  end

  describe "structure/1" do
    test "accepts a clean exporter document with declared semantics" do
      html = """
      <!DOCTYPE html>
      <html>
      <body>
      <main data-exporter-id="page/1" data-bubble-id="bpmkbvvo">
        <h1 data-exporter-id="t1" data-bubble-id="bpmkbvvz">Title</h1>
        <button type="button" data-exporter-id="b1" data-bubble-id="bpmkbvvv">Go</button>
        <input type="email" data-exporter-id="i1" data-bubble-id="bpmkbvxi" placeholder="you@example.com">
        <div data-exporter-id="s1" data-bubble-id="bpmkbvwf" aria-hidden="true"></div>
      </main>
      </body>
      </html>
      """

      snapshot = %{
        "main" => ["bpmkbvvo"],
        "headings" => %{"h1" => ["bpmkbvvz"]},
        "buttons" => ["bpmkbvvv"],
        "inputs" => ["bpmkbvxi"],
        "decorative" => ["bpmkbvwf"]
      }

      assert :ok = Fidelity.structure(html, snapshot)
    end

    test "checks text-only Link names and navigation attributes" do
      html = """
      <html><body>
        <a data-exporter-id="external" data-bubble-id="external" href="https://example.com">External</a>
        <a data-exporter-id="newtab" data-bubble-id="newtab" href="https://example.com/new" target="_blank" rel="nofollow noopener">New tab</a>
        <a data-exporter-id="disabled" data-bubble-id="disabled">Disabled</a>
      </body></html>
      """

      snapshot = %{
        "links" => ["external", "newtab", "disabled"],
        "link_attributes" => %{
          "external" => %{"href" => "https://example.com", "target" => nil},
          "newtab" => %{
            "href" => "https://example.com/new",
            "target" => "_blank",
            "rel" => "nofollow noopener"
          },
          "disabled" => %{"href" => nil}
        }
      }

      assert :ok = Fidelity.structure(html, snapshot)

      assert {:error, %Error{kind: :invalid_input}} =
               Fidelity.structure(String.replace(html, ">Disabled<", "><"), snapshot)

      assert {:error, %Error{kind: :invalid_input}} =
               Fidelity.structure(
                 String.replace(html, ~s( target="_blank"), ""),
                 snapshot
               )
    end

    test "checks Text and Password Input attributes" do
      html = """
      <html><body>
        <input data-exporter-id="text" data-bubble-id="text" type="text" placeholder="Text placeholder" aria-label="Text placeholder">
        <input data-exporter-id="password" data-bubble-id="password" type="password" value="BubbleEx mask demo" placeholder="Password placeholder" aria-label="Password placeholder">
      </body></html>
      """

      snapshot = %{
        "inputs" => ["text", "password"],
        "input_attributes" => %{
          "text" => %{
            "type" => "text",
            "value" => nil,
            "placeholder" => "Text placeholder",
            "aria-label" => "Text placeholder"
          },
          "password" => %{
            "type" => "password",
            "value" => "BubbleEx mask demo",
            "placeholder" => "Password placeholder",
            "aria-label" => "Password placeholder"
          }
        }
      }

      assert :ok = Fidelity.structure(html, snapshot)

      assert {:error, %Error{kind: :invalid_input}} =
               Fidelity.structure(
                 String.replace(html, ~s(type="password"), ~s(type="text")),
                 snapshot
               )
    end

    test "fails on script tags, inline handlers, or missing exporter ids" do
      assert {:error, %Error{kind: :invalid_input}} =
               Fidelity.structure(
                 "<html><script></script><main data-bubble-id=\"x\"></main></html>",
                 %{}
               )

      assert {:error, %Error{kind: :invalid_input}} =
               Fidelity.structure(
                 ~s(<html><main data-exporter-id="p" onclick="x"></main></html>),
                 %{}
               )

      assert {:error, %Error{kind: :invalid_input}} =
               Fidelity.structure(~s(<html><main data-bubble-id="x"></main></html>), %{
                 "main" => ["x"]
               })
    end
  end

  describe "a11y/1" do
    test "fails only on unlabeled emitted controls and unmarked decorative shapes" do
      bad = """
      <html><body>
        <button type="button" data-exporter-id="b"></button>
        <input type="email" data-exporter-id="i">
        <a data-exporter-id="a" href="/"></a>
        <img data-exporter-id="img" src="x.png">
        <div data-exporter-id="s" data-placeholder-kind="nope"></div>
      </body></html>
      """

      assert {:error, %Error{kind: :invalid_input, context: %{violations: violations}}} =
               Fidelity.a11y(bad)

      assert Enum.any?(violations, &(&1.role == "button"))
      assert Enum.any?(violations, &(&1.role == "input"))
      assert Enum.any?(violations, &(&1.role == "a"))
      assert Enum.any?(violations, &(&1.role == "img"))
    end

    test "accepts labeled controls and aria-hidden decorative shapes" do
      html = """
      <html><body>
        <button type="button" data-exporter-id="b">Go</button>
        <input type="email" data-exporter-id="i" aria-label="Email">
        <a data-exporter-id="a" href="/">Docs</a>
        <img data-exporter-id="img" src="x.png" alt="Hero">
        <div data-exporter-id="s" aria-hidden="true"></div>
      </body></html>
      """

      assert :ok = Fidelity.a11y(html)
    end
  end

  describe "run/2" do
    @tag :fidelity
    @tag :tmp_dir
    test "bpmkbvvo passes the committed-reference gate", %{tmp_dir: tmp} do
      assert {:ok, report} = Fidelity.run("bpmkbvvo", out_dir: Path.join(tmp, "pkg"))
      assert report["status"] == "pass"
      assert report["mismatches"] == []
    end

    @tag :fidelity
    @tag :tmp_dir
    test "bprkyexk passes the committed-reference gate", %{tmp_dir: tmp} do
      assert {:ok, report} = Fidelity.run("bprkyexk", out_dir: Path.join(tmp, "pkg"))
      assert report["status"] == "pass"
      assert report["mismatches"] == []
    end

    @tag :fidelity
    @tag :tmp_dir
    test "bptaixqv passes the committed-reference gate", %{tmp_dir: tmp} do
      assert {:ok, report} = Fidelity.run("bptaixqv", out_dir: Path.join(tmp, "pkg"))
      assert report["status"] == "pass"
      assert report["mismatches"] == []
    end

    @tag :fidelity
    @tag :tmp_dir
    test "bpewigqu passes the committed-reference gate", %{tmp_dir: tmp} do
      assert {:ok, report} = Fidelity.run("bpewigqu", out_dir: Path.join(tmp, "pkg"))
      assert report["status"] == "pass"
      assert report["mismatches"] == []
    end
  end
end
