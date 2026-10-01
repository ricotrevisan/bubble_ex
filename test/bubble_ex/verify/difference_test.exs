defmodule BubbleEx.Verify.DifferenceTest do
  # The target policy and the per-case record of intended differences
  # (WTF-426): stricter than Bubble by the owner's decision.
  use ExUnit.Case, async: true

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

  test "the policy: two flags, Bubble's reading and the target's, by scope" do
    assert Difference.flags() == [:actor_empty_denies, :hidden_field_constraint_matches]
    assert Difference.flags(:rule_conditions) == [:actor_empty_denies]
    assert Difference.flags(:search_constraints) == [:hidden_field_constraint_matches]

    assert %{bubble: false, target: true, direction: :stricter} =
             Difference.policy().actor_empty_denies

    # WTF-457: Bubble matches a constraint on a field the user may not
    # view; the enforced policies find only records where the user may.
    assert %{bubble: true, target: false, direction: :stricter, decision: decision} =
             Difference.policy().hidden_field_constraint_matches

    assert decision =~ "WTF-457"

    assert Difference.intended(Assumptions.defaults()) == Assumptions.target()
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

    unknown = put_in(doc, ["cases", Access.at(0), "flags"], ["everyone_exclusive"])
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
