defmodule BubbleEx.Verify.InterpreterTest do
  # The privacy interpreter (WTF-382, V2 of WTF-358) against the two
  # hand-authored expectation tables the compiled Ash conditions and
  # policies are held to in PostgreSQL (scripts/ash_compile_check.sh, which
  # also compares the interpreter's verdicts with PostgreSQL directly), and
  # each assumption flag flipped.
  use ExUnit.Case, async: true

  alias BubbleEx.Expression.IR
  alias BubbleEx.Model
  alias BubbleEx.Test.{ExpressionFixture, PrivacyCrossCheck}
  alias BubbleEx.Verify.Interpreter
  alias BubbleEx.Verify.Interpreter.{Access, Assumptions, Dataset, Eval}

  @conditions "test/support/expression/expectations/privacy.json"
              |> File.read!()
              |> Jason.decode!()
  @policies "test/support/target/ash/expectations/policies.json"
            |> File.read!()
            |> Jason.decode!()
  @policy_app "test/support/target/ash/policies.json" |> File.read!() |> Jason.decode!()

  setup_all do
    model = ExpressionFixture.model()
    project = ExpressionFixture.project(model)
    {:ok, pmodel} = Model.build(@policy_app)
    {:ok, pproject} = BubbleEx.Target.Ash.map(pmodel, [], privacy: :unverified)

    %{
      model: model,
      ds: PrivacyCrossCheck.dataset(model, project, @conditions["records"]),
      pmodel: pmodel,
      pproject: pproject,
      pds: PrivacyCrossCheck.dataset(pmodel, pproject, @policies["records"])
    }
  end

  defp interpreter(model, overrides \\ []) do
    {:ok, interpreter} = Interpreter.new(model, assumptions: overrides)
    interpreter
  end

  defp holds(model, ds, user, type, rule, key, overrides \\ []) do
    case Interpreter.condition(interpreter(model, overrides), ds, user, type, rule, key) do
      {:ok, b, flags} -> {b, flags}
      other -> other
    end
  end

  describe "the condition expectation table (shared with the Ash and Elixir backends)" do
    test "every rule selects exactly the expected records for every actor", %{
      model: model,
      ds: ds
    } do
      interpreter = interpreter(model)

      for %{"type" => type, "rule" => rule, "expected" => expected} <- @conditions["cases"],
          {actor, ids} <- expected do
        user = if actor != "logged_out", do: actor

        selected =
          for key <- Dataset.keys(ds, type),
              {:ok, true, _} <- [Interpreter.condition(interpreter, ds, user, type, rule, key)],
              do: key

        assert Enum.sort(selected) == Enum.sort(ids), "#{type}/#{rule} as #{actor}"
      end
    end

    test "an unsupported rule is unknown, never true or false", %{model: model, ds: ds} do
      assert {:unknown, "not compiled: " <> _} =
               Interpreter.condition(interpreter(model), ds, "u1", "task", "m_raw_", "k1")

      assert {:unknown, "no such rule"} =
               Interpreter.condition(interpreter(model), ds, "u1", "task", "nope", "k1")
    end
  end

  describe "the policy expectation table (the generated Ash policies' reads)" do
    test "the interpreter agrees wherever it decides, and the policies deny where it cannot",
         %{pmodel: model, pproject: project, pds: ds} do
      interpreter = interpreter(model)

      outcomes =
        for %{"type" => type, "action" => action, "expected" => expected} <- @policies["reads"],
            action in ["get", "search"],
            {persona, want} <- expected do
          mine = PrivacyCrossCheck.reads(interpreter, project, ds, type, action, persona)
          {agree, disagree, unknown} = PrivacyCrossCheck.compare(mine, want)
          assert disagree == [], "#{type}.#{action} as #{persona}: #{inspect(disagree)}"
          {length(agree), length(unknown), type}
        end

      # agreeing entries (records either side shows) and undecided ones
      assert {Enum.sum(Enum.map(outcomes, &elem(&1, 0))),
              Enum.sum(Enum.map(outcomes, &elem(&1, 1)))} ==
               {80, 38}

      # Only the types with a deliberately uncompilable rule (raw_) are undecided.
      assert outcomes
             |> Enum.filter(&(elem(&1, 1) > 0))
             |> Enum.map(&elem(&1, 2))
             |> Enum.uniq()
             |> Enum.sort() ==
               ["doc", "memo"]
    end

    test "public types show everything to everyone", %{pmodel: model, pds: ds} do
      {:ok, access} = Interpreter.access(interpreter(model), ds, nil, "t1")
      assert %Access{visible: true, searchable: true, assumptions: []} = access
      assert "name_text" in access.fields and "Created Date" in access.fields
      refute "_id" in access.fields
    end

    test "a partly undecided record keeps what is known", %{pmodel: model, pds: ds} do
      # doc's raw_ (unsupported) grants view_all: title and body are known
      # (everyone, public_), the rest undecided.
      {:ok, access} = Interpreter.access(interpreter(model), ds, nil, "d2")
      assert access.visible == true
      assert access.fields == ["body_text", "title_text"]
      assert "secret_text" in access.unknown_fields
      refute Interpreter.determined?(access)
      assert access.reason =~ "raw_"
    end

    test "search lists the searchable records", %{pmodel: model, pds: ds} do
      assert {:ok, %{records: ["n1", "n2"], unknown: []}} =
               Interpreter.search(interpreter(model), ds, "u2", "note")

      # raw_ (unsupported) could make d1 and d3 searchable
      {:ok, docs} = Interpreter.search(interpreter(model), ds, nil, "doc")
      assert docs.records == ["d2", "d4"] and docs.unknown == ["d1", "d3"]
    end
  end

  describe "assumption flags (defaults: the compiler's fail-safe reading)" do
    test "the registry" do
      assert length(Assumptions.names()) == 15

      assert Assumptions.wtf_384() == [
               :empty_equals_empty,
               :empty_yes_no_is_no,
               :empty_list_contains_nothing,
               :dangling_ref_is_empty
             ]

      assert Assumptions.defaults().actor_empty_denies
      refute Assumptions.defaults().empty_yes_no_is_no
      assert {:ok, a} = Assumptions.new(empty_equals_empty: false)
      assert Assumptions.changed(a) == [:empty_equals_empty]
      assert {:error, %{kind: :invalid_input}} = Assumptions.new(nope: true)
      assert {:error, %{kind: :invalid_input}} = Assumptions.new(empty_equals_empty: :maybe)
      assert {:error, _} = Interpreter.new(ExpressionFixture.model(), assumptions: [nope: true])
    end

    test "actor_empty_denies: a logged-out user fails even a negated condition",
         %{model: model, ds: ds} do
      # o_no_access_: not(This's access contains Current User)
      assert {false, flags} = holds(model, ds, nil, "task", "o_no_access_", "k2")
      assert :actor_empty_denies in flags

      assert {true, _} =
               holds(model, ds, nil, "task", "o_no_access_", "k2", actor_empty_denies: false)
    end

    test "empty_equals_empty: two empty record values", %{model: model, ds: ds} do
      # s_same_team_: This's team is This's parent's team; k2's team is
      # empty and its parent is dangling.
      assert {true, flags} = holds(model, ds, "u1", "task", "s_same_team_", "k2")
      assert :empty_equals_empty in flags

      assert {false, _} =
               holds(model, ds, "u1", "task", "s_same_team_", "k2", empty_equals_empty: false)
    end

    test "empty_list_contains_nothing: doesn't contain on an empty record list",
         %{model: model, ds: ds} do
      assert {true, flags} = holds(model, ds, "u1", "task", "o_no_access_", "k2")
      assert :empty_list_contains_nothing in flags

      assert {false, _} =
               holds(model, ds, "u1", "task", "o_no_access_", "k2",
                 empty_list_contains_nothing: false
               )
    end

    test "dangling_ref_is_empty: is empty on a reference to a missing record",
         %{model: model, ds: ds} do
      # i_unfiled_: This's team is empty; k3's team is gone.
      assert {true, flags} = holds(model, ds, "u1", "task", "i_unfiled_", "k3")
      assert :dangling_ref_is_empty in flags

      assert {false, _} =
               holds(model, ds, "u1", "task", "i_unfiled_", "k3", dangling_ref_is_empty: false)
    end

    test "empty_yes_no_is_no: x is no on an empty yes/no", %{model: model, ds: ds} do
      this = IR.node(:this, [:rule_record], "custom.task")
      public = IR.node(:field, [this, "task", "public_boolean"], "boolean")
      is_no = IR.node(:eq, [public, IR.node(:literal, [false], "boolean")], "boolean")
      ctx = ctx(model, ds, "u1", "k2")

      assert {false, [:empty_yes_no_is_no]} = Eval.holds(is_no, true, ctx)
      {:ok, flipped} = Assumptions.new(empty_yes_no_is_no: true)
      assert {true, _} = Eval.holds(is_no, true, %{ctx | flags: flipped})
      # yes/no used as a condition: empty is not yes, in either reading
      assert {true, _} = Eval.holds(IR.node(:not, [public], "boolean"), true, ctx)
    end

    test "everyone_guards_record_values: the everyone grant needs the lacking rules' record values",
         %{pmodel: model, pds: ds} do
      # note: hidden_ (hidden is yes) grants nothing; everyone grants all.
      # n3's hidden is empty: the compiled negation denies.
      {:ok, access} = Interpreter.access(interpreter(model), ds, "u1", "n3")
      assert access.visible == false
      assert :everyone_guards_record_values in access.assumptions

      {:ok, flipped} =
        Interpreter.access(
          interpreter(model, everyone_guards_record_values: false),
          ds,
          "u1",
          "n3"
        )

      assert flipped.visible == true
    end

    test "everyone_exclusive: everyone applies only when no other rule matches",
         %{pmodel: model, pds: ds} do
      # n2 is hidden: for u1 hidden_ matches, so everyone does not apply.
      {:ok, access} = Interpreter.access(interpreter(model), ds, "u1", "n2")
      assert access.visible == false
      assert :everyone_exclusive in access.assumptions

      {:ok, flipped} =
        Interpreter.access(interpreter(model, everyone_exclusive: false), ds, "u1", "n2")

      assert flipped.visible == true and flipped.searchable == true
    end

    test "builtin_fields_hidden_unless_listed and no_visible_field_unreadable",
         %{pmodel: model, pds: ds} do
      # user: everyone views only name; u1 reading u2.
      {:ok, access} = Interpreter.access(interpreter(model), ds, "u1", "u2")
      assert access.fields == ["name_text"]
      assert :builtin_fields_hidden_unless_listed in access.assumptions

      {:ok, flipped} =
        Interpreter.access(
          interpreter(model, builtin_fields_hidden_unless_listed: false),
          ds,
          "u1",
          "u2"
        )

      assert "Created Date" in flipped.fields and "email" in flipped.fields
      refute "admin_boolean" in flipped.fields

      # board: everyone grants nothing; logged out sees no board.
      {:ok, board} = Interpreter.access(interpreter(model), ds, nil, "b1")
      assert board.visible == false and :no_visible_field_unreadable in board.assumptions

      {:ok, readable} =
        Interpreter.access(interpreter(model, no_visible_field_unreadable: false), ds, nil, "b1")

      assert readable.visible == true and readable.fields == []
    end

    test "absent_permission_denied: a flag the rule does not state" do
      app =
        update_in(
          @policy_app,
          ["user_types", "note", "privacy_role", "mine_", "permissions"],
          &Map.delete(&1, "search_for")
        )

      {:ok, model} = Model.build(app)
      {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :unverified)
      ds = PrivacyCrossCheck.dataset(model, project, @policies["records"])

      # n2: hidden, created by u2; only mine_ matches for u2.
      {:ok, access} = Interpreter.access(interpreter(model), ds, "u2", "n2")
      assert access.visible == true and access.searchable == false
      assert :absent_permission_denied in access.assumptions

      {:ok, flipped} =
        Interpreter.access(interpreter(model, absent_permission_denied: false), ds, "u2", "n2")

      assert flipped.searchable == true
    end

    test "a verdict lists only the assumptions whose flip changes it", %{pmodel: model, pds: ds} do
      # u3 is an admin: doc's admin_ grants everything, whatever the flags.
      {:ok, access} = Interpreter.access(interpreter(model), ds, "u3", "d1")
      assert access.visible and access.assumptions == []
    end
  end

  defp ctx(model, ds, user, this, flags \\ []) do
    {:ok, assumptions} = Assumptions.new(flags)
    %{ds: ds, user: user, logged_in: user != nil, this: this, flags: assumptions, model: model}
  end

  defp task_field(field, type),
    do: IR.node(:field, [IR.node(:this, [:rule_record], "custom.task"), "task", field], type)

  describe "assumption flags for unmodeled Bubble facts" do
    test "empty_text_contains_nothing: contains with an empty text", %{model: model, ds: ds} do
      # k3's title is empty; does it contain ""?
      ir =
        IR.node(
          :text_contains,
          [task_field("title_text", "text"), IR.node(:literal, [""], "text")],
          "boolean"
        )

      assert {false, [:empty_text_contains_nothing]} =
               Eval.holds(ir, true, ctx(model, ds, "u1", "k3"))

      assert {true, _} =
               Eval.holds(
                 ir,
                 true,
                 ctx(model, ds, "u1", "k3", empty_text_contains_nothing: false)
               )
    end

    test "ordering_with_empty_false: an empty number compared", %{model: model, ds: ds} do
      ir =
        IR.node(
          :gt,
          [task_field("estimate_number", "number"), IR.node(:literal, [-1], "number")],
          "boolean"
        )

      assert {false, [:ordering_with_empty_false]} =
               Eval.holds(ir, true, ctx(model, ds, "u1", "k2"))

      assert {false, _} = Eval.holds(ir, false, ctx(model, ds, "u1", "k2"))

      assert {true, _} =
               Eval.holds(ir, true, ctx(model, ds, "u1", "k2", ordering_with_empty_false: false))
    end

    test "empty_item_not_contained: doesn't contain an empty record item", %{model: model, ds: ds} do
      # k4: access [u1, u3], no assignee
      ir =
        IR.node(
          :member,
          [task_field("access_list_user", "list.user"), task_field("assignee_user", "user")],
          "boolean"
        )

      assert {true, [:empty_item_not_contained]} =
               Eval.holds(ir, false, ctx(model, ds, "u1", "k4"))

      assert {false, _} =
               Eval.holds(ir, false, ctx(model, ds, "u1", "k4", empty_item_not_contained: false))
    end

    test "logged_out_user_is_empty: Bubble's temporary user", %{model: model, ds: ds} do
      # p_not_owner_: This's Created By is not Current User; k1 was created by u1.
      assert {false, flags} = holds(model, ds, nil, "task", "p_not_owner_", "k1")
      assert :logged_out_user_is_empty in flags and :actor_empty_denies in flags

      assert {true, _} =
               holds(model, ds, nil, "task", "p_not_owner_", "k1",
                 logged_out_user_is_empty: false
               )

      # still logged out
      assert {false, _} =
               holds(model, ds, nil, "task", "d_public_", "k1", logged_out_user_is_empty: false)
    end

    test "search_independent_of_view: found in searches but not viewable" do
      app =
        update_in(
          @policy_app,
          ["user_types", "board", "privacy_role", "lead_", "permissions"],
          fn p ->
            Map.merge(p, %{"view_all" => false, "search_for" => true})
          end
        )

      {:ok, model} = Model.build(app)
      {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :unverified)
      ds = PrivacyCrossCheck.dataset(model, project, @policies["records"])

      {:ok, access} = Interpreter.access(interpreter(model), ds, "u1", "b1")
      assert access.visible == false and access.searchable == true
      assert :search_independent_of_view in access.assumptions

      {:ok, flipped} =
        Interpreter.access(interpreter(model, search_independent_of_view: false), ds, "u1", "b1")

      assert flipped.searchable == false
    end

    test "a condition used as a value reports its flags", %{model: model, ds: ds} do
      # This's public is (This's team is empty): k3's team is dangling
      ir =
        IR.node(
          :eq,
          [
            task_field("public_boolean", "boolean"),
            IR.node(:is_empty, [task_field("team_custom_team", "custom.team")], "boolean")
          ],
          "boolean"
        )

      assert {_, flags} = Eval.holds(ir, true, ctx(model, ds, "u1", "k3"))
      assert :dangling_ref_is_empty in flags
    end
  end

  describe "mutation and the everyone rule's reach" do
    test "observe/4 is the verdict; mutate/4 drops or negates a rule", %{pmodel: model, pds: ds} do
      interpreter = interpreter(model)
      {:ok, access} = Interpreter.access(interpreter, ds, "u2", "n2")

      assert Interpreter.observe(interpreter, ds, "u2", "n2") ==
               {access.visible, access.fields, access.unknown_fields, access.searchable}

      # n2 is hidden and u2's own: only mine_ shows it to u2
      assert {true, _, [], true} = Interpreter.observe(interpreter, ds, "u2", "n2")
      dropped = Interpreter.mutate(interpreter, "note", "mine_", :drop)
      assert {false, [], [], false} = Interpreter.observe(dropped, ds, "u2", "n2")
      negated = Interpreter.mutate(interpreter, "note", "mine_", :negate)
      assert {false, _, _, false} = Interpreter.observe(negated, ds, "u2", "n2")
      no_everyone = Interpreter.mutate(interpreter, "note", "everyone", :drop)
      assert {false, _, _, _} = Interpreter.observe(no_everyone, ds, "u1", "n1")
    end

    test "everyone_applies/5 computes what the verdicts use", %{pmodel: model, pds: ds} do
      interpreter = interpreter(model)
      # n2 is hidden: hidden_ holds
      refute Interpreter.everyone_applies(interpreter, ds, "u1", "note", "n2")
      # logged out: mine_ reads the user; its negation is guarded
      refute Interpreter.everyone_applies(interpreter, ds, nil, "note", "n1")

      # no guards, and the temporary user (who created nothing): it applies
      unguarded =
        interpreter(model,
          actor_empty_denies: false,
          everyone_guards_record_values: false,
          logged_out_user_is_empty: false
        )

      assert Interpreter.everyone_applies(unguarded, ds, nil, "note", "n1")
    end
  end

  test "deterministic, and errors for unknown input", %{pmodel: model, pds: ds} do
    interpreter = interpreter(model)

    for persona <- [nil, "u1", "u2", "u3", "u4"], key <- Dataset.keys(ds, "doc") do
      assert Interpreter.access(interpreter, ds, persona, key) ==
               Interpreter.access(interpreter, ds, persona, key)
    end

    assert {:error, %{kind: :invalid_input}} = Interpreter.access(interpreter, ds, nil, "missing")
    assert {:error, %{kind: :invalid_input}} = Interpreter.new(:not_a_model)
  end

  test "unsupported constructs are named" do
    this = IR.node(:this, [:filter_item], "custom.task")
    assert {:error, "This Thing as filter_item"} = Eval.supported(this)

    assert {:error, "search"} =
             Eval.supported(IR.node(:search, ["task", nil], "list.custom.task"))

    assert {:error, "an option of s with no stored key"} =
             Eval.supported(IR.node(:option, ["s", "v", nil], "option.s"))
  end
end
