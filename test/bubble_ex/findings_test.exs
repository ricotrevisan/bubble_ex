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

  describe ":redundant_reverse_list" do
    test "a list kept in sync by the workflow that sets the reference back", %{findings: fs} do
      f = find(fs, :redundant_reverse_list, "workspace", "projects_list_custom_project")

      assert f.confidence == :high
      assert f.path == "/user_types/workspace/fields/projects_list_custom_project"

      assert f.proposal == %{
               transform: :derive_reverse_relationship,
               drop_field: "field:workspace/projects_list_custom_project",
               relationship: %{
                 source_type: "data_type:project",
                 via: "field:project/workspace_custom_workspace",
                 cardinality: :many
               },
               remove_writes: ["action:aAddToWorkspace"],
               maintaining_workflows: ["workflow:wCreateProject"]
             }

      assert "field:project/workspace_custom_workspace" in f.evidence.symbols
      assert Enum.any?(f.evidence.references, &(&1.from == "action:aAddToWorkspace"))
      assert f.affects.workflows == ["workflow:wCreateProject"]
    end

    test "not for a list no reference-setting workflow maintains", %{findings: fs} do
      # Project's Tasks: Task has a Project reference, but the workflows that
      # add and remove tasks never set it, so the list may be any set of tasks.
      assert subjects(fs, :redundant_reverse_list) == [
               {"workspace", "projects_list_custom_project"}
             ]
    end
  end

  describe ":denormalized_field" do
    test "a copied field of a related record, maintained on create and on update", %{
      findings: fs
    } do
      f = find(fs, :denormalized_field, "project", "sort_workspace_name_text")

      assert f.confidence == :high
      assert f.proposal.transform == :derive_calculation

      assert f.proposal.derivation == %{
               via: ["field:project/workspace_custom_workspace"],
               source_field: "field:workspace/name_text"
             }

      assert f.proposal.remove_writes == ["action:aCreateProject", "action:aSyncName"]
      assert f.proposal.alternatives == []
      # Both workflows write other fields too, so neither can simply go.
      assert f.proposal.delete_workflows == []
      assert f.affects.workflows == ["workflow:wCreateProject", "workflow:wRenameSync"]
      assert f.evidence.writes == 2 and f.evidence.traced_writes == 2
    end

    test "a count of the record's own list is an aggregate", %{findings: fs} do
      f = find(fs, :denormalized_field, "project", "task_count_number")

      assert f.proposal.transform == :derive_aggregate

      assert f.proposal.derivation == %{
               aggregate: :count,
               via: [],
               source_field: "field:project/tasks_list_custom_task"
             }

      # The initial 0 and the decrement are consistent but not traceable.
      assert f.confidence == :medium
      assert f.confidence_reason =~ "1 of 3 writes"
    end

    test "not for formatted text, parameters, same-record copies or unique IDs", %{
      findings: fs
    } do
      assert subjects(fs, :denormalized_field) == [
               {"project", "sort_workspace_name_text"},
               {"project", "task_count_number"}
             ]
    end
  end

  describe ":list_relationship" do
    test "a list of things grown by add/remove is a join resource", %{findings: fs} do
      f = find(fs, :list_relationship, "user", "favorites_list_custom_project")

      assert f.confidence == :high

      assert f.proposal == %{
               transform: :extract_join_resource,
               field: "field:user/favorites_list_custom_project",
               from_type: "data_type:user",
               to_type: "data_type:project",
               source_order: :preserved,
               source_limit: 10_000
             }

      assert f.message =~ "10,000"
      assert find(fs, :list_relationship, "project", "viewers_list_user").confidence == :low
    end

    test "not for lists another finding already models", %{findings: fs} do
      # Workspace's Projects is a reverse list and its Members an access list.
      assert subjects(fs, :list_relationship) == [
               {"project", "tasks_list_custom_task"},
               {"project", "viewers_list_user"},
               {"user", "favorites_list_custom_project"}
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

      assert f.affects.privacy_rules == [
               "privacy_rule:project/workspace_member_",
               "privacy_rule:workspace/member_"
             ]
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
      assert f.affects.workflows == ["workflow:wFavorite"]
    end

    test "not for text written from literals or parameters", %{findings: fs} do
      assert subjects(fs, :id_in_text) == [
               {"project", "legacy_task_id_text"},
               {"project", "owner_id_text"}
             ]
    end
  end

  describe ":search_index" do
    test "indexes by operator", %{findings: fs} do
      title = find(fs, :search_index, "project", "title_text")

      assert title.confidence == :high

      assert title.proposal.indexes == [
               %{method: :btree, access: [:sort], operators: [:sort], searches: 1},
               %{
                 method: :full_text,
                 access: [:full_text],
                 operators: [:text_contains],
                 searches: 1
               },
               %{
                 method: :trigram,
                 access: [:substring],
                 operators: [:text_contains_string],
                 searches: 1
               }
             ]

      assert title.affects.pages == ["page:pHome"]

      assert [%{method: :geo, access: [:geo]}] =
               find(fs, :search_index, "project", "location_geographic_address").proposal.indexes

      assert [%{method: :btree, access: [:range], operators: [:greater_than]}] =
               find(fs, :search_index, "task", "points_number").proposal.indexes

      assert find(fs, :search_index, "task", "points_number").confidence == :medium
    end

    test "not for negative operators, unique IDs or in-memory filters", %{findings: fs} do
      # `note_text` is only constrained by "not equal", `_id` is the primary
      # key and `status_text` only appears in `:filtered`.
      assert subjects(fs, :search_index) == [
               {"project", "location_geographic_address"},
               {"project", "title_text"},
               {"project", "workspace_custom_workspace"},
               {"task", "points_number"}
             ]
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
        {f.id, f.kind, f.subject, f.proposal, f.confidence, f.affects, f.evidence.symbols,
         Enum.map(f.evidence.references, &{&1.from, &1.kind, &1.to})}
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
    test "reuses a prebuilt index", %{result: result} do
      {:ok, index} = Index.build(@app)
      assert {:ok, ^result} = Findings.analyze(@app, index: index)
    end

    test "returns the index diagnostics and a summary", %{result: result} do
      assert result.diagnostics == []
      assert is_binary(result.index_sha256)

      assert Findings.summary(result) == %{
               redundant_reverse_list: %{high: 1},
               denormalized_field: %{high: 1, medium: 1},
               list_relationship: %{high: 2, low: 1},
               privacy_access_list: %{high: 1},
               id_in_text: %{high: 1, medium: 1},
               search_index: %{high: 2, medium: 2},
               number_type: %{high: 2}
             }

      assert %{"findings" => [%{"id" => _} | _], "diagnostics" => []} = Findings.to_map(result)
    end

    test "rejects unknown kinds and bad input" do
      assert {:error, %Error{kind: :invalid_input, context: %{kinds: [:nope]}}} =
               Findings.analyze(@app, kinds: [:number_type, :nope])

      assert {:error, %Error{kind: :invalid_input}} = Findings.analyze(@app, index: :nope)
      assert {:error, %Error{kind: :invalid_input}} = Findings.analyze("not an app")
    end
  end
end
