defmodule BubbleEx.FindingsTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{Error, Finding, Findings, Index, SampleHelper}

  # An invented app: workspaces with members and projects, projects with
  # tasks. See the fixture for the workflows each finding is about.
  @app SampleHelper.load_json_sample("synthetic_findings_export")

  setup_all do
    {:ok, result} = Findings.analyze(@app)
    %{result: result, findings: result.findings}
  end

  defp find(findings, kind, type, field),
    do: Enum.find(findings, &(&1.kind == kind and &1.subject == %{type: type, field: field}))

  defp subjects(findings, kind),
    do: for(%{kind: ^kind, subject: s} <- findings, do: {s.type, s.field})

  defp subjects_by_type(findings, kind),
    do: for(%{kind: ^kind, subject: s} <- findings, do: s.type)

  describe ":redundant_reverse_list" do
    test "a list kept in sync by the workflow that sets the reference back", %{findings: fs} do
      f = find(fs, :redundant_reverse_list, "workspace", "projects_list_custom_project")

      assert f.confidence == :high
      assert f.category == :decision
      assert f.path == "/user_types/workspace/fields/projects_list_custom_project"

      assert f.proposal == %{
               transform: :derive_reverse_relationship,
               drop_field: "field:workspace/projects_list_custom_project",
               relationship: %{
                 source_type: "data_type:project",
                 via: "field:project/workspace_custom_workspace",
                 cardinality: :many
               },
               remove_writes: [
                 %{
                   action: "action:aAddToWorkspace",
                   field: "field:workspace/projects_list_custom_project"
                 }
               ],
               maintaining_workflows: ["workflow:wCreateProject"],
               rewrite_reads: ["element:eProjectCount"]
             }

      assert "field:project/workspace_custom_workspace" in f.evidence.symbols
      assert f.affects.maintainers.workflows == ["workflow:wCreateProject"]
      assert f.affects.readers.pages == ["page:pHome"]
      assert f.affects.readers.workflows == []
    end

    test "not for uncoupled lists, nor for several lists mirroring one reference", %{
      findings: fs
    } do
      # Project's Tasks: no workflow adding tasks sets Task's Project.
      # User's Pinned and Starred tasks: both mirror Task's Assignee, so each
      # is a filtered subset; they stay list findings.
      assert subjects(fs, :redundant_reverse_list) == [
               {"workspace", "projects_list_custom_project"}
             ]

      assert find(fs, :list_relationship, "user", "pinned_tasks_list_custom_task")
      assert find(fs, :list_relationship, "user", "starred_tasks_list_custom_task")
    end
  end

  describe ":denormalized_field" do
    test "a copy of a related record, kept in sync by updates", %{findings: fs} do
      f = find(fs, :denormalized_field, "project", "sort_workspace_name_text")

      assert f.confidence == :high
      assert f.proposal.transform == :derive_from_related

      assert f.proposal.derivation == %{
               via: ["field:project/workspace_custom_workspace"],
               source_field: "field:workspace/name_text"
             }

      assert f.proposal.remove_writes ==
               for(
                 a <- ~w(aCreateProject aSyncName aSyncNotify aSyncOnly),
                 do: %{action: "action:" <> a, field: "field:project/sort_workspace_name_text"}
               )

      assert f.proposal.alternatives == []
      assert f.evidence.writes == %{total: 4, traced: 4}

      assert f.affects.maintainers.workflows ==
               ~w(workflow:wCreateProject workflow:wRenameSync workflow:wSyncNotify workflow:wSyncOnly)
    end

    test "deletes only workflows whose every action is a removable copy", %{findings: fs} do
      f = find(fs, :denormalized_field, "project", "sort_workspace_name_text")

      # wSyncOnly only copies. wSyncNotify also writes Summary and schedules
      # wSyncOnly; wRenameSync also writes Backup Title; wCreateProject
      # creates the project. The schedule of wSyncOnly must go with it.
      assert f.proposal.delete_workflows == ["workflow:wSyncOnly"]
      assert f.proposal.remove_calls == ["action:aNotify"]
    end

    test "a copy of a source that never changes is high even on creation only", %{
      findings: fs
    } do
      f = find(fs, :denormalized_field, "project", "workspace_created_date")

      assert f.confidence == :high
      assert f.confidence_reason =~ "never changes"
      assert f.proposal.derivation.source_field == "field:workspace/Created Date"
    end

    test "not for partially traced fields, formatted text, parameters, same-record copies or unique IDs",
         %{findings: fs} do
      # Summary: one copy and one literal. Task Count: a count, a literal 0
      # and a decrement. Both are owned data.
      assert subjects(fs, :denormalized_field) == [
               {"project", "sort_workspace_name_text"},
               {"project", "workspace_created_date"}
             ]
    end
  end

  describe ":list_relationship" do
    test "a list of things grown by add/remove is a join", %{findings: fs} do
      f = find(fs, :list_relationship, "project", "tasks_list_custom_task")

      assert f.confidence == :high

      assert f.proposal == %{
               transform: :normalize_list_to_join,
               field: "field:project/tasks_list_custom_task",
               from_type: "data_type:project",
               to_type: "data_type:task",
               join: %{
                 id: f.proposal.join.id,
                 between: ["data_type:project", "data_type:task"],
                 fields: ["field:project/tasks_list_custom_task"],
                 basis: :single
               },
               source_order: :preserved,
               source_limit: 10_000
             }

      assert f.message =~ "10,000"
      assert f.related == []
    end

    test "both sides of one many-to-many share one join and are related", %{findings: fs} do
      favorites = find(fs, :list_relationship, "user", "favorites_list_custom_project")
      viewers = find(fs, :list_relationship, "project", "viewers_list_user")

      assert favorites.proposal.join == viewers.proposal.join

      assert favorites.proposal.join.fields == [
               "field:project/viewers_list_user",
               "field:user/favorites_list_custom_project"
             ]

      assert favorites.proposal.join.basis == :coupled
      assert favorites.related == [viewers.id]
      assert viewers.related == [favorites.id]
    end

    test "not for unused lists or lists another finding already models", %{findings: fs} do
      # Project's Legacy tasks is unused; Workspace's Projects is a reverse
      # list and its Members an access list.
      assert subjects(fs, :list_relationship) == [
               {"project", "tasks_list_custom_task"},
               {"project", "viewers_list_user"},
               {"user", "favorites_list_custom_project"},
               {"user", "pinned_tasks_list_custom_task"},
               {"user", "starred_tasks_list_custom_task"},
               {"user", "workspaces_list_custom_workspace"}
             ]
    end
  end

  describe ":privacy_access_list" do
    test "a list of users that rules test for the current user, also through a reference", %{
      findings: fs
    } do
      f = find(fs, :privacy_access_list, "workspace", "members_list_user")

      assert f.confidence == :high

      assert f.proposal.checks == [
               %{
                 rule: "privacy_rule:project/workspace_member_",
                 membership_test: true,
                 via: ["field:project/workspace_custom_workspace"]
               },
               %{rule: "privacy_rule:workspace/member_", membership_test: true, via: []}
             ]

      assert f.affects.readers.privacy_rules == [
               "privacy_rule:project/workspace_member_",
               "privacy_rule:workspace/member_"
             ]

      assert f.affects.maintainers.workflows == ["workflow:wJoinWorkspace"]
    end

    test "shares its membership join with the user's mirrored list", %{findings: fs} do
      members = find(fs, :privacy_access_list, "workspace", "members_list_user")
      workspaces = find(fs, :list_relationship, "user", "workspaces_list_custom_workspace")

      assert members.proposal.join == workspaces.proposal.join
      assert members.related == [workspaces.id]
      assert workspaces.related == [members.id]
    end

    test "not for a list of users no rule reads", %{findings: fs} do
      assert subjects(fs, :privacy_access_list) == [{"workspace", "members_list_user"}]
    end
  end

  describe ":id_in_text" do
    test "text written from a unique ID", %{findings: fs} do
      f = find(fs, :id_in_text, "project", "owner_id_text")

      assert f.confidence == :high

      assert f.proposal == %{
               transform: :text_to_reference,
               field: "field:project/owner_id_text",
               target_type: "data_type:user",
               cardinality: :one
             }
    end

    test "text compared with a unique ID in a search", %{findings: fs} do
      f = find(fs, :id_in_text, "project", "legacy_task_id_text")

      assert f.confidence == :medium
      assert f.proposal.target_type == "data_type:task"
      assert f.affects.readers.workflows == ["workflow:wFavorite"]
    end

    test "not for literals, or IDs whose type is unknown (possibly external)", %{findings: fs} do
      assert subjects(fs, :id_in_text) == [
               {"project", "legacy_task_id_text"},
               {"project", "owner_id_text"}
             ]
    end
  end

  describe ":search_index" do
    test "one hint per data type, with access patterns only", %{findings: fs} do
      f = Enum.find(fs, &(&1.kind == :search_index and &1.subject == %{type: "project"}))

      assert f.category == :hint
      assert f.confidence == :medium
      assert f.path == "/user_types/project"
      assert f.affects.readers.pages == ["page:pHome"]

      col = &%{field: "field:project/" <> &1, access: &2}

      assert f.proposal == %{
               transform: :add_indexes,
               type: "data_type:project",
               indexes: [
                 %{
                   columns: [col.("location_geographic_address", :geo)],
                   operators: ["geographic_search"],
                   searches: 1
                 },
                 %{
                   columns: [col.("title_text", :full_text)],
                   operators: [:text_contains],
                   searches: 1
                 },
                 %{
                   columns: [col.("title_text", :substring)],
                   operators: [:text_contains_string],
                   searches: 1
                 },
                 %{
                   columns: [
                     col.("workspace_custom_workspace", :equality),
                     col.("title_text", :sort)
                   ],
                   operators: [:equals, :sort],
                   searches: 1
                 }
               ]
             }
    end

    test "skips standalone indexes targets add anyway or rarely need", %{findings: fs} do
      # Task: `Done = yes` alone and a Created Date sort alone are dropped;
      # the Project search on Workspace alone is served by the foreign key.
      task = Enum.find(fs, &(&1.kind == :search_index and &1.subject == %{type: "task"}))

      assert task.proposal.indexes == [
               %{
                 columns: [%{field: "field:task/points_number", access: :range}],
                 operators: [:greater_than],
                 searches: 1
               }
             ]

      assert subjects_by_type(fs, :search_index) == ["project", "task"]
    end
  end

  describe ":number_type" do
    test "counts, integer literals and increments", %{findings: fs} do
      f = find(fs, :number_type, "project", "task_count_number")

      assert f.confidence == :high

      assert f.proposal == %{
               transform: :refine_number_type,
               field: "field:project/task_count_number",
               from: :number,
               to: :integer
             }

      assert f.evidence.writes == %{count: 1, increment: 1, literal: 1}
      assert find(fs, :number_type, "task", "points_number").confidence == :high
    end

    test "not for division or input values", %{findings: fs} do
      assert subjects(fs, :number_type) == [
               {"project", "task_count_number"},
               {"task", "points_number"}
             ]
    end
  end

  describe "determinism" do
    test "same app, same JSON", %{result: result} do
      {:ok, again} = Findings.analyze(@app)
      assert Jason.encode!(Findings.to_map(again)) == Jason.encode!(Findings.to_map(result))
    end

    test "findings are normalized and every ID is unique", %{findings: fs} do
      assert Finding.normalize(fs) == fs
      assert fs |> Enum.map(& &1.id) |> Enum.uniq() |> length() == length(fs)
    end

    test "IDs and proposals survive renames and moved definitions", %{findings: fs} do
      {:ok, moved} = @app |> rename_everything() |> move_workflows() |> Findings.analyze()

      assert stable(moved.findings) == stable(fs)
      assert Enum.map(moved.findings, & &1.proposal_sha256) == Enum.map(fs, & &1.proposal_sha256)
      # The inputs really differ: names and source paths changed.
      refute Enum.map(moved.findings, & &1.message) == Enum.map(fs, & &1.message)
      refute paths(moved.findings) == paths(fs)
    end

    test "unrelated additions change nothing", %{result: result} do
      app =
        @app
        |> put_in(["user_types", "zz_note"], %{
          "display" => "Note",
          "fields" => %{"body_text" => %{"display" => "Body", "value" => "text"}}
        })
        |> put_in(["api", "wfUnrelated"], %{
          "id" => "wUnrelated",
          "type" => "APIEvent",
          "properties" => %{"wf_name" => "unrelated"},
          "actions" => %{
            "0" => %{
              "id" => "aUnrelated",
              "type" => "NewThing",
              "properties" => %{
                "thing_type" => "custom.zz_note",
                "initial_values" => %{
                  "0" => %{
                    "action" => %{"type" => "Empty"},
                    "key" => "body_text",
                    "value" => "hi"
                  }
                }
              }
            }
          }
        })

      {:ok, again} = Findings.analyze(app)
      assert again.findings == result.findings
    end

    test "a kind's findings do not depend on the kinds requested or their order", %{findings: fs} do
      {:ok, only} = Findings.analyze(@app, kinds: [:number_type, :list_relationship])
      {:ok, reversed} = Findings.analyze(@app, kinds: [:list_relationship, :number_type])

      expected = Enum.filter(fs, &(&1.kind in [:list_relationship, :number_type]))
      assert only.findings == expected
      assert reversed.findings == expected
    end

    defp paths(findings),
      do: Enum.flat_map(findings, &Enum.map(&1.evidence.references, fn r -> r.path end))

    # Everything but messages and source paths.
    defp stable(findings) do
      Enum.map(findings, fn f ->
        {f.id, f.kind, f.subject, f.proposal, f.confidence, f.affects, f.related,
         f.evidence.symbols, Enum.map(f.evidence.references, &{&1.from, &1.kind, &1.to})}
      end)
    end

    defp rename_everything(app) do
      app
      |> update_in(["user_types"], &Map.new(&1, fn {k, t} -> {k, rename_type(k, t)} end))
      |> update_in(["api"], fn api ->
        Map.new(api, fn {k, w} -> {k, put_in(w, ["properties", "wf_name"], "renamed-" <> k)} end)
      end)
    end

    defp rename_type(key, type) do
      fields =
        Map.new(type["fields"], fn {k, f} -> {k, Map.put(f, "display", "renamed " <> k)} end)

      type |> Map.put("display", "Renamed " <> key) |> Map.put("fields", fields)
    end

    # Backend workflows under other collection keys, actions as lists.
    defp move_workflows(app) do
      update_in(app, ["api"], fn api ->
        Map.new(api, fn {k, w} ->
          actions =
            w["actions"]
            |> Enum.sort_by(&String.to_integer(elem(&1, 0)))
            |> Enum.map(&elem(&1, 1))

          {"moved_" <> k, Map.put(w, "actions", actions)}
        end)
      end)
    end
  end

  describe "options and results" do
    test "reuses a prebuilt index of the same app, and rejects another app's", %{result: result} do
      {:ok, index} = Index.build(@app)
      assert {:ok, ^result} = Findings.analyze(@app, index: index)

      {:ok, other} = Index.build(Map.put(@app, "app_version", "live"))

      assert {:error,
              %Error{kind: :invalid_input, message: "index was built from a different app"}} =
               Findings.analyze(@app, index: other)
    end

    test "a proposal change changes proposal_sha256 but not the ID", %{findings: fs} do
      {:ok, changed} =
        @app
        |> put_in(["api", "wfSyncOnly", "actions", "0", "properties", "changes", "1"], %{
          "action" => %{"type" => "Empty"},
          "key" => "backup_title_text",
          "value" => "x"
        })
        |> Findings.analyze()

      before = find(fs, :denormalized_field, "project", "sort_workspace_name_text")
      now = find(changed.findings, :denormalized_field, "project", "sort_workspace_name_text")

      assert now.id == before.id
      assert now.proposal.delete_workflows == []
      refute now.proposal_sha256 == before.proposal_sha256
    end

    test "returns the index diagnostics and a summary", %{result: result} do
      assert result.diagnostics == []
      assert is_binary(result.index_sha256)

      assert Findings.summary(result) == %{
               redundant_reverse_list: %{high: 1},
               denormalized_field: %{high: 2},
               list_relationship: %{high: 6},
               privacy_access_list: %{high: 1},
               id_in_text: %{high: 1, medium: 1},
               search_index: %{medium: 2},
               number_type: %{high: 2}
             }

      assert %{"findings" => [%{"id" => _, "category" => "decision"} | _], "diagnostics" => []} =
               Findings.to_map(result)
    end

    test "rejects unknown kinds and bad input" do
      assert {:error, %Error{kind: :invalid_input, context: %{kinds: [:nope]}}} =
               Findings.analyze(@app, kinds: [:number_type, :nope])

      assert {:error, %Error{kind: :invalid_input}} = Findings.analyze(@app, index: :nope)
      assert {:error, %Error{kind: :invalid_input}} = Findings.analyze("not an app")
    end
  end
end
