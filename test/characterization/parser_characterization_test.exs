defmodule BubbleEx.Characterization.ParserTest do
  @moduledoc """
  Characterization tests: freeze the *current* output of BubbleEx.Apps.Parser
  against inline synthetic JS strings so any refactor that changes behavior is
  caught immediately. Values were captured from the code as of 2026-06-20.
  """
  use ExUnit.Case, async: true

  alias BubbleEx.Apps.Parser

  @synthetic_js ~S"""
  const app = JSON.parse('{"_id":"synthapp","settings":{"client_safe":{"facebook_meta_tag_title":"Synthetic App","plugins":{"a":{},"b":{},"c":{}}}}}');
  """

  describe "parse_app_json/1 on a synthetic dynamic.js" do
    setup do
      assert {:ok, app} = Parser.parse_app_json(@synthetic_js)
      {:ok, app: app}
    end

    test "extracts the app id", %{app: app} do
      assert app["_id"] == "synthapp"
    end

    test "extracts the title", %{app: app} do
      assert Parser.extract_title(app) == "Synthetic App"
    end

    test "counts plugins", %{app: app} do
      assert Parser.count_plugins(app) == 3
    end
  end

  describe "JS string-literal decoding (the fragile decoder)" do
    test "decodes surrogate pairs, hex escapes, and apostrophes" do
      js = ~S"""
      const app = JSON.parse('{"_id":"abacus","title":"Bob\'s app","emoji":"😀","hex":"\x41"}');
      """

      assert {:ok, app} = Parser.parse_app_json(js)
      assert app["_id"] == "abacus"
      assert app["title"] == "Bob's app"
      assert app["emoji"] == "😀"
      assert app["hex"] == "A"
    end
  end
end
