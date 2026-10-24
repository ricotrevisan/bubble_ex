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

    test "reports a version Bubble locked for the app's plan" do
      payload = %{
        body:
          ~s(<!doctype html><title>Bubble Application</title><div class="mention">This ) <>
            ~s(<a href="https://bubble.io">Bubble</a> application is protected in run mode by a ) <>
            "password. The application plan does not include this feature.</div>",
        url: "https://locked.bubbleapps.io/version-test"
      }

      assert {:error,
              %BubbleEx.Error{
                kind: :version_locked,
                context: %{url: "https://locked.bubbleapps.io/version-test"}
              }} = Parser.extract_dynamic_js_url(payload)
    end

    test "reports a page without a dynamic_js script as a parse failure" do
      payload = %{body: "<html><body>maintenance</body></html>", url: "https://example.com"}

      assert {:error,
              %BubbleEx.Error{
                kind: :parse_failed,
                context: %{reason: :dynamic_js_script_not_found, url: "https://example.com"}
              }} = Parser.extract_dynamic_js_url(payload)
    end
  end

  describe "fetch_app/2 (offline, full pipeline via Req.Test)" do
    setup do
      HTTP.put_process_options(plug: {Req.Test, __MODULE__})
      on_exit(fn -> HTTP.delete_process_options() end)
      :ok
    end

    @app_json ~S({"_id":"acme-desktop","settings":{"client_safe":{"plugins":{"a":true,"b":{},"c":{}}}}})
    @version_url "https://acme-desktop.bubbleapps.io/version-test"

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

      assert {:ok, attrs} = Apps.fetch_app("acme-desktop")
      assert attrs.valid?
      assert attrs.bubble_id == "acme-desktop"
      assert attrs.app_plan == :paid
      assert attrs.plan_basis == "live 200"
      refute attrs.is_dedicated
      assert attrs.plugin_count == 3
    end

    test "includes the raw payload when include_payload: true" do
      stub_two_stage_fetch()

      assert {:ok, attrs} = Apps.fetch_app("acme-desktop", include_payload: true)
      assert is_map(attrs.payload)
      assert attrs.payload["_id"] == "acme-desktop"
    end

    test "rejects an unknown foreign_keys mode for a SQL format before any request" do
      Req.Test.stub(__MODULE__, fn _conn -> flunk("no request expected") end)

      for format <- [:postgres, :sqlite, :tsql], mode <- [:bogus, "enforced"] do
        assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
                 Apps.fetch_app("acme-desktop", format: format, foreign_keys: mode)
      end
    end

    test "ignores foreign_keys for a non-SQL format" do
      stub_two_stage_fetch()

      assert {:ok, attrs} = Apps.fetch_app("acme-desktop", format: :dbml, foreign_keys: :bogus)
      assert attrs.schema =~ "Table"
    end

    test "returns an error tuple when the page is not a Bubble app" do
      Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 200, "<html>not bubble</html>") end)

      assert {:error, %BubbleEx.Error{}} = Apps.fetch_app("acme-desktop")
    end

    test "classifies dedicated hosting from the live redirect" do
      stub_live_redirect(302, "https://d123.bubble.is/version-live")

      assert {:ok, attrs} = Apps.fetch_app("acme-desktop", max_retries: 0)

      assert attrs.app_plan == :dedicated
      assert attrs.plan_basis == "live 302 -> d123.bubble.is"
      assert attrs.is_dedicated
      assert attrs.dedicated_server == "d123"
      assert attrs.base_url == "https://d123.bubble.is"
      assert attrs.plugin_count == 3
    end

    test "classifies a custom-domain redirect as paid and fetches it" do
      stub_live_redirect(301, "https://www.custom-app.example/")

      assert {:ok, attrs} = Apps.fetch_app("acme-desktop", max_retries: 0)

      assert attrs.app_plan == :paid
      assert attrs.plan_basis == "live 301 -> custom domain"
      refute attrs.is_dedicated
      assert attrs.base_url == nil
      assert attrs.plugin_count == 3
    end

    test "classifies a free app from live_not_supported and the version-test page" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn = Conn.put_resp_header(conn, "x-bubble-something", "1")
        path = conn.request_path || ""

        cond do
          String.contains?(path, "dynamic_js") ->
            Conn.resp(conn, 200, "const app = JSON.parse('#{@app_json}');\n")

          path == "/version-test" ->
            Conn.resp(conn, 200, landing_page())

          true ->
            conn
            |> Conn.put_resp_header(
              "location",
              "https://bubble.io/live_not_supported?appname=acme-desktop"
            )
            |> Conn.send_resp(302, "")
        end
      end)

      assert {:ok, attrs} = Apps.fetch_app("acme-desktop", max_retries: 0)

      assert attrs.app_plan == :free
      assert attrs.plan_basis == "live 302 live_not_supported; version-test serves the app"
      refute attrs.is_dedicated
      assert attrs.bubble_id == "acme-desktop"
    end

    test "reads the plan from the live origin when a version URL is fetched" do
      counter = stub_version_fetch(fn conn -> Conn.resp(conn, 200, landing_page()) end)

      assert {:ok, attrs} = Apps.fetch_app(@version_url, max_retries: 0)

      assert attrs.app_plan == :paid
      assert attrs.plan_basis == "live 200"
      assert attrs.bubble_id == "acme-desktop"
      assert probes(counter) == 1
    end

    test "a dead live origin leaves the plan unknown but still fetches the app" do
      counter = stub_version_fetch(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:ok, attrs} = Apps.fetch_app(@version_url, max_retries: 0)

      assert attrs.app_plan == nil
      assert attrs.plan_basis == "no evidence (timeout)"
      assert attrs.bubble_id == "acme-desktop"
      assert probes(counter) == 1
    end

    test "a version URL that serves does not make a free app paid" do
      counter =
        stub_version_fetch(fn conn ->
          conn
          |> Conn.put_resp_header(
            "location",
            "https://bubble.io/live_not_supported?appname=acme-desktop"
          )
          |> Conn.send_resp(302, "")
        end)

      assert {:ok, attrs} = Apps.fetch_app(@version_url, max_retries: 0)

      assert attrs.app_plan == :free
      assert attrs.plan_basis == "live 302 live_not_supported; version-test serves the app"
      refute attrs.is_dedicated
      assert probes(counter) == 1
    end

    test "a version URL does not hide a live 404" do
      counter = stub_version_fetch(fn conn -> Conn.resp(conn, 404, "not found") end)

      assert {:ok, attrs} = Apps.fetch_app(@version_url, max_retries: 0)

      assert attrs.app_plan == :free
      assert attrs.plan_basis == "live 404; version-test serves the app"
      assert probes(counter) == 1
    end

    test "a version URL is classified from the live redirect, not its own answer" do
      counter =
        stub_version_fetch(fn conn ->
          conn
          |> Conn.put_resp_header("location", "https://d123.bubble.is/site/acme")
          |> Conn.send_resp(302, "")
        end)

      assert {:ok, attrs} = Apps.fetch_app(@version_url, max_retries: 0)

      assert attrs.app_plan == :dedicated
      assert attrs.plan_basis == "live 302 -> d123.bubble.is"
      assert attrs.dedicated_server == "d123"
      assert attrs.is_dedicated
      assert probes(counter) == 1
    end

    test "a live URL costs no extra probe" do
      counter = stub_version_fetch(fn conn -> Conn.resp(conn, 200, landing_page()) end)

      assert {:ok, %{app_plan: :paid}} = Apps.fetch_app("acme-desktop", max_retries: 0)
      assert probes(counter) == 1
    end

    test "strips the version segment from a dedicated instance URL" do
      counter = stub_version_fetch(fn conn -> Conn.resp(conn, 200, landing_page()) end)

      assert {:ok, attrs} =
               Apps.fetch_app("https://d123.bubble.is/site/acme/version-test", max_retries: 0)

      assert attrs.app_plan == :paid
      assert attrs.plan_basis == "live 200"
      assert probes(counter) == 1
    end

    test "reads template status from the :template_lookup option" do
      stub_two_stage_fetch()

      assert {:ok, attrs} =
               Apps.fetch_app("acme-desktop", template_lookup: &(&1 == "acme-desktop"))

      assert attrs.app_plan == :template
      assert attrs.plan_basis == "marketplace template"
    end

    test "falls back to the configured :template_lookup" do
      stub_two_stage_fetch()
      Application.put_env(:bubble_ex, :template_lookup, fn _bubble_id -> true end)
      on_exit(fn -> Application.delete_env(:bubble_ex, :template_lookup) end)

      assert {:ok, %{app_plan: :template}} = Apps.fetch_app("acme-desktop", max_retries: 0)
    end

    test "a rate-limited live response yields no plan and no app" do
      Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 429, "slow down") end)

      assert {:error, %BubbleEx.Error{kind: :http_error, context: %{status: 429}}} =
               Apps.fetch_app("acme-desktop", max_retries: 0)
    end

    test "a template on a dedicated instance is still dedicated hosting" do
      stub_live_redirect(302, "https://d123.bubble.is/version-live")

      assert {:ok, attrs} =
               Apps.fetch_app("acme-desktop",
                 max_retries: 0,
                 template_lookup: fn _bubble_id -> true end
               )

      assert attrs.app_plan == :template
      assert attrs.plan_basis == "marketplace template"
      assert attrs.dedicated_server == "d123"
      assert attrs.is_dedicated
    end

    defp landing_page do
      "<html><script src='/package/dynamic_js/1/dynamic.js'></script></html>"
    end

    # The live origin answers `live_response_fun`; the version URL always serves
    # the app's bundle, whatever the plan turns out to be. Live-origin probes are
    # counted so a test can prove how many a fetch made.
    defp stub_version_fetch(live_response_fun) do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn conn ->
        conn = Conn.put_resp_header(conn, "x-bubble-something", "1")
        path = conn.request_path || ""

        cond do
          String.contains?(path, "dynamic_js") ->
            Conn.resp(conn, 200, "const app = JSON.parse('#{@app_json}');\n")

          String.contains?(path, "/version-") ->
            Conn.resp(conn, 200, landing_page())

          true ->
            Agent.update(counter, &(&1 + 1))
            live_response_fun.(conn)
        end
      end)

      counter
    end

    defp probes(counter), do: Agent.get(counter, & &1)

    # The live URL redirects; whatever it points at serves the app.
    defp stub_live_redirect(status, location) do
      target = URI.parse(location).host

      Req.Test.stub(__MODULE__, fn conn ->
        conn = Conn.put_resp_header(conn, "x-bubble-something", "1")
        path = conn.request_path || ""

        cond do
          String.contains?(path, "dynamic_js") ->
            Conn.resp(conn, 200, "const app = JSON.parse('#{@app_json}');\n")

          conn.host == target ->
            Conn.resp(conn, 200, landing_page())

          true ->
            conn
            |> Conn.put_resp_header("location", location)
            |> Conn.send_resp(status, "")
        end
      end)
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

  # Live checks target a real, non-dedicated Bubble app that you choose. Set
  # BUBBLE_EX_LIVE_APP to its bubble ID; there is no default, and these tests
  # are skipped without it.
  @live_app System.get_env("BUBBLE_EX_LIVE_APP")
  @live_skip if(is_nil(@live_app), do: "set BUBBLE_EX_LIVE_APP to run", else: false)

  describe "dedicated?/2" do
    @describetag :integration

    @tag skip: @live_skip
    test "non-dedicated apps" do
      assert {:ok, %{is_dedicated: false}} = Apps.dedicated?(@live_app)
    end

    test "returns an error for a non-existent app" do
      assert {:error, %BubbleEx.Error{}} = Apps.dedicated?("thisappshouldnotexist")
    end
  end

  describe "fetch_app/2 (live)" do
    @describetag :integration

    @tag skip: @live_skip
    test "end to end fetches the app payload" do
      assert {:ok, attrs} =
               Apps.fetch_app(@live_app,
                 include_payload: true,
                 max_retries: 1,
                 retry_base_delay: 100
               )

      assert attrs.valid?
      assert attrs.bubble_id == @live_app
      assert attrs.payload["_id"] == @live_app
      assert is_integer(attrs.plugin_count)
    end

    test "returns invalid app attrs for a non-existent app" do
      assert {:ok, attrs} = BubbleEx.fetch_app("non-existent-app")
      assert attrs.valid? == false
    end
  end
end
