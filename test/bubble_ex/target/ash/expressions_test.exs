defmodule BubbleEx.Target.Ash.ExpressionsTest do
  # The Ash backend of the expression compiler (WTF-368): every privacy
  # condition of the synthetic expression fixture, printed with
  # Source.expr/1, the negative cases with their diagnostics, searches with
  # arguments and sort, and the printer's precedence. That these filters
  # compile and run against the pinned Ash is scripts/ash_compile_check.sh.
  use ExUnit.Case, async: true

  import BubbleEx.Test.ExpressionFixture

  alias BubbleEx.Expression.{Compiler, IR}
  alias BubbleEx.Target.Ash.{Expr, Expressions, Source}

  setup_all do
    model = model()
    project = project(model)
    {:ok, privacy} = Expressions.privacy(model, project)
    %{model: model, project: project, privacy: privacy}
  end

  @expected %{
    {"task", "a_owner_"} => "expr(is_not_distinct_from(creator_id, ^actor(:id)))",
    {"task", "b_workspace_"} =>
      "expr(is_not_distinct_from(^actor([:current_role, :workspace_id]), workspace_id))",
    {"task", "c_admin_"} => "expr(^actor(:admin) == true)",
    {"task", "d_public_"} => "expr(not is_nil(^actor(:id)) and public == true)",
    {"task", "e_access_"} => "expr(^actor(:id) in access)",
    {"task", "f_done_"} => ~s|expr(status == "done")|,
    {"task", "g_active_"} =>
      ~s|expr(is_distinct_from(^actor([:current_role, :role_kind]), "archived") or ^actor(:coach) == true)|,
    {"task", "h_parent_"} => "expr(is_not_distinct_from(parent.assignee_id, ^actor(:id)))",
    {"task", "i_unfiled_"} => "expr(is_nil(workspace_id))",
    {"task", "j_beta_"} =>
      ~s|expr("full_access" in ^actor([:current_role, :workspace, :beta_features]))|,
    {"task", "k_listed_"} => "expr(workspace_id in ^actor(:workspaces))",
    {"task", "n_estimate_"} => "expr(estimate > parent.estimate + 1)",
    {"user", "me_"} => "expr(id == ^actor(:id))",
    {"role", "mine_"} => "expr(^actor(:current_role_id) == id)",
    {"role", "account_"} => "expr(is_not_distinct_from(account_id, ^actor(:id)))",
    {"workspace", "members_"} => "expr(^actor(:id) in members)",
    {"workspace", "listed_"} => "expr(id in ^actor(:workspaces))"
  }

  test "every compiled privacy condition", %{privacy: privacy} do
    compiled =
      for %{expr: %Expr{} = e} = r <- privacy, into: %{}, do: {{r.type, r.rule}, Source.expr(e)}

    assert compiled == @expected
    assert Enum.all?(privacy, &(&1.expr == nil or &1.diagnostics == []))
  end

  test "actor templates through relationships list the loads they need", %{privacy: privacy} do
    loads =
      for %{expr: %Expr{} = e} = r <- privacy,
          e.actor_loads != [],
          into: %{},
          do: {r.rule, e.actor_loads}

    assert loads == %{
             "b_workspace_" => [["current_role"]],
             "g_active_" => [["current_role"]],
             "j_beta_" => [["current_role", "workspace"]]
           }
  end

  test "what is not compiled is itemized", %{privacy: privacy} do
    failed = for %{expr: nil} = r <- privacy, into: %{}, do: {{r.type, r.rule}, r.diagnostics}

    assert Map.keys(failed) |> Enum.sort() ==
             [{"archived_thing", "old_"}, {"task", "l_first_"}, {"task", "m_raw_"}]

    assert [%{code: :ash_expr_unmapped_reference, stage: {:target, :ash}} = unmapped] =
             failed[{"archived_thing", "old_"}]

    assert unmapped.subject == %{type: "archived_thing", rule: "old_"}
    assert unmapped.path == "/user_types/archived_thing/privacy_role/old_/condition"

    assert [%{code: :ash_expr_unsupported, details: %{constructs: ["a field of first"]}}] =
             failed[{"task", "l_first_"}]

    assert [%{code: :expr_uncompiled, stage: :model} = raw | _] = failed[{"task", "m_raw_"}]
    assert raw.path == "/user_types/task/privacy_role/m_raw_/condition/next/next"
  end

  test "a context input is unsupported in a filter unless arguments are allowed", %{
    project: project
  } do
    ir =
      IR.node(
        :eq,
        [
          IR.node(:input, [:parameter, %{"key" => "x"}], "text"),
          IR.node(:literal, ["a"], "text")
        ],
        "boolean"
      )

    assert {:ok, %{expr: nil, diagnostics: [%{code: :ash_expr_unsupported}]}} =
             Expressions.filter(ir, project, resource: "task")

    {:ok, %{expr: e}} = Expressions.filter(ir, project, resource: "task", inputs: :arguments)
    assert [%{name: "parameter_x", input: {:parameter, %{"key" => "x"}}}] = e.arguments
    assert {:error, %BubbleEx.Error{}} = Expressions.filter(ir, project, [])

    assert Source.expr(e) == ~s|expr(^arg(:parameter_x) == "a")|
  end

  test "a search compiles to a filter on the searched resource, with its sort", %{
    project: project
  } do
    env = env(ignore_empty_constraints: true)

    raw =
      search(
        "custom.task",
        [
          con("status_option_status", "equals", opt("status", "done")),
          con("estimate_number", "greater than", chain(el("bI1"), [msg("get_data")]))
        ],
        %{"sort_field" => "title_text", "descending" => true}
      )

    {:ok, %{ir: ir}} = Compiler.compile(parse!(raw, env), env)
    {:ok, %{expr: expr, diagnostics: []}} = Expressions.search(ir, project)

    assert {:error, %BubbleEx.Error{}} =
             Expressions.search(IR.node(:literal, [true], "boolean"), project)

    assert expr.resource == "Task"
    assert expr.sort == [{"title", :desc}]

    assert Source.expr(expr) ==
             ~s|expr(status == "done" and (is_nil(^arg(:element_state_bi1_get_data)) or estimate > ^arg(:element_state_bi1_get_data)))|

    assert [%{name: "element_state_bi1_get_data", type: "number"}] = expr.arguments
  end

  test "an option the enum lacks is unmapped", %{project: project} do
    ir =
      IR.node(
        :eq,
        [
          IR.node(:this, [:rule_record], "custom.task"),
          IR.node(:option, ["status", "gone", nil], "option.status")
        ],
        "boolean"
      )

    assert {:ok, %{expr: nil, diagnostics: [%{code: :ash_expr_unmapped_reference}]}} =
             Expressions.filter(ir, project, resource: "task")
  end

  test "the printer parenthesizes by precedence" do
    a = {:op, "==", {:ref, [], "a"}, {:value, 1}}
    b = {:op, "==", {:ref, ["rel"], "b"}, {:value, "x"}}

    print = &Source.expr(%Expr{resource: "R", expr: &1})
    assert print.({:and, [{:or, [a, b]}, a]}) == ~s|expr((a == 1 or rel.b == "x") and a == 1)|
    assert print.({:or, [{:and, [a, b]}, a]}) == ~s|expr(a == 1 and rel.b == "x" or a == 1)|
    assert print.({:not, a}) == "expr(not (a == 1))"

    assert print.({:op, "*", {:op, "+", {:ref, [], "a"}, {:value, 1}}, {:value, 2}}) ==
             "expr((a + 1) * 2)"

    assert print.({:op, "-", {:ref, [], "a"}, {:op, "-", {:ref, [], "b"}, {:value, 1}}}) ==
             "expr(a - (b - 1))"

    assert print.({:op, "in", {:actor, ["id"]}, {:ref, [], "members"}}) ==
             "expr(^actor(:id) in members)"

    assert_raise ArgumentError, fn -> print.({:ref, [], "bad name"}) end
  end

  test "compiling is deterministic and the result JSON-encodable", %{
    model: model,
    project: project,
    privacy: privacy
  } do
    assert Expressions.privacy(model, project) == {:ok, privacy}

    for %{expr: %Expr{} = e} <- privacy do
      assert e |> Expr.to_map() |> Jason.encode!() |> Jason.decode!() == Expr.to_map(e)
    end
  end
end
