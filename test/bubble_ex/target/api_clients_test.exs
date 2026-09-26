defmodule BubbleEx.Target.ApiClientsTest do
  # WTF-374: API Connector groups and calls as Req client modules, printed
  # by BubbleEx.Target.Phoenix with Req.Test request-shape tests. The
  # generated code is compiled and its tests run by
  # scripts/phoenix_compile_check.sh (fixture phoenix_api_clients).
  use ExUnit.Case, async: true

  alias BubbleEx.Model
  alias BubbleEx.Target.{ApiClients, Phoenix}
  alias BubbleEx.Target.ApiClients.{Call, Spec}

  @fixture "test/support/target/phoenix/api_clients.json"

  setup_all do
    {:ok, model} = @fixture |> File.read!() |> Jason.decode!() |> Model.build()
    {:ok, spec} = ApiClients.map(model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, files} = Phoenix.render(project, name: "Acme", api_clients: spec)
    %{model: model, spec: spec, project: project, files: files}
  end

  defp call(spec, group, call) do
    spec.groups
    |> Enum.find(&(&1.id == group))
    |> Map.fetch!(:calls)
    |> Enum.find(&(&1.id == call))
  end

  test "one module per group, one function per call; the rest is residue", %{spec: spec} do
    assert Enum.map(spec.groups, &{&1.module, Enum.map(&1.calls, fn c -> c.function end)}) == [
             {"Forms", ["subscribe"]},
             {"Mail", ["send_email"]},
             {"Payments", ["create_charge", "get_customer", "list_refunds"]},
             {"Tenants", ["tenant_ping", "remove_item", "send_call"]}
           ]

    assert Enum.map(spec.residue, &{&1.call, &1.reasons}) == [
             {"cOauth", [:unsupported_auth]},
             {"cDynamic", [:no_host]},
             {"cRaw", [:raw_body]}
           ]

    assert Spec.summary(spec) == %{
             "groups" => 4,
             "calls" => 11,
             "generated" => 8,
             "generated_env_configured" => 5,
             "residue" => 3,
             "residue_reasons" => %{"no_host" => 1, "raw_body" => 1, "unsupported_auth" => 1},
             "env" => %{"auth" => 4, "literal" => 10, "private" => 4, "private_line" => 2},
             "typed_responses" => 2
           }
  end

  test "maps a call's URL, headers, body and response", %{spec: spec} do
    assert %Call{
             method: :post,
             base: %{scheme: "https", host: [literal: "api.payments.example"], port: 8443},
             path: [[literal: "v1"], [literal: "charges"]],
             query: [%{name: "source", value: [env: "PAYMENTS_CREATE_CHARGE_LITERAL_1"]}],
             headers: [
               %{name: "X-Api-Key", value: [env: "PAYMENTS_API_KEY"]},
               %{name: "X-Tenant", value: [env: "PAYMENTS_SHARED_1"]},
               %{name: "Content-Type", value: [arg: "content_type"]},
               %{name: "Idempotency-Key", value: [env: "PAYMENTS_CREATE_CHARGE_IDEMPOTENCY_KEY"]}
             ],
             json:
               {:object,
                [
                  {"amount", {:arg, "amount"}},
                  {"currency", {:text, [arg: "currency"]}},
                  {"description",
                   {:text,
                    [
                      env: "PAYMENTS_CREATE_CHARGE_LITERAL_2",
                      arg: "order",
                      env: "PAYMENTS_CREATE_CHARGE_LITERAL_3",
                      arg: "customer"
                    ]}},
                  {"metadata",
                   {:object,
                    [
                      {"channel", {:text, [env: "PAYMENTS_CREATE_CHARGE_LITERAL_4"]}},
                      {"tags",
                       {:array,
                        [{:text, [env: "PAYMENTS_CREATE_CHARGE_LITERAL_5"]}, {:arg, "tag"}]}}
                    ]}},
                  {"capture", {:json, true}},
                  {"retries", {:env_json, "PAYMENTS_CREATE_CHARGE_LITERAL_6"}},
                  {"signature", {:text, [env: "PAYMENTS_CREATE_CHARGE_SIGNING"]}}
                ]},
             response: %{kind: :json, list: false, type: nil}
           } = call(spec, "gPay", "cCharge")

    customer = call(spec, "gPay", "cCustomer")
    assert customer.path == [[literal: "v1"], [literal: "customers"], [arg: "customer_id"]]
    assert customer.query == [%{name: "expand", value: [arg: "expand"]}]
    assert customer.response.type == "api.apiconnector2.gPay.cCustomer.Customer"
    assert call(spec, "gPay", "cRefunds").response.list

    assert Map.keys(spec.types) == [
             "api.apiconnector2.gPay.cCustomer.Address",
             "api.apiconnector2.gPay.cCustomer.Customer",
             "api.apiconnector2.gPay.cRefunds.Refund"
           ]

    assert spec.types["api.apiconnector2.gPay.cCustomer.Customer"]["plan_name"] == [
             "plan",
             "name"
           ]
  end

  test "secrets, stripped names and suspicious literals become environment variables",
       %{spec: spec} do
    send_email = call(spec, "gMail", "cSend")
    assert send_email.auth == {:basic, "MAIL_USERNAME", "MAIL_PASSWORD"}
    assert send_email.headers == [%{name: nil, value: [env_line: "MAIL_SEND_EMAIL_HEADER_LH1"]}]

    assert {:object,
            [
              {"to", {:text, [arg: "to"]}},
              {"token", {:text, [env: "MAIL_SEND_EMAIL_API_TOKEN"]}},
              {"key", {:text, [env: "MAIL_SEND_EMAIL_LITERAL_1"]}},
              {"html", {:text, [env: "MAIL_SEND_EMAIL_LITERAL_2"]}}
            ]} = send_email.json

    subscribe = call(spec, "gForms", "cSubscribe")
    assert subscribe.response.kind == :text

    assert subscribe.query == [%{name: "key", value: [env: "FORMS_API_KEY"]}]

    assert subscribe.form == [
             %{name: "email", value: [arg: "email"]},
             %{name: "list_id", value: [env: "FORMS_SUBSCRIBE_LIST_ID"]},
             %{name: nil, value: [env_line: "FORMS_SUBSCRIBE_PARAM_F3"]}
           ]

    assert Enum.map(spec.env, &{&1.name, &1.kind}) == [
             {"FORMS_API_KEY", :auth},
             {"FORMS_SUBSCRIBE_LIST_ID", :private},
             {"FORMS_SUBSCRIBE_LITERAL_1", :literal},
             {"FORMS_SUBSCRIBE_PARAM_F3", :private_line},
             {"MAIL_PASSWORD", :auth},
             {"MAIL_SEND_EMAIL_API_TOKEN", :private},
             {"MAIL_SEND_EMAIL_HEADER_LH1", :private_line},
             {"MAIL_SEND_EMAIL_LITERAL_1", :literal},
             {"MAIL_SEND_EMAIL_LITERAL_2", :literal},
             {"MAIL_USERNAME", :auth},
             {"PAYMENTS_API_KEY", :auth},
             {"PAYMENTS_CREATE_CHARGE_IDEMPOTENCY_KEY", :private},
             {"PAYMENTS_CREATE_CHARGE_LITERAL_1", :literal},
             {"PAYMENTS_CREATE_CHARGE_LITERAL_2", :literal},
             {"PAYMENTS_CREATE_CHARGE_LITERAL_3", :literal},
             {"PAYMENTS_CREATE_CHARGE_LITERAL_4", :literal},
             {"PAYMENTS_CREATE_CHARGE_LITERAL_5", :literal},
             {"PAYMENTS_CREATE_CHARGE_LITERAL_6", :literal},
             {"PAYMENTS_CREATE_CHARGE_SIGNING", :private},
             {"PAYMENTS_SHARED_1", :literal}
           ]
  end

  test "names avoid Kernel functions; methods and hosts come from the template", %{spec: spec} do
    assert call(spec, "gTenants", "cSend").function == "send_call"

    remove = call(spec, "gTenants", "cRemove")
    assert {remove.method, remove.base.scheme} == {:delete, "http"}
    assert remove.path == [[literal: "items"], [arg: "id"], []]

    ping = call(spec, "gTenants", "cPing")
    assert ping.base.host == [arg: "tenant", literal: ".crm.example"]
    assert ping.response.kind == :empty
  end

  test "is deterministic and rejects a non-Model", %{model: model, spec: spec} do
    assert {:ok, ^spec} = ApiClients.map(model)
    assert {:error, %BubbleEx.Error{kind: :invalid_input}} = ApiClients.map(%{})
    assert ApiClients.env_part("X-Api-Key") == "X_API_KEY"
    assert ApiClients.env_part("émoji 🔥") == "EMOJI"
    assert ApiClients.env_part("🔥") == "X"
  end

  describe "the Phoenix app" do
    @clients ~w(
      lib/acme/api_clients.ex
      lib/acme/api_clients/decode.ex
      lib/acme/api_clients/forms.ex
      lib/acme/api_clients/mail.ex
      lib/acme/api_clients/payments.ex
      lib/acme/api_clients/tenants.ex
      test/acme/api_clients/forms_test.exs
      test/acme/api_clients/mail_test.exs
      test/acme/api_clients/payments_test.exs
      test/acme/api_clients/tenants_test.exs
      test/acme/api_clients_test.exs
      .wtf/api_clients.json
    )

    test "renders the clients and their tests as generated, hash-guarded files",
         %{files: files, spec: spec} do
      manifest = Jason.decode!(files[".wtf/generated.json"])

      for path <- @clients do
        assert Map.has_key?(files, path), path
        assert manifest["generated"][path] == Phoenix.Manifest.sha256(files[path]), path
        refute Map.has_key?(manifest["owned"], path)
      end

      assert manifest["inputs"]["api_clients_sha256"] == Spec.sha256(spec)

      for {path, source} <- files, String.ends_with?(path, [".ex", ".exs"]), path in @clients do
        assert {:ok, _} = Code.string_to_quoted(source), path
        assert source =~ "Generated by bubble_ex"
      end
    end

    test "prints one function per call with Req and a request-shape test per call",
         %{files: files} do
      payments = files["lib/acme/api_clients/payments.ex"]
      assert payments =~ "defmodule Acme.ApiClients.Payments do"
      assert payments =~ ~S"def create_charge(params \\ %{}, opts \\ []) do"
      assert payments =~ ~s(base: "https://api.payments.example:8443")
      assert payments =~ ~s{path: "/v1/customers/" <> ApiClients.segment(p[:customer_id])}
      assert payments =~ "&Acme.ApiClients.Decode.customer/1"

      runtime = files["lib/acme/api_clients.ex"]
      assert runtime =~ "Req.request(options)"
      assert runtime =~ "retry: :safe_transient"
      assert runtime =~ "`PAYMENTS_CREATE_CHARGE_SIGNING` - private body parameter `signing`"

      test = files["test/acme/api_clients/payments_test.exs"]
      assert test =~ "Req.Test.stub(__MODULE__"
      assert length(Regex.scan(~r/sends its request shape/, test)) == 3
      assert test =~ ~s(assert conn.request_path == "/v1/customers/stub-customer-id")
      assert test =~ ~s(assert decoded.plan_name == "stub")
      assert test =~ ~s(@tag bubble: "cCustomer")

      decode = files["lib/acme/api_clients/decode.ex"]
      assert decode =~ ~s{plan_name: ApiClients.at(value, ["plan", "name"])}
      assert decode =~ ~s{address: address_fields(ApiClients.at(value, ["address"]))}
    end

    test "lists the environment and the residue", %{files: files} do
      document = Jason.decode!(files[".wtf/api_clients.json"])
      assert length(document["env"]) == 20
      assert %{"call" => "cRaw", "reasons" => ["raw_body"]} = List.last(document["residue"])
      assert document["names"]["gPay"]["functions"]["cCharge"] == "create_charge"
    end

    test "without clients nothing changes; an invalid option is refused", %{project: project} do
      {:ok, files} = Phoenix.render(project, name: "Acme")
      refute Enum.any?(Map.keys(files), &String.contains?(&1, "api_clients"))
      refute Jason.decode!(files[".wtf/generated.json"])["inputs"]["api_clients_sha256"]

      assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
               Phoenix.render(project, api_clients: :nope)
    end

    test "a resource named ApiClients clashes with the clients only", %{
      project: project,
      spec: spec
    } do
      resources =
        Enum.map(project.resources, fn
          %{source: %{type: "account"}} = r -> %{r | module: "ApiClients"}
          r -> r
        end)

      project = %{project | resources: resources}
      assert {:ok, _} = Phoenix.render(project, name: "Acme")

      assert {:error, %BubbleEx.Error{message: message}} =
               Phoenix.render(project, name: "Acme", api_clients: spec)

      assert message =~ "ApiClients"
    end
  end
end
