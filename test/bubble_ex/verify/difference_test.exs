defmodule BubbleEx.Verify.DifferenceTest do
  # The target policy and the per-case record of intended differences
  # (WTF-426): stricter than Bubble by the owner's decision.
  use ExUnit.Case, async: true

  alias BubbleEx.Expression.IR
  alias BubbleEx.Verify.{Difference, Observation}
  alias BubbleEx.Verify.Interpreter.Assumptions

  @seed %{id: "privacy_matrix", sha256: String.duplicate("a", 64)}

  defp case_(attrs) do
    struct!(
      Difference,
      Map.merge(
        %{
          scenario: "privacy_read.custom.board.anonymous",
          op: "get.e.board",
          kind: :visible,
          record: "e.board",
          type: "board",
          persona: "anonymous",
          bubble: true,
          target: false,
          flags: [:actor_empty_denies],
          rules: ["lead_"]
        },
        attrs
      )
    )
  end

  test "the policy: six flags, Bubble's reading and the target's, by scope" do
    rule_conditions = [
      :actor_empty_denies,
      :empty_yes_no_is_no,
      :everyone_exclusive,
      :everyone_guards_record_values,
      :logged_out_user_is_empty
    ]

    assert Difference.flags() == Enum.sort(rule_conditions ++ [:hidden_field_constraint_matches])
    assert Difference.flags(:rule_conditions) == rule_conditions
    assert Difference.flags(:search_constraints) == [:hidden_field_constraint_matches]

    assert %{bubble: false, target: true, direction: :stricter} =
             Difference.policy().actor_empty_denies

    # WTF-467: the 2026-10-01 replay flipped four flags in Bubble's
    # reading; the generated policies keep the stricter reading.
    for flag <- rule_conditions -- [:actor_empty_denies] do
      assert %{direction: :stricter, scope: :rule_conditions, decision: decision} =
               Difference.policy()[flag]

      assert decision =~ "WTF-467"
      assert Difference.policy()[flag].bubble == Assumptions.defaults()[flag]
      assert Difference.policy()[flag].target == Assumptions.target()[flag]
      assert Difference.policy()[flag].bubble != Difference.policy()[flag].target
    end

    # WTF-457: Bubble matches a constraint on a field the user may not
    # view; the enforced policies find only records where the user may.
    assert %{bubble: true, target: false, direction: :stricter, decision: decision} =
             Difference.policy().hidden_field_constraint_matches

    assert decision =~ "WTF-457"

    assert Difference.intended(Assumptions.defaults()) == Assumptions.target()
  end

  test "affected?/1: a condition reading the current user, or comparing a yes/no with other than yes" do
    this = IR.node(:this, [:rule_record], "custom.t")
    flag = IR.node(:field, [this, "custom.t", "done_boolean"], "boolean")
    no = IR.node(:literal, [false], "boolean")
    yes = IR.node(:literal, [true], "boolean")
    user = IR.node(:current_user, [], "user")
    owner = IR.node(:field, [this, "custom.t", "owner_user"], "user")

    refute Difference.affected?(nil)
    assert Difference.affected?(IR.node(:eq, [owner, user], "boolean"))
    # an empty yes/no is no in Bubble: `is no` holds there, not in the policies
    assert Difference.affected?(IR.node(:eq, [flag, no], "boolean"))
    assert Difference.affected?(IR.node(:not, [IR.node(:neq, [no, flag], "boolean")], "boolean"))
    refute Difference.affected?(IR.node(:eq, [flag, yes], "boolean"))
    refute Difference.affected?(flag)

    assert Difference.rule_flags(IR.node(:eq, [flag, no], "boolean")) == [:empty_yes_no_is_no]

    assert Difference.rule_flags(IR.node(:eq, [owner, user], "boolean")) ==
             [:actor_empty_denies, :logged_out_user_is_empty]
  end

  # WTF-471: `x is not no` reads an empty x as no in the policies too, as
  # Bubble does: neither stricter nor less strict, so not listed.
  test "rule_flags/1: `x is not no` matches Bubble; `x is no` stays stricter" do
    this = IR.node(:this, [:rule_record], "custom.t")
    flag = IR.node(:field, [this, "custom.t", "done_boolean"], "boolean")
    other = IR.node(:field, [this, "custom.t", "other_boolean"], "boolean")
    no = IR.node(:literal, [false], "boolean")
    yes = IR.node(:literal, [true], "boolean")

    for ir <- [
          IR.node(:neq, [flag, no], "boolean"),
          IR.node(:not, [IR.node(:eq, [flag, no], "boolean")], "boolean"),
          IR.node(:eq, [IR.node(:eq, [flag, no], "boolean"), no], "boolean"),
          IR.node(:neq, [flag, other], "boolean"),
          IR.node(:neq, [flag, yes], "boolean")
        ] do
      refute Difference.affected?(ir), inspect(ir)
      assert Difference.rule_flags(ir) == []
    end

    assert Difference.rule_flags(IR.node(:eq, [flag, no], "boolean")) == [:empty_yes_no_is_no]
    assert Difference.affected?(IR.node(:eq, [flag, other], "boolean"))
  end

  test "everyone_narrowed?/3: the everyone rule grants what some rule lacks" do
    perms = fn attrs ->
      Map.merge(%{view_all: false, view_fields: nil, search_for: false}, attrs)
    end

    fields = ["a", "b"]
    everyone = perms.(%{view_fields: ["a"]})

    refute Difference.everyone_narrowed?(nil, [nil], fields)
    refute Difference.everyone_narrowed?(perms.(%{}), [nil], fields)
    refute Difference.everyone_narrowed?(everyone, [perms.(%{view_all: true})], fields)
    assert Difference.everyone_narrowed?(everyone, [perms.(%{view_fields: ["b"]})], fields)
    assert Difference.everyone_narrowed?(everyone, [nil], fields)
    assert Difference.everyone_narrowed?(perms.(%{search_for: true}), [everyone], fields)
    # attachments and Data API grants count too
    assert Difference.everyone_narrowed?(perms.(%{view_attachments: true}), [nil], fields)
    assert Difference.everyone_narrowed?(perms.(%{delete_via_api: true}), [everyone], fields)

    refute Difference.everyone_narrowed?(
             perms.(%{create_via_api: true}),
             [perms.(%{create_via_api: true})],
             fields
           )

    # a listed field the type does not have is not granted
    refute Difference.everyone_narrowed?(perms.(%{view_fields: ["gone"]}), [nil], fields)
  end

  test "stricter?/3" do
    assert Difference.stricter?(:visible, true, false)
    refute Difference.stricter?(:visible, false, true)
    assert Difference.stricter?(:visible_fields, ["a", "b"], ["a"])
    refute Difference.stricter?(:visible_fields, ["a"], ["a", "b"])
    assert Difference.stricter?(:record_set, %{records: ["x", "y"]}, %{records: ["y"]})
    refute Difference.stricter?(:record_set, %{records: ["y"]}, %{records: ["x"]})
  end

  test "JSON round trip, and a record another library would not write is refused" do
    cases = [
      case_(%{}),
      case_(%{kind: :visible_fields, bubble: ["Created Date", "name_text"], target: []}),
      case_(%{
        op: "search",
        kind: :record_set,
        record: nil,
        bubble: %{ordered: false, records: ["e.board", "r.board.1"]},
        target: %{ordered: false, records: ["r.board.1"]}
      })
    ]

    json = Difference.to_json(cases, @seed)
    assert {:ok, %{seed: @seed, cases: decoded}} = Difference.from_json(json)
    assert decoded == Difference.sort(cases)

    doc = Jason.decode!(json)
    looser = put_in(doc, ["cases", Access.at(0), "target"], true)

    assert {:error, %{message: "a difference must be stricter than Bubble"}} =
             Difference.from_map(looser)

    other = put_in(doc, ["policy", "actor_empty_denies", "target"], false)
    assert {:error, _} = Difference.from_map(other)

    unknown = put_in(doc, ["cases", Access.at(0), "flags"], ["empty_equals_empty"])
    assert {:error, _} = Difference.from_map(unknown)
  end

  test "to_target/2 replaces only observations showing the Bubble value" do
    obs = [
      %Observation{op: "get.e.board", kind: :visible, record: "e.board", value: true},
      %Observation{op: "get.e.board", kind: :visible_fields, record: "e.board", value: ["x"]}
    ]

    [visible, fields] = Difference.to_target(obs, [case_(%{})])
    assert visible.value == false and fields.value == ["x"]

    # a recording that did not show what Bubble's reading predicts is kept
    assert Difference.to_target([%{hd(obs) | value: false}], [case_(%{})]) == [
             %{hd(obs) | value: false}
           ]
  end

  test "explaining/2 matches stricter diff entries within the case" do
    c = case_(%{kind: :visible_fields, bubble: ["a", "b"], target: ["a"]})
    entry = %{op: "field_visible", record: "e.board", field: "b", expected: true, actual: false}
    assert Difference.explaining([c], entry) == c
    assert Difference.explaining([c], %{entry | field: "a"}) == nil
    assert Difference.explaining([c], %{entry | expected: false, actual: true}) == nil
    assert %{intended: ["actor_empty_denies"], rules: ["lead_"]} = Difference.annotate(entry, c)
  end

  test "summary/1 is the owner's list per type and rule" do
    cases = [
      case_(%{}),
      case_(%{persona: "logged_in_empty", scenario: "privacy_read.custom.board.logged_in_empty"}),
      case_(%{type: "doc", rules: ["owner_", "everyone"]})
    ]

    assert [
             %{
               type: "board",
               rule: "lead_",
               observations: 2,
               personas: ["anonymous", "logged_in_empty"]
             },
             %{type: "doc", rule: "everyone", observations: 1},
             %{
               type: "doc",
               rule: "owner_",
               observations: 1,
               flags: [:actor_empty_denies],
               decision: d
             }
           ] = Difference.summary(cases)

    assert d =~ "stay stricter"
  end
end
