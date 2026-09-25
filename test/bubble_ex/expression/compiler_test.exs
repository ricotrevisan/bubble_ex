defmodule BubbleEx.Expression.CompilerTest do
  # The stack-neutral IR (WTF-368): one case per construct over the
  # synthetic expression fixture, the negative cases with their
  # diagnostics, and determinism.
  use ExUnit.Case, async: true

  import BubbleEx.Test.ExpressionFixture

  alias BubbleEx.Expression.{Compiler, IR}

  defp compile(raw, opts \\ []) do
    env = env(opts)
    {:ok, result} = Compiler.compile(parse!(raw, env), env)
    result
  end

  defp ir(raw, opts \\ []) do
    %{ir: %IR{} = ir, diagnostics: []} = compile(raw, opts)
    ir
  end

  defp n(op, args, type), do: IR.node(op, args, type)
  defp user, do: n(:current_user, [], "user")
  defp lit(v, t), do: n(:literal, [v], t)

  describe "sources and fields" do
    test "field chains through records, with Bubble IDs" do
      assert ir(chain(cu(), [msg("current_role_custom_role"), msg("workspace_custom_workspace")])) ==
               n(
                 :field,
                 [
                   n(:field, [user(), "user", "current_role_custom_role"], "custom.role"),
                   "role",
                   "workspace_custom_workspace"
                 ],
                 "custom.workspace"
               )
    end

    test "This Thing in a privacy rule and built-in fields" do
      env = rule_env("task")
      {:ok, %{ir: ir}} = Compiler.compile(parse!(chain(this(), [msg("Created By")]), env), env)

      assert ir ==
               n(:field, [n(:this, [:rule_record], "custom.task"), "task", "Created By"], "user")
    end

    test "options carry their stored key; attributes and labels" do
      assert ir(opt("status", "done")) == n(:option, ["status", "done", "done"], "option.status")

      assert %IR{op: :option_attribute, args: [_, "status", "color"], type: "text"} =
               ir(chain(opt("status", "done"), [msg("color")]))

      assert %IR{op: :option_label, args: [_, "status"]} =
               ir(chain(opt("status", "done"), [msg("display")]))
    end

    test "context sources become inputs named by Bubble IDs" do
      assert ir(chain(el("bI1"), [msg("get_data")])) ==
               n(:input, [:element_state, %{"element" => "bI1", "state" => "get_data"}], "number")

      assert %IR{
               op: :field,
               args: [%IR{op: :input, args: [:element_state, %{"element" => "bG1"}]} | _]
             } =
               ir(chain(src("ElementParent"), [msg("title_text")]), host: "bT1")

      assert %IR{
               op: :field,
               args: [%IR{op: :input, args: [:cell_thing, %{"element" => "bR1"}]} | _]
             } =
               ir(chain(src("CurrentDataItem"), [msg("title_text")]), host: "bT3")
    end

    test "dynamic text concatenates parts" do
      assert ir(text(["Hi ", chain(cu(), [msg("name_text")])])) ==
               n(
                 :concat,
                 [lit("Hi ", "text"), n(:field, [user(), "user", "name_text"], "text")],
                 "text"
               )

      assert ir(text(["plain"])) == lit("plain", "text")
    end
  end

  describe "operators" do
    test "comparisons, checks and boolean operators" do
      raw =
        chain(cu(), [
          msg("logged_in"),
          msg("and_", chain(cu(), [msg("admin_boolean"), msg("is_true")])),
          msg("or_", chain(cu(), [msg("name_text"), msg("is_not_empty")]))
        ])

      assert %IR{
               op: :or,
               args: [%IR{op: :and, args: [%IR{op: :logged_in}, %IR{op: :eq}]}, %IR{op: :not}]
             } =
               ir(raw)

      assert %IR{op: :gt, type: "boolean"} =
               ir(chain(cu(), [msg("name_text"), msg("greater_than", "a")]))

      assert %IR{op: :neq} = ir(chain(cu(), [msg("name_text"), msg("not_equals", "a")]))
    end

    test "list operators" do
      list = chain(cu(), [msg("workspaces_list_custom_workspace")])
      assert %IR{op: :count, type: "number"} = ir(chain(list, [msg("count")]))

      assert %IR{op: :member, args: [%IR{op: :field}, %IR{op: :this}]} =
               ir(chain(list, [msg("contains", this())]))

      assert %IR{op: :not, args: [%IR{op: :member}]} =
               ir(chain(list, [msg("not_contains", this())]))

      assert %IR{op: :first, type: "custom.workspace"} = ir(chain(list, [msg("first_element")]))
    end

    test "arithmetic, text operators and fallback" do
      assert %IR{op: :add, type: "number"} =
               ir(chain(el("bI1"), [msg("get_data"), msg("plus", 1)]))

      assert %IR{op: :uppercase} = ir(chain(cu(), [msg("name_text"), msg("to_uppercase")]))
      assert %IR{op: :fallback} = ir(chain(cu(), [msg("name_text"), msg("defaulting_to", "x")]))
    end

    test "operators the parser keeps raw" do
      date = chain(src("CurrentPageItem"), [msg("due_date")])
      opts = [host: "bT4"]

      assert %IR{op: :date_add, args: [_, %IR{op: :literal, args: [3]}, :day], type: "date"} =
               ir(chain(date, [msg("plus_days", 3)]), opts)

      assert %IR{op: :format_date, args: [_, "mmm d"]} =
               ir(chain(date, [msg("format_date", nil, %{"formatting_type" => "mmm d"})]), opts)

      replace =
        msg("find_replace", nil, %{
          "find" => text(["a"]),
          "replace" => text(["b"]),
          "use_regex" => false
        })

      assert %IR{op: :replace, args: [_, _, _, false]} =
               ir(chain(cu(), [msg("name_text"), replace]))

      yes_no =
        msg("format_boolean", nil, %{
          "formatting_for_true" => text(["Y"]),
          "formatting_for_false" => text(["N"])
        })

      assert %IR{op: :format_boolean} = ir(chain(cu(), [msg("admin_boolean"), yes_no]))
    end
  end

  describe "searches" do
    test "constraints become a predicate over the item, sort is kept" do
      raw =
        search("custom.task", [con("status_option_status", "equals", opt("status", "done"))], %{
          "sort_field" => "title_text",
          "descending" => true
        })

      assert %IR{
               op: :sort,
               args: [
                 %IR{op: :search, args: ["task", %IR{op: :eq, args: [lhs, _]}]},
                 "title_text",
                 true
               ]
             } =
               ir(raw)

      assert lhs ==
               n(
                 :field,
                 [n(:this, [:filter_item], "custom.task"), "task", "status_option_status"],
                 "option.status"
               )
    end

    test "a constraint whose value may be empty needs ignore_empty_constraints" do
      value = chain(el("bI1"), [msg("get_data")])
      raw = search("custom.task", [con("estimate_number", "greater than", value)])

      assert %{ir: nil, diagnostics: [diag]} = compile(raw)
      assert diag.code == :expr_uncompiled
      assert diag.details == %{construct: :ignore_empty_constraints}
      assert diag.path == "/properties/constraints/0"

      assert %IR{op: :search, args: [_, %IR{op: :or, args: [%IR{op: :is_empty}, %IR{op: :gt}]}]} =
               ir(raw, ignore_empty_constraints: true)

      assert %IR{op: :search, args: [_, %IR{op: :gt}]} = ir(raw, ignore_empty_constraints: false)

      stated =
        search("custom.task", [con("estimate_number", "greater than", value)], %{
          "ignore_empty_constraints" => true
        })

      assert %IR{op: :search, args: [_, %IR{op: :or}]} = ir(stated)
    end

    test "unmodeled search options are diagnosed" do
      raw = search("custom.task", [], %{"dynamic_sort_field" => "x"})

      assert %{
               ir: nil,
               diagnostics: [%{code: :expr_uncompiled, details: %{construct: :search_option}}]
             } = compile(raw)
    end
  end

  describe "not compiled" do
    test "a raw operator, with its pointer" do
      raw = chain(cu(), [msg("name_text"), msg("mystery", "x")])
      assert %{ir: nil, diagnostics: diags} = compile(raw, path: ["pages", "p", "text"])

      assert [
               %{
                 code: :expr_uncompiled,
                 path: "/pages/p/text/next/next",
                 details: %{construct: :raw}
               }
             ] =
               Enum.filter(diags, &(&1.code == :expr_uncompiled))
    end

    test "an element used as a value" do
      assert %{ir: nil, diagnostics: [%{details: %{construct: :element}}]} = compile(el("bI1"))
    end

    test "an untyped part is reported once, by typing" do
      assert %{ir: nil, diagnostics: [%{code: :expr_untyped_scope}]} =
               compile(chain(src("ElementParent"), [msg("title_text")]), host: "bP1")
    end

    test "subjects are stamped on every diagnostic" do
      %{diagnostics: [diag]} = compile(el("bI1"), subject: %{workflow: "bW1"})
      assert diag.subject == %{workflow: "bW1"}
    end
  end

  test "IR is deterministic and JSON-encodable" do
    raw = text(["Hi ", chain(src("ElementParent"), [msg("title_text")])])
    a = ir(raw, host: "bT1")
    assert a == ir(raw, host: "bT1")
    assert a |> IR.to_map() |> Jason.encode!() |> Jason.decode!() == IR.to_map(a)
    assert IR.ops(a) == [:concat, :literal, :field, :input]
  end
end
