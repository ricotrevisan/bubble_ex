defmodule BubbleEx.Target.Ash.DecisionsCut3Test do
  # BubbleEx.Target.Ash applying owner decisions, cut 3 (WTF-406, WTF-352
  # §4.2): normalize_list_to_join (a join resource, shared by two mirrored
  # lists, with a position column) and membership_policy (the same join for
  # a list of users that privacy rules test), over the synthetic findings
  # export (test/support/samples/synthetic_findings_export.json, invented
  # data) taken through Findings -> Decision -> resolve -> applicable
  # (BubbleEx.Test.DecidedFixture). The per-set source goldens are checked
  # by BubbleEx.Target.Ash.DecisionsTest; the combined cut-3 Project and its
  # privacy: :unverified source here.
  #
  # Regenerate the goldens after an intended change with
  #
  #     BUBBLE_EX_UPDATE_GOLDEN=1 mix test test/bubble_ex/target/ash/decisions_cut3_test.exs
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Decision, Finding, Model}
  alias BubbleEx.Decision.Applied
  alias BubbleEx.Findings.Joins
  alias BubbleEx.Target.Ash
  alias BubbleEx.Target.Ash.{Aggregate, PolicyCheck, Project, Relationship, Source}
  alias BubbleEx.Test.DecidedFixture

  @golden "test/support/target/ash/golden/decisions"
  @sha String.duplicate("a", 64)
  @now ~U[2026-09-26 00:00:00Z]

  defp check_golden(path, actual) do
    if System.get_env("BUBBLE_EX_UPDATE_GOLDEN"), do: File.write!(path, actual)
    assert File.exists?(path), "missing golden #{path}; set BUBBLE_EX_UPDATE_GOLDEN=1"
    expected = File.read!(path)

    assert actual == expected or
             (String.ends_with?(path, ".ex.txt") and
                Version.compare(System.version(), "1.19.0") != :lt and
                reformat(actual) == reformat(expected))
  end

  defp reformat(source), do: source |> Code.format_string!() |> IO.iodata_to_binary()

  defp project!(set, opts \\ []) do
    {:ok, project} = DecidedFixture.project(set, opts)
    project
  end

  defp resource(project, type), do: Enum.find(project.resources, &(&1.source.type == type))

  defp attribute(project, type, field),
    do: Enum.find(resource(project, type).attributes, &(&1.source[:field] == field))

  defp relationship(project, type, field),
    do: Enum.find(resource(project, type).relationships, &(&1.source[:field] == field))

  defp join_of(project, type, field) do
    rel = relationship(project, type, field)
    Enum.find(project.joins, &(&1.module == rel.through))
  end

  defp map(model, applied, opts \\ []),
    do: Ash.map(model, applied, Keyword.put_new(opts, :decisions_sha256, @sha))

  defp message({:error, %BubbleEx.Error{kind: :invalid_input, message: message}}), do: message

  defp model, do: DecidedFixture.build(:join).model

  # The applicable entries of `choices` (`{kind, subject, choice, params}`)
  # over the export, with the hints rejected.
  defp applicable(choices, app \\ nil) do
    %{model: model, index: index, findings: findings} =
      if app, do: build(app), else: DecidedFixture.build(:join)

    records =
      for {kind, subject, choice, params} <- choices do
        finding = Enum.find(findings, &(&1.kind == kind and &1.subject == subject))
        assert finding, "no #{kind} finding on #{inspect(subject)}"
        {:ok, decision} = Decision.for_finding(finding, choice, params)
        decision
      end

    hints =
      for f <- findings, f.kind == :search_index do
        {:ok, reject} = Decision.for_finding(f, :reject)
        reject
      end

    {:ok, resolved} = Decision.resolve(records ++ hints, findings, index: index, now: @now)
    {model, Decision.applicable(resolved, findings), findings}
  end

  defp build(app) do
    {:ok, model} = Model.build(app)
    {:ok, index} = BubbleEx.Index.build(app, model: model)
    {:ok, %{findings: findings}} = BubbleEx.Findings.analyze(app, model: model, index: index)
    %{model: model, index: index, findings: findings}
  end

  defp applied_of(kind, type, field, params \\ %{}) do
    {_model, applied, _} =
      applicable([
        {kind, %{type: type, field: field}, if(params == %{}, do: :accept, else: :modify), params}
      ])

    Enum.find(applied, &(&1.subject == %{type: type, field: field}))
  end

  describe "goldens" do
    test "cut3 matches its golden Project" do
      json =
        project!(:cut3)
        |> Project.to_map()
        |> CanonicalJson.ordered()
        |> Jason.encode!(pretty: true)

      check_golden(Path.join(@golden, "cut3.project.json"), json <> "\n")
    end

    test "cut3 renders its golden source (privacy: :unverified)" do
      {:ok, source} = :cut3 |> project!(privacy: :unverified) |> Source.render()
      check_golden(Path.join(@golden, "cut3.unverified.ex.txt"), source)
    end
  end

  describe "normalize_list_to_join" do
    test "a list becomes a many_to_many through a join resource of its own, order kept" do
      {:ok, faithful} = Ash.map(model())
      project = project!(:join)
      locked = attribute(faithful, "project", "tasks_list_custom_task").name

      refute attribute(project, "project", "tasks_list_custom_task")

      assert %Relationship{
               kind: :many_to_many,
               name: ^locked,
               destination: "Task",
               through: "ProjectTasks",
               source_attribute: "id",
               source_attribute_on_join_resource: "project_id",
               destination_attribute_on_join_resource: "task_id",
               destination_attribute: "id",
               join_relationship: "tasks_join"
             } = relationship(project, "project", "tasks_list_custom_task")

      join = join_of(project, "project", "tasks_list_custom_task")
      assert join.table == "project_tasks"
      assert join.source == %{join: join.join.id}

      assert Enum.map(join.attributes, &{&1.name, &1.type, &1.primary_key?}) == [
               {"project_id", :string, true},
               {"task_id", :string, true},
               {"position", :integer, false}
             ]

      assert [%{method: :btree, columns: ["task_id"]}] = join.indexes

      assert [
               %{
                 type: "project",
                 field: "tasks_list_custom_task",
                 owner: :left,
                 position: "position"
               }
             ] =
               join.join.sides

      # the join's names are locked in the name map
      assert project.names["joins"][join.join.id] == %{
               "module" => "ProjectTasks",
               "table" => "project_tasks",
               "attributes" => %{
                 "left" => "project_id",
                 "right" => "task_id",
                 "project/tasks_list_custom_task" => "position"
               }
             }

      assert project.names["resources"]["project"]["join_relationships"] == %{
               "tasks_list_custom_task" => "tasks_join",
               "viewers_list_user" => "viewers_join"
             }

      {:ok, source} = Source.render(project)
      assert source =~ "many_to_many :tasks, MyApp.Task do"
      assert source =~ "through MyApp.ProjectTasks"
      assert source =~ "defmodule MyApp.ProjectTasks do"
      assert source =~ "resource MyApp.ProjectTasks"
      assert Project.summary(project)["joins"] == 2
    end

    test "two mirrored lists share one join, each with its own options" do
      project = project!(:join)
      join = join_of(project, "project", "viewers_list_user")
      assert join == join_of(project, "user", "favorites_list_custom_project")

      # Favorites named the join; Viewers dropped its order
      assert {join.module, join.table} == {"FavoriteProject", "favorite_project"}

      assert Enum.map(join.join.sides, &{&1.type, &1.owner, &1.position}) == [
               {"project", :left, nil},
               {"user", :right, "favorites_position"}
             ]

      assert %{
               source_attribute_on_join_resource: "user_id",
               destination_attribute_on_join_resource: "project_id"
             } =
               relationship(project, "user", "favorites_list_custom_project")

      diag =
        Enum.find(
          project.diagnostics,
          &(&1.code == :ash_decision_applied and
              &1.subject == %{type: "project", field: "viewers_list_user"})
        )

      assert diag.message =~ "shared with the mirrored list user.favorites_list_custom_project"
      assert diag.message =~ "order is not kept"
    end

    test "a list whose mirror no decision normalizes has a join of its own; the mirror stays stored" do
      {model, applied, findings} =
        applicable([
          {:list_relationship, %{type: "project", field: "viewers_list_user"}, :accept, %{}}
        ])

      {:ok, project} = map(model, applied)
      join = join_of(project, "project", "viewers_list_user")
      assert [%{type: "project", position: "viewers_position"}] = join.join.sides
      assert attribute(project, "user", "favorites_list_custom_project").type == {:array, :string}

      # the same join ID (and so the same table) when the mirror is decided later
      viewers =
        Enum.find(findings, &(&1.subject == %{type: "project", field: "viewers_list_user"}))

      assert join.join.id == viewers.proposal.join.id

      assert Enum.any?(
               project.diagnostics,
               &(&1.code == :ash_decision_applied and &1.message =~ "stays stored")
             )
    end

    test "counts over a normalized list are aggregates; index hints on it are deferred" do
      {model, applied, _} =
        applicable([
          {:list_relationship, %{type: "project", field: "tasks_list_custom_task"}, :accept, %{}}
        ])

      count =
        applied_finding(:denormalized_field, %{type: "project", field: "task_count_number"}, %{
          transform: :derive_count,
          field: "field:project/task_count_number",
          derivation: %{via: [], source_field: "field:project/tasks_list_custom_task"}
        })

      hint =
        %{
          applied_finding(:search_index, %{type: "project"}, %{
            transform: :add_indexes,
            type: "data_type:project",
            indexes: [
              %{columns: [%{field: "field:project/tasks_list_custom_task", access: :membership}]}
            ]
          })
          | automatic: true,
            basis: nil,
            decision_id: nil
        }

      {:ok, project} = map(model, applied ++ [count, hint])

      assert %Aggregate{path: ["tasks"]} =
               Enum.find(
                 resource(project, "project").aggregates,
                 &(&1.source.field == "task_count_number")
               )

      assert [%{indexes: [0]}] = project.deferred

      assert Enum.any?(
               project.diagnostics,
               &(&1.code == :ash_decision_deferred and &1.message =~ "normalized to a join")
             )
    end

    test "the normalized list cannot be renamed as an attribute" do
      {model, applied, _} =
        applicable([
          {:list_relationship, %{type: "project", field: "tasks_list_custom_task"}, :accept, %{}}
        ])

      rename = rename(%{type: "project", field: "tasks_list_custom_task"}, "attribute", "items")
      assert map(model, applied ++ [rename]) |> message() =~ "normalized to a join"
    end
  end

  describe "membership_policy" do
    test "a list of users that rules test becomes a membership join; the rules test it" do
      project = project!(:membership, privacy: :unverified)
      members = relationship(project, "workspace", "members_list_user")

      assert %Relationship{kind: :many_to_many, name: "members", through: "UserWorkspaces"} =
               members

      assert members.gate == {:visible_if, ["privacy_rule_member"]}

      member =
        Enum.find(
          resource(project, "workspace").calculations,
          &(&1.name == "privacy_rule_member")
        )

      assert Source.expr(member.expr) =~ "exists(members_for_privacy, id == ^actor(:id))"

      # a rule on another type reads it through its reference
      project_rule =
        Enum.find(
          resource(project, "project").calculations,
          &(&1.name == "privacy_rule_workspace_member")
        )

      assert Source.expr(project_rule.expr) =~
               "exists(workspace_for_privacy.members_for_privacy, id == ^actor(:id))"

      # no rule is denied
      refute Enum.any?(project.diagnostics, &(&1.code == :ash_policy_rule_denied))
    end

    test "join rows are readable only by an actor who may view the list on its owner" do
      project = project!(:cut3, privacy: :unverified)

      # Workspace's Members (its Member rule) shares its join with User's
      # Workspaces (public): a row needs both, so the Member rule
      join = join_of(project, "workspace", "members_list_user")
      calc = Enum.find(join.calculations, &(&1.name == "privacy_visible"))
      assert calc.expr.expr == {:ref, ["workspace"], "privacy_rule_member"}
      assert Enum.all?(join.relationships, &(not &1.public?))

      assert [
               %{permission: :keyed, checks: [%PolicyCheck{test: :keyed}]},
               %{
                 permission: :view,
                 checks: [%PolicyCheck{test: {:calculation, "privacy_visible"}}]
               }
             ] = join.policies

      assert [%{name: "read", keyed?: true}] = join.extra_actions

      # Project's Tasks: its Workspace member rule
      tasks = join_of(project, "project", "tasks_list_custom_task")

      assert Enum.find(tasks.calculations, &(&1.name == "privacy_visible")).expr.expr ==
               {:ref, ["project"], "privacy_rule_workspace_member"}

      # the private rows relationships the actor-side membership reads
      assert Enum.any?(
               resource(project, "workspace").privacy_relationships,
               &(&1.name == "user_workspaces_rows" and &1.destination == "UserWorkspaces")
             )

      {:ok, source} = Source.render(project)
      assert source =~ "authorize_if expr(privacy_visible)"
      assert Project.privacy_summary(project)["calculations"] > 0
    end

    test "with privacy: :omit the joins have no policies" do
      project = project!(:cut3)
      assert project.joins != []

      for join <- project.joins do
        assert join.policies == [] and join.calculations == []
        assert Enum.all?(join.relationships, & &1.public?)
      end
    end

    test "a rule testing the current user's normalized list reads the member's join rows" do
      app = DecidedFixture.app(:join)

      # Workspace: "Current User's Workspaces contains This Workspace"
      rule = %{
        "display" => "Listed",
        "condition" => %{
          "type" => "CurrentUser",
          "next" => %{
            "name" => "workspaces_list_custom_workspace",
            "type" => "Message",
            "next" => %{
              "name" => "contains",
              "type" => "Message",
              "args" => %{"type" => "InjectedValue"}
            }
          }
        },
        "permissions" => %{"view_all" => true, "search_for" => true}
      }

      app = put_in(app, ["user_types", "workspace", "privacy_role", "listed_"], rule)

      {model, applied, _} =
        applicable(
          [
            {:list_relationship, %{type: "user", field: "workspaces_list_custom_workspace"},
             :accept, %{}}
          ],
          app
        )

      {:ok, project} = map(model, applied, privacy: :unverified)

      calc =
        Enum.find(resource(project, "workspace").calculations, &(&1.source[:rule] == "listed_"))

      assert Source.expr(calc.expr) ==
               "expr(not is_nil(^actor(:id)) and exists(user_workspaces_rows, user_id == ^actor(:id)))"

      refute Enum.any?(project.diagnostics, &(&1.code == :ash_policy_rule_denied))

      # faithful: the same rule is membership in the actor's array
      {:ok, faithful} = map(model, [], privacy: :unverified)

      faithful_calc =
        Enum.find(resource(faithful, "workspace").calculations, &(&1.source[:rule] == "listed_"))

      assert Source.expr(faithful_calc.expr) =~ "id in ^actor(:workspaces)"
    end
  end

  describe "stale and forged decisions" do
    test "a decision recorded against another proposal is rejected" do
      a = applied_of(:list_relationship, "project", "tasks_list_custom_task")
      stale = %{a | basis: %{a.basis | proposal_sha256: String.duplicate("c", 64)}}
      assert map(model(), [stale]) |> message() =~ "stale"
    end

    test "a join whose ID, lists or types do not fit is rejected" do
      a = applied_of(:list_relationship, "project", "viewers_list_user")
      join = a.proposal.join

      forged = [
        # an ID that is not the hash of its lists
        put_in(a.proposal.join.id, "join:0000000000000000"),
        # a list that is not the subject's mirror
        put_in(
          a.proposal.join,
          %{
            join
            | fields: [
                "field:project/viewers_list_user",
                "field:user/pinned_tasks_list_custom_task"
              ]
          }
          |> then(&%{&1 | id: Joins.id(&1.fields)})
        ),
        # a join that does not include the subject
        put_in(
          a.proposal.join,
          %{join | fields: ["field:user/favorites_list_custom_project"]}
          |> then(&%{&1 | id: Joins.id(&1.fields)})
        ),
        # between other types
        put_in(a.proposal.join.between, ["data_type:project", "data_type:task"]),
        # no join at all
        %{a | proposal: Map.delete(a.proposal, :join)}
      ]

      for f <- forged do
        assert map(model(), [f]) |> message() =~ "join does not fit"
      end

      wrong_type = put_in(a.proposal.to_type, "data_type:task")
      assert map(model(), [wrong_type]) |> message() =~ "types are not the list's"
    end

    test "a stale proposal on a field that is no longer a list is rejected" do
      a = applied_of(:list_relationship, "project", "tasks_list_custom_task")

      app =
        put_in(
          DecidedFixture.app(:join),
          ["user_types", "project", "fields", "tasks_list_custom_task", "value"],
          "text"
        )

      {:ok, model} = Model.build(app)
      assert map(model, [a]) |> message() =~ "needs a list of a mapped data type"
    end

    test "a membership_policy on a list that is not of users, or with parameters, is rejected" do
      a = applied_of(:privacy_access_list, "workspace", "members_list_user")

      assert map(model(), [put_in(a.proposal.member_type, "data_type:task")]) |> message() =~
               "list of users"

      assert map(model(), [%{a | params: %{keep_order: false}}]) |> message() =~ "no parameters"
    end

    test "two decisions on one join must agree on its name" do
      viewers =
        applied_of(:list_relationship, "project", "viewers_list_user", %{"join_name" => "seen_by"})

      favorites =
        applied_of(:list_relationship, "user", "favorites_list_custom_project", %{
          "join_name" => "favorite_project"
        })

      assert map(model(), [viewers, favorites]) |> message() =~ "different names"
    end

    test "invalid parameters from a hand-built entry are rejected" do
      a = applied_of(:list_relationship, "project", "tasks_list_custom_task")
      assert map(model(), [put_in(a.proposal[:keep_order], "yes")]) |> message() =~ "keep_order"

      for name <- ["Tasks", "schema_migrations", "a b", "x\"; drop table project; --"] do
        assert map(model(), [put_in(a.proposal[:join_name], name)]) |> message() =~ "join_name"
      end
    end

    test "a subject missing from the Model is reported as such (the capability probe's contract)" do
      # bubble_wtf's Wtf.Migration.Capabilities maps an empty Model with one
      # well-formed decision per transform: a supported transform must stop
      # at the missing subject, never at its own proposal checks.
      {:ok, empty} = Model.build(%{"_id" => "capability-probe", "user_types" => %{}})
      subject = %{type: "capability_probe", field: "capability_probe"}

      for {kind, transform} <- [
            list_relationship: :normalize_list_to_join,
            privacy_access_list: :membership_policy
          ] do
        id = Finding.id(kind, subject)

        applied = %Applied{
          key: "finding:" <> id,
          kind: :finding,
          finding_id: id,
          transform: transform,
          subject: subject,
          proposal: %{transform: transform},
          params: %{},
          proposal_sha256: @sha,
          basis_sha256: @sha,
          basis: %{proposal_sha256: @sha, basis_sha256: @sha}
        }

        assert {:error, %{kind: :invalid_input, message: message, context: context}} =
                 Ash.map(empty, [applied], privacy: :omit, decisions_sha256: @sha)

        assert message =~ "subject is not in the Model"
        assert context.subject == subject
        refute Map.has_key?(context, :transform)
      end
    end
  end

  describe "names" do
    test "hostile names never reach the generated code unescaped" do
      app =
        DecidedFixture.app(:join)
        |> put_in(["user_types", "project", "display"], ~S|Proj"ect #{System.halt()} """|)
        |> put_in(
          ["user_types", "project", "fields", "tasks_list_custom_task", "display"],
          ~S|Tasks"); File.rm_rf!("/") #|
        )

      {model, applied, _} =
        applicable(
          [
            {:list_relationship, %{type: "project", field: "tasks_list_custom_task"}, :accept,
             %{}}
          ],
          app
        )

      {:ok, project} = map(model, applied, privacy: :unverified)
      {:ok, source} = Source.render(project)
      assert {:ok, _} = Code.string_to_quoted(source)
      refute source =~ "System.halt()"
      refute source =~ "File.rm_rf!"

      join = join_of(project, "project", "tasks_list_custom_task")
      assert BubbleEx.Target.Ash.Naming.valid?(:pascal, join.module)
      assert BubbleEx.Target.Ash.Naming.valid?(:snake, join.table)
    end

    test "a name map with an invalid join name is rejected" do
      for bad <- [
            %{"joins" => %{"join:x" => %{"module" => "Evil\"; System.halt()"}}},
            %{"joins" => %{"join:x" => %{"table" => "Evil Table"}}},
            %{"joins" => %{"join:x" => %{"attributes" => %{"left" => "a\"b"}}}},
            %{"resources" => %{"project" => %{"join_relationships" => %{"f" => "Bad"}}}}
          ] do
        assert {:error, %{kind: :invalid_input}} = Ash.map(model(), [], names: bad)
      end
    end

    test "a locked join keeps its names; a join and a resource never share one" do
      %{model: model, applied: applied, decisions_sha256: sha} = DecidedFixture.build(:join)
      {:ok, first} = Ash.map(model, applied, decisions_sha256: sha)
      join = join_of(first, "project", "tasks_list_custom_task")

      names =
        put_in(first.names, ["joins", join.join.id], %{
          "module" => "Chores",
          "table" => "chores",
          "attributes" => %{
            "left" => "owner_id",
            "right" => "chore_id",
            "project/tasks_list_custom_task" => "rank"
          }
        })

      {:ok, locked} = Ash.map(model, applied, decisions_sha256: sha, names: names)
      join = join_of(locked, "project", "tasks_list_custom_task")
      assert {join.module, join.table} == {"Chores", "chores"}
      assert Enum.map(join.attributes, & &1.name) == ["owner_id", "chore_id", "rank"]

      assert %{source_attribute_on_join_resource: "owner_id", through: "Chores"} =
               relationship(locked, "project", "tasks_list_custom_task")

      clash = put_in(first.names, ["joins", join.join.id, "module"], "Task")

      assert {:error, %{message: message}} =
               Ash.map(model, applied, decisions_sha256: sha, names: clash)

      assert message =~ "join and a resource"

      # a new resource never takes a locked join's module
      renamed = put_in(first.names, ["joins", join.join.id, "module"], "Workspace")
      renamed = update_in(renamed, ["resources"], &Map.delete(&1, "workspace"))
      {:ok, moved} = Ash.map(model, applied, decisions_sha256: sha, names: renamed)
      assert resource(moved, "workspace").module == "Workspace2"
    end
  end

  describe "the whole cut" do
    test "every cut-3 transform applies together, deterministically and stably" do
      %{model: model, applied: applied, decisions_sha256: sha} = DecidedFixture.build(:cut3)

      for privacy <- [:omit, :unverified] do
        opts = [decisions_sha256: sha, privacy: privacy]
        {:ok, project} = Ash.map(model, applied, opts)
        {:ok, again} = Ash.map(model, applied, opts)
        assert Project.to_json(project) == Project.to_json(again)

        names = project.names |> Jason.encode!() |> Jason.decode!()
        {:ok, locked} = Ash.map(model, applied, Keyword.put(opts, :names, names))
        assert Project.to_json(locked) == Project.to_json(project)

        assert Project.summary(project)["applied"] == %{
                 "membership_policy" => 1,
                 "normalize_list_to_join" => 4
               }

        assert length(project.joins) == 3
        {:ok, _source} = Source.render(project)
      end
    end
  end

  # A hand-built applied finding, consistent with itself (IDs and hashes).
  defp applied_finding(kind, subject, proposal) do
    id = Finding.id(kind, subject)
    hashes = %{proposal_sha256: @sha, basis_sha256: String.duplicate("b", 64)}

    struct!(
      Applied,
      Map.merge(hashes, %{
        key: "finding:" <> id,
        kind: :finding,
        decision_id: "dec_x",
        finding_id: id,
        transform: proposal.transform,
        subject: subject,
        proposal: proposal,
        basis: hashes
      })
    )
  end

  defp rename(subject, slot, name) do
    {:ok, decision} =
      Decision.new(
        kind: :rename,
        target: "ash",
        subject: subject,
        choice: :accept,
        params: %{slot: slot, name: name}
      )

    %Applied{
      key: decision.key,
      kind: :rename,
      transform: :rename,
      subject: subject,
      target: "ash",
      params: decision.params
    }
  end
end
