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
    # `defaulting to`: the subject unless it is empty (a reference whose
    # record is gone included), else the default; a field chain over it
    # reads through whichever holds.
    {"task", "zb_assignee_or_creator_"} =>
      "expr(if(not exists(assignee, true), creator_id, assignee_id) == ^actor(:id))",
    {"task", "zd_team_or_actor_team_"} =>
      "expr(not is_nil(^actor(:id)) and not (not exists(team, true) and is_nil(^actor([:active_membership, :team]))))",
    {"task", "ze_title_or_untitled_"} =>
      ~s|expr(if(is_nil(title) or title == "", "Untitled", title) == "Untitled")|,
    {"task", "zf_parent_or_self_team_"} =>
      "expr(if(not exists(parent, true), team_id, parent.team_id) == ^actor([:active_membership, :team_id]))",
    {"task", "zg_access_or_team_members_"} =>
      "expr(^actor(:id) in if(is_nil(access) or access == [], team.members, access))",
    # WTF-471: `is not` between yes/no values reads an empty one as no
    {"task", "zh_public_not_no_"} => "expr(is_not_distinct_from(public, true))",
    {"user", "admin_not_coach_"} =>
      "expr(is_not_distinct_from(admin, true) != is_not_distinct_from(coach, true))",
    # conditions compared as values: each side expanded into its own
    # polarities, so an empty value matches neither (never NULL = NULL)
    {"task", "zi_not_no_is_no_"} =>
      "expr(is_not_distinct_from(public, true) and public == false or public == false and not is_nil(public) and is_not_distinct_from(public, true) and not is_nil(public))",
    # a compared condition's negative side needs its record values
    # non-empty (WTF-471: no grant where the base policies denied)
    {"task", "zj_access_has_assignee_is_public_"} =>
      "expr(assignee_id in access and public == true or (is_nil(access) or is_nil(assignee_id) or not (assignee_id in access)) and not (is_nil(access) or access == []) and exists(assignee, true) and public == false)",
    {"task", "zk_access_has_assignee_is_public_no_"} =>
      "expr(assignee_id in access and public == false or (is_nil(access) or is_nil(assignee_id) or not (assignee_id in access)) and not (is_nil(access) or access == []) and exists(assignee, true) and is_not_distinct_from(public, true) and not is_nil(public))",
    {"user", "admin_no_not_coach_no_"} =>
      "expr(admin == false and is_not_distinct_from(coach, true) and not is_nil(coach) or is_not_distinct_from(admin, true) and not is_nil(admin) and coach == false)",
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
             "j_feature_" => [["active_membership", "team"]],
             "zd_team_or_actor_team_" => [["active_membership", "team"]],
             "zf_parent_or_self_team_" => [["active_membership"]]
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

  # WTF-471: a condition used as a value is strictly yes or no. Without
  # the coercion, `(estimate > 3) defaulting to yes` on an empty estimate
  # would read the NULL comparison as empty and give yes.
  test "a condition used as a value is never NULL", %{project: project} do
    this = IR.node(:this, [:rule_record], "custom.task")
    estimate = IR.node(:field, [this, "task", "estimate_number"], "number")
    over = IR.node(:gt, [estimate, IR.node(:literal, [3.0], "number")], "boolean")
    yes = IR.node(:literal, [true], "boolean")
    ir = IR.node(:eq, [IR.node(:fallback, [over, yes], "boolean"), yes], "boolean")

    {:ok, %{expr: e, diagnostics: []}} = Expressions.filter(ir, project, resource: "task")

    assert Source.expr(e) ==
             "expr(if(is_nil(if(estimate > 3.0, true, false)), true, if(estimate > 3.0, true, false)) == true)"
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

  # WTF-478: a backend workflow's search matches nothing on an empty
  # constraint value, whatever it states; a page's drops it only when it
  # states `ignore_empty_constraints: true`.
  test "an empty constraint value matches nothing, or is dropped", %{project: project} do
    compile = fn searches, options ->
      env = env(searches: searches)

      raw =
        search(
          "custom.task",
          [con("estimate_number", "equals", chain(el("bI1"), [msg("get_data")]))],
          options
        )

      {:ok, %{ir: ir}} = Compiler.compile(parse!(raw, env), env)
      {:ok, %{expr: expr, diagnostics: []}} = Expressions.search(ir, project)
      Source.expr(expr)
    end

    arg = "^arg(:element_state_bi1_get_data)"
    nothing = "expr(not is_nil(#{arg}) and is_not_distinct_from(estimate, #{arg}))"
    dropped = "expr(is_nil(#{arg}) or is_not_distinct_from(estimate, #{arg}))"

    for options <- [
          %{},
          %{"ignore_empty_constraints" => false},
          %{"ignore_empty_constraints" => true}
        ] do
      assert compile.(:backend, options) == nothing
    end

    assert compile.(:page, %{}) == nothing
    assert compile.(:page, %{"ignore_empty_constraints" => true}) == dropped
  end

  # WTF-478: on a page that ignores empty constraints, `title = Current
  # User's name` is dropped for a signed-in user whose name is empty (as
  # Bubble does). For a logged-out visitor both sides read the actor, which
  # must be present: neither holds, so the search matches nothing (Bubble's
  # temporary user would drop it: stricter).
  test "a current-user field constraint: dropped when empty, nothing when logged out", %{
    project: project
  } do
    env = env(searches: :page)

    raw =
      search("custom.task", [con("title_text", "equals", chain(cu(), [msg("name_text")]))], %{
        "ignore_empty_constraints" => true
      })

    {:ok, %{ir: ir}} = Compiler.compile(parse!(raw, env), env)
    {:ok, %{expr: expr, diagnostics: []}} = Expressions.search(ir, project)

    # Dropped: the actor is present and its name empty. Otherwise compared,
    # which holds for no record when there is no actor (`^actor(:name)` is
    # nil, and `nil != ""` is not true).
    assert Source.expr(expr) ==
             ~s|expr(not is_nil(^actor(:id)) and (is_nil(^actor(:name)) or ^actor(:name) == "") | <>
               ~s|or ^actor(:name) != "" and title == ^actor(:name))|
  end

  # An empty list value (`[]`) is empty too: a page search that ignores
  # empty constraints drops `in []`, any other matches nothing.
  test "a list-valued constraint: [] is an empty value", %{project: project} do
    compile = fn searches, options ->
      env = env(searches: searches)
      list = chain(el("bR1"), [msg("get_list_data")])

      raw = search("custom.task", [con("_id", "in", list)], options)
      {:ok, %{ir: ir}} = Compiler.compile(parse!(raw, env), env)
      {:ok, %{expr: expr, diagnostics: []}} = Expressions.search(ir, project)
      Source.expr(expr)
    end

    arg = "^arg(:element_state_br1_get_list_data)"
    empty = "is_nil(#{arg}) or #{arg} == []"

    assert compile.(:page, %{"ignore_empty_constraints" => true}) ==
             "expr(#{empty} or id in #{arg})"

    for searches <- [:page, :backend], options <- [%{}, %{"ignore_empty_constraints" => false}] do
      assert compile.(searches, options) == "expr(not (#{empty}) and id in #{arg})"
    end

    assert compile.(:backend, %{"ignore_empty_constraints" => true}) ==
             "expr(not (#{empty}) and id in #{arg})"
  end

  # A backend workflow's text parameter: `""` is empty like nil, so
  # `title = q` with q = "" matches nothing, whatever the search states.
  test "a backend search's text parameter: \"\" matches nothing", %{project: project} do
    env = env(searches: :backend)

    q = %{
      "type" => "CurrentWorkflowItem",
      "properties" => %{"btype_id" => "text", "param_id" => "pQ", "param_name" => "q"}
    }

    for options <- [%{}, %{"ignore_empty_constraints" => true}] do
      raw = search("custom.task", [con("title_text", "equals", q)], options)
      {:ok, %{ir: ir}} = Compiler.compile(parse!(raw, env), env)
      {:ok, %{expr: expr, diagnostics: []}} = Expressions.search(ir, project)
      arg = "^arg(:parameter_pq_q)"

      assert Source.expr(expr) ==
               ~s|expr(not (is_nil(#{arg}) or #{arg} == "") and is_not_distinct_from(title, #{arg}))|
    end
  end

  test "Bubble's random sort compiles to :random; an unknown sort field does not (WTF-452)", %{
    project: project
  } do
    env = env(ignore_empty_constraints: true)

    compile = fn field ->
      raw =
        search(
          "custom.task",
          [con("status_option_status", "equals", opt("status", "done"))],
          %{"sort_field" => field, "descending" => true}
        )

      {:ok, %{ir: ir}} = Compiler.compile(parse!(raw, env), env)
      {:ok, result} = Expressions.search(ir, project)
      result
    end

    assert %{expr: %{sort: [:random]} = expr, diagnostics: []} = compile.("_random_sorting")
    assert Source.expr(expr) == ~s|expr(status == "done")|
    assert Expr.to_map(expr)["sort"] == ["random"]

    assert %{expr: nil, diagnostics: [diag]} = compile.("no_such_field_text")

    assert %{code: :ash_expr_unmapped_reference, details: %{constructs: ["the sort field"]}} =
             diag
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
