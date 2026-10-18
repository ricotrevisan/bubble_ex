defmodule BubbleEx.StaticJsTest do
  use ExUnit.Case, async: false

  alias BubbleEx.StaticJs

  # The shape of a real static.js (bubble.io's own, 2026-10-18), one
  # statement per line.
  @static_js Enum.join(
               [
                 ~s|window.preloaded = window.preloaded \|\| {};|,
                 ~s|"use strict";(()=>{var runtime="AKIAFIXTURERUNTIME"})();|,
                 ~s|window._bubble_page_load_data.hardcoded_plugins['stripe'] = true;|,
                 ~s|"use strict";(()=>{var stripe="sk_test_fixture"})();|,
                 ~s|window.preloaded['plugin/first_party:stripe'] = true;|,
                 ~s|window.plugins["1613760507644x836536289953054700"] = {"human":"Canvas \\"UI\\" Elements","code":"key_fixture"};|,
                 ~s|window._bubble_page_load_data.plugins_size['1613760507644x836536289953054700'] = 96395;|,
                 ~s|window.plugins["1499780054879x111265002286743550"] = {"dependencies":{}};|
               ],
               "\n"
             )

  test "index/1 finds marketplace plugin lines and Bubble's plugin blocks" do
    index = StaticJs.index(@static_js)

    assert index.plugins == %{
             6 => {"1613760507644x836536289953054700", ~s(Canvas "UI" Elements)},
             8 => {"1499780054879x111265002286743550", nil}
           }

    assert index.bubble_plugins == [{3, 5, "stripe"}]
  end

  test "source/2 names the plugin, Bubble's plugin or the runtime a line is in" do
    index = StaticJs.index(@static_js)

    assert %{
             kind: :plugin,
             plugin_id: "1613760507644x836536289953054700",
             plugin: ~s(Canvas "UI" Elements)
           } =
             StaticJs.source(index, 6)

    assert %{kind: :bubble_plugin, plugin_id: nil, plugin: "stripe"} = StaticJs.source(index, 4)
    assert %{kind: :bubble_runtime, plugin: nil} = StaticJs.source(index, 2)
    assert %{kind: :bubble_runtime} = StaticJs.source(index, 7)
    assert %{kind: :plugin, line: 6} = StaticJs.source(@static_js, 6)
  end

  test "an unclosed Bubble plugin block attributes nothing to it" do
    text = "window._bubble_page_load_data.hardcoded_plugins['google'] = true;\ncode"
    assert %{kind: :bubble_runtime} = StaticJs.source(text, 2)
  end

  test "attribute/2 places findings by TruffleHog's line, else by their value" do
    by_line = %{
      "DetectorName" => "Box",
      "Raw" => "anything",
      "SourceMetadata" => %{"Data" => %{"Filesystem" => %{"line" => 6}}}
    }

    by_value = %{"DetectorName" => "Stripe", "Raw" => "sk_test_fixture"}
    nowhere = %{"DetectorName" => "Other", "Raw" => "not in the file"}

    assert [
             %{
               "StaticJs" => %{
                 "kind" => "plugin",
                 "line" => 6,
                 "plugin_id" => "1613760507644x836536289953054700",
                 "plugin" => ~s(Canvas "UI" Elements)
               }
             },
             %{"StaticJs" => %{"kind" => "bubble_plugin", "line" => 4, "plugin" => "stripe"}},
             ^nowhere
           ] = StaticJs.attribute([by_line, by_value, nowhere], @static_js)
  end

  describe "scan/2" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "bubble_ex_static_js_#{System.pid()}_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      cli = Path.join(root, "trufflehog")

      finding = %{
        "DetectorName" => "Box",
        "DetectorType" => 1,
        "DecoderName" => "PLAIN",
        "Verified" => false,
        "Raw" => "key_fixture",
        "SourceMetadata" => %{"Data" => %{"Filesystem" => %{"line" => 6}}}
      }

      # Copies the scanned file so the test can check what was scanned.
      File.write!(cli, """
      #!/bin/sh
      cp "$2" '#{root}/scanned'
      printf '%s\\n' '#{Jason.encode!(finding)}'
      """)

      File.chmod!(cli, 0o700)
      original_path = System.get_env("PATH")
      System.put_env("PATH", root <> ":" <> original_path)

      on_exit(fn ->
        System.put_env("PATH", original_path)
        File.rm_rf!(root)
      end)

      %{root: root}
    end

    test "scans the text as is and attributes each finding", %{root: root} do
      assert {:ok, [%{"Raw" => "key_fixture", "StaticJs" => %{"kind" => "plugin", "line" => 6}}]} =
               StaticJs.scan(@static_js, verify: false)

      assert File.read!(Path.join(root, "scanned")) == @static_js
    end
  end
end
