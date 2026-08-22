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

    test "merges Bubble Object.assign JSON patches into the initial app map" do
      payload = ~S"""
      const app = JSON.parse('{"%p3":{"opaque":{"%nm":"old-name","%p":{"%rf":null},"%x":"page","id":"opaque"}},"_index":{"id_to_path":{"existing":"path"}}}');
      app['%p3']['opaque'] = Object.assign(app['%p3']['opaque'] ? app['%p3']['opaque'] : {}, JSON.parse('{"%el":{"text":{"%nm":"Greeting","%p":{"text":"Hello"},"%x":"Text","id":"text"}},"%nm":"tanstack-chart-demo","%wf":{}}'));
      app['_index']['id_to_path'] = Object.assign(app['_index']['id_to_path'] ? app['_index']['id_to_path'] : {}, JSON.parse('{"text":"pages.opaque.elements.text"}'));
      """

      assert {:ok, app_json} = Parser.parse_app_json(payload)
      page = app_json["%p3"]["opaque"]

      assert page["%nm"] == "tanstack-chart-demo"
      assert page["%p"] == %{"%rf" => nil}
      assert page["%el"]["text"]["%p"]["text"] == "Hello"

      assert app_json["_index"]["id_to_path"] == %{
               "existing" => "path",
               "text" => "pages.opaque.elements.text"
             }
    end

    test "fails instead of silently dropping a malformed Bubble page patch" do
      payload = ~S"""
      const app = JSON.parse('{"%p3":{"opaque":{"%nm":"target"}}}');
      app['%p3']['opaque'] = Object.assign(app['%p3']['opaque'] ? app['%p3']['opaque'] : {}, JSON.parse(not_a_string_literal));
      """

      assert {:error, %{phase: :decode_app_json_patch}} = Parser.parse_app_json(payload)
    end

    test "ignores unrelated Object.assign JavaScript" do
      payload = ~S"""
      const app = JSON.parse('{"_id":"synthapp"}');
      const copy = Object.assign({}, {"not":"an app patch"});
      """

      assert {:ok, %{"_id" => "synthapp"}} = Parser.parse_app_json(payload)
    end

    # Real Bubble payloads escape every single quote, so decode is escape-heavy.
    # The legacy decoder built a per-character list of tiny binaries, amplifying
    # memory ~160x (a 15MB dynamic.js peaked at 2.4GB and OOM-killed production).
    # A 7MB escaped payload must decode under a 400MB heap cap.
    test "decodes a large escape-heavy payload within a bounded heap" do
      body =
        ~S({"_id":"memtest","notes":") <>
          String.duplicate(~S(it\'s ), 1_000_000) <>
          ~S("})

      js = "const app = JSON.parse('" <> body <> "');"
      assert byte_size(js) > 5_000_000

      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{size: 50_000_000, kill: true, error_logger: true})
          send(parent, {:result, Parser.parse_app_json(js)})
        end)

      receive do
        {:result, {:ok, app_json}} ->
          assert app_json["_id"] == "memtest"
          assert String.starts_with?(app_json["notes"], "it's it's ")

        {:result, {:error, reason}} ->
          flunk("decode failed: #{inspect(reason)}")

        {:DOWN, ^ref, :process, ^pid, reason} ->
          flunk("decoder process killed by heap cap: #{inspect(reason)}")
      after
        30_000 ->
          Process.exit(pid, :kill)
          flunk("decode did not finish within 30s")
      end
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
