defmodule BubbleEx.HTTPHygieneTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Plug.Conn

  setup do
    BubbleEx.HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> BubbleEx.HTTP.delete_process_options() end)
    :ok
  end

  test "endpoint errors and labels never log nested bodies or query strings" do
    for status <- [200, 403] do
      Req.Test.stub(__MODULE__, fn conn ->
        Conn.resp(conn, status, "https://example.com/?code=synthetic-secret")
      end)

      log =
        capture_log([level: :debug], fn ->
          assert [] =
                   BubbleEx.Apps.Enricher.enrich_obj_endpoints(%{
                     "get" => ["records?code=synthetic-secret"],
                     "app_data" => %{"appname" => "public-app"}
                   })

          BubbleEx.Apps.Enricher.add_workflow_samples(
            %{public: %{get: [%{"name" => "workflow?code=synthetic-secret"}]}},
            "public-app"
          )

          assert {:error, _} =
                   BubbleEx.Apps.fetch_obj_endpoint("public-app", "records?code=synthetic-secret")

          assert {:error, _} =
                   BubbleEx.Apps.fetch_wf_endpoint("public-app", "workflow?code=synthetic-secret")
        end)

      assert log =~ "Failed to fetch obj endpoint"
      refute log =~ "synthetic-secret"
    end
  end

  test "upstream bundle queries survive requests but not retry or redirect logs" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Conn.put_resp_header("x-bubble-test", "true")
      |> Conn.resp(
        200,
        "<script src='/package/dynamic_js/d.js?code=synthetic-secret'></script>"
      )
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.query_string == "code=synthetic-secret"
      Conn.resp(conn, 503, "busy")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.query_string == "code=synthetic-secret"

      conn
      |> Conn.put_resp_header("location", "https://cdn.example.com/bundle?code=synthetic-secret")
      |> Conn.resp(302, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "cdn.example.com"
      assert conn.query_string == "code=synthetic-secret"

      conn
      |> Conn.put_resp_header("x-bubble-test", "true")
      |> Conn.resp(
        200,
        ~S|const app = JSON.parse('{"_id":"public-app","settings":{"client_safe":{"plugins":{}}}}');|
      )
    end)

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, %{bubble_id: "public-app"}} =
                 BubbleEx.Apps.fetch_app("public-app", retry_base_delay: 1)
      end)

    Req.Test.verify!(__MODULE__)
    assert log =~ "Retrying"
    refute log =~ "synthetic-secret"
  end
end
