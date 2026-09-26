defmodule BubbleEx.ApiConnectorLeakTest do
  # WTF-396: API Connector calls hold credentials in URLs (user info, paths,
  # query strings), header and parameter values (private or not) and bodies,
  # and real response data in their `types` registries (`sample_value`s from
  # "initialize call"). The Model reads only hosts, names, `private` flags,
  # type shapes and (WTF-374) a leak-safe request template: URL paths and
  # query strings, body structure, placeholders and only literals that
  # cannot hold a credential, every other literal redacted. So no value
  # reaches the Model, its diagnostics, the Index, the Findings built on
  # them, or the API clients generated from it (BubbleEx.Target.ApiClients,
  # printed by BubbleEx.Target.Phoenix with their tests). The fixture (both
  # key forms) marks every value that must not leak with `SECRET`.
  use ExUnit.Case, async: true

  alias BubbleEx.{Findings, Index, Model}
  alias BubbleEx.Index.Symbol
  alias BubbleEx.Target.{ApiClients, Phoenix}

  @app "test/support/samples/api_connector_secrets.json" |> File.read!() |> Jason.decode!()

  # Values, URL parts and body text of the fixture that are not names or
  # hosts. (A URL's port and query-string names are kept by the request
  # template, as its path segments are, one by one.)
  @forbidden [
    "SECRET",
    "Bearer",
    "application/json",
    "svc-user",
    "/v1/charges",
    "/api/",
    "/v3/send",
    "api_key=",
    "access_token=",
    "key=",
    "://",
    "?",
    "#",
    "[endpoint]",
    "[id]",
    "<amount>",
    "@",
    "424242",
    "sample_value",
    "raw_response"
  ]

  # What the generated clients and tests must not hold: every value.
  @forbidden_generated ["SECRET", "Bearer", "application/json", "svc-user", "424242"]

  setup_all do
    {:ok, model} = Model.build(@app)
    {:ok, index} = Index.build(@app, model: model)
    {:ok, findings} = Findings.analyze(@app, index: index)
    {:ok, clients} = ApiClients.map(model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, files} = Phoenix.render(project, name: "Leak", api_clients: clients)

    %{
      model: model,
      index: index,
      clients: clients,
      generated: Map.filter(files, fn {path, _} -> String.contains?(path, "api_clients") end),
      outputs: %{
        model: Model.to_json(model),
        index: Index.to_json(index),
        findings: findings |> Findings.to_map() |> Jason.encode!(),
        diagnostics:
          (model.diagnostics ++ index.diagnostics ++ findings.diagnostics)
          |> Enum.map(&BubbleEx.Diagnostic.to_map/1)
          |> Jason.encode!()
      }
    }
  end

  test "the fixture holds every forbidden string" do
    source = Jason.encode!(@app)
    for s <- @forbidden, do: assert(String.contains?(source, s), s)
  end

  test "no value, query string, user info or URL path reaches the output", %{outputs: outputs} do
    for {name, json} <- outputs, s <- @forbidden do
      refute String.contains?(json, s), "#{name} output contains #{inspect(s)}"
    end
  end

  test "names, hosts and private markers do", %{outputs: %{model: model, index: index}} do
    for json <- [model, index],
        s <- ~w(Create\ charge Send\ email api.payments.example api.mail.example
                  Authorization X-Api-Key signing_secret subject) do
      assert String.contains?(json, s), s
    end
  end

  test "the index surfaces them on the call symbols", %{index: index} do
    assert %Symbol{name: "Send email", attrs: attrs} = Index.symbol(index, "api_call:gLive/cSend")

    assert attrs == %{
             method: "post",
             publish_as: "action",
             host: "api.mail.example",
             headers: ["Accept", "X-Api-Key"],
             parameters: [
               %{id: "lh1", in: :header, name: "X-Api-Key", private: true},
               %{id: "lh2", in: :header, name: "Accept", private: false},
               %{id: "lb1", in: :body, name: "subject", private: false}
             ]
           }

    charge = Index.symbol(index, "api_call:gExport/cCharge")
    assert charge.name == "Create charge"
    assert charge.attrs.host == "api.payments.example"
    assert charge.attrs.headers == ["Authorization", "Content-Type"]

    assert Enum.filter(charge.attrs.parameters, & &1.private) |> Enum.map(& &1.id) ==
             ~w(h1 h4 u1 b2 p2)

    assert %{headers: ["X-Tenant"], parameters: [%{id: "shA", private: true} | _]} =
             Index.symbol(index, "api_group:gExport").attrs

    assert Index.symbol(index, "api_call:gExport/cWholeUrl").attrs == %{method: "get"}
  end

  test "response types keep their shape and still resolve", %{model: model} do
    call = model.connectors |> hd() |> Model.Connector.call("cTyped")

    assert call.registry == %{
             "api.apiconnector2.gExport.cTyped.Other" => nil,
             "api.apiconnector2.gExport.cTyped.Resp" => %{
               "caption" => "Response",
               "fields" => %{
                 "count" => %{"caption" => "Count", "path" => ["count"], "ret_btype" => "number"},
                 "email" => %{"caption" => "Email", "path" => ["email"], "ret_btype" => "text"},
                 "odd" => nil,
                 "token" => %{"caption" => "Token", "path" => ["token"], "ret_btype" => "text"}
               }
             }
           }

    resp = Model.external_type(model, "api.apiconnector2.gExport.cTyped.Resp")
    assert resp.resolution == :resolved
    assert Enum.map(resp.fields, & &1.id) == ~w(count email token odd)

    # cBadTypes (malformed `types`) and cStringCall (not an object).
    assert Enum.count(model.diagnostics, &(&1.code == :registry_malformed)) == 2

    gexport = hd(model.connectors)
    assert Model.Connector.call(gexport, "cBadTypes").types == :malformed
    assert Model.Connector.call(gexport, "cStringCall").raw == :string
  end

  test "the request template keeps structure, parameters and safe literals only", %{model: model} do
    charge = model.connectors |> hd() |> Model.Connector.call("cCharge")

    assert %{
             scheme: "https",
             port: 8443,
             path: [
               [%{kind: :literal, text: "v1"}],
               [%{kind: :literal, text: "charges"}],
               [%{kind: :redacted, index: 1}]
             ],
             query: [%{name: "api_key", value: [%{kind: :redacted, index: 2}]}],
             body: %{
               kind: :object,
               members: [
                 %{key: "amount", value: %{kind: :parameter, id: "b1"}},
                 %{key: "secret", value: %{kind: :text, parts: [%{kind: :redacted, index: 3}]}}
               ]
             }
           } = charge.request

    live = model.connectors |> List.last() |> Model.Connector.call("cSend")
    assert live.request.query == [%{name: "access_token", value: [%{kind: :redacted, index: 1}]}]

    # User info, a whole-URL parameter and a string call keep no URL at all.
    gexport = hd(model.connectors)

    for id <- ~w(cUserInfo cSlashPassword cHashUserInfo cQueryUserInfo cWholeUrl) do
      assert %{host: nil, path: [], query: [], unsupported: [:no_host]} =
               Model.Connector.call(gexport, id).request,
             id
    end

    assert gexport.shared_values == [
             %{parameter: "shB", parts: [%{kind: :redacted, index: 1}]}
           ]
  end

  test "no value reaches the generated clients, tests or their environment list",
       %{clients: clients, generated: generated} do
    assert map_size(generated) > 0
    spec = clients |> ApiClients.Spec.to_map() |> Jason.encode!()

    for {name, text} <- Map.put(generated, "spec", spec), s <- @forbidden_generated do
      refute String.contains?(text, s), "#{name} contains #{inspect(s)}"
    end

    for {name, text} <- generated do
      assert BubbleEx.Secrets.Native.Detectors.scan_value(text) == [], name
    end

    # The private values and redacted literals are environment variables.
    assert generated["lib/leak/api_clients.ex"] =~ "`MAIL_SEND_EMAIL_X_API_KEY`"
    assert generated["lib/leak/api_clients/mail.ex"] =~ ~s(env["MAIL_SEND_EMAIL_LITERAL_2"])
  end
end
