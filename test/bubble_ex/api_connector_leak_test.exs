defmodule BubbleEx.ApiConnectorLeakTest do
  # WTF-396: API Connector calls hold credentials in URLs (user info, paths,
  # query strings), header and parameter values (private or not) and bodies,
  # and real response data in their `types` registries (`sample_value`s from
  # "initialize call"). The Model reads only hosts, names, `private` flags
  # and type shapes, so none of those reach the Model, its diagnostics, the
  # Index or the Findings built on them. The fixture (both key forms) marks
  # every value that must not leak with `SECRET`.
  use ExUnit.Case, async: true

  alias BubbleEx.{Findings, Index, Model}
  alias BubbleEx.Index.Symbol

  @app "test/support/samples/api_connector_secrets.json" |> File.read!() |> Jason.decode!()

  # Values, URL parts and body text of the fixture that are not names or hosts.
  @forbidden [
    "SECRET",
    "Bearer",
    "application/json",
    "svc-user",
    "8443",
    "/v1/charges",
    "/api/",
    "/v3/send",
    "api_key=",
    "access_token",
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

  setup_all do
    {:ok, model} = Model.build(@app)
    {:ok, index} = Index.build(@app, model: model)
    {:ok, findings} = Findings.analyze(@app, index: index)

    %{
      model: model,
      index: index,
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
end
