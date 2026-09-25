defmodule BubbleEx.DiagnosticTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{Diagnostic, Expression, Privacy, Workflows}
  alias BubbleEx.Db.{Encoder, Reader}
  alias BubbleEx.Diagnostic.Codes

  describe "code registry" do
    # Emission conventions. A code reaches `Diagnostic.new/4` either as a
    # literal first argument or through one of these forwarding helpers, whose
    # callers pass literals. Adding an emitter means adding its pattern here.
    defp emitter_patterns do
      [
        # Diagnostic.new(:code, ...), Workflows Source.diagnostic(:code, ...),
        # Encoder graph_diagnostic(:code, ...)
        ~r/(?:Diagnostic\.new|Source\.diagnostic|graph_diagnostic)\(\s*:(\w+)/,
        # Expression Parser.raw(raw, :code, ...) and its local calls
        ~r/\braw\(\s*\w+,\s*:(\w+)/,
        # Parser operand_node's {:raw, :code, message}
        ~r/\{:raw,\s*:(\w+)/,
        # Reader ExternalTypes warn/fail_node
        ~r/\bwarn\((?:state,\s*)?:(\w+)/,
        ~r/\bfail_node\((?:state,\s*)?\w+,\s*:(\w+)/,
        # Encoder root_code/4 clauses
        ~r/defp \w+_code\([^\n]*?\)(?:\s+when [^\n]*)?,?\s*do:\s*:(\w+)/
      ]
    end

    # Reader registry lookups return the category as `{:error, code}`.
    @category_files ["lib/bubble_ex/db/reader/external_types.ex"]

    # Forwarders may pass a variable named `code`, or `root_code(...)`.
    defp forwarded, do: ~r/Diagnostic\.new\(\s*(?!:)(?!code\b)(?!root_code\()([^\s,]+)/

    defp sources, do: Path.wildcard("lib/**/*.ex") -- ["lib/bubble_ex/diagnostic/codes.ex"]

    defp emitted_codes do
      for file <- sources(),
          source = File.read!(file),
          pattern <- emitters(file),
          [_, code] <- Regex.scan(pattern, source),
          into: MapSet.new(),
          do: String.to_atom(code)
    end

    defp emitters(file) when file in @category_files,
      do: [~r/\{:error,\s*:(\w+)\}/ | emitter_patterns()]

    defp emitters(_file), do: emitter_patterns()

    test "every emitted code is registered with severity, outcome and stage" do
      emitted = emitted_codes()
      assert MapSet.size(emitted) > 40

      for code <- emitted do
        assert {:ok, entry} = Codes.fetch(code), "unregistered diagnostic code #{inspect(code)}"
        assert entry.severity in [:error, :warning, :info]
        assert entry.outcome in [:preserved, :degraded, :unresolved]
        assert entry.stage in [:read, :parse, :model, :target]
        assert is_binary(entry.doc) and entry.doc != ""
      end
    end

    test "every registered code is emitted somewhere" do
      assert MapSet.new(Codes.all()) == emitted_codes()
    end

    test "codes only reach Diagnostic.new as literals or through known forwarders" do
      for file <- sources(), [_, arg] <- Regex.scan(forwarded(), File.read!(file)) do
        flunk("#{file}: Diagnostic.new/4 called with #{arg}; pass a literal code")
      end
    end

    # Runtime backstop for the static scan: run every emitter over the
    # committed fixtures plus an adversarial payload, and check each emitted
    # diagnostic against the registry.
    test "every diagnostic emitted over the fixtures is registered and consistent" do
      emitted = sweep()
      assert length(emitted) > 50

      for d <- emitted do
        assert {:ok, entry} = Codes.fetch(d.code), "unregistered #{inspect(d.code)}"
        assert d.severity == entry.severity, inspect(d.code)
        assert d.outcome == entry.outcome, inspect(d.code)

        case d.stage do
          {:target, format} -> assert entry.stage == :target and is_atom(format)
          stage -> assert stage == entry.stage, inspect(d.code)
        end
      end

      covered = emitted |> Enum.map(& &1.code) |> MapSet.new()
      assert MapSet.size(covered) >= 30, inspect(MapSet.to_list(covered))
    end

    defp sweep do
      apps =
        Enum.map(
          BubbleEx.SampleHelper.available_json_samples(),
          &BubbleEx.SampleHelper.load_json_sample/1
        ) ++
          [BubbleEx.Test.ExternalApiTypeFixture.app(), adversarial_app()]

      workflow_docs =
        "test/support/workflows/*.json"
        |> Path.wildcard()
        |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))

      Enum.flat_map(apps, &app_diagnostics/1) ++
        Enum.flat_map(apps, &index_diagnostics/1) ++
        Enum.flat_map(workflow_docs ++ apps, &inventory_diagnostics/1) ++
        Enum.flat_map(expression_samples(), &expression_diagnostics/1)
    end

    defp app_diagnostics(app) do
      # The Reader requires object data types (Privacy is swept on the full app).
      reader_app = Map.update(app, "user_types", %{}, &Map.filter(&1, fn {_, t} -> is_map(t) end))
      {:ok, db} = Reader.parse(reader_app)

      rendered =
        for format <- [:dbml, :postgres, :sqlite, :tsql, :ecto, :ash, :zod, :xano, :convex],
            mode <- [:preserve, :opaque, :legacy],
            {:ok, result} = Encoder.render(format, db, external_types: mode),
            d <- result.diagnostics,
            do: d

      privacy =
        case Privacy.parse(app) do
          {:ok, p} -> p.diagnostics
          {:error, _} -> []
        end

      db.diagnostics ++ rendered ++ privacy
    end

    defp index_diagnostics(app) do
      {:ok, index} = BubbleEx.Index.build(app)
      index.diagnostics
    end

    defp inventory_diagnostics(doc) do
      {:ok, inventory} = Workflows.inventory(doc)

      nested =
        for w <- inventory.workflows ++ inventory.unclassified_definitions,
            a <- w.actions,
            d <- a.diagnostics,
            do: d

      inventory.diagnostics ++ nested
    end

    defp expression_diagnostics(raw) do
      {:ok, e} = Expression.parse(raw)
      e.diagnostics
    end

    defp expression_samples do
      message = fn name, extra -> Map.merge(%{"type" => "Message", "name" => name}, extra) end

      [
        %{"type" => "CurrentUser", "next" => message.("mystery", %{"args" => 1})},
        %{"type" => "NoSuchSource"},
        %{"type" => "CurrentUser", "%x" => "CurrentUser"},
        %{"type" => "CurrentUser", "next" => "oops"},
        %{"type" => "CurrentUser", "next" => message.("is_empty", %{"args" => 1})},
        %{"type" => "CurrentUser", "next" => message.("nope", %{})},
        %{"type" => "TextExpression", "entries" => %{"b" => "x", "a" => "y"}},
        %{"type" => "CurrentUser", "odd" => 1},
        %{"type" => "GetElement", "next" => message.("value", %{})},
        []
      ]
    end

    defp adversarial_app do
      %{
        "_id" => "adversarial",
        "user_types" => %{
          "broken" => "not a type",
          "task" => %{
            "display" => "Task",
            "fields" => %{
              "payload" => %{"display" => "P", "value" => "api.apiconnector2.none.call.X"}
            },
            "exposed_api" => "yes",
            "privacy_role" => %{
              "x_" => %{
                "permissions" => %{"view_all" => "yes", "export" => true},
                "priority" => 1
              },
              "y_" => "oops"
            }
          },
          "list" => %{"display" => "L", "fields" => %{}, "privacy_role" => []}
        },
        "pages" => %{
          "home" => %{
            "workflows" => %{
              "w" => %{
                "type" => "Mystery",
                "%x" => "Mystery",
                "odd" => 1,
                "properties" => "bad",
                "actions" => %{
                  "b" => 1,
                  "a" => %{"type" => "ShowElement", "properties" => %{"element_id" => "gone"}}
                }
              },
              "v" => %{"type" => "PageLoaded", "actions" => "bad"},
              "u" => %{"type" => "PageLoaded"}
            }
          },
          "bad" => false,
          "meta" => %{"name" => "meta"}
        },
        "element_definitions" => %{"r" => %{"workflows" => 5}},
        "history" => %{"entry" => %{"type" => "Mystery", "actions" => []}}
      }
    end

    test "the moduledoc table lists every code" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Codes)
      for code <- Codes.all(), do: assert(doc =~ "`#{inspect(code)}`")
    end
  end

  describe "new/4" do
    test "takes severity, outcome and stage from the registry" do
      d = Diagnostic.new(:unresolved_field, ["a", "b/c"], "msg", subject: %{type: "t"})

      assert %Diagnostic{
               code: :unresolved_field,
               severity: :warning,
               outcome: :unresolved,
               stage: :parse,
               subject: %{type: "t"},
               path: "/a/b~1c",
               details: %{},
               message: "msg"
             } = d
    end

    test "target codes carry the target format" do
      assert %Diagnostic{stage: {:target, :ash}} =
               Diagnostic.new(:external_type_cycle_edge, "", "m", target: :ash)

      assert_raise ArgumentError, fn -> Diagnostic.new(:external_type_cycle_edge, "", "m") end

      assert_raise ArgumentError, fn ->
        Diagnostic.new(:unknown_operator, "", "m", target: :ash)
      end
    end

    test "rejects unregistered codes and non-ID subjects" do
      assert_raise ArgumentError, fn -> Diagnostic.new(:no_such_code, [], "m") end

      assert_raise ArgumentError, fn ->
        Diagnostic.new(:unknown_operator, [], "m", subject: %{name: "Task"})
      end

      assert_raise ArgumentError, fn ->
        Diagnostic.new(:unknown_operator, [], "m", subject: %{type: :task})
      end
    end
  end

  describe "normalize/1" do
    test "dedups on {stage, code, subject, path}, ignoring message and details" do
      a = Diagnostic.new(:unknown_operator, ["x"], "first", details: %{n: 1})
      b = Diagnostic.new(:unknown_operator, ["x"], "second", details: %{n: 2})
      other_path = Diagnostic.new(:unknown_operator, ["y"], "first")
      other_subject = Diagnostic.new(:unknown_operator, ["x"], "first", subject: %{rule: "r"})

      other_stage =
        Diagnostic.new(:external_type_cycle_edge, ["x"], "m", target: :ash)

      same_other_target =
        Diagnostic.new(:external_type_cycle_edge, ["x"], "m", target: :ecto)

      assert Diagnostic.key(a) == Diagnostic.key(b)

      normalized =
        Diagnostic.normalize([a, b, other_path, other_subject, other_stage, same_other_target])

      assert length(normalized) == 5
      assert Enum.find(normalized, &(&1.path == "/x" and &1.subject == %{})).message == "first"
    end

    test "orders by severity, subject, code and path, independent of input order" do
      info = Diagnostic.new(:unresolved_property, ["a"], "m")
      warning = Diagnostic.new(:unresolved_field, ["a"], "m")
      error_b = Diagnostic.new(:unknown_source, ["b"], "m")
      error_a = Diagnostic.new(:unknown_source, ["a"], "m")
      error_code = Diagnostic.new(:malformed_node, ["z"], "m")
      typed = Diagnostic.new(:malformed_node, ["a"], "m", subject: %{type: "t"})
      typed_field = Diagnostic.new(:malformed_node, ["a"], "m", subject: %{type: "t", field: "f"})

      expected = [error_code, error_a, error_b, typed, typed_field, warning, info]

      for _ <- 1..10 do
        assert Diagnostic.normalize(Enum.shuffle(expected)) == expected
      end
    end
  end

  test "put_subject/2 adds IDs without overriding more specific ones" do
    d = Diagnostic.new(:unknown_operator, [], "m", subject: %{rule: "inner"})

    assert [%{subject: %{type: "t", rule: "inner"}}] =
             Diagnostic.put_subject([d], %{type: "t", rule: "outer"})
  end

  test "encodes to JSON with string stages and sorted keys" do
    d =
      Diagnostic.new(:external_type_cycle_edge, ["t"], "m",
        target: :ash,
        subject: %{type: "t", field: "f"},
        details: %{mode: :preserve}
      )

    json = Jason.encode!(d)
    assert json == Jason.encode!(BubbleEx.CanonicalJson.ordered(Diagnostic.to_map(d)))

    assert %{
             "code" => "external_type_cycle_edge",
             "severity" => "info",
             "outcome" => "degraded",
             "stage" => "target:ash",
             "subject" => %{"type" => "t", "field" => "f"},
             "path" => "/t",
             "details" => %{"mode" => "preserve"},
             "message" => "m"
           } = Jason.decode!(json)
  end

  test "details and subject survive a JSON round trip unchanged" do
    d =
      Diagnostic.new(:connector_missing, ["x"], "m",
        subject: %{external_type: "api.apiconnector2.a.b.C", field: "f"},
        details: %{
          external_type: "api.apiconnector2.a.b.D",
          root: %{type: "item", field: "payload"},
          via: [%{external_type: "api.apiconnector2.a.b.C", field: "f"}],
          mode: :preserve,
          flags: [true, false, nil, 1.5],
          pair: {:a, "b"}
        }
      )

    map = Diagnostic.to_map(d)
    assert map |> Jason.encode!() |> Jason.decode!() == map

    assert map["details"]["via"] == [
             %{"external_type" => "api.apiconnector2.a.b.C", "field" => "f"}
           ]

    assert map["details"]["mode"] == "preserve"
    assert map["details"]["pair"] == ["a", "b"]
    assert d |> Jason.encode!() |> Jason.decode!() == map
  end

  describe "stage text form" do
    test "round-trips every stage" do
      for stage <- [:read, :parse, :model, {:target, :ash}, {:target, :postgres}] do
        assert {:ok, ^stage} = stage |> Diagnostic.stage_to_string() |> Diagnostic.parse_stage()
      end

      assert Diagnostic.stage_to_string({:target, :ash}) == "target:ash"
    end

    test "rejects unknown text without creating atoms" do
      for text <- ["", "target:", "load", "Target:ash", "target:no_such_format_wtf360_xyz"] do
        assert Diagnostic.parse_stage(text) == :error
      end
    end
  end

  describe "Reader conversion" do
    @nested "api.apiconnector2.conn.call.Parent"
    @child "api.apiconnector2.gone.call.Child"

    defp reader_app(field_key) do
      fields =
        case field_key do
          "%f3" -> %{"payload" => %{"%d" => "Payload", "%v" => @nested}}
          "fields" -> %{"payload" => %{"display" => "Payload", "value" => @nested}}
        end

      type =
        if field_key == "%f3",
          do: %{"%d" => "Item", "%f3" => fields},
          else: %{"display" => "Item", "fields" => fields}

      registry = %{
        @nested => %{
          "caption" => "Parent",
          "fields" => %{
            "child" => %{"caption" => "Child", "path" => ["child"], "ret_btype" => @child},
            "odd" => %{"caption" => "Odd", "path" => ["odd"], "ret_btype" => "weird"}
          }
        }
      }

      %{
        "_id" => "app",
        "user_types" => %{"item" => type},
        "option_sets" => %{
          "status" => %{
            "%d" => "Status",
            "attributes" => %{"x" => %{"%d" => "X", "%v" => "api."}}
          }
        },
        "settings" => %{
          "client_safe" => %{
            "apiconnector2" => %{
              "conn" => %{
                "calls" => %{
                  "call" => %{"ret_value" => @nested, "types" => Jason.encode!(registry)}
                }
              }
            }
          }
        }
      }
    end

    test "Reader warnings become :read diagnostics keyed by Bubble IDs and source pointers" do
      assert {:ok, db} = Reader.parse(reader_app("%f3"))
      types_path = "/settings/client_safe/apiconnector2/conn/calls/call/types"

      assert [
               %Diagnostic{
                 code: :connector_missing,
                 stage: :read,
                 outcome: :unresolved,
                 subject: %{external_type: @nested, field: "child"},
                 path: ^types_path,
                 details: %{
                   external_type: @child,
                   root: %{type: "item", field: "payload"},
                   via: [%{external_type: @nested, field: "child"}],
                   embedded_path: "/api.apiconnector2.conn.call.Parent/fields/child"
                 }
               },
               %Diagnostic{
                 code: :field_type_unsupported,
                 subject: %{external_type: @nested, field: "odd"},
                 path: ^types_path,
                 details: %{descriptor: "weird"}
               },
               %Diagnostic{
                 code: :invalid_descriptor,
                 stage: :read,
                 severity: :warning,
                 outcome: :degraded,
                 subject: %{option_set: "status", field: "x"},
                 path: "/option_sets/status/attributes/x/%v",
                 details: %{descriptor: "api."}
               }
             ] = db.diagnostics
    end

    test "root pointers follow the source key form" do
      assert {:ok, db} =
               reader_app("fields")
               |> put_in(["user_types", "item", "fields", "payload", "value"], "api.bad")
               |> Reader.parse()

      assert %Diagnostic{path: "/user_types/item/fields/payload/value"} =
               Enum.find(db.diagnostics, &(&1.subject == %{type: "item", field: "payload"}))
    end

    test "Encoder.render keeps Reader diagnostics and adds target ones" do
      {:ok, db} = Reader.parse(reader_app("%f3"))
      assert {:ok, result} = Encoder.render(:postgres, db)
      assert Enum.all?(db.diagnostics, &(&1 in result.diagnostics))

      assert %Diagnostic{
               stage: {:target, :postgres},
               subject: %{external_type: @nested, field: "child"},
               path: "/settings/client_safe/apiconnector2/conn/calls/call/types"
             } = Enum.find(result.diagnostics, &(&1.code == :external_type_unresolved_nested))

      assert result.diagnostics == Diagnostic.normalize(result.diagnostics)
    end
  end

  describe "canonical expression hashing" do
    test "is independent of diagnostics and their subjects" do
      condition = %{
        "type" => "CurrentUser",
        "next" => %{"type" => "Message", "name" => "mystery", "args" => 1}
      }

      {:ok, direct} = Expression.parse(condition)

      app = %{
        "user_types" => %{
          "task" => %{
            "display" => "Task",
            "fields" => %{},
            "privacy_role" => %{
              "x_" => %{"condition" => condition, "permissions" => %{}},
              "everyone" => %{"permissions" => %{}}
            }
          }
        }
      }

      {:ok, privacy} = Privacy.parse(app)
      [type] = privacy.data_types
      rule = Enum.find(type.rules, &(&1.id == "x_"))

      assert [%{subject: %{}}] = direct.diagnostics
      assert [%{subject: %{type: "task", rule: "x_"}}] = rule.diagnostics
      assert Expression.sha256(direct.ast) == Expression.sha256(rule.condition)
      refute elem(Expression.canonical(direct.ast), 1) =~ "diagnostic"
    end
  end

  test "unclassified candidates carry their source key in details, not as a workflow ID" do
    payload = %{
      "pages" => %{
        "home" => %{
          "workflows" => %{},
          "history" => %{"entry_7" => %{"type" => "Mystery", "actions" => []}}
        }
      }
    }

    assert {:ok, inventory} = Workflows.inventory(payload)
    assert [candidate] = inventory.unclassified_definitions
    assert [_ | _] = candidate.diagnostics

    for d <- candidate.diagnostics do
      refute Map.has_key?(d.subject, :workflow)
      assert d.details.source_key == "entry_7"
    end
  end

  test "workflow inventory diagnostics carry the workflow ID and serialize as JSON" do
    payload = %{
      "pages" => %{
        "home" => %{
          "workflows" => %{"bTwf" => %{"type" => "Mystery", "actions" => []}}
        }
      }
    }

    assert {:ok, %{inventory: inventory, json: json}} = Workflows.render(payload)

    assert %Diagnostic{stage: :parse, subject: %{workflow: "bTwf"}} =
             Enum.find(inventory.diagnostics, &(&1.code == :unsupported_type))

    assert inventory.diagnostics == Diagnostic.normalize(inventory.diagnostics)

    assert %{"code" => "unsupported_type", "subject" => %{"workflow" => "bTwf"}} =
             json
             |> Jason.decode!()
             |> Map.fetch!("diagnostics")
             |> Enum.find(&(&1["code"] == "unsupported_type"))
  end
end
