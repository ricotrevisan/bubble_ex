defmodule BubbleEx.ApiConnectorProbeTest do
  # Security review of PR #135 (WTF-374): the reviewer's probes. Each probe
  # value sits in a non-private place of an API Connector call (query-string
  # names and values, path segments, body strings and numbers, shared header
  # values) and must reach none of: the Model's JSON (and so its SHA-256),
  # the API client Spec, the generated clients, their tests and
  # `.wtf/api_clients.json`. Credential-shaped strings are built at run time
  # so that no scanner sees them in the source.
  use ExUnit.Case, async: true

  alias BubbleEx.Model
  alias BubbleEx.Target.{ApiClients, Phoenix}
  alias BubbleEx.Target.ApiClients.Spec

  @aws "AKIA" <> "IOSFODNN7EXAMPLE"
  @stripe "sk_" <> "live_" <> "4eC39HqLyjWDarjtT1zdp7dc"
  @github "ghp_" <> "16C7e42F292c6912E7710c838347Ae178B4a"
  @random "Zx81kQpLm20aRt"
  @random_query "kERbTLL13G8y9F0kdul9UqIZri0EvYQ6"
  @random_key "e298a9d4709fe526fec1ec8ab4abc5a4"
  @random_header "X-Qz81Lmk7Rt"
  @random_host "eo1a2b3c4d5e6f"
  @random_media "application/x-q7hunter"

  # Secret-shaped names: query-string names, a body key, header and key
  # parameter names, a host label, a media type.
  @names [
    @aws,
    @stripe,
    @github,
    @random,
    @random_query,
    @random_key,
    @random_header,
    @random_host,
    @random_media
  ]

  # Low-entropy values a word test would keep.
  @values [
    "hunter2",
    "314159",
    "deadbeefcafebabe",
    "mysupersecretvalue",
    "correct horse battery staple",
    "abcdefghijklmnopqrstuvwx",
    "ABCDE",
    "wombatkey"
  ]

  defp app do
    [v1, v2, v3, v4, v5, v6, v7, v8] = @values

    calls = %{
      "cNames" => %{
        "name" => "Names",
        "method" => "get",
        "url" =>
          "https://api.example.com/users?#{@aws}&#{@stripe}=1&#{@github}=x&#{@random}=x&ok=1"
      },
      "cValues" => %{
        "name" => "Values",
        "method" => "post",
        "url" => "https://api.example.com/v1/#{v6}/users?pin=#{v2}&q=#{v1}",
        "body" =>
          Jason.encode!(%{
            "a" => v3,
            "b" => v4,
            "c" => v5,
            "d" => 314_159,
            "e" => [v7, true, nil],
            "f" => "Hello <who>, #{v1}"
          }),
        "body_params" => %{"w" => %{"key" => "who", "value" => v4}}
      },
      "cRandomQuery" => %{
        "name" => "Random query",
        "method" => "get",
        "url" => "https://api.example.com/users?#{@random_query}=1"
      },
      "cRandomKey" => %{
        "name" => "Random key",
        "method" => "post",
        "url" => "https://api.example.com/users",
        "body" => Jason.encode!(%{"outer" => %{@random_key => true}})
      },
      "cRandomHeader" => %{
        "name" => "Random header",
        "method" => "get",
        "url" => "https://api.example.com/users",
        "headers" => %{
          "h1" => %{"key" => @random_header, "value" => "x", "private" => true},
          "h2" => %{"key" => @random_header <> "2", "value" => "x"}
        }
      },
      "cRandomHost" => %{
        "name" => "Random host",
        "method" => "get",
        "url" => "https://#{@random_host}.m.pipedream.net/users"
      },
      "cKeyPath" => %{
        "name" => "Key path",
        "method" => "get",
        "url" => "https://api.example.com/v1/token/users/#{v5 |> String.replace(" ", "-")}"
      }
    }

    %{
      "_id" => "probe",
      "user_types" => %{
        "user" => %{
          "display" => "User",
          "fields" => %{"email" => %{"display" => "email", "value" => "text"}}
        }
      },
      "settings" => %{
        "client_safe" => %{
          "apiconnector2" => %{
            "gProbe" => %{
              "human" => "Probe",
              "auth" => "private_key_header",
              "token_param_name" => @random_header,
              "shared_headers" => %{
                "h1" => %{"key" => "X-Key", "value" => v8},
                "h2" => %{"key" => "Accept", "value" => v1},
                "h3" => %{"key" => "Content-Type", "value" => "application/json"},
                "h4" => %{"key" => "Accept", "value" => @random_media}
              },
              "calls" => calls
            }
          }
        }
      }
    }
  end

  setup_all do
    {:ok, model} = Model.build(app())
    {:ok, spec} = ApiClients.map(model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, files} = Phoenix.render(project, name: "Probe", api_clients: spec)
    generated = Map.filter(files, fn {path, _} -> String.contains?(path, "api_clients") end)

    %{
      model: model,
      spec: spec,
      outputs:
        Map.merge(generated, %{
          "model" => Model.to_json(model),
          "spec" => spec |> Spec.to_map() |> Jason.encode!()
        })
    }
  end

  test "the fixture holds every probe" do
    source = Jason.encode!(app())
    for probe <- @names ++ @values, do: assert(String.contains?(source, probe), probe)
  end

  test "no probe reaches the Model, the Spec or the generated files", %{outputs: outputs} do
    assert Map.has_key?(outputs, "lib/probe/api_clients/probe.ex")
    assert Map.has_key?(outputs, "test/probe/api_clients/probe_test.exs")

    for {name, text} <- outputs, probe <- @names ++ @values do
      # The Model's `host` (WTF-396) keeps the host; its request template
      # and everything generated do not.
      unless name == "model" and probe == @random_host,
        do: refute(String.contains?(text, probe), "#{name} contains #{inspect(probe)}")
    end
  end

  test "the Model's hash does not depend on the probe values", %{model: model} do
    swapped =
      app()
      |> Jason.encode!()
      |> then(fn json ->
        Enum.reduce(@values, json, fn
          "314159", json -> String.replace(json, "314159", "271828")
          value, json -> String.replace(json, value, "Q" <> String.reverse(value))
        end)
      end)
      |> Jason.decode!()

    {:ok, other} = Model.build(swapped)
    assert Model.sha256(other) == Model.sha256(model)
  end

  test "secret-shaped query names make the call unsupported; values become variables",
       %{spec: spec} do
    assert [
             %{call: "cNames", reasons: [:query]},
             %{call: "cRandomHeader", reasons: [:unnamed_parameter]},
             %{call: "cRandomKey", reasons: [:body_key]},
             %{call: "cRandomQuery", reasons: [:query]}
           ] = Enum.sort_by(spec.residue, & &1.call)

    [group] = spec.groups
    values = Enum.find(group.calls, &(&1.id == "cValues"))

    assert values.path == [[literal: "v1"], [env: "PROBE_VALUES_LITERAL_1"], [literal: "users"]]
    assert Enum.map(values.query, & &1.name) == ["pin", "q"]
    assert Enum.all?(values.query, &match?([env: _], &1.value))

    assert %{
             "X-Key" => [env: _],
             "Accept" => [env: _],
             "Content-Type" => [literal: "application/json"]
           } =
             Map.new(values.headers, &{&1.name, &1.value})

    key_path = Enum.find(group.calls, &(&1.id == "cKeyPath"))
    assert [[literal: "v1"], [env: _], [env: _], [env: _]] = key_path.path
  end
end
