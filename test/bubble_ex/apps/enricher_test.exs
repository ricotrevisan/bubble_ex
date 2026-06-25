defmodule BubbleEx.Apps.EnricherTest do
  use ExUnit.Case, async: false

  alias BubbleEx.Apps.Enricher
  alias BubbleEx.HTTP
  alias Plug.Conn

  describe "enrich_obj_endpoints/1" do
    setup do
      HTTP.put_process_options(plug: {Req.Test, __MODULE__})
      on_exit(fn -> HTTP.delete_process_options() end)
      :ok
    end

    test "reports the total and sample items from the obj endpoint" do
      # The Bubble obj endpoint wraps its payload in a "response" envelope, which
      # HTTP.fetch_json/2 unwraps — so count/remaining/results sit at the top level.
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "application/json")
        |> Conn.resp(
          200,
          Jason.encode!(%{
            "response" => %{
              "count" => 2,
              "remaining" => 3,
              "results" => [%{"_id" => "a"}, %{"_id" => "b"}]
            }
          })
        )
      end)

      response = %{"get" => ["user"], "app_data" => %{"appname" => "my-app"}}

      assert [enriched] = Enricher.enrich_obj_endpoints(response)
      assert enriched["endpoint"] == "user"
      assert enriched["total"] == 5
      assert enriched["sample_items"] == [%{"_id" => "a"}, %{"_id" => "b"}]
    end

    test "returns an empty list when there are no get endpoints" do
      assert Enricher.enrich_obj_endpoints(%{"get" => []}) == []
    end
  end

  describe "enrich_wf_endpoints/1" do
    test "categorizes endpoints into public get/post and auth, preserving order" do
      response = %{
        "post" => [
          %{"auth_unecessary" => true, "method" => "get", "name" => "g1"},
          %{"auth_unecessary" => true, "method" => "get", "name" => "g2"},
          %{"auth_unecessary" => true, "method" => "post", "name" => "p1"},
          %{"auth_unecessary" => false, "method" => "post", "name" => "a1"}
        ]
      }

      result = Enricher.enrich_wf_endpoints(response)

      assert Enum.map(result.public.get, & &1["name"]) == ["g1", "g2"]
      assert Enum.map(result.public.post, & &1["name"]) == ["p1"]
      assert result.public.count == 3
      assert Enum.map(result.auth, & &1["name"]) == ["a1"]
    end

    test "returns the empty structure when there is no post key" do
      assert Enricher.enrich_wf_endpoints(%{}) ==
               %{public: %{get: [], post: [], count: 0}, auth: []}
    end
  end

  describe "add_plugin_count/2" do
    test "adds the plugin count derived from the payload" do
      app_data = %{"settings" => %{"client_safe" => %{"plugins" => %{"a" => true, "b" => %{}}}}}
      assert %{plugin_count: 2} = Enricher.add_plugin_count(%{}, app_data)
    end
  end

  describe "maybe_add_db_diagram/3" do
    @app_data "test/support/samples/synthetic_app.json" |> File.read!() |> Jason.decode!()

    test "format: :postgres renders SQL into :schema" do
      attrs = Enricher.maybe_add_db_diagram(%{}, @app_data, format: :postgres)
      assert attrs[:schema] =~ ~s[CREATE TABLE "custom"."Onboarding Answer" (]
      refute Map.has_key?(attrs, :dbml)
    end

    test "legacy dbml: true still fills :dbml and :dbdiagram" do
      attrs = Enricher.maybe_add_db_diagram(%{}, @app_data, dbml: true)
      assert attrs[:dbml] =~ ~s(Project "synthapp" {)
      assert attrs[:dbdiagram] == attrs[:dbml]
      refute Map.has_key?(attrs, :schema)
    end

    test "format and legacy dbml can be requested together" do
      attrs = Enricher.maybe_add_db_diagram(%{}, @app_data, dbml: true, format: :postgres)
      assert attrs[:dbml] =~ "Project"
      assert attrs[:schema] =~ "CREATE TABLE"
    end

    test "an unknown format is ignored (no :schema, no crash)" do
      attrs = Enricher.maybe_add_db_diagram(%{}, @app_data, format: :mongodb)
      refute Map.has_key?(attrs, :schema)
    end

    test "no db option leaves attrs untouched" do
      assert Enricher.maybe_add_db_diagram(%{a: 1}, @app_data, []) == %{a: 1}
    end
  end
end
