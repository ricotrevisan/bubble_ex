defmodule BubbleEx.AppsTest do
  use ExUnit.Case, async: false

  alias BubbleEx.Apps
  alias BubbleEx.Apps.Parser
  alias BubbleEx.Apps.Validator
  alias BubbleEx.HTTP
  alias Plug.Conn

  describe "validate_input/1" do
    test "normalizes bare domains to HTTPS URLs" do
      assert {:ok, "https://bubble.io"} = Validator.validate_input("bubble.io")
    end

    test "turns a bare slug into a bubbleapps.io URL" do
      assert {:ok, "https://my-app.bubbleapps.io"} = Validator.validate_input("my-app")
    end
  end

  describe "get_dynamic_js extraction (offline)" do
    test "extracts and absolutizes the dynamic js URL from page HTML" do
      payload = %{
        body: "<script src='/package/dynamic_js/123/dynamic.js'></script>",
        url: "https://example.com"
      }

      assert {:ok, url} = Parser.extract_dynamic_js_url(payload)
      assert url == "https://example.com:443/package/dynamic_js/123/dynamic.js"
    end
  end

  describe "fetch_app/2 (offline, full pipeline via Req.Test)" do
    setup do
      HTTP.put_process_options(plug: {Req.Test, __MODULE__})
      on_exit(fn -> HTTP.delete_process_options() end)
      :ok
    end

    @app_json ~S({"_id":"abacus-desktop","settings":{"client_safe":{"plugins":{"a":true,"b":{},"c":{}}}}})

    defp stub_two_stage_fetch do
      Req.Test.stub(__MODULE__, fn conn ->
        conn = Conn.put_resp_header(conn, "x-bubble-something", "1")
        path = conn.request_path || ""

        if String.contains?(path, "dynamic_js") do
          Conn.resp(conn, 200, "const app = JSON.parse('#{@app_json}');\n")
        else
          Conn.resp(
            conn,
            200,
            "<html><script src='/package/dynamic_js/1/dynamic.js'></script></html>"
          )
        end
      end)
    end

    test "fetches and parses an app end-to-end with no network" do
      stub_two_stage_fetch()

      assert {:ok, attrs} = Apps.fetch_app("abacus-desktop")
      assert attrs.valid?
      assert attrs.bubble_id == "abacus-desktop"
      assert attrs.app_plan == :paid
      assert attrs.plugin_count == 3
    end

    test "includes the raw payload when include_payload: true" do
      stub_two_stage_fetch()

      assert {:ok, attrs} = Apps.fetch_app("abacus-desktop", include_payload: true)
      assert is_map(attrs.payload)
      assert attrs.payload["_id"] == "abacus-desktop"
    end

    test "returns an error tuple when the page is not a Bubble app" do
      Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 200, "<html>not bubble</html>") end)

      assert {:error, %BubbleEx.Error{}} = Apps.fetch_app("abacus-desktop")
    end
  end

  # ── Live integration tests (excluded by default; require network) ──────────

  describe "check_versions/3" do
    @describetag :integration

    test "meta" do
      versions = Apps.check_versions("meta", nil, nil)
      assert is_list(versions)
      assert "live" in versions
      refute "test" in versions
    end

    test "returns empty list for a nonexistent app" do
      assert Apps.check_versions("thisappdoesnotexist") == []
    end
  end

  describe "check/1" do
    @describetag :integration

    test "valid and invalid apps" do
      assert %{valid: true, bubble_id: "meta"} = Apps.check("bubble.io")
      assert %{valid: false, bubble_id: nil} = Apps.check("theverge.com")
    end
  end

  describe "dedicated?/2" do
    @describetag :integration

    test "non-dedicated apps" do
      assert {:ok, %{is_dedicated: false}} = Apps.dedicated?("betterlegal")
    end

    test "returns an error for a non-existent app" do
      assert {:error, %BubbleEx.Error{}} = Apps.dedicated?("thisappshouldnotexist")
    end
  end

  describe "fetch_app/2 (live)" do
    @describetag :integration

    test "abacus-desktop end to end fetches app payload" do
      assert {:ok, attrs} =
               Apps.fetch_app("abacus-desktop",
                 include_payload: true,
                 max_retries: 1,
                 retry_base_delay: 100
               )

      assert attrs.valid?
      assert attrs.bubble_id == "abacus-desktop"
      assert attrs.payload["_id"] == "abacus-desktop"
      assert attrs.plugin_count == 12
    end

    test "returns invalid app attrs for a non-existent app" do
      assert {:ok, attrs} = BubbleEx.fetch_app("non-existent-app")
      assert attrs.valid? == false
    end
  end
end
