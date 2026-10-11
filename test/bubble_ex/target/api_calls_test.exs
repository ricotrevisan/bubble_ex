defmodule BubbleEx.Target.ApiCallsTest do
  # WTF-533: API Connector calls in workflows, lowered to the generated Req
  # clients. Synthetic fixture test/support/target/phoenix/api_calls.json
  # (host api.example.test, never reached: every request here goes to a
  # Req.Test stub). Its behaviour in a generated app (a backend and a page
  # workflow, both privacy modes) is test/support/target/phoenix/
  # api_calls_behavior.exs, run by scripts/phoenix_compile_check.sh.
  use ExUnit.Case, async: false

  alias BubbleEx.{Index, Model}
  alias BubbleEx.Expression.{IR, Sites}
  alias BubbleEx.Target.{ApiClients, Phoenix}
  alias BubbleEx.Target.Ash.Workflows, as: AshWorkflows
  alias BubbleEx.Target.Elixir, as: ElixirTarget
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Workflows.{Backend, Frontend}

  @fixture "test/support/target/phoenix/api_calls.json"
  @item "api.apiconnector2.gEx.cItem.Item"
  @receipt "api.apiconnector2.gEx.cNote.Receipt"

  setup_all do
    app = @fixture |> File.read!() |> Jason.decode!()
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, spec} = ApiClients.map(model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, backend} = Backend.build(app, model, index)
    {:ok, lowered} = Frontend.build(app, model, index)

    {:ok, workflows} =
      AshWorkflows.map(backend, project, namespace: "Acme", api_clients: spec)

    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    {:ok, page_data} = BubbleEx.PageData.build(app, model)

    {:ok, pages} =
      FrontendWorkflows.map(lowered, project,
        namespace: "Acme",
        frontend: frontend,
        backend: workflows,
        page_data: page_data,
        api_clients: spec
      )

    {:ok, expressions} =
      BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
        runtime: "Acme.Bubble.Runtime",
        namespace: "Acme"
      )

    render_opts = [
      name: "Acme",
      workflows: workflows,
      frontend: frontend,
      expressions: expressions,
      frontend_workflows: pages
    ]

    {:ok, files} = Phoenix.render(project, [api_clients: spec] ++ render_opts)

    # The generated clients under a name of their own, for their runtime
    # tests below.
    {:ok, runtime} = Phoenix.render(project, name: "WtfApiCallsRt", api_clients: spec)

    unless Code.ensure_loaded?(WtfApiCallsRt.ApiClients) do
      for path <- ["api_clients.ex", "api_clients/decode.ex", "api_clients/example.ex"] do
        Code.compile_string(runtime["lib/wtf_api_calls_rt/" <> path], path)
      end
    end

    %{
      app: app,
      model: model,
      index: index,
      spec: spec,
      project: project,
      backend: backend,
      lowered: lowered,
      workflows: workflows,
      pages: pages,
      files: files,
      render_opts: render_opts
    }
  end

  defp step(workflows, id) do
    Enum.find_value(workflows, fn w -> Enum.find(w.steps, &(&1.bubble_id == id)) end)
  end

  describe "parsing" do
    test "a call's errors-in-response option and its own return type", %{model: model} do
      [group] = model.connectors
      assert Model.Connector.call(group, "cNote").wrap_errors
      refute Model.Connector.call(group, "cItem").wrap_errors

      # Return types no data field stores are resolved too: what a call's
      # result is.
      for id <- [@item, @receipt] do
        assert %Model.ExternalType{resolution: :resolved} = Model.external_type(model, id)
      end

      assert Enum.map(Model.external_type(model, @item).fields, & &1.id) ==
               ~w(_api_c2_id _api_c2_name _api_c2_price)
    end

    test "a call's own type that cannot be read leaves no diagnostic, only an untyped result" do
      app =
        @fixture
        |> File.read!()
        |> Jason.decode!()
        |> put_in(
          ["settings", "client_safe", "apiconnector2", "gEx", "calls", "cItem", "types"],
          "{"
        )

      {:ok, model} = Model.build(app)
      refute Enum.any?(model.diagnostics, &(&1.subject[:external_type] == @item))
      {:ok, spec} = ApiClients.map(model)
      assert hd(hd(spec.groups).calls).response.type == nil
    end

    test "secrets are environment variable names under BUBBLE_API_, never values", %{spec: spec} do
      assert Enum.map(spec.env, &{&1.name, &1.kind}) == [
               {"BUBBLE_API_EXAMPLE_API_KEY", :auth},
               {"BUBBLE_API_EXAMPLE_GET_ITEM_X_TENANT", :private},
               {"BUBBLE_API_EXAMPLE_POST_NOTE_SIGNING", :private}
             ]

      json = spec |> ApiClients.Spec.to_map() |> Jason.encode!()
      # The fixture's private values.
      for value <- ["tenant", ~s("s")], do: refute(json =~ ~s("#{value}"))
    end

    test "the Spec keeps each call's errors option and response shapes", %{spec: spec} do
      [group] = spec.groups
      note = Enum.find(group.calls, &(&1.id == "cNote"))
      assert note.wrap_errors
      assert note.response.type == @receipt

      assert %{id: "_api_c2_error.status_code", path: ["error", "status_code"], type: :number} =
               Enum.find(spec.shapes[@receipt], &(&1.id == "_api_c2_error.status_code"))
    end
  end

  describe "lowering" do
    test "a backend API call step: its non-private parameters, by Bubble ID", %{backend: backend} do
      step = step(backend.workflows, "aItem")
      assert step.op == :api_call
      assert step.residue == []
      assert %{group: "gEx", call: "cItem"} = step.args

      assert Enum.map(step.args.params, &{&1.parameter, &1.in, &1.key}) == [
               {"u1", :url, "item_id"},
               {"p1", :query, "lang"}
             ]

      # The private header the action sets is never a value of the step.
      assert step.args.ignored == 1
    end

    test "a page API call step", %{lowered: lowered} do
      step = step(lowered.workflows, "aPageNote")
      assert step.op == :api_call
      assert step.residue == []
      assert Enum.map(step.args.params, & &1.key) == ["text"]
      assert step.args.ignored == 1
    end

    test "an unknown call, a call that is not generated and an unknown member are residue", %{
      app: app
    } do
      actions = %{
        "0" => %{"id" => "aGone", "type" => "apiconnector2-gEx.cGone", "properties" => %{}},
        "1" => %{
          "id" => "aOdd",
          "type" => "apiconnector2-gEx.cItem",
          "properties" => %{"returns_raw" => true}
        },
        "2" => %{"id" => "aOauth", "type" => "apiconnector2-gOauth.cMe", "properties" => %{}}
      }

      app =
        app
        |> put_in(["api", "wFetch", "actions"], actions)
        |> put_in(["settings", "client_safe", "apiconnector2", "gOauth"], %{
          "human" => "Oauth",
          "auth" => "oauth2_password",
          "calls" => %{"cMe" => %{"method" => "get", "url" => "https://api.example.test/me"}}
        })

      {:ok, model} = Model.build(app)
      {:ok, index} = Index.build(app, model: model)
      {:ok, backend} = Backend.build(app, model, index)

      assert [
               %{subject: "action:aGone", reason: :api_connector_action, detail: gone},
               %{subject: "action:aOauth", reason: :api_connector_action, detail: oauth},
               %{subject: "action:aOdd", reason: :unsupported_option}
             ] = Backend.residue(backend)

      assert gone == %{call: "gEx.cGone", reasons: [:unresolved]}
      assert oauth == %{call: "gOauth.cMe", reasons: [:unsupported_auth]}
    end

    test "Result of step N is the call's API type", %{app: app, model: model} do
      raw = app["api"]["wFetch"]
      env = BubbleEx.Expression.Env.new(model, custom_events: %{})
      env = Sites.workflow_env(raw, ["api", "wFetch"], nil, env)
      assert env.steps["aItem"] == @item
    end
  end

  describe "binding and printing" do
    test "the backend step calls the client with its argument keys", %{workflows: workflows} do
      [action] = AshWorkflows.actions(workflows)
      [call, return] = action.steps
      assert call.residue == [] and return.residue == []

      assert %{module: "ApiClients.Example", function: "get_item", params: params} = call.args
      assert Enum.map(params, & &1.key) == ["item_id", "lang"]
    end

    test "without the clients the step is residue", %{backend: backend, project: project} do
      {:ok, workflows} = AshWorkflows.map(backend, project, namespace: "Acme")
      [action] = AshWorkflows.actions(workflows)

      assert [%{reason: :api_connector_action, detail: %{target: "phoenix"}}] =
               hd(action.steps).residue
    end

    test "page steps run on the server through the backend runtime", %{files: files} do
      page = files["lib/acme_web/live/index_live/workflows.ex"]
      assert page =~ "BubbleWorkflows.api(ctx, fn run ->"
      assert page =~ ~s|Runtime.api_call(run, "aPageItem", Acme.ApiClients.Example, :get_item|
      # A field of the call's result, from its typed map.
      assert page =~ ~s|Access.key("_api_c2_name")|

      body = files["lib/acme/workflows/unfiled/bodies.ex"]
      assert body =~ ~s|Runtime.api_call(ctx, "aItem", Acme.ApiClients.Example, :get_item|
    end

    test "secrets are configured by name only; no value of the export is in any file", %{
      files: files
    } do
      runtime = files["config/runtime.exs"]
      assert runtime =~ "config :acme, Acme.ApiClients,"
      assert runtime =~ "BUBBLE_API_EXAMPLE_POST_NOTE_SIGNING"

      assert files[".env.example"] =~ "BUBBLE_API_EXAMPLE_API_KEY=\n"
      assert files["lib/mix/tasks/bubble.api_env.ex"] =~ "defmodule Mix.Tasks.Bubble.ApiEnv"
      assert files["README.md"] =~ "## API Connector secrets"

      text = files |> Map.values() |> Enum.join("\n")
      # The private header the backend action sets, the private body
      # parameter the page sets.
      refute text =~ "must never be sent"
      refute text =~ "page-private-value"
    end

    test "rendering workflows that call the clients needs the clients", %{
      project: project,
      render_opts: opts
    } do
      assert {:error, %BubbleEx.Error{message: message}} = Phoenix.render(project, opts)
      assert message =~ "api_clients"
    end

    test "a field of an API value: its typed struct's attribute, else its decoded map's",
         %{project: project} do
      item = fn type ->
        IR.node(:input, [:step_result, %{"action" => "a1"}], type)
      end

      field = IR.node(:external_field, [item.(@item), @item, "_api_c2_name"], "text")
      assert {:ok, %{source: source}} = ElixirTarget.compile(field, project)
      assert source == ~s|get_in(step_result_a1, [Access.key("_api_c2_name")])|

      # A list of API values' field is not compiled.
      list = IR.node(:external_field, [item.("list." <> @item), @item, "_api_c2_name"], "text")
      assert {:ok, %{source: nil}} = ElixirTarget.compile(list, project)

      # A type a data field stores has a typed struct: its attribute.
      {:ok, model} =
        "test/support/target/phoenix/api_clients.json"
        |> File.read!()
        |> Jason.decode!()
        |> Model.build()

      {:ok, typed} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
      customer = "api.apiconnector2.gPay.cCustomer.Customer"
      field = IR.node(:external_field, [item.(customer), customer, "email"], "text")
      assert {:ok, %{source: source}} = ElixirTarget.compile(field, typed)
      assert source =~ ~r/get_in\(step_result_a1, \[Access\.key\(:[a-z_]+\)\]\)/
    end
  end

  describe "the generated clients' runtime (Req.Test stubs)" do
    # The generated runtime and client modules, compiled in setup_all
    # under their own name, against Req.Test: never the network.

    @client WtfApiCallsRt.ApiClients.Example
    @env %{
      "BUBBLE_API_EXAMPLE_API_KEY" => "k",
      "BUBBLE_API_EXAMPLE_GET_ITEM_X_TENANT" => "t",
      "BUBBLE_API_EXAMPLE_POST_NOTE_SIGNING" => "s"
    }

    setup do
      on_exit(fn ->
        Application.delete_env(:wtf_api_calls_rt, WtfApiCallsRt.ApiClients)
        Application.delete_env(:wtf_api_calls_rt, @client)
      end)

      Application.put_env(:wtf_api_calls_rt, @client, plug: {Req.Test, @client}, retry_delay: 1)
      Application.put_env(:wtf_api_calls_rt, WtfApiCallsRt.ApiClients, env: @env)
      :ok
    end

    defp stub(respond) do
      test = self()

      Req.Test.stub(@client, fn conn ->
        send(test, :request)
        respond.(conn)
      end)
    end

    defp count(n \\ 0) do
      receive do
        :request -> count(n + 1)
      after
        0 -> n
      end
    end

    test "success: the response decoded into the call's typed map" do
      stub(&Req.Test.json(&1, %{"id" => "42", "name" => "Widget", "price" => "9.5"}))

      assert {:ok, item} = apply(@client, :get_item, [%{item_id: "42"}])
      assert item == %{"_api_c2_id" => "42", "_api_c2_name" => "Widget", "_api_c2_price" => 9.5}
    end

    test "a missing secret is a typed error naming it, and nothing is sent" do
      stub(&Req.Test.json(&1, %{}))

      Application.put_env(:wtf_api_calls_rt, WtfApiCallsRt.ApiClients,
        env: Map.delete(@env, "BUBBLE_API_EXAMPLE_API_KEY")
      )

      assert {:error, %{__struct__: WtfApiCallsRt.ApiClients.MissingEnvError} = error} =
               apply(@client, :get_item, [%{}])

      assert error.names == ["BUBBLE_API_EXAMPLE_API_KEY"]
      assert Exception.message(error) =~ "BUBBLE_API_EXAMPLE_API_KEY"
      assert count() == 0

      # Never the system environment.
      System.put_env("BUBBLE_API_EXAMPLE_API_KEY", "system")
      on_exit(fn -> System.delete_env("BUBBLE_API_EXAMPLE_API_KEY") end)
      assert {:error, %{names: ["BUBBLE_API_EXAMPLE_API_KEY"]}} = apply(@client, :get_item, [%{}])
    end

    test "non-2xx: an error, unless the call includes errors in its response" do
      stub(&Plug.Conn.send_resp(&1, 503, "down"))
      assert {:error, {:status, 503, "down"}} = apply(@client, :get_item, [%{}])

      assert {:ok, receipt} = apply(@client, :post_note, [%{text: "x"}])

      assert receipt == %{
               "_api_c2_id" => nil,
               "_api_c2_returned_an_error" => true,
               "_api_c2_error.status_code" => 503,
               "_api_c2_error.status_message" => "Service Unavailable",
               "_api_c2_error.body" => "down"
             }

      stub(&Req.Test.json(&1, %{"id" => "n1"}))

      assert {:ok, %{"_api_c2_returned_an_error" => false, "_api_c2_id" => "n1"}} =
               apply(@client, :post_note, [%{text: "x"}])
    end

    test "timeouts: a GET is retried, a POST never" do
      stub(&Req.Test.transport_error(&1, :timeout))

      assert {:error, %Req.TransportError{reason: :timeout}} = apply(@client, :get_item, [%{}])
      assert count() == 3

      assert {:error, %Req.TransportError{reason: :timeout}} = apply(@client, :post_note, [%{}])
      assert count() == 1
    end
  end
end
