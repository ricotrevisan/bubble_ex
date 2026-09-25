defmodule BubbleEx.DecisionTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{Decision, Error, Finding, Findings, Index, SampleHelper}
  alias BubbleEx.Decision.{Applied, Params, Resolved}
  alias BubbleEx.Finding.Kinds

  # The invented workspaces/projects/tasks app of `BubbleEx.FindingsTest`.
  @app SampleHelper.load_json_sample("synthetic_findings_export")

  @copy %{type: "project", field: "sort_workspace_name_text"}
  @points %{type: "task", field: "points_number"}
  @owner_id %{type: "project", field: "owner_id_text"}
  @members %{type: "workspace", field: "members_list_user"}
  @reverse %{type: "workspace", field: "projects_list_custom_project"}
  @tasks %{type: "project", field: "tasks_list_custom_task"}

  setup_all do
    %{findings: analyze(@app)}
  end

  defp analyze(app) do
    {:ok, %Findings{findings: findings}} = Findings.analyze(app)
    findings
  end

  defp index(app) do
    {:ok, index} = Index.build(app)
    index
  end

  defp finding(findings, kind, subject),
    do: Enum.find(findings, &(&1.kind == kind and &1.subject == subject)) || flunk("no finding")

  defp decide(finding, choice, params \\ %{}, opts \\ []) do
    {:ok, decision} = Decision.for_finding(finding, choice, params, opts)
    decision
  end

  defp rename(subject, slot, name, opts \\ []) do
    {:ok, decision} =
      Decision.new(
        Keyword.merge(
          [kind: :rename, target: "ash", subject: subject, choice: :accept],
          opts
        )
        |> Keyword.put(:params, %{slot: slot, name: name})
      )

    decision
  end

  defp parity(opts) do
    {:ok, decision} =
      Decision.new(
        Keyword.merge(
          [
            kind: :parity_exception,
            subject: %{type: "project"},
            choice: :accept,
            params: %{
              scope: "scenario:create_project",
              bubble_behavior: "keeps a trailing space",
              chosen_behavior: "trims the title"
            }
          ],
          opts
        )
      )

    decision
  end

  defp state(resolved, decision) do
    entry = Enum.find(resolved.entries, &(&1.decision == decision)) || flunk("no entry")
    {entry.state, entry.reasons}
  end

  defp resolve!(decisions, findings, opts \\ []) do
    {:ok, resolved} = Decision.resolve(decisions, findings, opts)
    resolved
  end

  defp invalid(result) do
    assert {:error, %Error{kind: :invalid_input, message: message}} = result
    message
  end

  defp update_field(app, type, field, fun),
    do: update_in(app, ["user_types", type, "fields", field], fun)

  describe "codec" do
    test "round-trips every kind through the map and JSON forms", %{findings: fs} do
      decisions = [
        decide(finding(fs, :number_type, @points), :modify, %{to: :decimal},
          id: "dec_1",
          revision: 2,
          rationale: "Points can be fractional.",
          author: %{kind: :owner, id: "user:42", via: :form},
          decided_at: ~U[2026-09-25 14:02:11Z],
          basis: %{bubble_version: "test", bubble_ex: "0.9.0"}
        ),
        decide(finding(fs, :denormalized_field, @copy), :accept),
        decide(finding(fs, :search_index, %{type: "project"}), :modify, %{drop: [2, 0, 2]}),
        rename(@copy, :attribute, "sort_key"),
        parity(expires_at: ~U[2027-01-01 00:00:00Z], basis: %{scenario_sha256: "abc"})
      ]

      for d <- decisions do
        assert {:ok, ^d} = d |> Decision.to_map() |> Decision.from_map()
        assert {:ok, ^d} = d |> Decision.to_json() |> Decision.from_json()

        assert Decision.to_json(d) ==
                 d
                 |> Decision.to_json()
                 |> Jason.decode!()
                 |> then(&elem(Decision.from_map(&1), 1))
                 |> Decision.to_json()
      end

      [modify | _] = decisions
      json = Decision.to_json(modify)

      assert Jason.decode!(json) == %{
               "schema_version" => 1,
               "id" => "dec_1",
               "key" => "finding:number_type:568835fc8a7c3aac",
               "kind" => "finding",
               "revision" => 2,
               "subject" => %{"type" => "task", "field" => "points_number"},
               "target" => nil,
               "choice" => "modify",
               "params" => %{"to" => "decimal"},
               "basis" => %{
                 "finding_id" => "number_type:568835fc8a7c3aac",
                 "proposal_sha256" => modify.basis.proposal_sha256,
                 "basis_sha256" => modify.basis.basis_sha256,
                 "bubble_version" => "test",
                 "bubble_ex" => "0.9.0"
               },
               "rationale" => "Points can be fractional.",
               "author" => %{"kind" => "owner", "id" => "user:42", "via" => "form"},
               "decided_at" => "2026-09-25T14:02:11Z",
               "expires_at" => nil
             }

      # Canonical: sorted keys, whatever the input order.
      assert json ==
               json
               |> Jason.decode!(objects: :ordered_objects)
               |> reversed()
               |> Jason.encode!()
               |> Decision.from_json()
               |> elem(1)
               |> Decision.to_json()

      assert String.starts_with?(json, ~s({"author":))
      assert Enum.at(decisions, 2).params == %{drop: [0, 2]}
    end

    test "keys: the finding ID, else a hash of the identity", %{findings: fs} do
      f = finding(fs, :number_type, @points)
      assert decide(f, :accept).key == "finding:" <> f.id

      a = rename(@copy, :attribute, "sort_key")
      assert a.key =~ ~r/^rename:[0-9a-f]{16}$/
      assert rename(@copy, :attribute, "other_name").key == a.key
      refute rename(@copy, :calculation, "sort_key").key == a.key
      refute rename(@tasks, :attribute, "sort_key").key == a.key

      assert parity([]).key =~ ~r/^parity_exception:[0-9a-f]{16}$/
    end

    test "decoding is strict", %{findings: fs} do
      map = fs |> finding(:number_type, @points) |> decide(:accept) |> Decision.to_map()

      assert invalid(Decision.from_map(Map.put(map, "extra", 1))) =~ "unknown decision members"
      assert invalid(Decision.from_map(Map.delete(map, "kind"))) =~ "missing"
      assert invalid(Decision.from_map(%{map | "schema_version" => 2})) =~ "schema_version"
      assert invalid(Decision.from_map(%{map | "kind" => "deviation"})) =~ "unknown kind"
      assert invalid(Decision.from_map(%{map | "choice" => "maybe"})) =~ "unknown choice"
      assert invalid(Decision.from_map(%{map | "revision" => 0})) =~ "revision"
      assert invalid(Decision.from_map(%{map | "key" => "finding:other"})) =~ "key"
      assert invalid(Decision.from_map(%{map | "target" => "ash"})) =~ "no target"
      assert invalid(Decision.from_map(%{map | "subject" => %{"page" => "p"}})) =~ "subject"

      assert invalid(Decision.from_map(%{map | "subject" => %{"type" => "task", "field" => "x"}})) =~
               "finding_id"

      assert invalid(Decision.from_map(put_in(map, ["basis", "extra"], "x"))) =~ "basis"
      assert invalid(Decision.from_map(%{map | "basis" => %{}})) =~ "basis needs"
      assert invalid(Decision.from_map(%{map | "author" => %{"kind" => "robot"}})) =~ "author"
      assert invalid(Decision.from_map(%{map | "decided_at" => "yesterday"})) =~ "ISO 8601"

      assert invalid(Decision.from_map(%{map | "expires_at" => "2027-01-01T00:00:00Z"})) =~
               "no expires_at"

      assert invalid(Decision.from_json("{")) =~ "JSON"
      assert invalid(Decision.from_map([])) =~ "object"
      assert {:ok, _} = Decision.from_map(Map.delete(map, "key"))
    end

    test "renames and parity exceptions are always accept, with their own params" do
      assert invalid(
               Decision.new(
                 kind: :rename,
                 target: "ash",
                 subject: @copy,
                 choice: :reject,
                 params: %{slot: :attribute, name: "x"}
               )
             ) =~ "always accept"

      assert invalid(
               Decision.new(
                 kind: :rename,
                 target: "phoenix",
                 subject: @copy,
                 choice: :accept,
                 params: %{slot: :attribute, name: "x"}
               )
             ) =~ "target"

      assert invalid(
               Decision.new(
                 kind: :rename,
                 target: "ash",
                 subject: @copy,
                 choice: :accept,
                 params: %{slot: :column, name: "x"}
               )
             ) =~ "slot"

      assert invalid(
               Decision.new(
                 kind: :rename,
                 target: "ash",
                 subject: @copy,
                 choice: :accept,
                 params: %{slot: :module, name: "Thing"}
               )
             ) =~ "subject"

      assert invalid(
               Decision.new(
                 kind: :rename,
                 target: "ash",
                 subject: @copy,
                 choice: :accept,
                 params: %{slot: :attribute, name: "Drop Table"}
               )
             ) =~ "name"

      assert invalid(
               Decision.new(
                 kind: :rename,
                 target: "ash",
                 subject: @copy,
                 choice: :accept,
                 params: %{slot: :attribute, name: "x", type: "integer"}
               )
             ) =~ "rename params"

      assert %Decision{} = rename(%{type: "project"}, :module, "Projects.Project")

      assert %Decision{} =
               rename(%{workflow: "wCreateProject"}, :endpoint_path, "projects/create")

      assert invalid(
               Decision.new(
                 kind: :parity_exception,
                 subject: %{type: "project"},
                 choice: :accept,
                 params: %{scope: "s"}
               )
             ) =~ "bubble_behavior"
    end
  end

  describe "modify whitelist" do
    test "every registered transform has a whitelist entry" do
      transforms =
        for kind <- Kinds.all(),
            {:ok, %{transforms: ts}} = Kinds.fetch(kind),
            t <- ts,
            uniq: true,
            do: t

      assert Enum.sort(transforms) == Params.transforms()
    end

    test "rejects parameters the transform does not allow", %{findings: fs} do
      points = finding(fs, :number_type, @points)
      assert invalid(Decision.for_finding(points, :modify, %{add_column: "x"})) =~ "not allowed"
      assert invalid(Decision.for_finding(points, :modify, %{to: "float"})) =~ "invalid value"
      assert invalid(Decision.for_finding(points, :modify, %{})) =~ "use accept"

      assert invalid(Decision.for_finding(points, :accept, %{to: :decimal})) =~
               "takes no parameters"

      assert invalid(Decision.for_finding(points, :modify, %{keep_order: true})) =~ "not allowed"

      members = finding(fs, :privacy_access_list, @members)

      assert invalid(Decision.for_finding(members, :modify, %{keep_order: true})) =~
               "accept or reject only"

      reverse = finding(fs, :redundant_reverse_list, @reverse)

      assert invalid(Decision.for_finding(reverse, :modify, %{alternative: 0})) =~
               "accept or reject only"

      tasks = finding(fs, :list_relationship, @tasks)

      assert invalid(Decision.for_finding(tasks, :modify, %{join_name: "DROP TABLE"})) =~
               "invalid value"

      assert %Decision{} = decide(tasks, :modify, %{keep_order: true, join_name: "project_tasks"})

      # Against the proposal: an existing alternative or index, a target
      # type only where the finding named none.
      copy = finding(fs, :denormalized_field, @copy)
      assert invalid(Decision.for_finding(copy, :modify, %{alternative: 0})) =~ "no alternative"

      owner = finding(fs, :id_in_text, @owner_id)

      assert invalid(Decision.for_finding(owner, :modify, %{target_type: "data_type:task"})) =~
               "already names"

      search = finding(fs, :search_index, %{type: "task"})
      assert invalid(Decision.for_finding(search, :modify, %{drop: [1]})) =~ "has 1 indexes"
    end

    test "checks modify params of a decoded decision against the finding", %{findings: fs} do
      copy = finding(fs, :denormalized_field, @copy)
      map = copy |> decide(:accept) |> Decision.to_map()

      # Decoding knows only the kind: `alternative` is allowed for
      # :denormalized_field, `to` is not.
      {:ok, d} =
        Decision.from_map(%{map | "choice" => "modify", "params" => %{"alternative" => 3}})

      assert invalid(Decision.check(d, copy)) =~ "no alternative"

      assert invalid(
               Decision.from_map(%{map | "choice" => "modify", "params" => %{"to" => "decimal"}})
             ) =~ "not allowed"

      assert invalid(Decision.check(d, finding(fs, :number_type, @points))) =~ "another finding"
    end

    test "applies an alternative and trims indexes" do
      f =
        Finding.new(:denormalized_field, @copy,
          proposal: %{
            transform: :derive_from_related,
            field: "field:project/sort_workspace_name_text",
            derivation: %{via: ["a"], source_field: "b"},
            alternatives: [%{transform: :derive_count, derivation: %{list: "c"}, writes: 1}]
          },
          confidence: :low,
          message: "m"
        )

      assert Params.apply(f.proposal, %{alternative: 0}).transform == :derive_count
      assert Params.apply(f.proposal, %{alternative: 0}).derivation == %{list: "c"}

      assert Params.apply(%{transform: :add_indexes, indexes: [:a, :b, :c]}, %{drop: [0, 2]}).indexes ==
               [:b]
    end
  end

  describe "resolve/3" do
    test "a fresh decision is active; undecided lists the other decision findings", %{
      findings: fs
    } do
      points = finding(fs, :number_type, @points)
      d = decide(points, :accept)
      resolved = resolve!([d], fs)

      assert state(resolved, d) == {:active, []}
      refute points.id in resolved.undecided
      assert finding(fs, :denormalized_field, @copy).id in resolved.undecided
      refute Enum.any?(resolved.undecided, &String.starts_with?(&1, "search_index:"))
      assert Resolved.summary(resolved).active == 1
    end

    test "caption renames keep decisions active", %{findings: fs} do
      d = decide(finding(fs, :denormalized_field, @copy), :accept)
      r = rename(@copy, :attribute, "sort_key")

      renamed =
        @app
        |> update_field("workspace", "name_text", &Map.put(&1, "display", "Workspace title"))
        |> update_field(
          "project",
          "sort_workspace_name_text",
          &Map.put(&1, "display", "Sort key")
        )
        |> put_in(["user_types", "workspace", "display"], "Team")

      resolved = resolve!([d, r], analyze(renamed), index: index(renamed))
      assert state(resolved, d) == {:active, []}
      assert state(resolved, r) == {:active, []}
    end

    test "a change to a copied field's type makes the decision stale", %{findings: fs} do
      d =
        decide(finding(fs, :denormalized_field, @copy), :accept, %{},
          basis: %{bubble_ex: "0.9.0"}
        )

      changed = update_field(@app, "workspace", "name_text", &Map.put(&1, "value", "number"))

      assert state(resolve!([d], analyze(changed)), d) == {:stale, [:basis_changed]}

      assert state(resolve!([d], analyze(changed), bubble_ex: "0.10.0"), d) ==
               {:stale, [:basis_changed, :analyzer_updated]}
    end

    test "a changed proposal makes a decision (even a reject) stale", %{findings: fs} do
      f = finding(fs, :number_type, @points)
      d = decide(%{f | proposal_sha256: String.duplicate("0", 64)}, :reject)
      assert state(resolve!([d], fs), d) == {:stale, [:proposal_changed]}
    end

    test "a finding that disappears orphans its decision", %{findings: fs} do
      d = decide(finding(fs, :denormalized_field, @copy), :accept)

      # The field is now a list: still there, no longer a copy.
      listed =
        update_field(
          @app,
          "project",
          "sort_workspace_name_text",
          &Map.put(&1, "value", "list.text")
        )

      assert state(resolve!([d], analyze(listed), index: index(listed)), d) ==
               {:orphaned, [:finding_absent, :subject_present]}

      # The field is deleted, or gone.
      deleted =
        update_field(@app, "project", "sort_workspace_name_text", &Map.put(&1, "deleted", true))

      assert state(resolve!([d], analyze(deleted), index: index(deleted)), d) ==
               {:orphaned, [:finding_absent, :subject_gone]}

      gone =
        update_in(
          @app,
          ["user_types", "project", "fields"],
          &Map.delete(&1, "sort_workspace_name_text")
        )

      assert state(resolve!([d], analyze(gone), index: index(gone)), d) ==
               {:orphaned, [:finding_absent, :subject_gone]}

      assert state(resolve!([d], analyze(gone)), d) == {:orphaned, [:finding_absent]}

      r = rename(@copy, :attribute, "sort_key")

      assert state(resolve!([r], analyze(gone), index: index(gone)), r) ==
               {:orphaned, [:subject_gone]}
    end

    test "a newer revision supersedes the older one", %{findings: fs} do
      f = finding(fs, :number_type, @points)
      old = decide(f, :accept)
      new = decide(f, :reject, %{}, revision: 2)
      resolved = resolve!([new, old], fs)

      assert state(resolved, old) == {:superseded, [:newer_revision]}
      assert state(resolved, new) == {:active, []}
      assert Enum.map(resolved.entries, & &1.decision.revision) == [1, 2]

      assert invalid(Decision.resolve([old, old], fs)) =~ "share a key and revision"
      assert invalid(Decision.resolve([:nope], fs)) =~ "structs"
    end

    test "parity exceptions expire by date or when their scenario changes", %{findings: fs} do
      d = parity(expires_at: ~U[2027-01-01 00:00:00Z], basis: %{scenario_sha256: "abc"})
      before = ~U[2026-12-31 23:59:59Z]

      assert state(resolve!([d], fs, now: before), d) == {:active, []}
      assert state(resolve!([d], fs, now: ~U[2027-01-01 00:00:00Z]), d) == {:expired, [:expired]}

      assert state(
               resolve!([d], fs, now: before, scenarios: %{"scenario:create_project" => "abc"}),
               d
             ) ==
               {:active, []}

      assert state(
               resolve!([d], fs, now: before, scenarios: %{"scenario:create_project" => "def"}),
               d
             ) ==
               {:expired, [:scenario_changed]}
    end

    test "modify params that no longer fit the finding are stale", %{findings: fs} do
      search = finding(fs, :search_index, %{type: "project"})
      d = decide(search, :modify, %{drop: [3]})

      trimmed = %{
        search
        | proposal: %{search.proposal | indexes: Enum.take(search.proposal.indexes, 2)}
      }

      assert state(resolve!([d], [trimmed]), d) == {:stale, [:params_invalid]}
    end
  end

  describe "applicable/2" do
    test "active accepts, modifies and renames, plus undecided hints", %{findings: fs} do
      points = finding(fs, :number_type, @points)
      copy = finding(fs, :denormalized_field, @copy)
      tasks = finding(fs, :list_relationship, @tasks)
      project_search = finding(fs, :search_index, %{type: "project"})
      task_search = finding(fs, :search_index, %{type: "task"})

      decisions = [
        decide(points, :modify, %{to: :decimal}, id: "dec_points"),
        decide(copy, :accept),
        decide(tasks, :reject),
        decide(project_search, :modify, %{drop: [0]}),
        rename(@copy, :calculation, "sort_key"),
        parity([])
      ]

      applied = Decision.applicable(resolve!(decisions, fs, now: ~U[2026-09-25 00:00:00Z]), fs)
      keys = Enum.map(applied, & &1.key)

      assert keys == Enum.sort(keys)
      refute ("finding:" <> tasks.id) in keys
      refute Enum.any?(keys, &String.starts_with?(&1, "parity_exception:"))

      assert %Applied{
               kind: :finding,
               decision_id: "dec_points",
               transform: :refine_number_type,
               automatic: false
             } =
               a = Enum.find(applied, &(&1.finding_id == points.id))

      assert a.proposal == %{points.proposal | to: :decimal}
      assert Enum.find(applied, &(&1.finding_id == copy.id)).proposal == copy.proposal

      assert Enum.find(applied, &(&1.finding_id == project_search.id)).proposal.indexes ==
               tl(project_search.proposal.indexes)

      assert %Applied{automatic: true, decision_id: nil, transform: :add_indexes} =
               Enum.find(applied, &(&1.finding_id == task_search.id))

      assert %Applied{
               kind: :rename,
               target: "ash",
               transform: :rename,
               params: %{slot: :calculation, name: "sort_key"}
             } =
               Enum.find(applied, &(&1.kind == :rename))
    end

    test "stale, orphaned and rejected hint decisions apply nothing", %{findings: fs} do
      task_search = finding(fs, :search_index, %{type: "task"})
      copy = finding(fs, :denormalized_field, @copy)
      stale = decide(%{copy | basis_sha256: String.duplicate("0", 64)}, :accept)
      rejected = decide(task_search, :reject)

      applied = Decision.applicable(resolve!([stale, rejected], fs), fs)
      refute Enum.any?(applied, &(&1.finding_id in [copy.id, task_search.id]))
    end
  end

  describe "decisions_sha256/1" do
    test "hashes only generation inputs of the current records", %{findings: fs} do
      points = finding(fs, :number_type, @points)
      copy = finding(fs, :denormalized_field, @copy)
      base = [decide(points, :accept, %{}, rationale: "a"), decide(copy, :accept)]
      sha = Decision.decisions_sha256(base)

      assert sha =~ ~r/^[0-9a-f]{64}$/
      assert Decision.decisions_sha256(Enum.reverse(base)) == sha

      # An audit-only revision: new record ID, rationale, author, time and
      # basis metadata.
      audit =
        decide(points, :accept, %{},
          revision: 2,
          id: "dec_2",
          rationale: "b",
          author: %{kind: :agent, via: :chat},
          decided_at: ~U[2026-09-26 00:00:00Z],
          basis: %{bubble_version: "live"}
        )

      assert Decision.decisions_sha256([audit | base]) == sha

      # A changed choice, parameter or proposal hash is a new input.
      refute Decision.decisions_sha256([decide(points, :reject, %{}, revision: 2) | base]) == sha

      refute Decision.decisions_sha256([
               decide(points, :modify, %{to: :decimal}, revision: 2) | base
             ]) == sha

      refute Decision.decisions_sha256([
               decide(%{points | proposal_sha256: String.duplicate("0", 64)}, :accept, %{},
                 revision: 2
               )
               | base
             ]) == sha

      refute Decision.decisions_sha256(tl(base)) == sha
      assert_raise ArgumentError, fn -> Decision.decisions_sha256(base ++ base) end
    end
  end

  describe "Finding.basis_sha256" do
    test "set by the analyzer, in the JSON form, and independent of IDs", %{findings: fs} do
      for f <- fs do
        assert f.basis_sha256 =~ ~r/^[0-9a-f]{64}$/
        assert Finding.to_map(f)["basis_sha256"] == f.basis_sha256
        assert f.id == Finding.id(f.kind, f.subject)
        assert f.proposal_sha256 == Finding.proposal_sha256(f)
      end
    end

    test "names the subject's symbols", %{findings: fs} do
      alias BubbleEx.Index.Subject

      assert Subject.symbol_ids(%{type: "t", field: "f", workflow: "w"}) == [
               "field:t/f",
               "workflow:w"
             ]

      assert Subject.symbol_ids(%{type: "t", rule: "r"}) == ["privacy_rule:t/r"]
      assert Subject.symbol_ids(%{option_set: "s", field: "a"}) == ["option_attribute:s/a"]
      assert Subject.symbol_ids(%{external_type: "api.apiconnector2.bA.bB"}) == ["api_call:bA/bB"]

      search = finding(fs, :search_index, %{type: "task"})
      assert "data_type:task" in Finding.basis_symbols(search)
      assert Finding.basis_symbols(search) == Enum.sort(Finding.basis_symbols(search))
    end

    test "covers the subject and evidence symbols' content, not names or paths" do
      index = index(@app)
      field = "field:workspace/name_text"
      sha = Index.subject_sha256(index, [field, "data_type:workspace"])

      assert Index.subject_sha256(index, ["data_type:workspace", field, field]) == sha

      renamed =
        @app
        |> update_field("workspace", "name_text", &Map.put(&1, "display", "Title"))
        |> index()

      assert Index.subject_sha256(renamed, [field, "data_type:workspace"]) == sha

      retyped =
        @app |> update_field("workspace", "name_text", &Map.put(&1, "value", "number")) |> index()

      refute Index.subject_sha256(retyped, [field, "data_type:workspace"]) == sha

      refute Index.subject_sha256(index, [field, "field:workspace/missing"]) ==
               Index.subject_sha256(index, [field])
    end
  end

  # Reverses the member order of every object, to check canonical output.
  defp reversed(%Jason.OrderedObject{values: values}),
    do: %Jason.OrderedObject{
      values: values |> Enum.reverse() |> Enum.map(fn {k, v} -> {k, reversed(v)} end)
    }

  defp reversed(list) when is_list(list), do: Enum.map(list, &reversed/1)
  defp reversed(value), do: value
end
