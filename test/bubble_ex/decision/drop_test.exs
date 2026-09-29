defmodule BubbleEx.Decision.DropTest do
  # The owner's drop decision (WTF-422) through the whole pipeline: the
  # record and its codec, resolve/3 (stale, orphaned, forged, dangling
  # references), applicable/2, Target.Ash (omission, dangling references,
  # privacy never widened, the input contract), the workflow and frontend
  # bindings, the Plan (closed tasks, residue), structural verification
  # (the decision bucket) and the loader (counts only). Hostile IDs and
  # determinism too. All data is invented.
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Decision, Index, Model, Plan}
  alias BubbleEx.Decision.{Applied, Drop, Resolved}
  alias BubbleEx.Index.Symbol
  alias BubbleEx.Target.Ash
  alias BubbleEx.Target.Ash.{Loader, Project}
  alias BubbleEx.Target.Phoenix.Structural.Coverage
  alias BubbleEx.Test.{DecidedFixture, HostileIds}

  @now ~U[2026-09-27 00:00:00Z]
  @task_lists [
    "field:project/legacy_tasks_list_custom_task",
    "field:project/tasks_list_custom_task",
    "field:user/pinned_tasks_list_custom_task",
    "field:user/starred_tasks_list_custom_task"
  ]

  setup_all do
    app = DecidedFixture.app()
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    %{app: app, model: model, index: index}
  end

  defp drop!(index, symbol, opts \\ []) do
    {:ok, d} = Decision.drop(index, symbol, "Not migrated.", opts)
    d
  end

  defp resolve!(records, index) do
    {:ok, resolved} = Decision.resolve(records, [], index: index, now: @now)
    resolved
  end

  defp states(resolved), do: Enum.map(resolved.entries, &{&1.state, &1.reasons})

  defp map!(model, records, index, opts \\ []) do
    applied = records |> resolve!(index) |> Decision.applicable([])

    Ash.map(
      model,
      applied,
      Keyword.merge([decisions_sha256: Decision.decisions_sha256(records), index: index], opts)
    )
  end

  defp codes(project, codes), do: for(d <- project.diagnostics, d.code in codes, do: d)

  defp message({:error, %BubbleEx.Error{kind: :invalid_input, message: m}}), do: m

  describe "the record" do
    test "is keyed to the symbol, with a rationale and a basis", %{index: index} do
      d = drop!(index, "data_type:task")

      assert d.kind == :drop and d.choice == :accept
      assert d.subject == %{type: "task"}
      assert d.params == %{symbol: :data_type, dangling: []}
      assert d.key == Drop.key(:data_type, %{type: "task"})
      assert "drop:" <> hex = d.key
      assert hex =~ ~r/\A[0-9a-f]{16}\z/
      assert d.basis.basis_sha256 == Index.subject_sha256(index, ["data_type:task"])

      # the key names the symbol only: accepting a dangling reference is a
      # new revision of the same key
      assert drop!(index, "data_type:task", dangling: @task_lists).key == d.key
    end

    test "round-trips its canonical JSON", %{index: index} do
      d = drop!(index, "data_type:task", dangling: Enum.take(@task_lists, 2), id: "dec_1")
      assert {:ok, ^d} = d |> Decision.to_json() |> Decision.from_json()
      assert Decision.to_json(d) == d |> Decision.to_map() |> CanonicalJson.encode()
    end

    test "needs a rationale, a basis and a subject that fits the symbol", %{index: index} do
      map = index |> drop!("field:project/note_text") |> Decision.to_map()

      for {change, error} <- [
            {%{"rationale" => nil}, "rationale"},
            {%{"rationale" => "  \n"}, "rationale"},
            {%{"basis" => %{}}, "basis_sha256"},
            {%{"basis" => %{"basis_sha256" => "abc"}}, "basis"},
            {%{"params" => %{"symbol" => "data_type", "dangling" => []}}, "subject"},
            {%{"params" => %{"symbol" => "plugin", "dangling" => []}}, "drop symbol"},
            {%{"params" => %{"symbol" => "field", "dangling" => ["field:a/b"]}}, "dangling"},
            {%{"params" => %{"symbol" => "field", "extra" => 1}}, "drop params"},
            {%{"expires_at" => "2027-01-01T00:00:00Z"}, "expires_at"},
            {%{"target" => "ash"}, "target"},
            {%{"key" => "drop:0000000000000000"}, "key"}
          ] do
        assert {:error, %{message: message}} = map |> Map.merge(change) |> Decision.from_map()
        assert message =~ error, inspect({change, message})
      end
    end

    test "refuses what cannot be dropped", %{index: index} do
      for symbol <- ["data_type:user", "field:task/Created Date", "data_type:ghost", "action:x"] do
        assert {:error, %{kind: :invalid_input}} = Decision.drop(index, symbol, "x")
      end

      assert {:error, %{message: m}} =
               Decision.drop(index, "data_type:task", "x", dangling: ["field:task/title_text"])

      assert m =~ "do not reference"
    end

    test "is withdrawn, not acknowledged", %{index: index} do
      d = drop!(index, "field:project/note_text")
      assert {:ok, w} = Decision.withdraw(d, rationale: "Needed after all.")
      assert w.revision == 2 and w.choice == :withdraw
      assert {:error, _} = Decision.acknowledge(d)

      resolved = resolve!([d, w], index)
      assert states(resolved) == [superseded: [:newer_revision], withdrawn: []]
      assert Decision.applicable(resolved, []) == []
    end

    test "the decision hash covers the drop, not its audit fields", %{index: index} do
      d = drop!(index, "field:project/note_text")
      sha = Decision.decisions_sha256([d])

      assert Decision.decisions_sha256([%{d | rationale: "Edited.", id: "x"}]) == sha
      refute Decision.decisions_sha256([drop!(index, "field:project/title_text")]) == sha

      with_dangling = drop!(index, "data_type:task", dangling: @task_lists)

      refute Decision.decisions_sha256([with_dangling]) ==
               Decision.decisions_sha256([drop!(index, "data_type:task")])
    end
  end

  describe "resolve/3" do
    test "a dangling reference blocks until dropped too or accepted", %{index: index} do
      bare = drop!(index, "data_type:task")
      resolved = resolve!([bare], index)
      assert states(resolved) == [active: [:dangling_references]]
      assert [_] = Resolved.blocking(resolved)

      # three accepted, the fourth dropped too
      accepted =
        drop!(index, "data_type:task",
          dangling: @task_lists -- ["field:project/tasks_list_custom_task"]
        )

      also = drop!(index, "field:project/tasks_list_custom_task")
      resolved = resolve!([accepted, also], index)
      assert Enum.all?(resolved.entries, &(&1.state == :active and &1.reasons == []))
      assert Resolved.blocking(resolved) == []

      # the field drop withdrawn: that reference dangles again
      {:ok, back} = Decision.withdraw(also)
      resolved = resolve!([accepted, also, back], index)

      assert Enum.find(resolved.entries, &(&1.decision == accepted)).reasons == [
               :dangling_references
             ]
    end

    test "a drop made against another version of its symbol is stale and blocks", %{
      app: app,
      index: index
    } do
      d = drop!(index, "field:project/note_text")
      changed = put_in(app, ["user_types", "project", "fields", "note_text", "value"], "number")
      {:ok, model2} = Model.build(changed)
      {:ok, index2} = Index.build(changed, model: model2)

      resolved = resolve!([d], index2)
      assert states(resolved) == [stale: [:basis_changed]]
      assert [_] = Resolved.blocking(resolved)
      assert Decision.applicable(resolved, []) == []
    end

    test "a drop whose symbol is gone is orphaned (archived)", %{app: app, index: index} do
      d = drop!(index, "field:project/note_text")
      gone = update_in(app, ["user_types", "project", "fields"], &Map.delete(&1, "note_text"))
      {:ok, model2} = Model.build(gone)
      {:ok, index2} = Index.build(gone, model: model2)

      resolved = resolve!([d], index2)
      assert states(resolved) == [orphaned: [:subject_gone]]
      assert Resolved.blocking(resolved) == []
      assert Resolved.archived(resolved) != []
    end

    test "a forged record never applies", %{index: index} do
      d = drop!(index, "field:project/note_text")

      # a hand-written basis: stale, blocking, applies nothing
      forged = %{d | basis: %{basis_sha256: String.duplicate("0", 64)}}
      resolved = resolve!([forged], index)
      assert states(resolved) == [stale: [:basis_changed]]
      assert Decision.applicable(resolved, []) == []

      # a hand-written drop of the User type or a built-in field
      for {subject, symbol} <- [
            {%{type: "user"}, :data_type},
            {%{type: "task", field: "Created Date"}, :field}
          ] do
        id = Drop.symbol_id(symbol, subject)

        {:ok, record} =
          Decision.new(
            kind: :drop,
            subject: subject,
            choice: :accept,
            params: %{symbol: symbol},
            basis: %{basis_sha256: Index.subject_sha256(index, [id])},
            rationale: "x"
          )

        resolved = resolve!([record], index)
        assert states(resolved) == [stale: [:params_invalid]]
        assert [_] = Resolved.blocking(resolved)
      end
    end

    test "applicable/2 lists active drops", %{index: index} do
      d = drop!(index, "workflow:wSyncOnly", id: "dec_w")
      assert [%Applied{} = a] = [d] |> resolve!(index) |> Decision.applicable([])

      assert a.kind == :drop and a.transform == :drop and a.key == d.key
      assert a.decision_id == "dec_w"
      assert a.subject == %{workflow: "wSyncOnly"}
      assert a.basis == %{basis_sha256: d.basis.basis_sha256}
      assert Drop.check_applied(a, index) == :ok
    end
  end

  describe "impact/2" do
    test "lists what a drop would break, as IDs", %{index: index} do
      assert {:ok, impact} = Drop.impact(index, "data_type:task")
      assert impact.kind == :data_type and impact.refusal == nil
      assert impact.dangling == @task_lists
      assert "field:task/title_text" in impact.removed
      assert "action:aCreateTask" in impact.dependents

      assert {:ok, %{callers: ["workflow:wSyncNotify"]}} =
               Drop.impact(index, "workflow:wSyncOnly")

      assert {:ok, %{refusal: :not_droppable}} = Drop.impact(index, "data_type:user")
      assert Drop.impact(index, "data_type:ghost") == :error
    end
  end

  describe "Target.Ash" do
    test "omits the dropped type, its fields and every relationship to it", %{
      model: model,
      index: index
    } do
      {:ok, project} =
        map!(model, [drop!(index, "data_type:task", dangling: @task_lists)], index)

      refute Enum.any?(project.resources, &(&1.source.type == "task"))

      for r <- project.resources,
          rel <- r.relationships,
          do: refute(rel.destination =~ "Task", inspect(rel))

      # an accepted reference keeps its IDs as strings, no relationship
      project_r = Enum.find(project.resources, &(&1.source.type == "project"))
      tasks = Enum.find(project_r.attributes, &(&1.source[:field] == "tasks_list_custom_task"))
      assert tasks.type == {:array, :string}
      assert length(codes(project, [:ash_drop_reference_accepted])) == 4
      assert [%{subject: %{type: "task"}}] = codes(project, [:ash_dropped_omitted])
      assert [%{kind: :drop}] = project.applied
    end

    test "an unaccepted dangling reference is an error diagnostic", %{
      model: model,
      index: index
    } do
      {:ok, project} = map!(model, [drop!(index, "data_type:task")], index)
      errors = codes(project, [:ash_drop_dangling_reference])
      assert length(errors) == 4
      assert Enum.all?(errors, &(&1.severity == :error))
      assert Enum.all?(errors, &(&1.details.drop == Drop.key(:data_type, %{type: "task"})))
    end

    test "a rule reading a dropped field compiles to deny, with a diagnostic", %{
      model: model,
      index: index
    } do
      records = [drop!(index, "field:workspace/members_list_user")]
      {:ok, faithful} = Ash.map(model, [], privacy: :unverified)
      {:ok, project} = map!(model, records, index, privacy: :unverified)

      reads = codes(project, [:ash_policy_reads_dropped])
      assert length(reads) == 2
      denied = MapSet.new(codes(project, [:ash_policy_rule_denied]), & &1.subject)
      for d <- reads, do: assert(MapSet.member?(denied, d.subject))

      # never wider: every check the drop leaves authorizes no more than
      # before (the rules reading the field are gone from the policies)
      for r <- project.resources do
        before = Enum.find(faithful.resources, &(&1.source == r.source))
        assert length(authorize_ifs(r)) <= length(authorize_ifs(before)), r.module
      end
    end

    test "keeps the capability probe's missing-subject error" do
      {:ok, empty} = Model.build(%{"_id" => "probe", "user_types" => %{}})
      sha = String.duplicate("0", 64)

      for {symbol, subject} <- [
            {:data_type, %{type: "capability_probe"}},
            {:field, %{type: "capability_probe", field: "capability_probe"}},
            {:option_set, %{option_set: "capability_probe"}}
          ] do
        a = %Applied{
          key: Drop.key(symbol, subject),
          kind: :drop,
          transform: :drop,
          subject: subject,
          params: %{symbol: symbol, dangling: []},
          basis_sha256: sha,
          basis: %{basis_sha256: sha}
        }

        assert {:error, %{kind: :invalid_input, message: m, context: context}} =
                 Ash.map(empty, [a], privacy: :omit, decisions_sha256: sha)

        assert m =~ "subject is not in the Model"
        assert context.subject == subject and not Map.has_key?(context, :transform)
      end
    end

    test "refuses forged, stale and conflicting entries", %{model: model, index: index} do
      d = drop!(index, "field:project/note_text")
      [a] = [d] |> resolve!(index) |> Decision.applicable([])
      sha = Decision.decisions_sha256([d])
      map = &Ash.map(model, &1, Keyword.merge([decisions_sha256: sha], &2))

      assert {:ok, _} = map.([a], index: index)
      assert map.([%{a | key: "drop:0000000000000000"}], []) |> message() =~ "malformed"
      assert map.([%{a | basis: nil}], []) |> message() =~ "stale or forged"

      other = String.duplicate("1", 64)
      forged = %{a | basis_sha256: other, basis: %{basis_sha256: other}}
      assert {:ok, _} = map.([forged], [])
      assert map.([forged], index: index) |> message() =~ "stale or forged"

      # an owner's decision about a dropped symbol: withdraw one
      rename = rename_applied(%{type: "project", field: "note_text"}, "attribute", "memo")
      assert map.([a, rename], []) |> message() =~ "dropped"

      # the User type and built-in fields
      for {subject, symbol} <- [
            {%{type: "user"}, :data_type},
            {%{type: "task", field: "Created Date"}, :field}
          ] do
        entry = %{a | subject: subject, params: %{symbol: symbol, dangling: []}}
        entry = %{entry | key: Drop.key(symbol, subject)}
        assert map.([entry], []) |> message() =~ "cannot be dropped"
      end
    end

    test "a hint about a dropped symbol applies nothing" do
      %{model: model, index: index, findings: findings} = DecidedFixture.build(:indexes)
      hints = for f <- findings, f.category == :hint, f.subject[:type] == "card", do: f
      assert hints != []

      {:ok, d} = Decision.drop(index, "data_type:card", "x", dangling: dangling(index, "card"))
      {:ok, resolved} = Decision.resolve([d], findings, index: index, now: @now)
      applied = Decision.applicable(resolved, findings)

      assert {:ok, project} =
               Ash.map(model, applied, decisions_sha256: Decision.decisions_sha256([d]))

      refute Enum.any?(project.applied, &(&1.subject[:type] == "card" and &1.kind != :drop))
    end

    test "is deterministic whatever the order of the records", %{model: model, index: index} do
      records = DecidedFixture.build(:drop).records
      {:ok, a} = map!(model, records, index)
      {:ok, b} = map!(model, Enum.reverse(records), index)
      assert Project.to_json(a) == Project.to_json(b)
      assert a.applied_sha256 == b.applied_sha256
    end
  end

  describe "workflows and pages" do
    test "a dropped backend workflow is not bound; its caller is residue", %{
      app: app,
      model: model,
      index: index
    } do
      {:ok, project} = map!(model, [drop!(index, "workflow:wSyncOnly")], index)
      {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
      {:ok, spec} = Ash.Workflows.map(backend, project, namespace: "Acme")

      actions = Ash.Workflows.actions(spec)
      refute Enum.any?(actions, &(&1.workflow == "wSyncOnly"))
      caller = Enum.find(actions, &(&1.workflow == "wSyncNotify"))
      refute Ash.Workflows.native?(caller)

      assert [%{reason: :uses_dropped, detail: %{symbol: "workflow:wSyncOnly"}}] =
               for(s <- caller.steps, r <- s.residue, r.reason == :uses_dropped, do: r)

      assert Enum.any?(spec.diagnostics, &(&1.code == :workflow_residue))
    end

    test "a dropped page is neither routed nor rendered; what uses it is residue" do
      app =
        "test/support/target/phoenix/frontend_workflows.json" |> File.read!() |> Jason.decode!()

      %{model: model, index: index, project: project} =
        DecidedFixture.dropped(app, ["page:bOther", "workflow:wEvt", "workflow:wApiNote"],
          privacy: :omit
        )

      {:ok, frontend} = BubbleEx.Frontend.normalize(app)
      {:ok, lowered} = BubbleEx.Workflows.Frontend.build(app, model, index)
      {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
      {:ok, backend} = Ash.Workflows.map(backend, project, namespace: "Shop")

      {:ok, flows} =
        BubbleEx.Target.Elixir.FrontendWorkflows.map(lowered, project,
          namespace: "Shop",
          frontend: frontend,
          backend: backend
        )

      workflows = BubbleEx.Target.Elixir.FrontendWorkflows.Spec.workflows(flows)
      refute Enum.any?(workflows, &(&1.workflow == "wEvt"))

      used =
        for w <- workflows,
            s <- w.steps,
            r <- s.residue,
            r.reason == :uses_dropped,
            do: {w.workflow, r.detail.symbol}

      assert Enum.sort(used) == [
               {"wCall", "workflow:wEvt"},
               {"wNav", "page:bOther"},
               {"wSchedule", "workflow:wApiNote"}
             ]

      {:ok, files} =
        BubbleEx.Target.Phoenix.render(project,
          module: "Shop",
          frontend: frontend,
          workflows: backend,
          frontend_workflows: flows
        )

      routes = files["lib/shop_web/bubble_routes.ex"]
      refute routes =~ "bOther"
      assert routes =~ "bHome"
      refute files[".wtf/surfaces.json"] =~ "bOther"
      refute Enum.any?(Map.keys(files), &(&1 =~ "other_live"))
    end
  end

  describe "the plan" do
    setup %{app: app, model: model, index: index} do
      %{records: records, applied: applied} = DecidedFixture.build(:drop)
      {:ok, frontend} = BubbleEx.Frontend.normalize(app)
      {:ok, plan} = Plan.build(model, index, frontend, applied)
      %{plan: plan, applied: applied, records: records, frontend: frontend}
    end

    test "each drop is a task closed by its decision", %{plan: plan, applied: applied} do
      drops = for a <- applied, a.kind == :drop, do: a
      tasks = for t <- plan.tasks, t.kind == :drop, do: t
      assert length(tasks) == length(drops)

      for a <- drops do
        id = Drop.symbol_id(a.params.symbol, a.subject)
        task = Plan.task(plan, "drop:" <> id)
        assert task.status == :closed and task.closed_by == a.key and task.actor == :generator
        assert id in task.subjects
        assert [%{check: :decision_recorded, args: %{key: key}} | _] = task.criteria
        assert key == a.key
      end

      assert "field:task/title_text" in Plan.task(plan, "drop:data_type:task").subjects
    end

    test "a dropped workflow's task covers its actions", %{plan: plan, index: index} do
      actions = for a <- Index.children(index, "workflow:wSyncOnly"), do: a.id
      assert actions != []

      assert Plan.task(plan, "drop:workflow:wSyncOnly").subjects ==
               Enum.sort(["workflow:wSyncOnly" | actions])
    end

    test "dropped symbols are nobody's work; what uses them is residue", %{plan: plan} do
      schema = Plan.task(plan, "generate:schema").subjects
      refute "data_type:task" in schema
      refute "field:project/note_text" in schema
      assert "field:project/title_text" in schema

      refute Plan.task(plan, "workflow:wSyncOnly")
      caller = Plan.task(plan, "workflow:wSyncNotify")
      assert Enum.any?(caller.residue, &(&1.reason == :uses_dropped))
      assert caller.status == :open

      assert Enum.any?(
               caller.depends_on,
               &(&1.kind == :decision and &1.task == "drop:workflow:wSyncOnly")
             )
    end

    test "round-trips its JSON and is deterministic", %{
      model: model,
      index: index,
      frontend: frontend,
      applied: applied,
      plan: plan
    } do
      json = Plan.to_json(plan)
      assert {:ok, decoded} = Plan.decode(json)
      assert Plan.to_json(decoded) == json
      {:ok, again} = Plan.build(model, index, frontend, Enum.reverse(applied))
      assert Plan.to_json(again) == Plan.to_json(plan)
    end

    test "refuses a forged or stale drop", %{model: model, index: index, applied: applied} do
      [a | _] = for a <- applied, a.kind == :drop, do: a
      other = String.duplicate("2", 64)
      forged = %{a | basis_sha256: other, basis: %{basis_sha256: other}}

      assert {:error, %{message: m}} =
               Plan.build(model, index, nil, [forged | List.delete(applied, a)])

      assert m =~ "stale or forged"
    end

    test "structural verification counts drops in the decision bucket", %{
      model: model,
      index: index,
      plan: plan
    } do
      {:ok, project} = DecidedFixture.project(:drop)
      accounted = Coverage.account(%{model: model, index: index, plan: plan, project: project})
      counts = Coverage.counts(accounted)

      assert counts["data_types"]["decision"] == 1
      assert counts["data_types"]["reasons"]["decision:owner_drop"] == 1
      # Task's own fields and built-ins, and the three fields dropped alone
      task_fields = Enum.count(accounted.fields, &(&1.subjects.type == "task"))
      assert counts["fields"]["reasons"]["decision:owner_drop"] == task_fields + 3
      assert counts["workflows"]["reasons"]["decision:owner_drop"] == 1
      assert counts["fields"]["uncovered"] == 0 and counts["data_types"]["uncovered"] == 0
    end
  end

  describe "the loader" do
    @describetag :tmp_dir

    test "skips dropped types and fields and reports them as counts", %{tmp_dir: dir} do
      alias BubbleEx.Test.LoadFixture, as: F
      {:ok, project} = F.project(:drop)
      {Loader, config} = Loader.target(project, query: fn _, _ -> {:ok, %{rows: []}} end)
      {:ok, plan} = Loader.plan(config, F.model(:drop))

      assert plan.dropped == ["task"]
      refute BubbleEx.Load.Plan.table(plan, "task")

      assert Enum.sort(BubbleEx.Load.Plan.table(plan, "project").skipped) == [
               %{field: "note_text", reason: :dropped},
               %{field: "tasks_list_custom_task", reason: :dropped}
             ]

      {:ok, export} = F.export(:drop, Path.join(dir, "export"))
      target = BubbleEx.Test.LoadMemoryTarget.start(project)
      {:ok, report} = BubbleEx.Load.dry_run(export, F.model(:drop), target)

      assert report.blocked == []
      diag = &Enum.find(report.diagnostics, fn d -> d.code == &1 and d.subject == &2 end)

      assert %{details: %{count: 1, sample_ids: []}} =
               diag.(:load_type_dropped, %{type: "task"})

      assert %{details: %{count: 2, sample_ids: []}} =
               diag.(:load_dropped_field_data, %{type: "project", field: "note_text"})

      assert %{details: %{count: 1}} =
               diag.(:load_dropped_field_data, %{type: "workspace", field: "members_list_user"})

      refute Enum.any?(
               report.diagnostics,
               &(&1.code in [:load_type_unmapped, :load_unmapped_key])
             )

      refute inspect(report) =~ "secret-note"
    end

    test "a plan with no drop hashes as before" do
      plan = %BubbleEx.Load.Plan{target: "x", tables: []}

      assert BubbleEx.Load.Plan.sha256(plan) !=
               BubbleEx.Load.Plan.sha256(%{plan | dropped: ["t"]})

      assert BubbleEx.Load.Plan.sha256(plan) ==
               CanonicalJson.sha256(%{
                 "target" => "x",
                 "auth" => nil,
                 "tables" => [],
                 "joins" => []
               })
    end
  end

  describe "hostile IDs" do
    test "drops of hostile symbols resolve, map and plan" do
      raw =
        "test/support/target/phoenix/frontend_workflows.json" |> File.read!() |> Jason.decode!()

      app = HostileIds.rename(raw, HostileIds.ids(raw))
      # a type and a field whose keys escape in symbol IDs
      type = ~s(t/~"\#{x}\n)
      field = ~s(f/~1"*/)

      app =
        put_in(app, ["user_types", type], %{
          "display" => "Hostile",
          "fields" => %{field => %{"display" => "F", "value" => "text"}}
        })

      page = Symbol.id(:page, HostileIds.hostile("bOther"))
      workflow = Symbol.id(:workflow, HostileIds.hostile("wEvt"))
      field_id = Symbol.id(:field, [type, field])

      %{records: records, resolved: resolved, project: project} =
        DecidedFixture.dropped(app, [page, workflow, field_id, Symbol.id(:data_type, "note")],
          privacy: :omit
        )

      assert Enum.all?(resolved.entries, &(&1.state == :active))
      field_drop = Enum.find(records, &(&1.params.symbol == :field))
      assert field_drop.subject == %{type: type, field: field}
      assert {:ok, ^field_drop} = field_drop |> Decision.to_json() |> Decision.from_json()
      assert Enum.all?(records, &(&1.key =~ ~r/\Adrop:[0-9a-f]{16}\z/))

      hostile = Enum.find(project.resources, &(&1.source.type == type))
      refute Enum.any?(hostile.attributes, &(&1.source[:field] == field))
      assert Project.dropped(project).pages == MapSet.new([HostileIds.hostile("bOther")])

      {:ok, model} = Model.build(app)
      {:ok, index} = Index.build(app, model: model)
      {:ok, plan} = Plan.build(model, index, nil, Decision.applicable(resolved, []))
      assert Plan.task(plan, "drop:" <> page).status == :closed
      json = Plan.to_json(plan)
      assert {:ok, decoded} = Plan.decode(json)
      assert Plan.to_json(decoded) == json
    end
  end

  # --- helpers ------------------------------------------------------------------

  defp dangling(index, type) do
    drop = %{params: %{symbol: :data_type}, subject: %{type: type}}
    Drop.referencing(index, drop, Drop.removed(index, [drop]))
  end

  defp authorize_ifs(%{policies: policies}),
    do: for(p <- policies, c <- p.checks, c.kind == :authorize_if, do: c)

  defp rename_applied(subject, slot, name) do
    {:ok, d} =
      Decision.new(
        kind: :rename,
        target: "ash",
        subject: subject,
        choice: :accept,
        params: %{slot: slot, name: name}
      )

    %Applied{
      key: d.key,
      kind: :rename,
      transform: :rename,
      subject: subject,
      target: "ash",
      params: d.params
    }
  end
end
