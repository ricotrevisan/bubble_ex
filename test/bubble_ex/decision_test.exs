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

  @now ~U[2026-09-25 12:00:00Z]
  @sha_a String.duplicate("a", 64)
  @sha_b String.duplicate("b", 64)

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
              checks: ["api_workflow"],
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

  # Resolves against the unchanged app at @now unless told otherwise.
  defp resolve!(decisions, findings, opts \\ []) do
    opts =
      opts |> Keyword.put_new_lazy(:index, fn -> index(@app) end) |> Keyword.put_new(:now, @now)

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
        parity(expires_at: ~U[2027-01-01 00:00:00Z], basis: %{scenario_sha256: @sha_a})
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

    test "renames and parity exceptions are accept or withdraw, with their own params" do
      assert invalid(
               Decision.new(
                 kind: :rename,
                 target: "ash",
                 subject: @copy,
                 choice: :reject,
                 params: %{slot: :attribute, name: "x"}
               )
             ) =~ "rename decisions are accept, withdraw"

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
                 params: %{scope: "s", checks: ["dom_text"]}
               )
             ) =~ "bubble_behavior"

      for checks <- [nil, [], ["vibes"], ["dom_text", "dom_text"], "dom_text"] do
        assert invalid(
                 Decision.new(
                   kind: :parity_exception,
                   subject: %{type: "project"},
                   choice: :accept,
                   params: %{
                     scope: "s",
                     checks: checks,
                     bubble_behavior: "a",
                     chosen_behavior: "b"
                   }
                 )
               ) =~ "checks"
      end

      {:ok, d} =
        Decision.new(
          kind: :parity_exception,
          subject: %{type: "project"},
          choice: :accept,
          params: %{
            scope: "s",
            checks: ["journey", "dom_text"],
            bubble_behavior: "a",
            chosen_behavior: "b"
          }
        )

      assert d.params.checks == ["dom_text", "journey"]
      assert {:ok, ^d} = d |> Decision.to_json() |> Decision.from_json()
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

      opts = [index: index(@app), now: @now]
      assert invalid(Decision.resolve([old, old], fs, opts)) =~ "share a key and revision"
      assert invalid(Decision.resolve([:nope], fs, opts)) =~ "structs"
      assert invalid(Decision.resolve([old], fs, now: @now)) =~ "needs index"
      assert invalid(Decision.resolve([old], fs, index: index(@app))) =~ "needs index"
    end

    test "parity exceptions expire by date, or when their scenario changes or is unknown", %{
      findings: fs
    } do
      d = parity(expires_at: ~U[2027-01-01 00:00:00Z], basis: %{scenario_sha256: @sha_a})
      before = ~U[2026-12-31 23:59:59Z]
      same = %{"scenario:create_project" => @sha_a}

      assert state(resolve!([d], fs, now: before, scenarios: same), d) == {:active, []}

      assert state(resolve!([d], fs, now: ~U[2027-01-01 00:00:00Z], scenarios: same), d) ==
               {:expired, [:expired]}

      assert state(
               resolve!([d], fs, now: before, scenarios: %{"scenario:create_project" => @sha_b}),
               d
             ) == {:expired, [:scenario_changed]}

      # Fail-safe: a scenario nobody vouched for does not keep the exception.
      assert state(resolve!([d], fs, now: before), d) == {:expired, [:scenario_unknown]}

      # An exception on a check pattern (no scenario hash) expires by date only.
      pattern = parity([])
      assert state(resolve!([pattern], fs), pattern) == {:active, []}
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

  describe "acknowledge, withdraw and publication" do
    test "an orphan whose subject still exists blocks until acknowledged", %{findings: fs} do
      d = decide(finding(fs, :denormalized_field, @copy), :accept)

      listed =
        update_field(
          @app,
          "project",
          "sort_workspace_name_text",
          &Map.put(&1, "value", "list.text")
        )

      opts = [index: index(listed)]
      resolved = resolve!([d], analyze(listed), opts)
      assert [%{decision: ^d, state: :orphaned}] = Resolved.blocking(resolved)
      assert Resolved.archived(resolved) == []

      # A new reject does not help: its finding is still gone.
      {:ok, reject} = Decision.new(Map.merge(Map.from_struct(d), %{choice: :reject, revision: 2}))
      assert Resolved.blocking(resolve!([d, reject], analyze(listed), opts)) == []

      assert state(resolve!([d, reject], analyze(listed), opts), reject) ==
               {:orphaned, [:finding_absent, :subject_present]}

      {:ok, ack} = Decision.acknowledge(d, rationale: "seen", decided_at: @now)
      assert ack.revision == 2 and ack.choice == :acknowledge and ack.key == d.key
      assert ack.basis == %{finding_id: d.basis.finding_id}
      assert {:ok, ^ack} = ack |> Decision.to_json() |> Decision.from_json()

      resolved = resolve!([d, ack], analyze(listed), opts)
      assert state(resolved, ack) == {:acknowledged, [:finding_absent, :subject_present]}
      assert Resolved.blocking(resolved) == []

      assert Decision.applicable(resolved, analyze(listed)) |> Enum.filter(&(&1.key == d.key)) ==
               []

      # If the finding comes back, the acknowledgement is stale (non-blocking).
      back = resolve!([d, ack], fs)
      assert {:stale, [:proposal_changed, :basis_changed]} = state(back, ack)
      assert Resolved.blocking(back) == []
    end

    test "an orphan whose subject is gone is archived, not blocking", %{findings: fs} do
      d = decide(finding(fs, :denormalized_field, @copy), :accept)
      r = rename(@copy, :attribute, "sort_key")

      gone =
        update_in(
          @app,
          ["user_types", "project", "fields"],
          &Map.delete(&1, "sort_workspace_name_text")
        )

      resolved = resolve!([d, r], analyze(gone), index: index(gone))
      assert Resolved.blocking(resolved) == []

      assert resolved |> Resolved.archived() |> Enum.map(& &1.decision) |> Enum.sort() ==
               Enum.sort([d, r])
    end

    test "a stale accept blocks until re-decided or acknowledged with the new finding", %{
      findings: fs
    } do
      d = decide(finding(fs, :denormalized_field, @copy), :accept)
      changed = update_field(@app, "workspace", "name_text", &Map.put(&1, "value", "number"))
      now_findings = analyze(changed)
      opts = [index: index(changed)]
      new_copy = finding(now_findings, :denormalized_field, @copy)

      assert [%{state: :stale}] = Resolved.blocking(resolve!([d], now_findings, opts))

      {:ok, ack} = Decision.acknowledge(d, finding: new_copy)
      resolved = resolve!([d, ack], now_findings, opts)
      assert state(resolved, ack) == {:acknowledged, []}
      assert Resolved.blocking(resolved) == []

      reaccept = decide(new_copy, :accept, %{}, revision: 2)
      resolved = resolve!([d, reaccept], now_findings, opts)
      assert state(resolved, reaccept) == {:active, []}
      assert Enum.any?(Decision.applicable(resolved, now_findings), &(&1.key == d.key))

      # A stale reject never blocks: it applies nothing either way.
      reject = decide(finding(fs, :denormalized_field, @copy), :reject)
      assert Resolved.blocking(resolve!([reject], now_findings, opts)) == []

      assert invalid(Decision.acknowledge(d, finding: finding(fs, :number_type, @points))) =~
               "own finding"
    end

    test "renames and parity exceptions are withdrawn", %{findings: fs} do
      r = rename(@copy, :calculation, "sort_key")
      p = parity(expires_at: ~U[2027-01-01 00:00:00Z])
      {:ok, r2} = Decision.withdraw(r, rationale: "back to the derived name")
      {:ok, p2} = Decision.withdraw(p)

      assert {r2.key, r2.revision, r2.choice} == {r.key, 2, :withdraw}
      assert {:ok, ^r2} = r2 |> Decision.to_json() |> Decision.from_json()

      resolved = resolve!([r, r2, p, p2], fs)
      assert state(resolved, r2) == {:withdrawn, []}
      assert state(resolved, p2) == {:withdrawn, []}
      assert state(resolved, r) == {:superseded, [:newer_revision]}
      refute Enum.any?(Decision.applicable(resolved, fs), &(&1.kind == :rename))

      assert invalid(Decision.withdraw(decide(finding(fs, :number_type, @points), :accept))) =~
               "acknowledge"

      assert invalid(Decision.acknowledge(r)) =~ "withdraw"
      d = decide(finding(fs, :number_type, @points), :accept)

      assert invalid(Decision.from_map(%{Decision.to_map(d) | "choice" => "withdraw"})) =~
               "finding decisions are"
    end
  end

  describe "review hardening" do
    test "target_type must be one the finding saw, and live in the index" do
      f =
        Finding.new(:id_in_text, @owner_id,
          evidence: %{
            symbols: ["field:project/owner_id_text"],
            target_types: ["data_type:ghost", "data_type:user"]
          },
          proposal: %{
            transform: :text_to_reference,
            field: "field:project/owner_id_text",
            target_type: nil,
            cardinality: :one
          },
          confidence: :low,
          message: "m"
        )

      f = %{f | basis_sha256: @sha_a}

      assert invalid(Decision.for_finding(f, :modify, %{target_type: "data_type:project"})) =~
               "not one the finding saw"

      user = decide(f, :modify, %{target_type: "data_type:user"})
      ghost = decide(f, :modify, %{target_type: "data_type:ghost"})
      assert state(resolve!([user], [f]), user) == {:active, []}
      assert state(resolve!([ghost], [f]), ghost) == {:stale, [:params_invalid]}
    end

    test "decoding rejects null unknown basis members, non-string keys, empty values and reserved modules",
         %{findings: fs} do
      map = fs |> finding(:number_type, @points) |> decide(:accept) |> Decision.to_map()

      assert invalid(Decision.from_map(put_in(map, ["basis", "extra"], nil))) =~ "basis"
      assert invalid(Decision.from_map(put_in(map, ["basis", "proposal_sha256"], ""))) =~ "basis"
      assert invalid(Decision.from_map(put_in(map, ["basis", "basis_sha256"], "abc"))) =~ "basis"
      assert invalid(Decision.from_map(put_in(map, ["basis", "bubble_version"], ""))) =~ "basis"
      assert invalid(Decision.from_map(Map.put(map, :kind, "finding"))) =~ "strings"
      assert invalid(Decision.from_map(%{map | "subject" => %{type: "task"}})) =~ "subject"
      assert invalid(Decision.from_map(%{map | "id" => ""})) =~ "empty"
      assert invalid(Decision.from_json(nil)) =~ "string"

      modify = %{map | "choice" => "modify", "params" => %{to: "decimal"}}
      assert invalid(Decision.from_map(modify)) =~ "not allowed"

      for name <- ["Kernel", "Enum.Things", "Ash", "Ecto.Thing"] do
        assert invalid(
                 Decision.new(
                   kind: :rename,
                   target: "ash",
                   subject: %{type: "project"},
                   choice: :accept,
                   params: %{slot: :module, name: name}
                 )
               ) =~ "invalid module name"
      end
    end

    test "decisions_sha256 changes when a re-accept records another basis", %{findings: fs} do
      copy = finding(fs, :denormalized_field, @copy)
      old = decide(copy, :accept)
      reaccepted = decide(%{copy | basis_sha256: @sha_b}, :accept, %{}, revision: 2)
      refute Decision.decisions_sha256([old]) == Decision.decisions_sha256([old, reaccepted])

      p = parity(expires_at: ~U[2027-01-01 00:00:00Z])

      {:ok, later} =
        Decision.new(
          Map.merge(Map.from_struct(p), %{revision: 2, expires_at: ~U[2028-01-01 00:00:00Z]})
        )

      refute Decision.decisions_sha256([p]) == Decision.decisions_sha256([p, later])
    end

    test "hint bases ignore search hosts; action positions do not count", %{findings: fs} do
      search = finding(fs, :search_index, %{type: "project"})

      assert Enum.all?(
               Finding.basis_symbols(search),
               &String.starts_with?(&1, ["data_type:", "field:"])
             )

      swapped =
        update_in(@app, ["api", "wfCreateProject", "actions"], fn %{"0" => a, "1" => b} ->
          %{"0" => b, "1" => a}
        end)

      ids = ["action:aCreateProject", "action:aAddToWorkspace"]
      assert Index.subject_sha256(index(swapped), ids) == Index.subject_sha256(index(@app), ids)

      refute Enum.map(ids, &Index.symbol(index(swapped), &1).attrs[:index]) ==
               Enum.map(ids, &Index.symbol(index(@app), &1).attrs[:index])
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
