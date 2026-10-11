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

    test "a public parameter in the host is residue; a private one comes from the environment",
         %{app: app} do
      hosted = fn private? ->
        app
        |> put_in(
          ["settings", "client_safe", "apiconnector2", "gEx", "calls", "cItem", "url"],
          "https://[region].api.example.test/v1/items/[item_id]"
        )
        |> put_in(
          [
            "settings",
            "client_safe",
            "apiconnector2",
            "gEx",
            "calls",
            "cItem",
            "url_params",
            "u2"
          ],
          %{"key" => "region", "value" => "eu", "private" => private?}
        )
      end

      host = fn private? -> private? |> hosted.() |> Model.build() |> elem(1) end

      # Public: a step or a page could send the API key to any host.
      model = host.(false)
      [group] = model.connectors
      item = Model.Connector.call(group, "cItem")
      assert :host_parameter in Model.ConnectorSupport.unsupported(group, item)
      {:ok, spec} = ApiClients.map(model)

      assert %{call: "cItem", reasons: [:host_parameter]} =
               Enum.find(spec.residue, &(&1.call == "cItem"))

      {:ok, index} = Index.build(hosted.(false), model: model)
      {:ok, backend} = Backend.build(hosted.(false), model, index)

      assert %{residue: [%{reason: :api_connector_action, detail: %{reasons: [:host_parameter]}}]} =
               step(backend.workflows, "aItem")

      # A whole-host placeholder too.
      whole =
        app
        |> put_in(
          ["settings", "client_safe", "apiconnector2", "gEx", "calls", "cItem", "url"],
          "https://[item_id]/v1"
        )
        |> Model.build()
        |> then(fn {:ok, model} -> model end)

      [g] = whole.connectors

      assert :host_parameter in Model.ConnectorSupport.unsupported(
               g,
               Model.Connector.call(g, "cItem")
             )

      # Private: the owner's environment.
      model = host.(true)
      [group] = model.connectors
      assert Model.ConnectorSupport.unsupported(group, Model.Connector.call(group, "cItem")) == []
      {:ok, spec} = ApiClients.map(model)
      item = spec.groups |> hd() |> Map.fetch!(:calls) |> Enum.find(&(&1.id == "cItem"))

      assert [{:env, "BUBBLE_API_EXAMPLE_GET_ITEM_REGION"}, {:literal, ".api.example.test"}] =
               item.base.host
    end

    test "a port placeholder is residue; a public one chooses where the call goes (WTF-534)",
         %{app: app} do
      ported = fn url, param ->
        app
        |> put_in(
          ["settings", "client_safe", "apiconnector2", "gEx", "calls", "cItem", "url"],
          url
        )
        |> put_in(
          [
            "settings",
            "client_safe",
            "apiconnector2",
            "gEx",
            "calls",
            "cItem",
            "url_params",
            "u2"
          ],
          param
        )
      end

      reasons = fn app ->
        {:ok, model} = Model.build(app)
        [group] = model.connectors
        item = Model.Connector.call(group, "cItem")
        {:ok, spec} = ApiClients.map(model)
        refute Enum.any?(hd(spec.groups).calls, &(&1.id == "cItem"))
        {item.request, Model.ConnectorSupport.unsupported(group, item)}
      end

      url = "https://api.example.test:[port]/v1/items/[item_id]"

      # Public: a step or a page could send the call (and its key) to any
      # port, as with a host parameter.
      {request, why} =
        reasons.(ported.(url, %{"key" => "port", "value" => "8443", "private" => false}))

      assert request.port == %{kind: :parameter, id: "u2"}
      assert request.host == [%{kind: :literal, text: "api.example.test"}]
      assert :dynamic_port in why
      assert :host_parameter in why

      public = ported.(url, %{"key" => "port", "value" => "8443", "private" => false})
      {:ok, model} = Model.build(public)
      {:ok, index} = Index.build(public, model: model)
      {:ok, backend} = Backend.build(public, model, index)

      assert %{residue: [%{reason: :api_connector_action, detail: %{reasons: reasons_of_step}}]} =
               step(backend.workflows, "aItem")

      assert :host_parameter in reasons_of_step

      # Private: its value is the owner's, but a port from the environment
      # is not generated: residue all the same.
      {request, why} =
        reasons.(ported.(url, %{"key" => "port", "value" => "8443", "private" => true}))

      assert request.port == %{kind: :parameter, id: "u2"}
      assert why == [:dynamic_port]

      # A placeholder naming nothing, and a port that is not a number.
      {_request, why} =
        reasons.(
          ported.("https://api.example.test:[nothing]/v1", %{"key" => "x", "private" => false})
        )

      assert :dynamic_port in why

      {request, why} =
        reasons.(ported.("https://api.example.test:80a/v1", %{"key" => "x", "private" => false}))

      assert request.port == nil
      assert why == [:no_host]

      # A literal port is still structure.
      {:ok, model} =
        Model.build(
          ported.("https://api.example.test:8443/v1/items/[item_id]", %{
            "key" => "x",
            "private" => false
          })
        )

      [group] = model.connectors
      assert Model.Connector.call(group, "cItem").request.port == 8443
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

      Application.put_env(:wtf_api_calls_rt, @client, plug: {Req.Test, @client})
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

    test "timeouts: an action call is never retried, a GET included" do
      stub(&Req.Test.transport_error(&1, :timeout))

      assert {:error, %Req.TransportError{reason: :timeout}} = apply(@client, :get_item, [%{}])
      assert count() == 1

      assert {:error, %Req.TransportError{reason: :timeout}} = apply(@client, :post_note, [%{}])
      assert count() == 1
    end

    test "a host the owner did not configure is refused when it is private" do
      rt = WtfApiCallsRt.ApiClients
      # No Req.Test plug here: the address check applies, and refuses
      # before anything connects.
      Application.put_env(:wtf_api_calls_rt, @client, retry: false)

      request = fn base ->
        %{
          method: :get,
          base: base,
          path: "/latest",
          query: [],
          headers: [{"x-api-key", "k"}],
          body: nil,
          auth: nil,
          response: :json
        }
      end

      for base <- [
            "http://127.0.0.1:9",
            "http://169.254.169.254",
            "http://[::1]:9",
            "http://10.1.2.3"
          ] do
        assert {:error, {:blocked_address, :private}} =
                 apply(rt, :request, [@client, [], request.(base)]),
               base
      end

      # A host that does not resolve is refused too (this fixture's).
      assert {:error, {:blocked_address, _}} = apply(@client, :get_item, [%{}])

      # The owner's own base URL is trusted (localhost; port 9 refuses).
      assert {:error, %Req.TransportError{}} =
               apply(rt, :request, [
                 @client,
                 [base_url: "http://127.0.0.1:9"],
                 request.("https://x.example.test")
               ])
    end

    test "a text outside quotes in a JSON body is only ever a scalar" do
      rt = WtfApiCallsRt.ApiClients
      assert apply(rt, :json_arg, ["12"]) == 12
      assert apply(rt, :json_arg, [~s({"$ne":null})]) == ~s({"$ne":null})
      assert apply(rt, :json_arg, ["[1]"]) == "[1]"
      assert apply(rt, :segment, [".."]) == "%2E%2E"
    end

    # --- WTF-534: hardening -------------------------------------------------------------

    defp shape(base, response \\ :json) do
      %{
        method: :get,
        base: base,
        path: "/latest",
        query: [],
        headers: [{"x-api-key", "k"}],
        body: nil,
        auth: nil,
        response: response
      }
    end

    test "reserved, documentation and translated addresses are refused" do
      rt = WtfApiCallsRt.ApiClients
      blocked? = &apply(rt, :blocked?, [&1])
      ip = fn text -> text |> String.to_charlist() |> :inet.parse_address() |> elem(1) end

      for text <- ~w(
            0.0.0.0 10.1.2.3 100.64.0.1 127.0.0.1 169.254.169.254 172.16.0.1 192.168.1.1
            192.0.0.8 192.0.2.10 198.51.100.7 203.0.113.200 192.88.99.1 198.18.0.1 198.19.255.255
            224.0.0.1 240.0.0.1 255.255.255.255
            :: ::1 ::127.0.0.1 ::8.8.8.8
            ::ffff:0:0 ::ffff:127.0.0.1 ::ffff:8.8.8.8 ::ffff:0:8.8.8.8 ::ffff:0:127.0.0.1
            64:ff9b::127.0.0.1 64:ff9b::10.0.0.1 64:ff9b:1::8.8.8.8 64:ff9b:1:ffff::1
            2002:7f00:1:: 2002:a00:1::1 2002:c000:201:: 2002:a9fe:a9fe::
            fec0::1 feff::1 fe80::1 fc00::1 fd00:ec2::254 ff02::1
            100::1 2001::1 2001:0:4136:e378:8000:63bf:3fff:fdd2 2001:2::1 2001:db8::1 3fff::1
          ) do
        assert blocked?.(ip.(text)), text
      end

      # Public addresses (from the ranges around the blocked ones; nothing
      # here connects).
      for text <- ~w(
            1.1.1.1 8.8.8.8 100.63.255.255 100.128.0.1 172.15.255.255 172.32.0.1 192.0.1.1
            192.0.3.1 192.88.98.1 198.17.255.255 198.20.0.1 198.51.99.1 198.51.101.1
            203.0.112.1 203.0.114.1 223.255.255.255
            64:ff9b::8.8.8.8 2002:808:808::1 2001:4860::8888 2001:3::1 2001:db9::1
            2606:4700::1111 3ff0::1 3fff:1000::1 4000::1 fbff::1
          ) do
        refute blocked?.(ip.(text)), text
      end

      # Through the address check, before anything connects.
      guard = %{trusted: nil, allow?: false}

      for url <- ~w(http://192.0.2.1/ https://[2002:a00:1::1]/ https://[::ffff:0:a00:1]/
                    http://[64:ff9b:1::1]/ http://[fec0::1]/ http://203.0.113.9:8443/) do
        assert {:error, {:blocked_address, :private}} = apply(rt, :check_address, [url, guard]),
               url
      end

      # An IP address has nothing to pin.
      assert {:ok, nil} = apply(rt, :check_address, ["https://8.8.8.8/x", guard])
    end

    test "plug: nil is no plug: the address is checked, and nothing connects to a private one" do
      rt = WtfApiCallsRt.ApiClients
      # The group's configuration has a Req.Test plug: the guard is off.
      stub(&Req.Test.json(&1, %{"ok" => true}))

      assert {:ok, %{"ok" => true}} =
               apply(rt, :request, [@client, [], shape("http://127.0.0.1:9")])

      # `plug: nil` connects: the guard is on, and refuses before connecting.
      for base <- ["http://127.0.0.1:9", "http://[::1]:9", "http://10.1.2.3"] do
        assert {:error, {:blocked_address, :private}} =
                 apply(rt, :request, [@client, [plug: nil, retry: false], shape(base)]),
               base
      end

      assert count() == 1

      # The owner's opt-in still allows it (port 9 refuses).
      assert {:error, %Req.TransportError{}} =
               apply(rt, :request, [
                 @client,
                 [plug: nil, retry: false, allow_private_addresses: true],
                 shape("http://127.0.0.1:9")
               ])
    end

    test "more than one content encoding, in one header or several, is refused" do
      rt = WtfApiCallsRt.ApiClients
      json = ~s({"ok":true})

      respond = fn encodings, body ->
        Req.Test.stub(@client, fn conn ->
          conn
          |> Plug.Conn.prepend_resp_headers(Enum.map(encodings, &{"content-encoding", &1}))
          |> Plug.Conn.send_resp(200, body)
        end)

        apply(rt, :request, [@client, [], shape("https://api.example.test")])
      end

      for {encodings, body} <- [
            {["gzip", "identity"], :zlib.gzip(json)},
            {["identity", "gzip"], :zlib.gzip(json)},
            {["gzip", "gzip"], :zlib.gzip(:zlib.gzip(json))},
            {["gzip, gzip"], :zlib.gzip(:zlib.gzip(json))},
            {["deflate", "identity"], :zlib.compress(json)},
            {["identity", "identity"], json},
            {["br"], json}
          ] do
        assert {:error, {:decode, :content_encoding}} = respond.(encodings, body),
               inspect(encodings)
      end

      # One encoding, in any case and spacing, is inflated.
      assert {:ok, %{"ok" => true}} = respond.([" GZip "], :zlib.gzip(json))
      assert {:ok, %{"ok" => true}} = respond.(["deflate"], :zlib.compress(json))
      assert {:ok, %{"ok" => true}} = respond.(["identity"], json)
      assert {:ok, %{"ok" => true}} = respond.([], json)
    end

    test "a truncated gzip or deflate body is a decode error, never the text so far" do
      rt = WtfApiCallsRt.ApiClients
      text = String.duplicate("the quick brown fox ", 2_000)
      gzip = :zlib.gzip(text)
      deflate = :zlib.compress(text)

      assert {:ok, ^text} = apply(rt, :inflate, [gzip, 31, 1_000_000])
      assert {:ok, ^text} = apply(rt, :inflate, [deflate, 15, 1_000_000])

      for {data, window} <- [
            {binary_part(gzip, 0, byte_size(gzip) - 4), 31},
            {binary_part(gzip, 0, div(byte_size(gzip), 2)), 31},
            {binary_part(gzip, 0, 12), 31},
            {binary_part(deflate, 0, byte_size(deflate) - 2), 15},
            {"", 31}
          ] do
        assert {:error, {:decode, :content_encoding}} =
                 apply(rt, :inflate, [data, window, 1_000_000]),
               "#{byte_size(data)} bytes"
      end

      Req.Test.stub(@client, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.send_resp(200, binary_part(gzip, 0, byte_size(gzip) - 8))
      end)

      assert {:error, {:decode, :content_encoding}} =
               apply(rt, :request, [@client, [], shape("https://api.example.test", :text)])
    end

    # A local server for one request on 127.0.0.1 (TLS with `tls`, the
    # server's `[cert:, key:]`): it tells the test the request's head and
    # the TLS server name, and answers `response`.
    defp serve(response, tls \\ nil) do
      test = self()
      spawn(fn -> serve_one(test, response, tls) end)
      assert_receive {:port, port}, 1_000
      port
    end

    defp serve_one(test, response, tls) do
      listen_opts = [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]

      {:ok, listen} =
        if tls,
          do: :ssl.listen(0, listen_opts ++ [certs_keys: [Map.new(tls)]]),
          else: :gen_tcp.listen(0, listen_opts)

      {:ok, {_, port}} = if tls, do: :ssl.sockname(listen), else: :inet.sockname(listen)
      send(test, {:port, port})

      with {:ok, socket, sni} <- accept(listen, tls),
           {:ok, head} <- head(socket, tls, "") do
        send(test, {:served, head, sni})
        reply(socket, tls, response)
      else
        error -> send(test, {:refused, error})
      end
    end

    defp reply(socket, nil, response) do
      :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
    end

    defp reply(socket, _tls, response) do
      :ssl.send(socket, response)
      :ssl.close(socket)
    end

    defp accept(listen, nil) do
      with {:ok, socket} <- :gen_tcp.accept(listen, 5_000), do: {:ok, socket, nil}
    end

    defp accept(listen, _tls) do
      with {:ok, socket} <- :ssl.transport_accept(listen, 5_000),
           {:ok, socket} <- :ssl.handshake(socket, 5_000),
           {:ok, info} <- :ssl.connection_information(socket, [:sni_hostname]),
           do: {:ok, socket, info[:sni_hostname]}
    end

    defp head(socket, tls, acc) do
      if String.contains?(acc, "\r\n\r\n") do
        {:ok, acc}
      else
        recv = if tls, do: :ssl.recv(socket, 0, 5_000), else: :gen_tcp.recv(socket, 0, 5_000)
        with {:ok, data} <- recv, do: head(socket, tls, acc <> data)
      end
    end

    defp ok(body),
      do:
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: " <>
          "#{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body

    defp tls_chain(name) do
      san = {:Extension, {2, 5, 29, 17}, false, [dNSName: String.to_charlist(name)]}
      key = {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}
      conf = [key: key, digest: :sha256]
      data = :public_key.pkix_test_data(%{root: conf, peer: [extensions: [san]] ++ conf})
      {[cert: data[:cert], key: data[:key]], data[:cacerts]}
    end

    # The failed handshake logs TLS alerts.
    @tag capture_log: true
    test "the request connects to the address checked, the host in Host, SNI and verification" do
      rt = WtfApiCallsRt.ApiClients
      {:ok, _} = Application.ensure_all_started(:ssl)

      # api.example.test never resolves: only the pinned address connects.
      port = serve(ok(~s({"ok":true})))

      options =
        apply(rt, :pin, [
          [
            url: "http://api.example.test:#{port}/v1/x?a=1",
            headers: [{"x-api-key", "k"}],
            connect_options: [timeout: 2_000],
            retry: false
          ],
          {127, 0, 0, 1}
        ])

      assert options[:url] == "http://127.0.0.1:#{port}/v1/x?a=1"
      assert options[:connect_options][:hostname] == "api.example.test"
      assert options[:connect_options][:timeout] == 2_000
      assert {:ok, %Req.Response{status: 200}} = Req.request(options)
      assert_receive {:served, head, nil}, 2_000
      assert head =~ ~r{\AGET /v1/x\?a=1 HTTP/1.1\r\n}
      assert head =~ "\r\nhost: api.example.test:#{port}\r\n"
      refute head =~ "127.0.0.1"

      # A Host header the call sets itself is kept; the default port is not
      # repeated; an IPv6 address goes in brackets, with Req's :inet6.
      assert [{"Host", "own"}] =
               apply(rt, :pin, [
                 [url: "https://a.example.test/", headers: [{"Host", "own"}]],
                 {8, 8, 8, 8}
               ])[
                 :headers
               ]

      assert [{"host", "a.example.test"}] =
               apply(rt, :pin, [[url: "https://a.example.test/"], {8, 8, 8, 8}])[:headers]

      v6 =
        apply(rt, :pin, [
          [url: "https://a.example.test:8443/x"],
          {0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}
        ])

      assert v6[:url] == "https://[2606:4700::1111]:8443/x"
      assert v6[:inet6] == true
      assert v6[:headers] == [{"host", "a.example.test:8443"}]

      # Nothing to pin: unchanged.
      assert apply(rt, :pin, [[url: "https://a.example.test/"], nil]) == [
               url: "https://a.example.test/"
             ]

      # TLS: the server name and the certificate's hostname are the host's.
      {server, cacerts} = tls_chain("api.example.test")
      port = serve(ok(~s({"ok":true})), server)

      tls = fn port, cacerts ->
        apply(rt, :pin, [
          [
            url: "https://api.example.test:#{port}/v1/x",
            connect_options: [timeout: 2_000, transport_opts: [cacerts: cacerts]],
            retry: false
          ],
          {127, 0, 0, 1}
        ])
      end

      assert {:ok, %Req.Response{status: 200}} = Req.request(tls.(port, cacerts))
      assert_receive {:served, head, ~c"api.example.test"}, 2_000
      assert head =~ "\r\nhost: api.example.test:#{port}\r\n"

      # A certificate for another host fails verification: pinning never
      # turns it off.
      {server, cacerts} = tls_chain("other.example.test")
      port = serve(ok("{}"), server)
      assert {:error, %Req.TransportError{reason: reason}} = Req.request(tls.(port, cacerts))
      assert inspect(reason) =~ "hostname"
      assert_receive {:refused, _}, 2_000
    end
  end
end
