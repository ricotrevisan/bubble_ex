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

  # WTF-514: pages and workflows read an empty text as empty (`"" is nil`,
  # BubbleEx.Target.Elixir), but the generated privacy policies keep the
  # stricter rule (owner decision, 2026-09-29): `""` and nil stay apart,
  # and an empty actor side matches nothing, an empty field included.
  test "policies keep an empty text apart from empty (WTF-514)", %{project: project} do
    this = IR.node(:this, [:rule_record], "custom.task")
    title = IR.node(:field, [this, "task", "title_text"], "text")
    parent = IR.node(:field, [this, "task", "parent_custom_task"], "custom.task")
    parent_title = IR.node(:field, [parent, "task", "title_text"], "text")
    name = IR.node(:field, [IR.node(:current_user, [], "user"), "user", "name_text"], "text")
    empty_text = IR.node(:literal, [""], "text")

    cases = [
      {IR.node(:eq, [title, parent_title], "boolean"),
       "expr(is_not_distinct_from(title, parent.title))"},
      {IR.node(:neq, [title, parent_title], "boolean"),
       "expr(is_distinct_from(title, parent.title))"},
      {IR.node(:eq, [title, empty_text], "boolean"), ~s|expr(title == "")|},
      {IR.node(:eq, [title, name], "boolean"),
       ~s|expr(^actor(:name) != "" and title == ^actor(:name))|},
      {IR.node(:neq, [title, name], "boolean"),
       ~s|expr(not is_nil(^actor(:name)) and ^actor(:name) != "" and is_distinct_from(title, ^actor(:name)))|}
    ]

    for {ir, expected} <- cases do
      {:ok, %{expr: e, diagnostics: []}} = Expressions.filter(ir, project, resource: "task")
      assert Source.expr(e) == expected
    end
  end

  # WTF-529: a search reads an empty yes/no as no, as Bubble does (replay
  # 2026-09-29 and 2026-10-01: `x is no` holds on a record whose x is
  # empty). The privacy policies (`filter/3`, `privacy/2`) keep the
  # stricter `x is no` (owner decision, 2026-09-29).
  describe "yes/no comparisons (WTF-529)" do
    setup do
      item = IR.node(:this, [:filter_item], "custom.task")
      record = IR.node(:this, [:rule_record], "custom.task")

      admin =
        IR.node(:field, [IR.node(:current_user, [], "user"), "user", "admin_boolean"], "boolean")

      %{
        public: IR.node(:field, [item, "task", "public_boolean"], "boolean"),
        rule_public: IR.node(:field, [record, "task", "public_boolean"], "boolean"),
        parent_public:
          IR.node(
            :field,
            [
              IR.node(:field, [item, "task", "parent_custom_task"], "custom.task"),
              "task",
              "public_boolean"
            ],
            "boolean"
          ),
        admin: admin,
        yes: IR.node(:literal, [true], "boolean"),
        no: IR.node(:literal, [false], "boolean")
      }
    end

    defp searched(pred, project) do
      ir = IR.node(:search, ["task", pred], "list.custom.task")
      {:ok, %{expr: expr, diagnostics: []}} = Expressions.search(ir, project)
      Source.expr(expr)
    end

    defp policy(pred, project) do
      {:ok, %{expr: expr, diagnostics: []}} = Expressions.filter(pred, project, resource: "task")
      Source.expr(expr)
    end

    test "in a search an empty yes/no is no", %{project: project} = c do
      no = "expr(public == false or is_nil(public))"
      yes = "expr(public == true)"

      cases = [
        {IR.node(:eq, [c.public, c.no], "boolean"), no},
        {IR.node(:eq, [c.no, c.public], "boolean"), no},
        {IR.node(:neq, [c.public, c.yes], "boolean"), no},
        {IR.node(:eq, [c.public, c.yes], "boolean"), yes},
        {IR.node(:neq, [c.public, c.no], "boolean"), yes},
        # `not x`, `not (x is no)`, `not (x is not yes)`
        {IR.node(:not, [c.public], "boolean"), no},
        {IR.node(:not, [IR.node(:eq, [c.public, c.no], "boolean")], "boolean"), yes},
        {IR.node(:not, [IR.node(:neq, [c.public, c.yes], "boolean")], "boolean"), yes},
        # a field of a related record: empty also when there is none
        {IR.node(:eq, [c.parent_public, c.no], "boolean"),
         "expr(parent.public == false or is_nil(parent.public))"},
        # two values: both read as yes or no, never NULL
        {IR.node(:eq, [c.public, c.parent_public], "boolean"),
         "expr(is_not_distinct_from(public, true) == is_not_distinct_from(parent.public, true))"},
        {IR.node(:neq, [c.public, c.parent_public], "boolean"),
         "expr(is_not_distinct_from(public, true) != is_not_distinct_from(parent.public, true))"},
        # `is empty` stays an exact NULL test (not replayed for yes/no)
        {IR.node(:is_empty, [c.public], "boolean"), "expr(is_nil(public))"},
        {IR.node(:not, [IR.node(:is_empty, [c.public], "boolean")], "boolean"),
         "expr(not is_nil(public))"},
        # the current user's value reads the same way, unguarded: empty (a
        # logged-out visitor's too) is no
        {IR.node(:eq, [c.admin, c.no], "boolean"),
         "expr(is_distinct_from(^actor(:admin), true))"},
        {IR.node(:neq, [c.admin, c.no], "boolean"), "expr(^actor(:admin) == true)"},
        {IR.node(:not, [c.admin], "boolean"), "expr(is_distinct_from(^actor(:admin), true))"},
        {c.admin, "expr(^actor(:admin) == true)"},
        {IR.node(:eq, [c.public, c.admin], "boolean"),
         "expr(is_not_distinct_from(public, true) == is_not_distinct_from(^actor(:admin), true))"}
      ]

      for {pred, expected} <- cases, do: assert(searched(pred, project) == expected)
    end

    test "privacy rules keep the stricter reading", %{project: project} = c do
      cases = [
        # the current user's empty value matches nothing
        {IR.node(:eq, [c.admin, c.no], "boolean"), "expr(^actor(:admin) == false)"},
        {IR.node(:not, [c.admin], "boolean"),
         "expr(not is_nil(^actor(:admin)) and is_distinct_from(^actor(:admin), true))"},
        {IR.node(:eq, [c.rule_public, c.no], "boolean"), "expr(public == false)"},
        {IR.node(:neq, [c.rule_public, c.yes], "boolean"),
         "expr(is_distinct_from(public, true))"},
        {IR.node(:neq, [c.rule_public, c.no], "boolean"),
         "expr(is_not_distinct_from(public, true))"},
        {IR.node(:not, [c.rule_public], "boolean"), "expr(is_distinct_from(public, true))"}
      ]

      for {pred, expected} <- cases, do: assert(policy(pred, project) == expected)
    end
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
    assert expr.sort == [{"title", :desc_nils_last}]

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

  # WTF-520: `contains keyword(s)` (Bubble's keyword match) on a text
  # field, read conservatively: every whitespace-separated word of the
  # input a case-insensitive substring of the field, `\`, `%` and `_`
  # escaped. The SQL itself runs in scripts/phoenix_compile_check.sh
  # (page_data_behavior.exs: several words, case, escaping, empty input).
  describe "contains keyword(s)" do
    defp keywords(project, op, options, searches \\ :page) do
      env = env(searches: searches)

      # A text parameter: `""` is empty like nil.
      q = %{
        "type" => "CurrentWorkflowItem",
        "properties" => %{"btype_id" => "text", "param_id" => "pQ", "param_name" => "q"}
      }

      raw = search("custom.task", [con("title_text", op, q)], options)
      {:ok, %{ir: ir}} = Compiler.compile(parse!(raw, env), env)
      {:ok, result} = Expressions.search(ir, project)
      result
    end

    @arg "^arg(:parameter_pq_q)"
    @call ~s|fragment("coalesce(cardinality(?::text[]) > 0 AND ? ILIKE ALL (?::text[]), false)", | <>
            ~s|^arg(:parameter_keywords_pq_q), title, ^arg(:parameter_keywords_pq_q))|

    test "the words are bound as patterns: no split per row, the exact SQL", %{
      project: project
    } do
      %{expr: expr, diagnostics: []} =
        keywords(project, "text contains", %{"ignore_empty_constraints" => true})

      # The input's value (for its emptiness) and its words' patterns,
      # computed by the caller (`keywords: true`).
      assert [
               %{name: "parameter_keywords_pq_q", type: "text", keywords: true, input: input},
               %{name: "parameter_pq_q", type: "text", input: input} = plain
             ] = expr.arguments

      refute Map.has_key?(plain, :keywords)

      source = Source.expr(expr)
      assert source == ~s|expr(is_nil(#{@arg}) or #{@arg} == "" or #{@call})|
      refute source =~ "regexp"
      assert {:ok, _} = Code.string_to_quoted(source)
    end

    test "an empty input: dropped when the search ignores empty constraints, else nothing", %{
      project: project
    } do
      source = fn options, searches ->
        Source.expr(keywords(project, "text contains", options, searches).expr)
      end

      nothing = ~s|expr(not (is_nil(#{@arg}) or #{@arg} == "") and #{@call})|

      assert source.(%{"ignore_empty_constraints" => true}, :page) ==
               ~s|expr(is_nil(#{@arg}) or #{@arg} == "" or #{@call})|

      for options <- [%{}, %{"ignore_empty_constraints" => false}],
          do: assert(source.(options, :page) == nothing)

      # A backend search matches nothing on an empty input, whatever it states.
      assert source.(%{"ignore_empty_constraints" => true}, :backend) == nothing
    end

    test "doesn't contain keyword(s): an empty field contains none", %{project: project} do
      %{expr: expr, diagnostics: []} =
        keywords(project, "not text contains", %{"ignore_empty_constraints" => true})

      assert Source.expr(expr) ==
               ~s|expr(is_nil(#{@arg}) or #{@arg} == "" or is_nil(title) or not #{@call})|
    end

    test "a literal's words are computed here, escaped and capped" do
      assert BubbleEx.Target.Keywords.patterns("  Bread\tBAKE ") == ["%Bread%", "%BAKE%"]

      assert BubbleEx.Target.Keywords.patterns(~S"100% a_b c\d") == [
               "%100\\%%",
               "%a\\_b%",
               ~S"%c\\d%"
             ]

      assert BubbleEx.Target.Keywords.patterns("   ") == []
      assert BubbleEx.Target.Keywords.patterns(nil) == []
      many = Enum.map_join(1..2_000, " ", &"w#{&1}")
      assert length(BubbleEx.Target.Keywords.words(many)) == 32

      assert BubbleEx.Target.Keywords.words(String.duplicate("x", 300)) == [
               String.duplicate("x", 256)
             ]
    end

    test "not compiled outside a search, on a value that is not a text, or on words that are not",
         %{project: project} do
      item = IR.node(:this, [:filter_item], "custom.task")
      title = IR.node(:field, [item, "task", "title_text"], "text")
      estimate = IR.node(:field, [item, "task", "estimate_number"], "number")
      words = &IR.node(:text_contains_words, [&1, &2], "boolean")
      lit = &IR.node(:literal, [&1], &2)

      rule_title =
        IR.node(
          :field,
          [IR.node(:this, [:rule_record], "custom.task"), "task", "title_text"],
          "text"
        )

      assert {:ok, %{expr: nil, diagnostics: [diag]}} =
               Expressions.filter(words.(rule_title, lit.("a b", "text")), project,
                 resource: "task"
               )

      assert diag.details.constructs == ["contains keyword(s) outside a search"]

      for {ir, construct} <- [
            {words.(estimate, lit.("1", "text")),
             "contains keyword(s) on a value that is not a text"},
            {words.(title, lit.(1, "number")), "contains keyword(s) whose words are not a text"},
            {words.(
               title,
               IR.node(:current_user, [], "user")
               |> then(&IR.node(:field, [&1, "user", "name_text"], "text"))
             ), "contains keyword(s) whose words are not an input or a literal"}
          ] do
        search = IR.node(:search, ["task", ir], "list.custom.task")
        assert {:ok, %{expr: nil, diagnostics: [diag]}} = Expressions.search(search, project)
        assert %{code: :ash_expr_unsupported, details: %{constructs: [^construct]}} = diag
      end

      # A literal's words are compiled in.
      search = IR.node(:search, ["task", words.(title, lit.("a_b", "text"))], "list.custom.task")
      assert {:ok, %{expr: expr, diagnostics: []}} = Expressions.search(search, project)

      assert Source.expr(expr) =~
               ~S|ILIKE ALL (?::text[]), false)", ["%a\\_b%"], title, ["%a\\_b%"])|
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
