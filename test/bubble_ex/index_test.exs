defmodule BubbleEx.IndexTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{Error, Index, SampleHelper}
  alias BubbleEx.Index.{Graph, Reference, Symbol}

  @app SampleHelper.load_json_sample("synthetic_index_export")

  setup_all do
    {:ok, index} = Index.build(@app)
    %{index: index}
  end

  defp edges(refs), do: refs |> Enum.map(&{&1.from, &1.kind, &1.to}) |> Enum.sort()

  defp ref!(index, from, kind, to),
    do: Enum.find(index.references, &match?(%{from: ^from, kind: ^kind, to: ^to}, &1))

  defp wf!(index, id), do: Index.symbol(index, "workflow:" <> id)

  describe "symbols" do
    test "cover every definition kind, keyed by stable Bubble IDs", %{index: index} do
      assert Index.summary(index).symbols == %{
               data_type: 3,
               # 6 + 5 built-ins per type + the User's email: 6 + 15 + 1
               field: 28,
               option_set: 2,
               option_value: 3,
               option_attribute: 1,
               page: 1,
               reusable: 1,
               element: 6,
               workflow: 16,
               action: 32,
               api_group: 1,
               api_call: 2,
               privacy_rule: 2
             }

      assert %Symbol{
               kind: :field,
               bubble_id: "title_text",
               name: "Title",
               parent: "data_type:task"
             } =
               Index.symbol(index, "field:task/title_text")

      assert %Symbol{kind: :option_value, bubble_id: "open", attrs: %{key: "s1"}} =
               Index.symbol(index, "option_value:os_status/open")

      # Pages, elements and workflows use the Bubble `id`, not the map key.
      assert %Symbol{kind: :page, bubble_id: "pHome", path: "/pages/pgHome"} =
               Index.symbol(index, "page:pHome")

      assert %Symbol{parent: "element:eMain"} = Index.symbol(index, "element:eTitle")
      assert %Symbol{parent: "page:pHome", name: "save"} = wf!(index, "wSave")
      assert %Symbol{parent: "reusable:rNav"} = wf!(index, "wNav")
      assert %Symbol{parent: nil, name: "update-task"} = wf!(index, "wApiA")

      assert %Symbol{parent: "workflow:wClick", attrs: %{type: "NewThing", index: 0}} =
               Index.symbol(index, "action:aNew")

      assert %Symbol{parent: "api_group:grpA", name: "Post item"} =
               Index.symbol(index, "api_call:grpA/callPost")

      assert %Symbol{parent: "data_type:task", attrs: %{}} =
               Index.symbol(index, "privacy_rule:task/member_")

      assert %Symbol{attrs: %{default: true}} = Index.symbol(index, "privacy_rule:task/everyone")

      assert %Symbol{attrs: %{deleted: true}} =
               Index.symbol(index, "field:workspace/old_flag_boolean")
    end

    test "IDs escape separators in Bubble IDs" do
      assert Symbol.id(:field, ["a/b", "c~d"]) == "field:a~1b/c~0d"
      assert Symbol.id(:workflow, "bAbC") == "workflow:bAbC"
    end

    test "are sorted by ID and unique", %{index: index} do
      ids = Enum.map(index.symbols, & &1.id)
      assert ids == Enum.sort(ids)
      assert ids == Enum.uniq(ids)
    end
  end

  describe "reference edges" do
    test "field types point at data types, option sets and API calls", %{index: index} do
      assert %Reference{attrs: %{list: false}} =
               ref!(
                 index,
                 "field:task/status_option_os_status",
                 :field_type,
                 "option_set:os_status"
               )

      assert %Reference{attrs: %{list: true}} =
               ref!(index, "field:workspace/members_list_user", :field_type, "data_type:user")

      assert %Reference{attrs: %{list: true, response_path: "items"}} =
               ref!(index, "field:task/feed_items", :field_type, "api_call:grpA/callFeed")
    end

    test "expressions read fields, types, options and elements", %{index: index} do
      assert %Reference{
               attrs: %{via: :expression},
               path: "/pages/pgHome/elements/grpMain/elements/txtTitle/properties/text"
             } =
               ref!(index, "element:eTitle", :reads_field, "field:user/name_text")

      assert %Reference{attrs: %{via: :constraint}} =
               ref!(
                 index,
                 "action:aOnList",
                 :reads_field,
                 "field:task/workspace_custom_workspace"
               )

      assert %Reference{attrs: %{via: :sort}} =
               ref!(index, "action:aOnList", :reads_field, "field:task/title_text")

      assert %Reference{attrs: %{via: :constraint}} =
               ref!(index, "element:eOpen", :reads_field, "field:task/done_boolean")

      assert ref!(index, "element:eOpen", :reads_type, "data_type:task")
      assert ref!(index, "action:aChange", :reads_option, "option_value:os_status/open")
      assert ref!(index, "element:eMain", :reads_option, "option_set:os_role")
      assert ref!(index, "action:aNew", :reads_element, "element:eTitle")
    end

    test "database-trigger expressions read the trigger's data type", %{index: index} do
      assert ref!(index, "workflow:wTrigger", :reads_field, "field:task/done_boolean")
      assert ref!(index, "workflow:wTrigger", :listens_to, "data_type:task")

      assert %Reference{attrs: %{operation: :delete}} =
               ref!(index, "action:aDeleteDone", :writes_type, "data_type:task")
    end

    test "privacy rules reference condition fields and granted fields", %{index: index} do
      assert edges(Index.references_from(index, "privacy_rule:task/member_")) == [
               {"privacy_rule:task/member_", :grants_binding, "field:task/done_boolean"},
               {"privacy_rule:task/member_", :grants_view, "field:task/Slug"},
               {"privacy_rule:task/member_", :grants_view, "field:task/title_text"},
               {"privacy_rule:task/member_", :reads_field,
                "field:task/workspace_custom_workspace"},
               {"privacy_rule:task/member_", :reads_field,
                "field:user/workspace_custom_workspace"}
             ]
    end

    test "data actions write types and fields with the operation", %{index: index} do
      assert %Reference{attrs: %{operation: :insert}} =
               ref!(index, "action:aNew", :writes_type, "data_type:task")

      assert %Reference{attrs: %{operation: :insert, change: "set"}} =
               ref!(index, "action:aNew", :writes_field, "field:task/title_text")

      assert %Reference{attrs: %{operation: :update}} =
               ref!(index, "action:aChange", :writes_field, "field:task/status_option_os_status")

      assert %Reference{attrs: %{operation: :delete}} =
               ref!(index, "action:aDeleteList", :writes_type, "data_type:task")
    end

    test "an untyped change target is inferred only when one type has every changed field", %{
      index: index
    } do
      assert %Reference{attrs: %{target: :inferred, operation: :update, change: "add"}} =
               ref!(index, "action:aInferred", :writes_field, "field:task/title_text")

      # `name_text` exists on user and workspace: no guess, a diagnostic.
      assert Index.references_from(index, "action:aAmbiguous", [:writes_type, :writes_field]) ==
               []

      assert Enum.any?(
               index.diagnostics,
               &(&1.code == :index_unresolved_reference and
                   &1.path == "/api/wfApiB/actions/4/properties/to_change")
             )
    end

    test "previous-step targets resolve to the step's result type before inference", %{
      index: index
    } do
      # `workspace_custom_workspace` is on User and Task, so inference alone
      # could not decide; the previous step (a NewThing of Task) does.
      assert %Reference{attrs: %{operation: :update} = attrs} =
               ref!(
                 index,
                 "action:aStepChange",
                 :writes_field,
                 "field:task/workspace_custom_workspace"
               )

      refute Map.has_key?(attrs, :target)

      assert %Reference{attrs: %{operation: :delete}} =
               ref!(index, "action:aStepDelete", :writes_type, "data_type:task")
    end

    test "inference ignores deleted fields and types", %{index: index} do
      # Only the deleted `workspace.old_flag_boolean` has this key.
      assert Index.references_from(index, "action:aDeletedField", [:writes_type, :writes_field]) ==
               []

      assert Enum.any?(
               index.diagnostics,
               &(&1.code == :index_unresolved_reference and
                   &1.path == "/api/wfApiB/actions/9/properties/to_change")
             )
    end

    test "list, current-user and copy actions write", %{index: index} do
      assert %Reference{attrs: %{operation: :update}} =
               ref!(index, "action:aChangeList", :writes_field, "field:task/done_boolean")

      assert ref!(index, "action:aChangeList", :writes_type, "data_type:task")

      assert %Reference{attrs: %{operation: :update}} =
               ref!(index, "action:aMe", :writes_field, "field:user/name_text")

      assert %Reference{attrs: %{operation: :insert}} =
               ref!(index, "action:aCopy", :writes_type, "data_type:task")
    end

    test "custom events triggered on a reusable instance", %{index: index} do
      assert %Reference{attrs: %{call: :direct}} =
               ref!(index, "action:aNavReset", :calls_workflow, "workflow:wNavReset")

      assert ref!(index, "action:aNavReset", :targets_element, "element:eNav")
      assert %Symbol{parent: "reusable:rNav"} = wf!(index, "wNavReset")
    end

    test "built-in fields are symbols and are read like any field", %{index: index} do
      assert %Symbol{attrs: %{builtin: :unique_id, value_type: "text"}, parent: "data_type:task"} =
               Index.symbol(index, "field:task/_id")

      assert %Symbol{attrs: %{builtin: :email}} = Index.symbol(index, "field:user/email")
      assert ref!(index, "field:task/Created By", :field_type, "data_type:user")

      assert %Reference{attrs: %{via: :constraint}} =
               ref!(index, "element:eOpen", :reads_field, "field:task/_id")

      assert %Reference{attrs: %{via: :expression}} =
               ref!(index, "element:eOpen", :reads_field, "field:user/_id")

      assert %Reference{attrs: %{via: :sort}} =
               ref!(index, "element:eOpen", :reads_field, "field:task/Created Date")
    end

    test "workflow calls carry their kind", %{index: index} do
      calls =
        for r <- index.references, r.kind == :calls_workflow, do: {r.from, r.to, r.attrs.call}

      assert Enum.sort(calls) == [
               {"action:aBack", "workflow:wApiA", :scheduled},
               {"action:aCallPlugin", "workflow:wPluginOnly", :direct},
               {"action:aHelper", "workflow:wHelper", :direct},
               {"action:aLoopA", "workflow:wLoopB", :direct},
               {"action:aLoopB", "workflow:wLoopA", :direct},
               {"action:aNavReset", "workflow:wNavReset", :direct},
               {"action:aOnList", "workflow:wApiB", :list_scheduled},
               {"action:aPoll", "workflow:wNav", :scheduled},
               {"action:aRecur", "workflow:wApiC", :recurring},
               {"action:aSchedule", "workflow:wApiA", :scheduled},
               {"action:aTrigger", "workflow:wSave", :direct}
             ]
    end

    test "API calls, element targets, event sources and reusable instances", %{index: index} do
      assert %Reference{attrs: %{via: :action}} =
               ref!(index, "action:aPost", :calls_api, "api_call:grpA/callPost")

      assert %Reference{attrs: %{via: :data_source}} =
               ref!(index, "element:eFeed", :calls_api, "api_call:grpA/callFeed")

      assert ref!(index, "action:aHide", :targets_element, "element:eMain")
      assert ref!(index, "workflow:wClick", :listens_to, "element:eSave")
      assert ref!(index, "element:eNav", :instance_of, "reusable:rNav")
      # "Current page" names the context, not an element.
      assert Index.references_from(index, "action:aScrollPage") == []
    end

    test "privacy: flags follow the workflow a reference is made in", %{index: index} do
      # A frontend schedule action's own setting stays on the action and the
      # call edge; its parameter expressions run with the caller's privacy.
      assert %Symbol{attrs: %{ignore_privacy_rules: true}} =
               Index.symbol(index, "action:aSchedule")

      assert %Reference{attrs: attrs} =
               ref!(index, "action:aSchedule", :calls_workflow, "workflow:wApiA")

      assert attrs == %{
               call: :scheduled,
               action_ignore_privacy_rules: true,
               callee_ignore_privacy_rules: false
             }

      refute Map.has_key?(
               ref!(index, "action:aSchedule", :reads_field, "field:user/name_text").attrs,
               :ignore_privacy_rules
             )

      # The action and the callee disagree the other way round too.
      assert %{action_ignore_privacy_rules: false, callee_ignore_privacy_rules: true} =
               ref!(index, "action:aOnList", :calls_workflow, "workflow:wApiB").attrs

      refute Map.has_key?(
               ref!(index, "action:aOnList", :calls_workflow, "workflow:wApiB").attrs,
               :ignore_privacy_rules
             )

      # Every reference made inside wApiB (which ignores privacy rules) and
      # inside the custom event it triggers.
      assert %{ignore_privacy_rules: true, runs_ignoring_privacy_rules: true} =
               wf!(index, "wApiB").attrs

      assert %{runs_ignoring_privacy_rules: true} = wf!(index, "wHelper").attrs
      refute Map.has_key?(wf!(index, "wApiA").attrs, :runs_ignoring_privacy_rules)

      for wf <- ~w(workflow:wApiB workflow:wHelper),
          action <- Index.children(index, wf),
          ref <- Index.references_from(index, action.id),
          do: assert(ref.attrs.ignore_privacy_rules, inspect(ref))

      assert %{callee_ignore_privacy_rules: true} =
               ref!(index, "action:aHelper", :calls_workflow, "workflow:wHelper").attrs
    end

    test "every reference kind is exercised", %{index: index} do
      assert index.references |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort() ==
               Enum.sort(Reference.kinds())
    end

    test "dangling targets are kept and diagnosed", %{index: index} do
      assert ref!(index, "field:task/project_custom_project", :field_type, "data_type:project")

      assert [
               %BubbleEx.Diagnostic{
                 code: :index_unresolved_reference,
                 severity: :warning,
                 outcome: :unresolved,
                 stage: :model,
                 path: "/user_types/task/fields/project_custom_project",
                 subject: %{type: "task", field: "project_custom_project"},
                 details: %{references: [%{reference: :field_type, to: "data_type:project"}]}
               }
             ] =
               Enum.filter(index.diagnostics, &String.contains?(&1.message, "data_type:project"))

      assert index.diagnostics == BubbleEx.Diagnostic.normalize(index.diagnostics)

      # Built-in fields are symbols, so granting `Slug` resolves.
      assert ref!(index, "privacy_rule:task/member_", :grants_view, "field:task/Slug")
    end
  end

  describe "workflow analysis" do
    test "execution classes follow actions and triggered custom events", %{index: index} do
      classes =
        for s <- Index.symbols(index, :workflow),
            into: %{},
            do: {s.bubble_id, s.attrs.execution_class}

      assert classes == %{
               "wApiA" => :server_backed,
               "wApiB" => :server_backed,
               "wApiC" => :server_backed,
               "wTrigger" => :server_backed,
               # NewThing (server) + HideElement (client) + a server-backed event
               "wClick" => :mixed,
               "wSave" => :server_backed,
               "wLoad" => :client_only,
               "wTimer" => :client_only,
               "wNav" => :client_only,
               "wNavReset" => :client_only,
               "wLoopA" => :client_only,
               "wLoopB" => :client_only,
               "wHelper" => :server_backed,
               "wPlugin" => :unknown,
               # Only triggers a plugin-only custom event: unknown, not client_only.
               "wPluginCaller" => :unknown,
               "wPluginOnly" => :unknown
             }

      assert wf!(index, "wPlugin").attrs.unclassified_actions == 1
    end

    test "invocation modes", %{index: index} do
      modes =
        for s <- Index.symbols(index, :workflow),
            into: %{},
            do: {s.bubble_id, s.attrs.invocation_modes}

      assert modes == %{
               "wApiA" => [:public_http, :scheduled],
               "wApiB" => [:scheduled],
               "wApiC" => [:recurring],
               "wTrigger" => [:database_trigger],
               "wClick" => [:event],
               "wSave" => [:direct],
               "wLoad" => [:event],
               "wTimer" => [:recurring],
               "wNav" => [:scheduled],
               "wNavReset" => [:direct],
               "wLoopA" => [:direct],
               "wLoopB" => [:direct],
               "wHelper" => [:direct],
               "wPlugin" => [:event],
               "wPluginCaller" => [:event],
               "wPluginOnly" => [:direct]
             }
    end

    test "cycles are strongly connected components with their call kinds", %{index: index} do
      assert [scheduled, loop, self] = Index.cycles(index)

      assert scheduled == %{
               workflows: ["workflow:wApiA", "workflow:wApiB"],
               calls: [
                 %{
                   from: "workflow:wApiA",
                   to: "workflow:wApiB",
                   action: "action:aOnList",
                   call: :list_scheduled
                 },
                 %{
                   from: "workflow:wApiB",
                   to: "workflow:wApiA",
                   action: "action:aBack",
                   call: :scheduled
                 }
               ],
               call_kinds: [:list_scheduled, :scheduled],
               synchronous: false
             }

      # Custom events triggering each other directly never end.
      assert %{
               workflows: ["workflow:wLoopA", "workflow:wLoopB"],
               call_kinds: [:direct],
               synchronous: true
             } = loop

      # A workflow scheduling itself is ordinary Bubble recursion.
      assert %{workflows: ["workflow:wNav"], call_kinds: [:scheduled], synchronous: false} = self
    end

    test "a mixed cycle is synchronous only if its direct calls alone loop" do
      app =
        @app
        |> put_in(
          ["pages", "pgHome", "workflows", "wfLoopB", "actions", "0", "type"],
          "ScheduleCustom"
        )

      {:ok, index} = Index.build(app)

      assert %{call_kinds: [:direct, :scheduled], synchronous: false} =
               Enum.find(Index.cycles(index), &("workflow:wLoopA" in &1.workflows))
    end
  end

  describe "queries" do
    test "who reads and writes a field", %{index: index} do
      field = "field:task/title_text"

      assert edges(Index.writers(index, field)) == [
               {"action:aInferred", :writes_field, field},
               {"action:aNew", :writes_field, field}
             ]

      assert edges(Index.readers(index, field)) == [{"action:aOnList", :reads_field, field}]

      workflows =
        Index.writers(index, field) |> Enum.map(&Index.ancestor(index, &1.from, :workflow).id)

      assert Enum.sort(workflows) == ["workflow:wApiB", "workflow:wClick"]
      assert Index.ancestor(index, "element:eTitle", :page).id == "page:pHome"
    end

    test "privacy rules referencing a field", %{index: index} do
      assert edges(
               Index.privacy_rules_referencing(index, "field:task/workspace_custom_workspace")
             ) == [
               {"privacy_rule:task/member_", :reads_field,
                "field:task/workspace_custom_workspace"}
             ]

      assert edges(Index.privacy_rules_referencing(index, "field:task/done_boolean")) == [
               {"privacy_rule:task/member_", :grants_binding, "field:task/done_boolean"}
             ]
    end

    test "what depends on a data type", %{index: index} do
      deps = Index.dependents(index, "data_type:workspace")

      assert {"field:task/workspace_custom_workspace", :field_type, "data_type:workspace"} in edges(
               deps
             )

      assert {"field:user/workspace_custom_workspace", :field_type, "data_type:workspace"} in edges(
               deps
             )

      task_sources =
        index |> Index.dependents("data_type:task") |> Enum.map(& &1.from) |> MapSet.new()

      for source <-
            ~w(action:aNew action:aChange action:aDeleteList element:eOpen workflow:wTrigger
                       privacy_rule:task/member_ action:aOnList),
          do: assert(source in task_sources, source)
    end

    test "callers and callees of a workflow", %{index: index} do
      assert [%{workflow: "workflow:wClick", action: "action:aTrigger", call: :direct}] =
               Index.callers(index, "workflow:wSave")

      assert index |> Index.callers("workflow:wApiA") |> Enum.map(&{&1.workflow, &1.call}) == [
               {"workflow:wApiB", :scheduled},
               {"workflow:wSave", :scheduled}
             ]

      assert index
             |> Index.callees("workflow:wApiB")
             |> Enum.map(&{&1.workflow, &1.call})
             |> Enum.sort() == [
               {"workflow:wApiA", :scheduled},
               {"workflow:wApiC", :recurring},
               {"workflow:wHelper", :direct}
             ]
    end

    test "per-workflow writes", %{index: index} do
      assert edges(Index.workflow_writes(index, "workflow:wApiA")) == [
               {"action:aChange", :writes_field, "field:task/done_boolean"},
               {"action:aChange", :writes_field, "field:task/status_option_os_status"},
               {"action:aChange", :writes_type, "data_type:task"}
             ]
    end

    test "unknown IDs return nothing", %{index: index} do
      assert Index.symbol(index, "field:nope/nope") == nil
      assert Index.readers(index, "field:nope/nope") == []
      assert Index.callers(index, "workflow:nope") == []
      assert Index.ancestor(index, "workflow:nope", :page) == nil
    end
  end

  describe "determinism and hashes" do
    test "identical output for the same input", %{index: index} do
      {:ok, again} = Index.build(@app)
      assert Index.to_json(again) == Index.to_json(index)
      assert again.semantic_sha256 == index.semantic_sha256
    end

    test "collection order is not semantic: shuffled array collections index the same", %{
      index: index
    } do
      # Workflow collections supplied as JSON arrays in several orders. Action
      # order is semantic and kept.
      for seed <- 1..5 do
        :rand.seed(:exsss, {seed, seed, seed})

        app =
          @app
          |> update_in(["api"], &(&1 |> Map.values() |> Enum.shuffle()))
          |> update_in(["pages", "pgHome", "workflows"], &(&1 |> Map.values() |> Enum.shuffle()))

        {:ok, shuffled} = Index.build(app)
        assert shuffled.semantic_sha256 == index.semantic_sha256
        assert Enum.map(shuffled.symbols, & &1.id) == Enum.map(index.symbols, & &1.id)
        assert edge_set(shuffled) == edge_set(index)
        # Paths and the source hash name positions, so the full hash differs.
        refute shuffled.content_sha256 == index.content_sha256
      end
    end

    test "the same app in readable and compact keys indexes the same" do
      readable = %{
        "user_types" => %{
          "task" => %{
            "display" => "Task",
            "fields" => %{"title_text" => %{"display" => "Title", "value" => "text"}}
          }
        },
        "pages" => %{
          "pg" => %{
            "id" => "pX",
            "name" => "index",
            "type" => "Page",
            "elements" => %{
              "t" => %{
                "id" => "eX",
                "type" => "Text",
                "properties" => %{
                  "text" => %{
                    "type" => "Search",
                    "properties" => %{"type_to_find" => "custom.task"},
                    "next" => %{
                      "type" => "Message",
                      "name" => "first_element",
                      "next" => %{"type" => "Message", "name" => "title_text"}
                    }
                  }
                }
              }
            },
            "workflows" => %{
              "w" => %{
                "id" => "wX",
                "type" => "PageLoaded",
                "actions" => %{
                  "0" => %{
                    "id" => "aX",
                    "type" => "HideElement",
                    "properties" => %{"element_id" => "eX"}
                  }
                }
              }
            }
          }
        }
      }

      {:ok, a} = Index.build(readable)
      {:ok, b} = Index.build(compact(readable))
      assert a.semantic_sha256 == b.semantic_sha256
      assert edge_set(a) == edge_set(b)

      assert Enum.map(a.symbols, &Map.delete(&1, :path)) ==
               Enum.map(b.symbols, &Map.delete(&1, :path))
    end

    test "content hash covers content and carries format and source identity", %{index: index} do
      assert index.schema_version == Index.schema_version()
      assert index.content_sha256 =~ ~r/\A[0-9a-f]{64}\z/
      assert {:ok, %{source_sha256: source}} = BubbleEx.Workflows.inventory(@app)
      assert index.source_sha256 == source

      renamed =
        put_in(@app, ["user_types", "task", "fields", "title_text", "display"], "Headline")

      {:ok, changed} = Index.build(renamed)
      refute changed.content_sha256 == index.content_sha256
      # A caption edit renames nothing: IDs are Bubble IDs.
      assert Enum.map(changed.symbols, & &1.id) == Enum.map(index.symbols, & &1.id)

      # Captions are content: both hashes change.
      refute changed.semantic_sha256 == index.semantic_sha256

      map = Index.to_map(index)
      assert map.content_sha256 == index.content_sha256
      assert map.semantic_sha256 == index.semantic_sha256
      refute Map.has_key?(map, :lookup)
      assert Jason.decode!(Index.to_json(index))["schema_version"] == 1
    end
  end

  describe "input forms" do
    test "reads the live payload's compact keys" do
      app = %{
        "user_types" => %{
          "task" => %{
            "%d" => "Task",
            "%f3" => %{"title_text" => %{"%d" => "Title", "%v" => "text"}}
          }
        },
        "%p3" => %{
          "pg" => %{
            "%id" => "pX",
            "%nm" => "index",
            "%x" => "Page",
            "%el" => %{
              "t" => %{
                "%id" => "eX",
                "%x" => "Text",
                "%p" => %{
                  "text" => %{
                    "%x" => "Search",
                    "%p" => %{"type_to_find" => "custom.task"},
                    "%n" => %{
                      "%x" => "Message",
                      "%nm" => "first_element",
                      "%n" => %{"%x" => "Message", "%nm" => "title_text"}
                    }
                  }
                }
              }
            },
            "%wf" => %{
              "w" => %{
                "%id" => "wX",
                "%x" => "PageLoaded",
                "actions" => %{
                  "0" => %{"%id" => "aX", "%x" => "HideElement", "%p" => %{"element_id" => "eX"}}
                }
              }
            }
          }
        }
      }

      {:ok, index} = Index.build(app)
      assert %Symbol{name: "Task"} = Index.symbol(index, "data_type:task")
      assert %Symbol{parent: "page:pX"} = Index.symbol(index, "element:eX")
      assert %Symbol{parent: "page:pX"} = Index.symbol(index, "workflow:wX")
      assert ref!(index, "element:eX", :reads_field, "field:task/title_text")
      assert ref!(index, "element:eX", :reads_type, "data_type:task")
      assert ref!(index, "action:aX", :targets_element, "element:eX")
      # The live payload has no privacy rules.
      assert Index.symbols(index, :privacy_rule) == []
    end

    test "duplicate Bubble IDs keep the first definition and are diagnosed" do
      app = put_in(@app, ["api", "wfCopy"], @app["api"]["wfApiC"])
      {:ok, index} = Index.build(app)
      assert wf!(index, "wApiC").path == "/api/wfApiC"

      assert [%{code: :index_duplicate_symbol, path: "/api/wfCopy"}] =
               Enum.filter(index.diagnostics, &(&1.code == :index_duplicate_symbol))
    end

    test "a Bubble ID shared by definitions of different kinds is diagnosed" do
      element = %{"id" => "pHome", "type" => "Text"}
      app = put_in(@app, ["pages", "pgHome", "elements", "grpMain", "elements", "clash"], element)
      {:ok, index} = Index.build(app)

      assert [
               %{
                 code: :index_duplicate_symbol,
                 path: "/pages/pgHome/elements/grpMain/elements/clash"
               }
             ] =
               Enum.filter(index.diagnostics, &(&1.code == :index_duplicate_symbol))

      # References by that Bubble ID resolve to the first definition by path.
      assert Index.symbol(index, "element:pHome")
    end

    test "empty app and invalid input" do
      assert {:ok, %Index{symbols: [], references: [], cycles: []}} = Index.build(%{})
      assert {:error, %Error{kind: :invalid_input}} = Index.build("nope")
      assert {:error, %Error{kind: :invalid_input}} = Index.build(%{atom: 1})
    end

    test "is reachable from the top-level API" do
      assert {:ok, %Index{}} = BubbleEx.symbol_index(@app)
    end
  end

  describe "Tarjan SCC" do
    test "finds components deterministically" do
      graph = %{a: [:b], b: [:c], c: [:a, :d], d: [:e], e: [:d], f: [:f], g: []}
      assert Graph.sccs(graph) == [[:a, :b, :c], [:d, :e], [:f], [:g]]
      assert Graph.cycles(graph) == [[:a, :b, :c], [:d, :e], [:f]]
    end

    test "handles nodes only reachable as successors and long chains" do
      chain = Map.new(1..2_000, &{&1, [&1 + 1]})
      assert Graph.cycles(chain) == []
      assert Graph.cycles(Map.put(chain, 2_001, [1])) == [Enum.to_list(1..2_001)]
    end
  end

  defp edge_set(index),
    do: index.references |> Enum.map(&{&1.from, &1.kind, &1.to, &1.attrs}) |> Enum.sort()

  @compact %{
    "display" => "%d",
    "fields" => "%f3",
    "value" => "%v",
    "pages" => "%p3",
    "elements" => "%el",
    "workflows" => "%wf",
    "id" => "%id",
    "type" => "%x",
    "properties" => "%p",
    "name" => "%nm",
    "next" => "%n"
  }

  # The live payload's compact spelling of the keys the index reads. Data
  # type and field keys are Bubble IDs, never renamed.
  defp compact(map, parent \\ nil)

  defp compact(map, parent) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if parent in ["user_types", "fields", "%f3"], do: k, else: Map.get(@compact, k, k)
      {key, compact(v, key)}
    end)
  end

  defp compact(list, _) when is_list(list), do: Enum.map(list, &compact(&1, nil))
  defp compact(v, _), do: v
end
