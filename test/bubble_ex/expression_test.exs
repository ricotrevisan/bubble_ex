defmodule BubbleEx.ExpressionTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Diagnostic, Error, Expression}
  alias BubbleEx.Expression.Schema

  alias BubbleEx.Expression.Ast.{
    AllOptions,
    ArbitraryText,
    Arithmetic,
    Check,
    Compare,
    Constraint,
    CurrentUser,
    DynamicText,
    Empty,
    Fallback,
    Field,
    Filter,
    ListOp,
    Literal,
    Logical,
    OptionValue,
    Property,
    Raw,
    Scope,
    Search,
    ThisThing
  }

  @schema Schema.from_user_types(%{
            "user" => %{
              "display" => "User",
              "fields" => %{
                "admin_boolean" => %{"display" => "Admin", "value" => "boolean"},
                "role_custom_role" => %{"display" => "Role", "value" => "custom.role"},
                "tasks_list_custom_task" => %{"display" => "Tasks", "value" => "list.custom.task"}
              }
            },
            "role" => %{
              "%d" => "Role",
              "%f3" => %{"workspace_text" => %{"%d" => "Workspace", "%v" => "text"}}
            },
            "task" => %{
              "display" => "Task",
              "fields" => %{
                "owner_user" => %{"display" => "Owner", "value" => "user"},
                "done_boolean" => %{"display" => "Done", "value" => "boolean"},
                "points_number" => %{"display" => "Points", "value" => "number"}
              }
            }
          })

  # Readable-key builders mirroring Bubble's editor/export JSON.
  defp src(type, fields \\ %{}), do: Map.merge(%{"type" => type, "is_slidable" => false}, fields)
  defp msg(name, fields \\ %{}), do: Map.merge(%{"type" => "Message", "name" => name}, fields)

  defp chain(source, messages) do
    messages
    |> Enum.reverse()
    |> Enum.reduce(nil, fn m, acc -> if acc, do: Map.put(m, "next", acc), else: m end)
    |> then(&Map.put(source, "next", &1))
  end

  defp user(messages), do: chain(src("CurrentUser"), messages)
  defp this(messages), do: chain(src("InjectedValue"), messages)

  defp parse!(raw, opts \\ []) do
    {:ok, %Expression{} = parsed} =
      Expression.parse(raw, Keyword.merge([schema: @schema, this_type: "custom.task"], opts))

    assert_round_trip(raw, parsed.ast)
    parsed
  end

  defp assert_round_trip(raw, ast) do
    {:ok, encoded} = Expression.to_bubble(ast)
    assert CanonicalJson.encode(encoded) == CanonicalJson.encode(raw)
    assert CanonicalJson.sha256(encoded) == CanonicalJson.sha256(raw)
  end

  defp codes(%Expression{diagnostics: diagnostics}), do: Enum.map(diagnostics, & &1.code)

  describe "sources" do
    test "Current User" do
      assert %{ast: %CurrentUser{type: "user"}, diagnostics: []} = parse!(src("CurrentUser"))
    end

    test "This Thing is typed by the caller" do
      assert %{ast: %ThisThing{type: "custom.task"}, diagnostics: []} =
               parse!(src("InjectedValue"))

      assert %{ast: %ThisThing{type: nil}} = parse!(src("InjectedValue"), this_type: nil)
    end

    test "empty and literals" do
      assert %{ast: %Empty{}} = parse!(%{"type" => "Empty"})
      assert %{ast: %Literal{value: "x", type: "text"}} = parse!("x")
      assert %{ast: %Literal{value: 2.5, type: "number"}} = parse!(2.5)
      assert %{ast: %Literal{value: false, type: "boolean"}} = parse!(false)
      assert %{ast: %Literal{value: nil, type: nil}} = parse!(nil)
    end

    test "option values in both source spellings" do
      props = %{"option_set" => "option.status", "option_value" => "open"}

      for type <- ["OneOptionValue", "OptionValue"] do
        assert %{ast: %OptionValue{option_set: "option.status", value: "open"}, diagnostics: []} =
                 parse!(src(type, %{"properties" => props}))
      end

      assert %{ast: %AllOptions{option_set: "option.status", type: "list.option.status"}} =
               parse!(
                 src("AllOptionValue", %{"properties" => %{"option_set" => "option.status"}})
               )
    end

    test "option value missing its value is an unexpected shape" do
      raw = src("OneOptionValue", %{"properties" => %{"option_set" => "option.status"}})
      assert %{ast: %Raw{reason: :unexpected_shape}} = parsed = parse!(raw)
      assert codes(parsed) == [:unexpected_shape]
    end

    test "dynamic text keeps numeric entry order" do
      entries =
        Map.new(0..10, &{Integer.to_string(&1), "#{&1} "}) |> Map.put("3", src("CurrentUser"))

      assert %{ast: %DynamicText{parts: parts}} =
               parse!(%{"type" => "TextExpression", "entries" => entries})

      assert Enum.at(parts, 2) == "2 " and Enum.at(parts, 10) == "10 "
      assert %CurrentUser{} = Enum.at(parts, 3)
    end

    test "dynamic text with ambiguous order is preserved raw" do
      raw = %{"type" => "TextExpression", "entries" => %{"1" => "a", "01" => "b"}}
      assert %{ast: %Raw{reason: :unresolved_order}} = parsed = parse!(raw)
      assert codes(parsed) == [:unresolved_order]
    end

    test "empty text without entries" do
      assert %{ast: %DynamicText{parts: []}, diagnostics: []} =
               parse!(%{"type" => "TextExpression"})
    end

    test "arbitrary text wraps dynamic text" do
      raw =
        src("ArbitraryText", %{
          "properties" => %{
            "arbitrary_text" => %{"type" => "TextExpression", "entries" => %{"0" => "hi"}}
          }
        })

      assert %{ast: %ArbitraryText{text: %DynamicText{parts: ["hi"]}}} = parse!(raw)
    end

    test "context scopes keep their reference and parameter type" do
      ref = %{"btype_id" => "custom.task", "param_id" => "p1", "param_name" => "Task"}
      raw = chain(src("CurrentWorkflowItem", %{"properties" => ref}), [msg("done_boolean")])

      assert %{
               ast: %Field{subject: %Scope{kind: :workflow_parameter, ref: ^ref}, type: "boolean"}
             } =
               parse!(raw)

      assert %{ast: %Scope{kind: :element, type: nil}} =
               parse!(src("GetElement", %{"properties" => %{"element_id" => "e1"}}))
    end

    test "search with constraints, sort options and advanced constraint" do
      raw =
        src("Search", %{
          "properties" => %{
            "type_to_find" => "custom.task",
            "descending" => true,
            "sort_field" => "Created Date",
            "constraints" => %{
              "0" => %{
                "key" => "owner_user",
                "constraint_type" => "equals",
                "value" => src("CurrentUser")
              },
              "1" => %{
                "key" => "_advanced_search_constraint",
                "constraint_type" => %{"type" => "Empty"},
                "value" => this([msg("done_boolean"), msg("is_false")])
              }
            }
          }
        })

      parsed = parse!(raw)
      assert parsed.diagnostics == []

      assert %Search{
               data_type: "custom.task",
               type: "list.custom.task",
               options: %{"descending" => true, "sort_field" => "Created Date"},
               constraints: [
                 %Constraint{key: "owner_user", op: :equals, value: %CurrentUser{}},
                 %Constraint{
                   op: nil,
                   value: %Check{
                     op: :is_false,
                     subject: %Field{subject: %ThisThing{type: "custom.task"}}
                   }
                 }
               ]
             } = parsed.ast
    end

    test "unknown constraint operators are kept and diagnosed" do
      raw =
        src("Search", %{
          "properties" => %{
            "type_to_find" => "custom.task",
            "constraints" => %{"0" => %{"key" => "x", "constraint_type" => "near", "value" => 1}}
          }
        })

      assert %{ast: %Search{constraints: [%Constraint{op: "near"}]}} = parsed = parse!(raw)
      assert codes(parsed) == [:unknown_constraint]
    end

    test "unknown sources are preserved and their chain is still parsed" do
      raw = chain(src("Formulas", %{"properties" => %{"length" => 4}}), [msg("is_empty")])
      parsed = parse!(raw)

      assert %Check{op: :is_empty, subject: %Raw{reason: :unknown_source, subject: nil}} =
               parsed.ast

      assert [%Diagnostic{code: :unknown_source, severity: :error, path: ""}] = parsed.diagnostics
    end
  end

  describe "field chains" do
    test "resolve against the schema in either key form" do
      raw = user([msg("role_custom_role"), msg("workspace_text")])
      parsed = parse!(raw)
      assert parsed.diagnostics == []

      assert %Field{
               field: "workspace_text",
               display: "Workspace",
               type: "text",
               subject: %Field{
                 field: "role_custom_role",
                 type: "custom.role",
                 subject: %CurrentUser{}
               }
             } = parsed.ast
    end

    test "fields on a list map over its items" do
      assert %{ast: %Field{type: "list.user"}} =
               parse!(user([msg("tasks_list_custom_task"), msg("owner_user")]))
    end

    test "created by and other built-in fields" do
      assert %{
               ast: %Field{builtin: :created_by, type: "user", field: "Created By"},
               diagnostics: []
             } =
               parse!(this([msg("Created By")]))

      assert %{ast: %Field{builtin: :created_date, type: "date"}} =
               parse!(chain(src("GetElement"), [msg("Created Date")]))

      assert %{ast: %Field{field: "email", type: "text"}} = parse!(user([msg("email")]))
    end

    test "unknown field on a known type is a diagnosed property" do
      parsed = parse!(this([msg("missing_text")]))
      assert %Property{name: "missing_text", subject: %ThisThing{}} = parsed.ast

      assert [%Diagnostic{code: :unresolved_field, severity: :warning, path: "/next"}] =
               parsed.diagnostics
    end

    test "accessor on an untyped subject is a property with an info diagnostic" do
      parsed = parse!(chain(src("GetElement"), [msg("is_hovered")]))
      assert %Property{name: "is_hovered"} = parsed.ast
      assert [%Diagnostic{code: :unresolved_property, severity: :info}] = parsed.diagnostics
    end
  end

  describe "operators" do
    test "comparisons" do
      for {name, op} <- [
            {"equals", :equals},
            {"not_equals", :not_equals},
            {"greater_than", :greater_than},
            {"less_than", :less_than},
            {"greater_or_equal_than", :greater_or_equal},
            {"less_or_equal_than", :less_or_equal}
          ] do
        raw = this([msg("points_number"), msg(name, %{"args" => 3})])

        assert %{
                 ast: %Compare{op: ^op, left: %Field{}, right: %Literal{value: 3}},
                 diagnostics: []
               } =
                 parse!(raw)
      end
    end

    test "and/or group strictly left to right with nested arguments" do
      raw =
        user([
          msg("logged_in"),
          msg("and_", %{"args" => user([msg("admin_boolean"), msg("is_true")])}),
          msg("or_", %{"args" => this([msg("done_boolean"), msg("is_false")])})
        ])

      assert %{
               ast: %Logical{
                 op: :or,
                 left: %Logical{
                   op: :and,
                   left: %Check{op: :logged_in},
                   right: %Check{op: :is_true}
                 },
                 right: %Check{op: :is_false}
               },
               diagnostics: []
             } = parse!(raw)
    end

    test "unary checks" do
      for {name, op} <- [
            {"is_empty", :is_empty},
            {"is_not_empty", :is_not_empty},
            {"is_true", :is_true},
            {"is_false", :is_false},
            {"logged_in", :logged_in},
            {"not_logged_in", :logged_out}
          ] do
        assert %{ast: %Check{op: ^op, subject: %CurrentUser{}}} = parse!(user([msg(name)]))
      end
    end

    test "list operators" do
      tasks = msg("tasks_list_custom_task")

      assert %{ast: %ListOp{op: :count, type: "number"}} = parse!(user([tasks, msg("count")]))

      assert %{ast: %ListOp{op: :first_item, type: "custom.task"}} =
               parse!(user([tasks, msg("first_element")]))

      assert %{ast: %ListOp{op: :contains, arg: %ThisThing{}, type: "boolean"}} =
               parse!(user([tasks, msg("contains", %{"args" => src("InjectedValue")})]))

      assert %{ast: %ListOp{op: :sorted, options: %{"descending" => true}}} =
               parse!(user([tasks, msg("sorted", %{"properties" => %{"descending" => true}})]))
    end

    test "filtered with constraints types This Thing as the list item" do
      filter =
        msg("filtered", %{
          "properties" => %{
            "constraints" => %{
              "0" => %{"key" => "done_boolean", "constraint_type" => "equals", "value" => true},
              "1" => %{
                "key" => "_advanced_search_constraint",
                "constraint_type" => %{"type" => "Empty"},
                "value" => this([msg("points_number"), msg("greater_than", %{"args" => 1})])
              }
            }
          }
        })

      parsed = parse!(user([msg("tasks_list_custom_task"), filter, msg("count")]))
      assert parsed.diagnostics == []

      assert %ListOp{
               op: :count,
               subject: %Filter{
                 type: "list.custom.task",
                 constraints: [
                   %Constraint{op: :equals, value: %Literal{value: true}},
                   %Constraint{
                     value: %Compare{left: %Field{subject: %ThisThing{type: "custom.task"}}}
                   }
                 ]
               }
             } = parsed.ast
    end

    test "fallback and arithmetic" do
      assert %{ast: %Fallback{fallback: %Literal{value: 0}}} =
               parse!(this([msg("points_number"), msg("defaulting_to", %{"args" => 0})]))

      assert %{ast: %Arithmetic{op: :plus, type: "number"}} =
               parse!(this([msg("points_number"), msg("plus", %{"args" => 1})]))
    end

    test "unknown operators keep their subject and let the chain continue" do
      raw =
        this([
          msg("points_number"),
          msg("format_number", %{"properties" => %{"x" => 1}}),
          msg("is_empty")
        ])

      parsed = parse!(raw)

      assert %Check{
               op: :is_empty,
               subject: %Raw{
                 reason: :unknown_operator,
                 raw: %{"name" => "format_number"},
                 subject: %Field{field: "points_number"}
               }
             } = parsed.ast

      assert [%Diagnostic{code: :unknown_operator, path: "/next/next"}] = parsed.diagnostics
    end

    test "known operators with the wrong operands are unexpected shapes" do
      for raw <- [user([msg("equals")]), user([msg("is_empty", %{"args" => 1})])] do
        assert %{ast: %Raw{reason: :unexpected_shape, subject: %CurrentUser{}}} =
                 parsed = parse!(raw)

        assert codes(parsed) == [:unexpected_shape]
      end
    end

    test "malformed links are preserved raw" do
      parsed = parse!(Map.put(src("CurrentUser"), "next", 42))
      assert %Raw{reason: :malformed_node, raw: 42, subject: %CurrentUser{}} = parsed.ast
      assert codes(parsed) == [:malformed_node]

      parsed = parse!(user([%{"type" => "Group", "name" => "x"}]))
      assert %Raw{reason: :malformed_node} = parsed.ast
    end
  end

  describe "fidelity" do
    test "alias collisions are preserved raw" do
      raw = %{"type" => "CurrentUser", "%x" => "CurrentUser"}
      assert %{ast: %Raw{reason: :alias_collision, raw: ^raw}} = parse!(raw)
    end

    test "editor metadata is retained silently, unexpected members with a warning" do
      raw = Map.merge(src("CurrentUser"), %{"said" => "abc", "type_friendly" => "User"})
      assert %{diagnostics: []} = parse!(raw)

      parsed = parse!(Map.put(src("CurrentUser"), "mystery", 1))

      assert [%Diagnostic{code: :uninterpreted_field, severity: :warning, path: "/mystery"}] =
               parsed.diagnostics
    end

    test "readable and compact key forms parse to the same canonical AST" do
      readable =
        user([
          msg("role_custom_role"),
          msg("workspace_text"),
          msg("equals", %{"args" => %{"type" => "TextExpression", "entries" => %{"0" => "w"}}})
        ])

      compact = %{
        "%x" => "CurrentUser",
        "is_slidable" => false,
        "%n" => %{
          "%x" => "Message",
          "%nm" => "role_custom_role",
          "%n" => %{
            "%x" => "Message",
            "%nm" => "workspace_text",
            "%n" => %{
              "%x" => "Message",
              "%nm" => "equals",
              "%a" => %{"%x" => "TextExpression", "%e" => %{"0" => "w"}}
            }
          }
        }
      }

      a = parse!(readable)
      b = parse!(compact)
      assert a.diagnostics == [] and b.diagnostics == []
      assert Expression.canonical(a.ast) == Expression.canonical(b.ast)
      assert Expression.sha256(a.ast) == Expression.sha256(b.ast)
    end

    test "compact search keys" do
      raw = %{
        "%x" => "Search",
        "%p" => %{
          "%t5" => "custom.task",
          "%co" => %{
            "0" => %{"%k" => "owner_user", "%c2" => "equals", "%v" => %{"%x" => "CurrentUser"}}
          }
        },
        "%n" => %{"%x" => "Message", "%nm" => "first_element"}
      }

      assert %{
               ast: %ListOp{
                 op: :first_item,
                 type: "custom.task",
                 subject: %Search{constraints: [%Constraint{key: "owner_user", op: :equals}]}
               },
               diagnostics: []
             } = parse!(raw)
    end

    test "parsing is deterministic and stable across a round trip" do
      raw = this([msg("owner_user"), msg("equals", %{"args" => src("CurrentUser")})])
      {:ok, a} = Expression.parse(raw, schema: @schema, this_type: "custom.task")
      {:ok, b} = Expression.parse(raw, schema: @schema, this_type: "custom.task")
      assert a == b
      {:ok, encoded} = Expression.to_bubble(a.ast)
      {:ok, c} = Expression.parse(encoded, schema: @schema, this_type: "custom.task")
      assert Expression.sha256(a.ast) == Expression.sha256(c.ast)
      assert {:ok, <<_::binary-size(64)>>} = Expression.sha256(a.ast)
    end

    test "nodes built without source metadata encode with readable keys" do
      ast = %Compare{
        op: :equals,
        left: %Field{subject: %ThisThing{}, field: "owner_user"},
        right: %CurrentUser{}
      }

      assert {:ok,
              %{
                "type" => "InjectedValue",
                "next" => %{
                  "type" => "Message",
                  "name" => "owner_user",
                  "next" => %{
                    "type" => "Message",
                    "name" => "equals",
                    "args" => %{"type" => "CurrentUser"}
                  }
                }
              }} = Expression.to_bubble(ast)
    end
  end

  describe "canonical hash" do
    defp hash(raw, opts \\ []) do
      {:ok, parsed} =
        Expression.parse(raw, Keyword.merge([schema: @schema, this_type: "custom.task"], opts))

      {:ok, hash} = Expression.sha256(parsed.ast)
      hash
    end

    test "does not depend on schema captions or inferred types" do
      raw = this([msg("owner_user"), msg("equals", %{"args" => src("CurrentUser")})])
      renamed = put_in(@schema, ["task", :fields, "owner_user", :display], "Assignee")
      retyped = put_in(@schema, ["task", :fields, "owner_user", :value], "custom.member")

      assert hash(raw) == hash(raw, schema: renamed)
      assert hash(raw) == hash(raw, schema: retyped)

      refute hash(raw) ==
               hash(this([msg("points_number"), msg("equals", %{"args" => src("CurrentUser")})]))
    end

    test "normalizes known compact keys inside verbatim payloads" do
      readable =
        user([
          msg("format_date", %{
            "properties" => %{"formatting_type" => "custom", "x" => %{"type" => "Empty"}}
          })
        ])

      compact = %{
        "%x" => "CurrentUser",
        "%n" => %{
          "%x" => "Message",
          "%nm" => "format_date",
          "%p" => %{"%ft" => "custom", "x" => %{"%x" => "Empty"}}
        }
      }

      assert %Raw{reason: :unknown_operator} = parse!(compact).ast
      assert hash(readable) == hash(compact)

      assert hash(src("GetElement", %{"properties" => %{"element_id" => "e1"}})) ==
               hash(%{"%x" => "GetElement", "%p" => %{"%ei" => "e1"}})
    end

    test "keeps both members when a payload spells a key both ways" do
      both = user([msg("mystery", %{"properties" => %{"type" => "a", "%x" => "b"}})])
      one = user([msg("mystery", %{"properties" => %{"type" => "a"}})])
      refute hash(both) == hash(one)
    end

    test "treats integral floats as the same JavaScript number" do
      eq = fn n -> this([msg("points_number"), msg("equals", %{"args" => n})]) end
      assert hash(eq.(1)) == hash(eq.(1.0))
      refute hash(eq.(1)) == hash(eq.(1.5))
      # The source value itself is still re-emitted exactly.
      assert {:ok, %{"next" => %{"next" => %{"args" => 1.0}}}} =
               Expression.to_bubble(parse!(eq.(1.0)).ast)
    end
  end

  describe "This Thing binding" do
    test "defaults to the caller's context and follows the top-level option" do
      assert %{ast: %ThisThing{binder: :context}} = parse!(src("InjectedValue"))

      assert %{ast: %ThisThing{binder: :rule_record}} =
               parse!(src("InjectedValue"), this_binder: :rule_record)
    end

    test "search and filter constraints re-bind it, including nested ones" do
      advanced = fn value ->
        %{
          "0" => %{
            "key" => "_advanced_search_constraint",
            "constraint_type" => %{"type" => "Empty"},
            "value" => value
          }
        }
      end

      inner_search =
        src("Search", %{
          "properties" => %{
            "type_to_find" => "custom.role",
            "constraints" => advanced.(this([msg("workspace_text"), msg("is_not_empty")]))
          }
        })

      raw =
        this([
          msg("owner_user"),
          msg("tasks_list_custom_task"),
          msg("filtered", %{
            "properties" => %{
              "constraints" =>
                advanced.(
                  this([
                    msg("owner_user"),
                    msg("role_custom_role"),
                    msg("contains", %{"args" => inner_search})
                  ])
                )
            }
          }),
          msg("count"),
          msg("greater_than", %{"args" => this([msg("points_number")])})
        ])

      parsed = parse!(raw, this_binder: :rule_record)
      assert parsed.diagnostics == []

      assert %Compare{
               left: %ListOp{
                 subject: %Filter{
                   subject: %Field{
                     subject: %Field{
                       subject: %ThisThing{binder: :rule_record, type: "custom.task"}
                     }
                   },
                   constraints: [
                     %Constraint{
                       value: %ListOp{
                         subject: %Field{
                           subject: %Field{
                             subject: %ThisThing{binder: :filter_item, type: "custom.task"}
                           }
                         },
                         arg: %Search{
                           constraints: [
                             %Constraint{
                               value: %Check{
                                 subject: %Field{
                                   subject: %ThisThing{binder: :filter_item, type: "custom.role"}
                                 }
                               }
                             }
                           ]
                         }
                       }
                     }
                   ]
                 }
               },
               right: %Field{subject: %ThisThing{binder: :rule_record}}
             } = parsed.ast
    end

    test "binding is part of the canonical form" do
      {:ok, a} = Expression.parse(src("InjectedValue"), this_binder: :rule_record)
      {:ok, b} = Expression.parse(src("InjectedValue"))
      refute Expression.sha256(a.ast) == Expression.sha256(b.ast)
    end
  end

  describe "diagnostic paths" do
    test "are prefixed with the caller's source path" do
      {:ok, parsed} = Expression.parse(user([msg("nope", %{"args" => 1})]), path: ["a", "b/c"])
      assert [%Diagnostic{path: "/a/b~1c/next"}] = parsed.diagnostics
    end
  end

  describe "views" do
    test "render" do
      raw =
        this([
          msg("owner_user"),
          msg("equals", %{"args" => src("CurrentUser")}),
          msg("and_", %{"args" => this([msg("done_boolean"), msg("is_true")])})
        ])

      assert {:ok,
              "This custom.task's Owner is Current User and (This custom.task's Done is yes)"} =
               Expression.render(parse!(raw).ast)
    end

    test "to_map is stack-neutral and omits source metadata" do
      {:ok, map} = Expression.to_map(parse!(user([msg("logged_in")])).ast)

      assert map == %{
               "node" => "check",
               "op" => "logged_in",
               "subject" => %{"node" => "current_user"}
             }
    end

    test "node_counts" do
      raw =
        user([msg("tasks_list_custom_task"), msg("contains", %{"args" => src("InjectedValue")})])

      assert {:ok, %{"list_op" => 1, "field" => 1, "current_user" => 1, "this_thing" => 1}} =
               Expression.node_counts(parse!(raw).ast)
    end
  end

  describe "errors" do
    test "non-JSON input" do
      assert {:error, %Error{kind: :invalid_input}} = Expression.parse(%{a: 1})
      assert {:error, %Error{kind: :invalid_input}} = Expression.parse({:tuple})
    end

    test "operators on a subject that cannot carry a chain" do
      for subject <- [%Literal{value: "x"}, %Raw{raw: 42, reason: :malformed_node}] do
        assert {:error, %Error{kind: :invalid_input}} =
                 Expression.to_bubble(%Check{op: :is_empty, subject: subject})
      end

      nested = %Compare{
        op: :equals,
        left: %CurrentUser{},
        right: %Check{op: :is_empty, subject: %Literal{value: 1}}
      }

      assert {:error, %Error{kind: :invalid_input}} = Expression.to_bubble(nested)
    end

    test "non-AST input" do
      for fun <- [:to_bubble, :render, :to_map, :canonical, :sha256, :node_counts] do
        assert {:error, %Error{kind: :invalid_input}} = apply(Expression, fun, [%{}])
      end
    end
  end

  describe "consistency with workflow explanations" do
    # Every operator the bounded explanation vocabulary fully supports is also
    # structured (never raw) in the AST.
    test "explanation operators are modeled" do
      binary =
        ~w(equals not_equals greater_than less_than greater_or_equal_than less_or_equal_than and_ or_)

      unary = ~w(is_true is_false is_empty is_not_empty logged_in not_logged_in)

      for name <- binary do
        parsed = parse!(user([msg(name, %{"args" => 1})]))
        refute match?(%Raw{}, parsed.ast), name
      end

      for name <- unary do
        parsed = parse!(user([msg(name)]))
        assert %Check{} = parsed.ast
      end
    end
  end
end
