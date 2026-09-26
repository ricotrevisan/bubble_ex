defmodule BubbleEx.Model.ConnectorRequestTest do
  # WTF-374: the leak-safe request template of an API Connector call.
  use ExUnit.Case, async: true

  alias BubbleEx.Model
  alias BubbleEx.Model.ConnectorRequest
  alias BubbleEx.Model.ConnectorRequest.Reader

  defp request(call, group \\ %{}) do
    call = Map.put_new(call, "url", "https://api.example.com")

    app = %{
      "settings" => %{
        "client_safe" => %{
          "apiconnector2" => %{"g" => Map.merge(group, %{"calls" => %{"c" => call}})}
        }
      }
    }

    {:ok, model} = Model.build(app)
    [%{calls: [%{request: request}]} = connector] = model.connectors
    {request, connector}
  end

  # Credential-shaped strings are built at run time so that no scanner sees
  # them in the source.
  @stripe "sk_" <> "live_" <> "4eC39HqLyjWDarjtT1zdp7dc"
  @github "ghp_" <> "16C7e42F292c6912E7710c838347Ae178B4a"
  @aws "AKIA" <> "IOSFODNN7EXAMPLE"

  defp literal(text), do: %{kind: :literal, text: text}
  defp redacted(i), do: %{kind: :redacted, index: i}

  describe "safe_text?/1" do
    test "keeps plain words, prose, versions and short numbers" do
      for text <- [
            "",
            "v1",
            "charges",
            "customerId",
            "Hello, world!",
            "Order 42 for Café Müller",
            "gpt4 and 4o",
            "API v2 (JSON)",
            "application/json",
            "You are a helpful assistant."
          ] do
        assert Reader.safe_text?(text), text
      end
    end

    test "redacts anything that could be a credential" do
      for text <- [
            @stripe,
            @github,
            "Bearer abcdefghijklmnop",
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjMifQ.abcdefghijkl",
            "T01234567",
            "SECRET-PATH-TOKEN",
            "a1b2c3d4e5f6",
            "123456789",
            "xkcdpqrstlmnbv",
            @aws,
            "😀"
          ] do
        refute Reader.safe_text?(text), text
      end
    end

    test "credential? names credentials, not words that contain them" do
      for name <- ~w(token api_key apiKey X-Api-Key client_secret password Authorization sig),
          do: assert(Reader.credential?(name), name)

      for name <- ~w(keyword monkey author passenger description tokenizer),
          do: refute(Reader.credential?(name), name)
    end
  end

  describe "the URL" do
    test "keeps the scheme, port, safe path segments and query names" do
      {request, _} =
        request(%{
          "method" => "get",
          "url" =>
            "https://api.example.com:8443/v1/items/T0SECRET99/[id]?format=json&api_key=abc#frag",
          "url_params" => %{"u" => %{"key" => "id", "value" => "never-read", "private" => false}}
        })

      assert %ConnectorRequest{
               scheme: "https",
               host: [%{kind: :literal, text: "api.example.com"}],
               port: 8443,
               body_type: :none,
               redacted: 2,
               unsupported: []
             } = request

      assert request.path == [
               [literal("v1")],
               [literal("items")],
               [redacted(1)],
               [%{kind: :parameter, id: "u"}]
             ]

      assert request.query == [
               %{name: "format", value: [literal("json")]},
               %{name: "api_key", value: [redacted(2)]}
             ]
    end

    test "a placeholder host is a parameter; user info or a whole-URL parameter is no host" do
      {request, _} =
        request(%{
          "url" => "https://[tenant].crm.example/api",
          "url_params" => %{"t" => %{"key" => "tenant"}}
        })

      assert request.host == [%{kind: :parameter, id: "t"}, literal(".crm.example")]

      for url <- ["https://user:pass@api.example.com/x", "[endpoint]"] do
        {request, _} = request(%{"url" => url})
        assert request.unsupported == [:no_host]
        assert request.path == []
      end

      {request, _} = request(%{"method" => "get", "url" => nil})
      assert request.unsupported == [:no_url]
    end

    test "a placeholder naming no parameter is unsupported unless a private key was stripped" do
      {request, _} = request(%{"url" => "https://api.example.com/[missing]"})
      assert :unmatched_placeholder in request.unsupported

      {request, _} =
        request(%{
          "url" => "https://api.example.com/[token]",
          "url_params" => %{"p" => %{"private" => true}}
        })

      assert request.path == [[%{kind: :secret, name: "token"}]]
      assert request.unsupported == []
    end
  end

  describe "the body" do
    test "a JSON template with placeholders in and out of strings and safe literals" do
      {request, _} =
        request(%{
          "method" => "post",
          "body" =>
            ~s({"amount": <amount>, "note": "Order <order>!", "model": "gpt4", "key": "#{@stripe}", "token": "plainword", "big": 12345678901, "n": 3, "ok": true, "html": "<b>x</b>"}),
          "body_params" => %{
            "a" => %{"key" => "amount", "value" => "never-read"},
            "o" => %{"key" => "order"}
          }
        })

      assert request.body_type == :json
      assert request.redacted == 3

      assert request.body == %{
               kind: :object,
               members: [
                 %{key: "amount", value: %{kind: :parameter, id: "a"}},
                 %{
                   key: "note",
                   value: %{
                     kind: :text,
                     parts: [literal("Order "), %{kind: :parameter, id: "o"}, literal("!")]
                   }
                 },
                 %{key: "model", value: %{kind: :text, parts: [literal("gpt4")]}},
                 %{key: "key", value: %{kind: :text, parts: [redacted(1)]}},
                 %{key: "token", value: %{kind: :text, parts: [redacted(2)]}},
                 %{key: "big", value: redacted(3)},
                 %{key: "n", value: %{kind: :json, value: 3}},
                 %{key: "ok", value: %{kind: :json, value: true}},
                 %{key: "html", value: %{kind: :text, parts: [literal("<b>x</b>")]}}
               ]
             }
    end

    test "a stripped private key's placeholder is a secret; HTML tags are not" do
      {request, _} =
        request(%{
          "method" => "post",
          "%b3" => ~s({"t": "<api_token>", "h": "<b>hi</b>"}),
          "body_params" => %{"p" => %{"private" => true}}
        })

      assert request.unsupported == []

      assert %{members: [%{value: %{parts: [%{kind: :secret, name: "api_token"}]}}, _]} =
               request.body
    end

    test "a body that is not JSON is raw and unsupported" do
      {request, _} = request(%{"method" => "post", "body" => "a=<b>&c=d"})
      assert request.body_type == :raw
      assert request.body == nil
      assert request.unsupported == [:raw_body]
    end

    test "form data, parameters next to a JSON body, files and response types" do
      {request, _} =
        request(%{
          "method" => "post",
          "body_type" => "form_data",
          "params" => %{"p" => %{"key" => "a"}}
        })

      assert {request.body_type, request.parameters_in} == {:form, :form}

      {request, _} = request(%{"method" => "get", "params" => %{"p" => %{"key" => "a"}}})
      assert {request.body_type, request.parameters_in} == {:none, :query}

      {request, _} =
        request(%{"method" => "post", "body" => "{}", "params" => %{"p" => %{"key" => "a"}}})

      assert request.unsupported == [:body_and_parameters]

      {request, _} =
        request(%{
          "method" => "post",
          "params" => %{"p" => %{"key" => "f", "binary_file" => true}}
        })

      assert :file_parameter in request.unsupported

      {request, _} = request(%{"data_type" => "text", "is_list" => true})
      assert {request.response, request.list} == {:text, true}

      {request, _} = request(%{"data_type" => "file"})
      assert :response_type in request.unsupported
    end
  end

  test "a group's shared values are safe literals or redacted, never private" do
    {_request, connector} =
      request(%{"url" => "https://api.example.com"}, %{
        "token_param_name" => "api_key",
        "shared_headers" => %{
          "a" => %{"key" => "X-Tenant", "value" => "acme"},
          "b" => %{"key" => "X-Secret", "value" => "whatever", "private" => true},
          "c" => %{"key" => "X-Token", "value" => "plain"}
        }
      })

    assert connector.key_name == "api_key"

    assert connector.shared_values == [
             %{parameter: "a", parts: [literal("acme")]},
             %{parameter: "c", parts: [redacted(1)]}
           ]
  end
end
