defmodule BubbleEx.Apps.PlanFetchTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Apps
  alias BubbleEx.HTTP
  alias Plug.Conn

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> HTTP.delete_process_options() end)
    :ok
  end

  describe "fetch_plan/2 (offline, Req.Test)" do
    test "a live 200 is paid, in one request" do
      stub(fn conn -> Conn.resp(conn, 200, "<html></html>") end)

      assert {:ok, attrs} = Apps.fetch_plan("acme", max_retries: 0)

      assert attrs == %{
               app_plan: :paid,
               plan_basis: "live 200",
               is_dedicated: false,
               dedicated_server: nil,
               base_url: nil
             }

      assert requests() == [{"acme.bubbleapps.io", "/"}]
    end

    test "live_not_supported plus a serving version-test is free, in two requests" do
      stub(fn conn ->
        if conn.request_path == "/version-test" do
          Conn.resp(conn, 200, "<html></html>")
        else
          live_not_supported(conn)
        end
      end)

      assert {:ok, attrs} = Apps.fetch_plan("acme", max_retries: 0)

      assert attrs.app_plan == :free
      assert attrs.plan_basis == "live 302 live_not_supported; version-test serves the app"
      refute attrs.is_dedicated

      assert requests() == [
               {"acme.bubbleapps.io", "/"},
               {"acme.bubbleapps.io", "/version-test"}
             ]
    end

    test "a live 400 names an invalid app and asks nothing more" do
      stub(fn conn -> Conn.resp(conn, 400, "invalid appname") end)

      assert {:ok, attrs} = Apps.fetch_plan("not-a-real-app", max_retries: 0)

      assert attrs.app_plan == nil
      assert attrs.plan_basis == "live 400 invalid appname"
      assert requests() == [{"not-a-real-app.bubbleapps.io", "/"}]
    end

    test "a name nobody claimed has no plan, and the basis names the missing evidence" do
      stub(fn conn ->
        if conn.request_path == "/version-test" do
          Conn.resp(conn, 400, "invalid appname")
        else
          live_not_supported(conn)
        end
      end)

      assert {:ok, attrs} = Apps.fetch_plan("unclaimed", max_retries: 0)

      assert attrs.app_plan == nil

      assert attrs.plan_basis ==
               "no evidence (live 302 live_not_supported; the app is not confirmed)"

      assert length(requests()) == 2
    end

    test "a bubble.is redirect is dedicated hosting, in one request" do
      stub(fn conn ->
        conn
        |> Conn.put_resp_header("location", "https://d121.bubble.is/site/acme")
        |> Conn.send_resp(302, "")
      end)

      assert {:ok, attrs} = Apps.fetch_plan("acme", max_retries: 0)

      assert attrs.app_plan == :dedicated
      assert attrs.plan_basis == "live 302 -> d121.bubble.is"
      assert attrs.is_dedicated
      assert attrs.dedicated_server == "d121"
      assert attrs.base_url == "https://d121.bubble.is/site/acme"
      assert requests() == [{"acme.bubbleapps.io", "/"}]
    end

    test "a version URL input is classified from the live origin" do
      stub(fn conn -> Conn.resp(conn, 200, "<html></html>") end)

      assert {:ok, attrs} =
               Apps.fetch_plan("https://acme.bubbleapps.io/version-test", max_retries: 0)

      assert attrs.app_plan == :paid
      assert attrs.plan_basis == "live 200"
      assert requests() == [{"acme.bubbleapps.io", "/"}]
    end

    test "a dedicated instance URL keeps its /site/<app> path" do
      stub(fn conn -> Conn.resp(conn, 200, "<html></html>") end)

      assert {:ok, %{app_plan: :paid, plan_basis: "live 200"}} =
               Apps.fetch_plan("https://d121.bubble.is/site/acme/version-test", max_retries: 0)

      assert requests() == [{"d121.bubble.is", "/site/acme"}]
    end

    test "a rate-limited app leaves the plan unknown, never paid" do
      stub(fn conn -> Conn.resp(conn, 429, "slow down") end)

      assert {:ok, attrs} = Apps.fetch_plan("acme", max_retries: 0)

      assert attrs.app_plan == nil
      assert attrs.plan_basis == "no evidence (live 429)"
      assert requests() == [{"acme.bubbleapps.io", "/"}]
    end

    test "reads template status from the :template_lookup option" do
      stub(fn conn -> Conn.resp(conn, 200, "<html></html>") end)

      assert {:ok, attrs} = Apps.fetch_plan("acme", template_lookup: &(&1 == "acme"))

      assert attrs.app_plan == :template
      assert attrs.plan_basis == "marketplace template"
      assert attrs.is_dedicated == false
    end

    test "falls back to the configured :template_lookup" do
      stub(fn conn -> Conn.resp(conn, 200, "<html></html>") end)
      Application.put_env(:bubble_ex, :template_lookup, fn _bubble_id -> true end)
      on_exit(fn -> Application.delete_env(:bubble_ex, :template_lookup) end)

      assert {:ok, %{app_plan: :template}} = Apps.fetch_plan("acme", max_retries: 0)
    end

    test "a lookup that says false leaves the plan to the response" do
      stub(fn conn -> Conn.resp(conn, 200, "<html></html>") end)

      assert {:ok, %{app_plan: :paid, plan_basis: "live 200"}} =
               Apps.fetch_plan("acme", max_retries: 0, template_lookup: fn _ -> false end)
    end

    test "a template claim cannot make a nonexistent app a plan" do
      stub(fn conn ->
        if conn.request_path == "/version-test" do
          Conn.resp(conn, 404, "not found")
        else
          live_not_supported(conn)
        end
      end)

      assert {:ok, attrs} =
               Apps.fetch_plan("acme", max_retries: 0, template_lookup: fn _ -> true end)

      assert attrs.app_plan == nil

      assert attrs.plan_basis ==
               "no evidence (live 302 live_not_supported; the app is not confirmed)"
    end

    test "a rate-limited existence check leaves the plan unknown" do
      stub(fn conn ->
        if conn.request_path == "/version-test" do
          Conn.resp(conn, 429, "slow down")
        else
          live_not_supported(conn)
        end
      end)

      assert {:ok, attrs} = Apps.fetch_plan("acme", max_retries: 0)

      assert attrs.app_plan == nil

      assert attrs.plan_basis ==
               "no evidence (live 302 live_not_supported; the app is not confirmed)"

      assert length(requests()) == 2
    end

    test "a transport failure on the live probe is an error, not an observation" do
      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %BubbleEx.Error{kind: :request_failed}} =
               Apps.fetch_plan("acme", max_retries: 0)
    end

    test "rejects an input that is neither a bubble id nor a URL" do
      Req.Test.stub(__MODULE__, fn _conn -> flunk("no request expected") end)

      assert {:error, %BubbleEx.Error{kind: :invalid_input}} = Apps.fetch_plan("Acme_App")
    end
  end

  defp live_not_supported(conn) do
    conn
    |> Conn.put_resp_header("location", "https://bubble.io/live_not_supported?appname=acme")
    |> Conn.send_resp(302, "")
  end

  defp stub(fun) do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, {:request, conn.host, conn.request_path || "/"})
      fun.(conn)
    end)
  end

  defp requests, do: collect_requests([])

  defp collect_requests(acc) do
    receive do
      {:request, host, path} -> collect_requests([{host, path} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
