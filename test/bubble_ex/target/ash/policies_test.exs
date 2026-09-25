defmodule BubbleEx.Target.Ash.PoliciesTest do
  # Privacy rules to Ash policies (WTF-356), over the policy fixture
  # (test/support/target/ash/policies.json) and the expression fixture. That
  # the policies compile and select what a hand-authored table expects is
  # checked by scripts/ash_compile_check.sh (policies.exs). All data is
  # invented.
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model}
  alias BubbleEx.Target.Ash

  alias BubbleEx.Target.Ash.{
    Action,
    Bypass,
    Calculation,
    FieldPolicy,
    Policy,
    PolicyCheck,
    Project,
    ResourcePrivacy,
    Source
  }

  @policies "test/support/target/ash/policies.json"
  @expressions "test/support/expression/app.json"

  defp load(path), do: path |> File.read!() |> Jason.decode!()

  defp project!(app, opts \\ []) do
    {:ok, model} = Model.build(app)
    {:ok, project} = Ash.map(model, [], opts)
    project
  end

  defp resource(project, type), do: Enum.find(project.resources, &(&1.source.type == type))

  defp policy(resource, action),
    do:
      Enum.find(
        resource.policies,
        &(&1.action == action and is_nil(&1.changing) and &1.permission != :keyed)
      )

  defp tests(checks), do: Enum.map(checks, &{&1.kind, &1.test})

  defp codes(project, subject),
    do:
      for(d <- project.diagnostics, d.stage == {:target, :ash}, d.subject == subject, do: d.code)

  defp calc(resource, name), do: Enum.find(resource.calculations, &(&1.name == name))

  setup_all do
    app = load(@policies)
    {:ok, index} = Index.build(app)
    %{app: app, project: project!(app, index: index)}
  end

  describe "safety gate" do
    test "policies are marked unverified in the Project, the diagnostics and the source",
         %{project: project} do
      assert project.policies_verified == false
      assert :ash_policies_unverified in codes(project, %{})

      {:ok, source} = Source.render(project)
      assert source =~ "NOT VERIFIED AGAINST BUBBLE: do not ship these policies"
      assert source =~ "def verified?, do: false"
      assert source =~ "authorizers: [Ash.Policy.Authorizer]"
    end

    test "the JSON form carries the flag", %{project: project} do
      assert Project.to_map(project)["policies_verified"] == false
    end
  end

  describe "reads" do
    test "rules combine by union; search and direct view are separate policies",
         %{project: project} do
      doc = resource(project, "doc")

      assert Enum.any?(doc.extra_actions, &match?(%Action{type: :read, name: "search"}, &1))

      assert Enum.any?(
               doc.extra_actions,
               &match?(%Action{type: :read, name: "read", primary?: true, keyed?: true}, &1)
             )

      refute :read in doc.actions

      # Every rule and the everyone rule grant some field: direct view.
      assert tests(policy(doc, "read").checks) == [authorize_if: :always]

      assert tests(policy(doc, "search").checks) == [
               authorize_if: {:calculation, "privacy_rule_admin"},
               authorize_if: {:calculation, "privacy_rule_owner"},
               authorize_if: {:calculation, "privacy_rule_public"}
             ]

      assert %Calculation{expr: %{expr: {:op, "==", {:ref, [], "owner_id"}, {:actor, ["id"]}}}} =
               calc(doc, "privacy_rule_owner")
    end

    test "a type without rules gets Bubble's public defaults", %{project: project} do
      team = resource(project, "team")
      assert team.privacy.source == :public_default
      assert tests(policy(team, "read").checks) == [authorize_if: :always]
      assert tests(policy(team, "search").checks) == [authorize_if: :always]

      assert [%FieldPolicy{checks: [%PolicyCheck{kind: :authorize_if, test: :always}]}] =
               team.field_policies

      refute Enum.any?(team.extra_actions, &(&1.name == "auto_bind"))
      assert team.calculations == []
    end

    test "a type whose rules the source lacks denies every read" do
      project = project!(load("test/support/model/live_payload.json"))

      for resource <- project.resources do
        assert resource.privacy.source == :unavailable
        assert tests(policy(resource, "read").checks) == [forbid_if: :always]
        assert tests(policy(resource, "search").checks) == [forbid_if: :always]
        assert :ash_privacy_rules_unavailable in codes(project, %{type: resource.source.type})
      end
    end
  end

  describe "the everyone rule" do
    test "grants to users no other rule matches, as a fail-safe negation", %{project: project} do
      note = resource(project, "note")

      assert tests(policy(note, "read").checks) == [
               authorize_if: {:calculation, "privacy_rule_mine"},
               authorize_if: {:calculation, "privacy_everyone_else"}
             ]

      # Negated, and only for notes whose hidden is known (fail-safe).
      assert %Calculation{
               source: %{type: "note", except_rules: ["hidden_"]},
               expr: %{
                 expr:
                   {:and,
                    [
                      {:call, "is_distinct_from", [{:ref, [], "hidden"}, {:value, true}]},
                      {:not, {:call, "is_nil", [{:ref, [], "hidden"}]}}
                    ]}
               }
             } = calc(note, "privacy_everyone_else")

      assert :ash_policy_default_rule_negated in codes(project, %{type: "note", rule: "everyone"})
    end

    test "a grant that needs an uncompilable rule negated is denied", %{project: project} do
      memo = resource(project, "memo")
      assert tests(policy(memo, "read").checks) == [forbid_if: :always]
      assert tests(policy(memo, "search").checks) == [forbid_if: :always]

      assert Enum.all?(memo.field_policies, &(tests(&1.checks) == [forbid_if: :always]))
      assert :ash_policy_default_grant_denied in codes(project, %{type: "memo", rule: "everyone"})
    end
  end

  describe "fields" do
    test "per-field visibility is the union of the rules showing each field",
         %{project: project} do
      doc = resource(project, "doc")

      by_field =
        for fp <- doc.field_policies, f <- fp.fields, into: %{}, do: {f, tests(fp.checks)}

      assert by_field["title"] == [authorize_if: :always]

      assert by_field["body"] == [
               authorize_if: {:calculation, "privacy_rule_admin"},
               authorize_if: {:calculation, "privacy_rule_owner"},
               authorize_if: {:calculation, "privacy_rule_public"}
             ]

      for field <- ~w(secret attachment owner_id public created_date creator_id) do
        assert by_field[field] == [
                 authorize_if: {:calculation, "privacy_rule_admin"},
                 authorize_if: {:calculation, "privacy_rule_owner"}
               ],
               field
      end

      # Every attribute but the primary key has exactly one field policy.
      fields = for fp <- doc.field_policies, f <- fp.fields, do: f

      assert Enum.sort(fields) ==
               Enum.sort(for a <- doc.attributes, not a.primary_key?, do: a.name)
    end

    test "unmapped fields in a rule's list are ignored and diagnosed", %{project: project} do
      assert :ash_policy_field_unmapped in codes(project, %{type: "doc", rule: "public_"})
    end

    test "a reference some users may not view is gated, with a private twin",
         %{project: project} do
      doc = resource(project, "doc")
      owner = Enum.find(doc.relationships, &(&1.name == "owner"))
      assert owner.gate == {:visible_if, ["privacy_rule_admin", "privacy_rule_owner"]}

      assert [%{name: "owner_for_privacy", public?: false, gate: nil}] =
               Enum.filter(doc.privacy_relationships, &(&1.source.field == "owner_user"))

      # Public-default types need no gate.
      assert Enum.all?(resource(project, "team").relationships, &is_nil(&1.gate))

      {:ok, source} = Source.render(project)
      assert source =~ "filter expr(parent(privacy_rule_admin or privacy_rule_owner))"
      assert source =~ "private_fields :hide"
      assert source =~ "authorize_if MyApp.Privacy.KeyedRead"

      assert %{checks: [%PolicyCheck{kind: :authorize_if, test: :keyed}]} =
               Enum.find(resource(project, "doc").policies, &(&1.permission == :keyed))

      assert source =~ "use Ash.Policy.SimpleCheck"

      # Ash does not apply field policies to relationship-path sorts.
      assert Enum.all?(project.resources, fn r ->
               Enum.all?(r.relationships ++ r.privacy_relationships, &(&1.sortable? == false))
             end)
    end

    test "aggregates over hidden fields are diagnosed", %{project: project} do
      assert :ash_policy_aggregates_unguarded in codes(project, %{type: "doc"})
      refute :ash_policy_aggregates_unguarded in codes(project, %{type: "team"})
    end

    test "calculations and actor loads read through the twins", %{project: project} do
      board = resource(project, "board")

      assert [
               %Calculation{
                 expr: %{expr: {:op, "==", _, {:actor, ["team_for_privacy", "lead_id"]}}}
               }
             ] =
               board.calculations

      assert project.actor_loads == [["team_for_privacy"]]
    end
  end

  describe "fail-safe" do
    test "an uncompilable condition grants nothing", %{project: project} do
      doc = resource(project, "doc")
      assert doc.privacy.denied_rules == ["raw_"]
      assert doc.privacy.compiled_rules == ["admin_", "owner_", "public_"]
      refute Enum.any?(doc.calculations, &(&1.source[:rule] == "raw_"))
      assert :ash_policy_rule_denied in codes(project, %{type: "doc", rule: "raw_"})
    end
  end

  describe "auto-binding" do
    test "an :auto_bind update with a policy per bindable field", %{project: project} do
      doc = resource(project, "doc")

      assert %Action{type: :update, name: "auto_bind", accept: ["body", "secret", "title"]} =
               Enum.find(doc.extra_actions, &(&1.name == "auto_bind"))

      assert tests(policy(doc, "auto_bind").checks) == [
               authorize_if: {:calculation, "privacy_rule_admin"},
               authorize_if: {:calculation, "privacy_rule_owner"}
             ]

      per_field =
        for %Policy{action: "auto_bind", changing: [field]} = p <- doc.policies,
            into: %{},
            do: {field, tests(p.checks)}

      assert per_field == %{
               "body" => [authorize_if: {:calculation, "privacy_rule_owner"}],
               "secret" => [authorize_if: {:calculation, "privacy_rule_admin"}],
               "title" => [authorize_if: {:calculation, "privacy_rule_owner"}]
             }
    end
  end

  describe "attachments, Data API and bypasses" do
    test "view attachments is data plus a diagnostic", %{project: project} do
      doc = resource(project, "doc")
      assert %ResourcePrivacy{file_fields: ["attachment"]} = doc.privacy
      assert length(doc.privacy.attachments) == 2
      assert :ash_policy_attachments_unenforced in codes(project, %{type: "doc"})
    end

    test "the Data API is data plus a diagnostic, with no actions", %{project: project} do
      doc = resource(project, "doc")
      assert doc.privacy.data_api.exposed == true

      assert tests(doc.privacy.data_api.modify) == [
               authorize_if: {:calculation, "privacy_rule_owner"}
             ]

      assert tests(doc.privacy.data_api.delete) == [
               authorize_if: {:calculation, "privacy_rule_admin"}
             ]

      assert tests(doc.privacy.data_api.create) == [forbid_if: :always]
      assert :ash_policy_data_api_unmapped in codes(project, %{type: "doc"})
    end

    test "workflows ignoring privacy rules become bypass requirements", %{project: project} do
      assert project.authorization_bypasses == [
               %Bypass{workflow: "wSweep", own: true, types: ["doc"]}
             ]

      assert :ash_policy_bypass_required in codes(project, %{workflow: "wSweep"})
    end

    test "no index, no bypasses", %{app: app} do
      assert project!(app).authorization_bypasses == []
    end
  end

  describe "actor loads" do
    test "the relationships the calculations read are listed and rendered" do
      project = project!(load(@expressions))

      assert project.actor_loads == [
               ["active_membership_for_privacy"],
               ["active_membership_for_privacy", "team_for_privacy"]
             ]

      {:ok, source} = Source.render(project)

      assert source =~
               "def actor_loads, do: [active_membership_for_privacy: [team_for_privacy: []]]"

      assert source =~ "Ash.get(MyApp.User, id, load: actor_loads(), authorize?: false)"
    end
  end

  describe "names" do
    test "rule calculation names are locked by the name map", %{app: app, project: project} do
      assert get_in(project.names, ["resources", "doc", "privacy_rules", "owner_"]) ==
               "privacy_rule_owner"

      renamed = put_in(app, ["user_types", "doc", "privacy_role", "owner_", "display"], "Author")
      assert calc(resource(project!(renamed), "doc"), "privacy_rule_author")

      locked = project!(renamed, names: project.names)
      assert calc(resource(locked, "doc"), "privacy_rule_owner").source.rule == "owner_"
    end
  end

  test "summary counts", %{project: project} do
    assert %{
             "resources" => %{"rules" => 5, "public_default" => 1},
             "rules" => %{"compiled" => 7, "denied" => 2},
             "auto_bind_actions" => 1,
             "authorization_bypasses" => 1
           } = Project.privacy_summary(project)
  end
end
