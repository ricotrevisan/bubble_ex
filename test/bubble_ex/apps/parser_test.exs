defmodule BubbleEx.Apps.ParserTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Apps.Parser

  describe "parse_app_json/1" do
    test "decodes Bubble JSON.parse JavaScript string literals before JSON decoding" do
      js = ~S"""
      const app = JSON.parse('{"_id":"abacus-desktop","title":"Bob\'s app","emoji":"\uD83D\uDE00","hex":"\x41","settings":{"client_safe":{"plugins":{"a":true,"b":{}}}}}');
      """

      assert {:ok, app_json} = Parser.parse_app_json(js)
      assert app_json["_id"] == "abacus-desktop"
      assert app_json["title"] == "Bob's app"
      assert app_json["emoji"] == "😀"
      assert app_json["hex"] == "A"
      assert map_size(app_json["settings"]["client_safe"]["plugins"]) == 2
    end

    test "parses a synthetic dynamic.js inline fixture" do
      payload = ~S"""
      const app = JSON.parse('{"_id":"synthapp","settings":{"client_safe":{"facebook_meta_tag_title":"Synthetic App","plugins":{"a":{},"b":{},"c":{}}}}}');
      """

      assert {:ok, app_json} = Parser.parse_app_json(payload)
      assert app_json["_id"] == "synthapp"
    end
  end

  describe "find_app_line/1" do
    test "returns the trimmed marker line from multi-line content" do
      js = "var x = 1;\n  const app = JSON.parse('{}');\nfoo();\n"
      assert {:ok, "const app = JSON.parse('{}');"} = Parser.find_app_line(js)
    end

    test "ignores a mid-line occurrence and finds the real marker line" do
      js = "x = \"const app = JSON inside string\";\nconst app = JSON.parse('{}');\n"
      assert {:ok, "const app = JSON.parse('{}');"} = Parser.find_app_line(js)
    end

    test "returns :not_found when absent" do
      assert {:error, :not_found} = Parser.find_app_line("no marker here\n")
    end
  end
end
