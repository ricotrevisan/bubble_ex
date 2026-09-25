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
                 code: :invalid_descriptor,
                 stage: :read,
                 severity: :warning,
                 outcome: :degraded,
                 subject: %{option_set: "status", field: "x"},
                 path: "/option_sets/status/attributes/x/%v",
                 details: %{descriptor: "api."}
               },
               %Diagnostic{
                 code: :connector_missing,
                 outcome: :unresolved,
                 subject: %{type: @nested, field: "child"},
                 path: ^types_path,
                 details: %{
                   external_type: @child,
                   root: %{type: "item", field: "payload"},
                   embedded_path: "/api.apiconnector2.conn.call.Parent/fields/child"
                 }
               },
               %Diagnostic{
                 code: :field_type_unsupported,
                 subject: %{type: @nested, field: "odd"},
                 path: ^types_path,
                 details: %{descriptor: "weird"}
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
               subject: %{type: @nested, field: "child"},
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
