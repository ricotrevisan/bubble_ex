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

  # Low-entropy secrets a word test would keep (security review of #135).
  @low_entropy [
    "hunter2",
    "123456",
    "deadbeefcafebabe",
    "mysupersecretvalue",
    "correct horse battery staple",
    "abcdefghijklmnopqrstuvwx",
    "ABCDE",
    "wombatkey"
  ]

  describe "kept structure" do
    test "path words and versions only" do
      for text <- ~w(v1 v2.1 2023-01-01 users orders messages api search users.json search-users),
          do: assert(Reader.path_word?(text), text)

      for text <-
            @low_entropy ++
              [@stripe, @github, @aws, "T01234567", "SECRET-PATH-TOKEN", "getCalendar", "42", ""],
          do: refute(Reader.path_word?(text), text)
    end

    test "structural? keeps empty text, path words and media types only" do
      for text <- ["", "v1", "application/json", "text/plain; charset=utf-8"],
          do: assert(Reader.structural?(text), text)

      for text <- @low_entropy ++ ["Hello, world!", "gpt4"],
          do: refute(Reader.structural?(text), text)
    end

    test "safe_name? refuses credential-shaped and random names" do
      for name <-
            ~w(format api_key max_tokens user_id X-Tenant pageSize q fields[] $filter utm_source),
          do: assert(Reader.safe_name?(name), name)

      for name <- ["Zx81kQpLm20aRt", @stripe, @github, @aws, "a b", "", "x=y"],
          do: refute(Reader.safe_name?(name), name)
    end

    test "safe_name? refuses random tokens: under 0.5% per shape over 5,000 samples" do
      :rand.seed(:exsss, {3, 7, 4})
      pick = fn alphabet, n -> for _ <- 1..n, into: "", do: <<Enum.random(alphabet)>> end
      lower = Enum.concat([?a..?z, ?0..?9])
      hex = Enum.concat([?0..?9, ?a..?f])
      mixed = Enum.concat([?a..?z, ?A..?Z, ?0..?9])

      uuid = fn ->
        <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> = pick.(hex, 32)
        Enum.join([a, b, c, d, e], "-")
      end

      shapes = [
        lower16: fn -> pick.(lower, 16) end,
        uuid: uuid,
        hex16: fn -> pick.(hex, 16) end,
        hex32: fn -> pick.(hex, 32) end,
        mixed32: fn -> pick.(mixed, 32) end,
        mixed12: fn -> pick.(mixed, 12) end,
        lower8: fn -> pick.(lower, 8) end,
        letters10: fn -> pick.(Enum.to_list(?a..?z), 10) end
      ]

      for {shape, sample} <- shapes do
        accepted = Enum.count(1..5000, fn _ -> Reader.safe_name?(sample.()) end)
        assert accepted < 25, "#{shape}: #{accepted} of 5000 accepted"
      end
    end

    test "safe_name? refuses the reviewer's names and keeps real API names" do
      for name <- [
            "kERbTLL13G8y9F0kdul9UqIZri0EvYQ6",
            "e298a9d4709fe526fec1ec8ab4abc5a4",
            "123e4567-e89b-12d3-a456-426614174000",
            "deadbeef",
            "ab12cd"
          ],
          do: refute(Reader.safe_name?(name), name)

      for name <- ~w(Content-Type Authorization X-Api-Key anthropic-version OpenAI-Organization
                     max_tokens response_format messages[0][content] page_size utm_source line1
                     oauth2 employee_count),
          do: assert(Reader.safe_name?(name), name)
    end

    test "media types are an allowlist" do
      for type <- ["application/json", "text/plain; charset=utf-8", "application/vnd.api+json"],
          do: assert(Reader.media_type?(type), type)

      for type <- ["application/x-hunter2", "text/plain; charset=latin1", "application/json2"],
          do: refute(Reader.media_type?(type), type)
    end

    test "credential? matches any name containing a credential word" do
      for name <-
            ~w(token api_key apiKey X-Api-Key client_secret password Authorization accesstoken
               clientsecret passcode passphrase xapikey secretkey signature pin otp session cookie
               bearer credentials pwd),
          do: assert(Reader.credential?(name), name)

      for name <- ~w(format limit description user_id), do: refute(Reader.credential?(name), name)
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
               redacted: 3,
               unsupported: []
             } = request

      assert request.path == [
               [literal("v1")],
               [literal("items")],
               [redacted(1)],
               [%{kind: :parameter, id: "u"}]
             ]

      assert request.query == [
               %{name: "format", value: [redacted(2)]},
               %{name: "api_key", value: [redacted(3)]}
             ]
    end

    test "literal path segments after one named like a credential are redacted" do
      {request, _} = request(%{"url" => "https://api.example.com/v1/token/users/search"})
      assert request.path == [[literal("v1")], [redacted(1)], [redacted(2)], [redacted(3)]]
    end

    test "a query name that is not a plain name is dropped and unsupported" do
      for name <- ["Zx81kQpLm20aRt", @stripe, @github, @aws] do
        {request, _} = request(%{"url" => "https://api.example.com/users?#{name}=1&ok=2"})
        assert request.query == [%{name: "ok", value: [redacted(1)]}]
        assert request.unsupported == [:query]
      end
    end

    test "a host with a label that is not a plain name is configured from the environment" do
      {request, _} = request(%{"url" => "https://eo1a2b3c4d5e6f.m.pipedream.net/users"})
      assert request.host == [redacted(1)]
      assert request.path == [[literal("users")]]

      {request, _} = request(%{"url" => "https://api.stripe.com/v1"})
      assert request.host == [literal("api.stripe.com")]
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
    test "a JSON template: placeholders, keys, booleans and null; every other literal redacted" do
      {request, _} =
        request(%{
          "method" => "post",
          "body" =>
            ~s({"amount": <amount>, "note": "Order <order>!", "model": "gpt4", "key": "#{@stripe}", "n": 3, "ok": true, "none": null, "empty": "", "html": "<b>x</b>"}),
          "body_params" => %{
            "a" => %{"key" => "amount", "value" => "never-read"},
            "o" => %{"key" => "order"}
          }
        })

      assert request.body_type == :json
      assert request.redacted == 6

      assert request.body == %{
               kind: :object,
               members: [
                 %{key: "amount", value: %{kind: :parameter, id: "a"}},
                 %{
                   key: "note",
                   value: %{
                     kind: :text,
                     parts: [redacted(1), %{kind: :parameter, id: "o"}, redacted(2)]
                   }
                 },
                 %{key: "model", value: %{kind: :text, parts: [redacted(3)]}},
                 %{key: "key", value: %{kind: :text, parts: [redacted(4)]}},
                 %{key: "n", value: redacted(5)},
                 %{key: "ok", value: %{kind: :json, value: true}},
                 %{key: "none", value: %{kind: :json, value: nil}},
                 %{key: "empty", value: %{kind: :text, parts: []}},
                 %{key: "html", value: %{kind: :text, parts: [redacted(6)]}}
               ]
             }
    end

    test "a body key that is not a plain name is dropped and unsupported" do
      {request, _} =
        request(%{
          "method" => "post",
          "body" => ~s({"Zx81kQpLm20aRt": 1, "#{@github}": 2, "ok": 3})
        })

      assert %{members: [%{key: "ok"}]} = request.body
      assert request.unsupported == [:body_key]
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

  test "a group's shared values: media types of Content-Type/Accept only, never private" do
    {_request, connector} =
      request(%{"url" => "https://api.example.com"}, %{
        "token_param_name" => "api_key",
        "shared_headers" => %{
          "a" => %{"key" => "X-Tenant", "value" => "acme"},
          "b" => %{"key" => "X-Secret", "value" => "whatever", "private" => true},
          "c" => %{"key" => "Content-Type", "value" => "application/json"},
          "d" => %{"key" => "X-Key", "value" => "wombatkey"},
          "e" => %{"key" => "Accept", "value" => "hunter2"}
        }
      })

    assert connector.key_name == "api_key"

    assert connector.shared_values == [
             %{parameter: "a", parts: [redacted(1)]},
             %{parameter: "c", parts: [literal("application/json")]},
             %{parameter: "d", parts: [redacted(2)]},
             %{parameter: "e", parts: [redacted(3)]}
           ]
  end
end
