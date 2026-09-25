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
    {"task", "a_owner_"} => "expr(creator_id == ^actor(:id))",
    {"task", "b_team_"} => "expr(^actor([:active_membership, :team_id]) == team_id)",
    {"task", "c_admin_"} => "expr(^actor(:admin) == true)",
    {"task", "d_public_"} => "expr(not is_nil(^actor(:id)) and public == true)",
    {"task", "e_access_"} => "expr(^actor(:id) in access)",
    {"task", "f_done_"} => ~s|expr(status == "done")|,
    {"task", "g_active_"} =>
      ~s|expr(not is_nil(^actor([:active_membership, :tier])) and is_distinct_from(^actor([:active_membership, :tier]), "retired") or ^actor(:coach) == true)|,
    {"task", "h_parent_"} => "expr(parent.assignee_id == ^actor(:id))",
    {"task", "i_unfiled_"} => "expr(not exists(team, true))",
    {"task", "j_feature_"} =>
      ~s|expr(^actor([:active_membership, :team, :features]) != [] and "early_access" in ^actor([:active_membership, :team, :features]))|,
    {"task", "k_listed_"} => "expr(^actor(:teams) != [] and team_id in ^actor(:teams))",
    {"task", "n_estimate_"} => "expr(estimate > parent.estimate + 1)",
    {"task", "o_no_access_"} =>
      "expr(not is_nil(^actor(:id)) and (is_nil(access) or not (^actor(:id) in access)))",
    {"task", "p_not_owner_"} =>
      "expr(not is_nil(^actor(:id)) and is_distinct_from(creator_id, ^actor(:id)))",
    {"task", "q_filed_"} => "expr(exists(team, true))",
    {"task", "r_done_by_id_"} => ~s|expr(status == "done")|,
    {"task", "s_same_team_"} => "expr(is_not_distinct_from(team_id, parent.team_id))",
    {"task", "t_access_no_"} => "expr(^actor(:id) in access)",
    {"task", "u_not_owner_no_"} => "expr(creator_id == ^actor(:id))",
    {"task", "v_public_is_"} =>
      "expr(public == true and not is_nil(^actor(:id)) and (is_nil(access) or not (^actor(:id) in access)) or public == false and ^actor(:id) in access)",
    {"task", "w_public_is_not_"} =>
      "expr(public == true and ^actor(:id) in access or public == false and not is_nil(^actor(:id)) and (is_nil(access) or not (^actor(:id) in access)))",
    {"task", "x_not_listed_"} =>
      "expr(not is_nil(^actor(:teams)) and ^actor(:teams) != [] and (is_nil(^actor(:teams)) or is_nil(team_id) or not (team_id in ^actor(:teams))))",
    {"task", "y_title_not_name_no_"} => ~s|expr(^actor(:name) != "" and title == ^actor(:name))|,
    {"task", "z_title_not_name_"} =>
      ~s|expr(not is_nil(^actor(:name)) and ^actor(:name) != "" and is_distinct_from(title, ^actor(:name)))|,
    {"task", "za_team_not_contained_"} =>
      "expr(not is_nil(^actor(:teams)) and ^actor(:teams) != [] and (is_nil(^actor(:teams)) or is_nil(team_id) or not (team_id in ^actor(:teams))))",
    {"user", "me_"} => "expr(id == ^actor(:id))",
    {"membership", "mine_"} => "expr(^actor(:active_membership_id) == id)",
    {"membership", "account_"} => "expr(member_id == ^actor(:id))",
    {"team", "members_"} => "expr(^actor(:id) in members)",
    {"team", "listed_"} => "expr(^actor(:teams) != [] and id in ^actor(:teams))"
  }

  test "every compiled privacy condition", %{privacy: privacy} do
    compiled =
      for %{expr: %Expr{} = e} = r <- privacy, into: %{}, do: {{r.type, r.rule}, Source.expr(e)}

    assert compiled == @expected

    assert Enum.all?(
             privacy,
             &(&1.expr == nil or Enum.all?(&1.diagnostics, fn d -> d.severity == :info end))
           )
  end

  test "actor templates through relationships list the loads they need", %{privacy: privacy} do
    loads =
      for %{expr: %Expr{} = e} = r <- privacy,
          e.actor_loads != [],
          into: %{},
          do: {r.rule, e.actor_loads}

    assert loads == %{
             "b_team_" => [["active_membership"]],
             "g_active_" => [["active_membership"]],
             "j_feature_" => [["active_membership", "team"]]
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

    assert [%{code: :ash_expr_unsupported, details: %{constructs: ["a field of first"]}} = first] =
             failed[{"task", "l_first_"}]

    # The failing sub-node (`Current User's Teams:first item's Name`), not the condition.
    assert first.path == "/user_types/task/privacy_role/l_first_/condition/next/next/next"

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

  test "a condition reading the actor used as a value is rejected", %{project: project} do
    logged_in = IR.node(:logged_in, [], "boolean")
    ir = IR.node(:gt, [logged_in, IR.node(:literal, [false], "boolean")], "boolean")

    assert {:ok, %{expr: nil, diagnostics: [%{code: :ash_expr_unsupported} = diag]}} =
             Expressions.filter(ir, project, resource: "task")

    assert diag.details.constructs == ["a condition reading the current user used as a value"]
  end

  test "negation never flips an actor guard", %{privacy: privacy, project: project} do
    for %{expr: %Expr{}, type: "task", rule: rule} <- privacy,
        rule in ["o_no_access_", "p_not_owner_", "x_not_listed_"] do
      condition =
        Enum.find(BubbleEx.Model.data_type(model(), "task").rules, &(&1.id == rule)).condition

      env = rule_env("task")
      {:ok, %{ir: ir}} = Compiler.compile(condition, env)
      negated = IR.node(:not, [ir], "boolean")
      {:ok, %{expr: e}} = Expressions.filter(negated, project, resource: "task")
      refute Source.expr(e) =~ "not (not is_nil(^actor", rule
    end
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
