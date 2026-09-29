defmodule BubbleEx.Load.PruneTest do
  # Pruning (`prune:`, WTF-414) over the :cut3 fixture in the in-memory
  # target: only rows the loader wrote (BubbleEx.Load.Written) are deleted,
  # only with the export and database the record is bound to, only as the
  # dry run's plan confirmed by its hash, and never most of a type or list
  # without an explicit override. The same cases run against PostgreSQL in
  # scripts/ash_compile_check/load.exs.
  use ExUnit.Case, async: true

  alias BubbleEx.Load
  alias BubbleEx.Load.{Export, Ledger, Report, Written}
  alias BubbleEx.Test.LoadFixture, as: F
  alias BubbleEx.Test.LoadMemoryTarget, as: Memory

  @moduletag :tmp_dir

  @app_task "1700000000000x000000000000000800"

  defp setup_cut3(dir) do
    {:ok, export} = F.export(:cut3, Path.join(dir, "export"))
    {:ok, project} = F.project(:cut3)

    %{
      export: export,
      project: project,
      model: F.model(:cut3),
      target: Memory.start(project),
      ledger: Path.join(dir, "ledger"),
      dir: dir
    }
  end

  # Loaded, recording what the loader wrote.
  defp loaded(dir) do
    f = setup_cut3(dir)
    {:ok, _} = Load.run(f.export, f.model, f.target, ledger_dir: f.ledger)
    f
  end

  defp diag(%Report{diagnostics: ds}, code, type, field \\ nil),
    do:
      Enum.find(
        ds,
        &(&1.code == code and &1.subject[:type] == type and &1.subject[:field] == field)
      )

  defp join(project, type, field),
    do:
      Enum.find(project.joins, fn j ->
        Enum.any?(j.join.sides, &(&1.type == type and &1.field == field))
      end).join

  defp key(project, type, field), do: "#{join(project, type, field).id}/#{type}/#{field}"
  defp members(f), do: key(f.project, "workspace", "members_list_user")
  defp tasks(f), do: key(f.project, "project", "tasks_list_custom_task")

  defp ws_rows(target) do
    target
    |> Memory.tables()
    |> Map.get("user_workspaces", %{})
    |> Map.values()
    |> Enum.map(
      &{&1["user_id"], &1["workspace_id"], &1["workspaces_position"], &1["members_position"]}
    )
    |> Enum.sort()
  end

  # The second task is deleted in Bubble (and leaves Plan's Tasks); Ada
  # and Bob leave Acme's Members (Ada's Workspaces still list Acme).
  defp delta_rows do
    rows = F.cut3_rows()
    [w1 | ws] = rows["workspace"]
    [p1 | ps] = rows["project"]

    %{
      rows
      | "workspace" => [Map.put(w1, "Members", [F.gone_user()]) | ws],
        "project" => [Map.put(p1, "Tasks", [F.todo1(), F.todo1(), F.gone_task()]) | ps],
        "task" => Enum.reject(rows["task"], &(&1["_id"] == F.todo2()))
    }
  end

  defp delta(f, name \\ "delta", rows \\ nil, opts \\ []),
    do: F.export(:cut3, Path.join(f.dir, name), rows || delta_rows(), opts)

  # Rows created in the app after the load: a task, and a membership of
  # Bob in Beta.
  defp app_rows(target) do
    Memory.put_rows(target, "task", %{@app_task => %{"id" => @app_task, "title" => "app"}})

    Memory.put_rows(target, "user_workspaces", %{
      {F.bob(), F.workspace2()} => %{
        "user_id" => F.bob(),
        "workspace_id" => F.workspace2(),
        "members_position" => 5
      }
    })
  end

  defp app_membership, do: [F.bob(), F.workspace2()]

  # A written record lock's holder line: host, OS pid, Erlang pid.
  defp holder_line(host, os, pid), do: "#{host} #{os} #{:erlang.pid_to_list(pid)}"

  defp host do
    {:ok, host} = :inet.gethostname()
    List.to_string(host)
  end

  # The app's membership acknowledged (the loader wrote 4 members of the
  # list; losing 2 is not "most").
  defp settings(f), do: [acknowledge_unowned: %{members(f) => [app_membership()]}]

  # The dry run, then the real run confirmed by its hash.
  defp prune!(f, export, settings, opts \\ []) do
    opts = [ledger_dir: f.ledger] ++ opts
    {:ok, dry} = Load.dry_run(export, f.model, f.target, [prune: settings] ++ opts)
    assert dry.blocked == [], inspect(dry.blocked)
    expect = [expect: dry.prune.sha256] ++ settings
    {dry, Load.run(export, f.model, f.target, [prune: expect] ++ opts)}
  end

  describe "options" do
    test "pruning needs a complete export, a ledger directory and confirmation", %{
      tmp_dir: dir
    } do
      f = loaded(dir)
      opts = [ledger_dir: f.ledger]

      assert {:error, %{message: m}} =
               Load.run(f.export, f.model, f.target, [prune: true, allow_partial: true] ++ opts)

      assert m =~ "allow_partial"
      assert {:error, %{message: m}} = Load.dry_run(f.export, f.model, f.target, prune: true)
      assert m =~ ":ledger_dir"

      # a bare prune: true only plans: a real run needs the dry run's hash
      assert {:error, %{message: m}} =
               Load.run(f.export, f.model, f.target, [prune: true] ++ opts)

      assert m =~ "expect"

      assert {:error, %{message: m}} =
               Load.run(f.export, f.model, f.target, [prune: [expect: 1]] ++ opts)

      assert m =~ "sha256"
      assert {:error, _} = Load.dry_run(f.export, f.model, f.target, [prune: [nope: 1]] ++ opts)

      {:ok, partial} =
        Export.write(Path.join(dir, "partial"), %{
          types: [
            %{type: "workspace", path: "workspace", rows: F.cut3_rows()["workspace"]},
            %{type: "task", path: "task", error: "not_found"}
          ]
        })

      assert {:error, %{message: m, context: %{types: ["task"]}}} =
               Load.dry_run(partial, f.model, f.target, [prune: true] ++ opts)

      assert m =~ "complete export"
    end

    test "a type the loader wrote that the export lacks refuses to prune", %{tmp_dir: dir} do
      f = loaded(dir)
      before = Memory.tables(f.target)
      {:ok, no_tasks} = delta(f, "no-tasks", Map.delete(F.cut3_rows(), "task"))

      assert {:error, %{context: %{types: ["task"]}, message: m}} =
               Load.dry_run(no_tasks, f.model, f.target, prune: true, ledger_dir: f.ledger)

      assert m =~ "delete all of their records"
      assert Memory.tables(f.target) == before
    end
  end

  describe "pruning" do
    test "the dry run reports and hashes the plan; the confirmed run deletes exactly the loader's rows",
         %{tmp_dir: dir} do
      f = loaded(dir)
      app_rows(f.target)
      {:ok, delta} = delta(f)

      # Without prune the removed members block, as before.
      {:ok, plain} = Load.dry_run(delta, f.model, f.target, ledger_dir: f.ledger)
      assert plain.blocked == [:load_join_stale_member]
      assert plain.prune == nil

      before = Memory.tables(f.target)
      {dry, {:ok, run}} = prune!(f, delta, settings(f))
      assert Memory.tables(f.target) != before

      assert %{sha256: sha, types: types, joins: joins} = dry.prune
      assert is_binary(sha) and byte_size(sha) == 64
      assert types == %{"task" => %{delete: 1, owned: 2, unowned: 1}}

      assert joins == %{
               tasks(f) => %{remove: 1, owned: 3, unowned: 0},
               members(f) => %{remove: 2, owned: 4, unowned: 1}
             }

      assert %{severity: :info, details: %{count: 1, sample_ids: [todo2]}} =
               diag(dry, :load_prune_record, "task")

      assert todo2 == F.todo2()

      assert %{severity: :warning, details: %{count: 1, sample_ids: [@app_task]}} =
               diag(dry, :load_prune_unowned, "task")

      unowned = diag(dry, :load_prune_unowned, "workspace", "members_list_user")
      assert unowned.severity == :warning
      assert unowned.details.stale_members.rows == [app_membership()]

      assert run.prune.sha256 == sha

      assert run.prune.types == %{
               "task" => %{delete: 1, owned: 2, unowned: 1, deleted: 1, cleared: 0}
             }

      assert run.prune.joins == %{
               tasks(f) => %{remove: 1, owned: 3, unowned: 0, deleted: 1, cleared: 0},
               members(f) => %{remove: 2, owned: 4, unowned: 1, deleted: 1, cleared: 1}
             }

      tables = Memory.tables(f.target)
      assert Map.keys(tables["task"]) |> Enum.sort() == Enum.sort([F.todo1(), @app_task])

      assert tables["project_tasks"] |> Map.values() |> Enum.map(& &1["task_id"]) |> Enum.sort() ==
               Enum.sort([F.todo1(), F.gone_task()])

      # Ada: Acme's Members column cleared, her Workspaces' kept; Bob's
      # Acme row (only a member) deleted; the app's Beta row kept.
      assert ws_rows(f.target) ==
               Enum.sort([
                 {F.ada(), F.workspace1(), 0, nil},
                 {F.gone_user(), F.workspace1(), nil, 0},
                 {F.bob(), F.workspace2(), nil, 5},
                 {F.carol(), F.workspace2(), 0, 0},
                 {F.carol(), F.workspace1(), 1, nil}
               ])

      {:ok, written} = Written.read(f.ledger, "memory")
      refute MapSet.member?(Written.records(written, "task"), F.todo2())
      assert MapSet.member?(Written.records(written, "task"), F.todo1())
      refute MapSet.member?(Written.records(written, "task"), @app_task)

      # Idempotent: a rerun (its own, now empty, plan) prunes nothing more.
      {again_dry, {:ok, again}} =
        prune!(f, delta, acknowledge_unowned: %{members(f) => [app_membership()]})

      assert again_dry.prune.types == %{"task" => %{delete: 0, owned: 1, unowned: 1}}
      assert again.prune.types["task"].deleted == 0
      assert Memory.tables(f.target) == tables

      text = run |> Report.to_map() |> Jason.encode!()
      refute text =~ "Acme"
      refute text =~ "Review"
    end

    test "a real run refuses a plan other than the one confirmed", %{tmp_dir: dir} do
      f = loaded(dir)
      {:ok, delta} = delta(f)
      opts = [ledger_dir: f.ledger]
      s = []
      {:ok, dry} = Load.dry_run(delta, f.model, f.target, [prune: s] ++ opts)
      before = Memory.tables(f.target)

      # another export (the same deletions): another plan
      other_rows =
        Map.update!(delta_rows(), "project", fn [p1 | ps] ->
          [Map.put(p1, "Title", "Plan B") | ps]
        end)

      {:ok, other} = delta(f, "other", other_rows)

      assert {:error, %{message: m, context: context} = refused} =
               Load.run(
                 other,
                 f.model,
                 f.target,
                 [prune: [expect: dry.prune.sha256] ++ s] ++ opts
               )

      assert m =~ "not the one confirmed"
      assert m =~ "Dry-run"
      # the refusal does not leak the hash that would confirm the other plan
      assert context == %{reason: :unconfirmed}
      {:ok, other_dry} = Load.dry_run(other, f.model, f.target, [prune: s] ++ opts)
      refute inspect(refused) =~ other_dry.prune.sha256

      # a hash that confirms nothing
      assert {:error, %{message: "pruning refused: the prune plan" <> _}} =
               Load.run(
                 delta,
                 f.model,
                 f.target,
                 [prune: [expect: String.duplicate("0", 64)] ++ s] ++ opts
               )

      assert Memory.tables(f.target) == before
    end

    test "a crash mid-prune resumes under the same confirmation and never deletes a row the loader did not write",
         %{tmp_dir: dir} do
      f = loaded(dir)
      app_rows(f.target)
      {:ok, delta} = delta(f)
      opts = [ledger_dir: f.ledger, batch_size: 1]

      # The same prune, uninterrupted, on another target.
      clean = %{f | target: Memory.start(f.project), ledger: Path.join(dir, "clean-ledger")}
      {:ok, _} = Load.run(f.export, f.model, clean.target, ledger_dir: clean.ledger)
      app_rows(clean.target)
      {_, {:ok, _}} = prune!(clean, delta, settings(f), batch_size: 1)

      {:ok, dry} = Load.dry_run(delta, f.model, f.target, [prune: settings(f)] ++ opts)
      confirmed = [prune: [expect: dry.prune.sha256] ++ settings(f)] ++ opts

      # The 3rd prune batch fails: two are done.
      Memory.fail_prune(f.target, 3)

      assert {:error, %{context: %{reason: :injected}}} =
               Load.run(delta, f.model, f.target, confirmed)

      mid = Memory.tables(f.target)
      assert mid["task"][@app_task]
      assert Enum.any?(ws_rows(f.target), &(&1 == {F.bob(), F.workspace2(), nil, 5}))

      # What is left is another plan (a subset): the run's ledger holds
      # the confirmed one, so the same expect resumes it.
      {:ok, left} = Load.dry_run(delta, f.model, f.target, [prune: settings(f)] ++ opts)
      assert left.prune.sha256 != dry.prune.sha256

      Memory.fail_prune(f.target, nil)
      {:ok, resumed} = Load.run(delta, f.model, f.target, confirmed)
      assert Memory.tables(f.target) == Memory.tables(clean.target)

      done =
        (Map.values(resumed.prune.types) ++ Map.values(resumed.prune.joins))
        |> Enum.map(&(&1.deleted + &1.cleared))
        |> Enum.sum()

      assert done == 4
      assert resumed.types["task"].resumed == 1
    end

    test "rows of a target loaded without a record are kept and reported", %{tmp_dir: dir} do
      f = setup_cut3(dir)
      # loaded without a ledger directory: nothing records what was written
      {:ok, _} = Load.run(f.export, f.model, f.target)
      {:ok, delta} = delta(f)
      before = Memory.tables(f.target)

      {:ok, dry} = Load.dry_run(delta, f.model, f.target, prune: true, ledger_dir: f.ledger)
      assert dry.blocked == [:load_join_stale_member]
      stale = diag(dry, :load_join_stale_member, "workspace", "members_list_user")
      assert length(stale.details.stale_members.rows) == 2

      # every stale row is unowned: acknowledged by name, list by list
      ack =
        for d <- dry.diagnostics, d.code == :load_join_stale_member, into: %{} do
          {key(f.project, d.subject.type, d.subject.field), d.details.stale_members.rows}
        end

      assert map_size(ack) == 2
      {_, {:ok, run}} = prune!(f, delta, acknowledge_unowned: ack)

      assert run.prune.types == %{
               "task" => %{delete: 0, owned: 0, unowned: 1, deleted: 0, cleared: 0}
             }

      assert Memory.tables(f.target)["task"] == before["task"]
      assert diag(run, :load_prune_unowned, "workspace", "members_list_user").details.count == 2
      assert length(ws_rows(f.target)) == 5
    end
  end

  describe "the export must be the target's (H1)" do
    test "another app, another version, an older export are refused", %{tmp_dir: dir} do
      f = loaded(dir)
      before = Memory.tables(f.target)
      opts = [prune: true, ledger_dir: f.ledger]

      {:ok, other_app} = delta(f, "other-app", nil, app: "another-app")

      assert {:error, %{context: %{reason: :app}}} =
               Load.dry_run(other_app, f.model, f.target, opts)

      # also a plain load: its IDs would join this app's record
      assert {:error, %{context: %{reason: :app}}} =
               Load.run(other_app, f.model, f.target, ledger_dir: f.ledger)

      {:ok, live} = delta(f, "live", nil, base_url: "https://acme.bubbleapps.io")

      assert {:error, %{context: %{reason: :base_url}}} =
               Load.dry_run(live, f.model, f.target, opts)

      {:ok, older} = delta(f, "older", nil, created_at: "2026-09-01T00:00:00Z")

      assert {:error, %{context: %{reason: :older_export}}} =
               Load.dry_run(older, f.model, f.target, opts)

      {:ok, undated} = delta(f, "undated", nil, created_at: nil)

      assert {:error, %{context: %{reason: :created_at}}} =
               Load.dry_run(undated, f.model, f.target, opts)

      assert Memory.tables(f.target) == before
    end

    test "a type or list losing all or most of the loader's rows blocks unless named", %{
      tmp_dir: dir
    } do
      f = loaded(dir)
      before = Memory.tables(f.target)

      # present but empty (e.g. read with a non-admin token): every task
      {:ok, empty} = delta(f, "empty-tasks", Map.put(F.cut3_rows(), "task", []))
      {:ok, dry} = Load.dry_run(empty, f.model, f.target, prune: true, ledger_dir: f.ledger)
      assert dry.blocked == [:load_prune_mass_delete]

      assert %{severity: :error, details: %{count: 2, owned: 2, key: "task"}} =
               diag(dry, :load_prune_mass_delete, "task")

      assert {:error, %{context: %{blocked: [:load_prune_mass_delete]}}} =
               Load.run(empty, f.model, f.target,
                 prune: [expect: dry.prune.sha256],
                 ledger_dir: f.ledger
               )

      # more than half of a list: 3 of the 4 members the loader wrote
      rows = F.cut3_rows()
      [w1 | ws] = rows["workspace"]

      {:ok, delta} =
        delta(f, "most", %{rows | "workspace" => [Map.put(w1, "Members", []) | ws]})

      {:ok, most} = Load.dry_run(delta, f.model, f.target, prune: true, ledger_dir: f.ledger)
      assert most.blocked == [:load_prune_mass_delete]

      assert %{details: %{count: 3, owned: 4}} =
               diag(most, :load_prune_mass_delete, "workspace", "members_list_user")

      refute diag(most, :load_prune_mass_delete, "task")
      assert Memory.tables(f.target) == before

      # named: it loads
      {_, {:ok, _}} = prune!(f, delta, allow_mass_delete: [members(f)])
      assert ws_rows(f.target) |> Enum.map(&elem(&1, 3)) |> Enum.reject(&is_nil/1) == [0]
    end
  end

  describe "unowned stale members (H2)" do
    test "block with prune unless acknowledged by name", %{tmp_dir: dir} do
      f = loaded(dir)
      app_rows(f.target)
      {:ok, delta} = delta(f)
      opts = [ledger_dir: f.ledger]
      s = []

      {:ok, dry} = Load.dry_run(delta, f.model, f.target, [prune: s] ++ opts)
      assert dry.blocked == [:load_join_stale_member]
      stale = diag(dry, :load_join_stale_member, "workspace", "members_list_user")
      assert %{severity: :error, details: %{count: 1}} = stale
      assert stale.details.stale_members.rows == [app_membership()]
      # the loader's own stale members are pruned, not blocking
      assert diag(dry, :load_prune_join_member, "workspace", "members_list_user").details.count ==
               2

      before = Memory.tables(f.target)

      assert {:error, %{context: %{blocked: [:load_join_stale_member], report: report}}} =
               Load.run(
                 delta,
                 f.model,
                 f.target,
                 [prune: [expect: dry.prune.sha256] ++ s] ++ opts
               )

      # a blocked real run's report carries no hash to confirm with
      assert report.prune.sha256 == nil
      assert Memory.tables(f.target) == before

      # acknowledging another row does not acknowledge it
      wrong = s ++ [acknowledge_unowned: %{members(f) => [[F.ada(), F.workspace2()]]}]
      {:ok, still} = Load.dry_run(delta, f.model, f.target, [prune: wrong] ++ opts)
      assert still.blocked == [:load_join_stale_member]

      {_, {:ok, _}} = prune!(f, delta, settings(f))
      assert Enum.any?(ws_rows(f.target), &(&1 == {F.bob(), F.workspace2(), nil, 5}))
    end
  end

  describe "the record is bound to the database (M1)" do
    test "a marker mismatch or a missing marker refuses to prune", %{tmp_dir: dir} do
      f = loaded(dir)
      marker = Memory.marker_of(f.target)
      assert is_binary(marker)
      assert Written.bound(elem(Written.read(f.ledger, "memory"), 1)).marker == marker
      {:ok, delta} = delta(f)
      opts = [prune: true, ledger_dir: f.ledger]

      Memory.set_marker(f.target, "11111111-1111-4111-8111-111111111111")

      assert {:error, %{context: %{reason: :marker_mismatch}}} =
               Load.dry_run(delta, f.model, f.target, opts)

      Memory.set_marker(f.target, nil)

      assert {:error, %{context: %{reason: :marker_missing}}} =
               Load.dry_run(delta, f.model, f.target, opts)

      # Another database at the same address (the same identity): a plain
      # load resets the record, which then holds only what it wrote there.
      other = Memory.start(f.project)
      {:ok, _} = Load.run(f.export, f.model, other, ledger_dir: f.ledger)
      {:ok, written} = Written.read(f.ledger, "memory")
      assert Written.bound(written).marker == Memory.marker_of(other)
      assert Written.records(written, "task") == MapSet.new([F.todo1(), F.todo2()])
    end
  end

  describe "locks (M2)" do
    test "a run needs the target's lock; a dry run does not", %{tmp_dir: dir} do
      f = loaded(dir)
      holder = spawn(fn -> Process.sleep(:infinity) end)
      Memory.hold_lock(f.target, holder)

      assert {:error, %{context: %{reason: :locked}}} =
               Load.run(f.export, f.model, f.target, ledger_dir: f.ledger)

      assert {:ok, _} = Load.dry_run(f.export, f.model, f.target, ledger_dir: f.ledger)

      # a holder that died (a killed run) holds none
      Process.exit(holder, :kill)
      assert {:ok, _} = Load.run(f.export, f.model, f.target, ledger_dir: f.ledger)
    end

    test "the written record is locked while a run records into it", %{tmp_dir: dir} do
      f = loaded(dir)
      lock = Written.path(f.ledger, "memory") <> ".lock"

      ledger_files = fn -> f.ledger |> Path.join("*") |> Path.wildcard() |> Enum.sort() end

      # a live holder (this OS process, a live Erlang process)
      holder = spawn(fn -> Process.sleep(:infinity) end)
      File.write!(lock, holder_line(host(), System.pid(), holder))
      before = ledger_files.()

      assert {:error, %{message: "another load is recording" <> _}} =
               Load.run(f.export, f.model, f.target, ledger_dir: f.ledger)

      # the lock is taken before the run's ledger is opened
      assert ledger_files.() == before

      # another host's lock is never taken over, even with no such process here
      File.write!(lock, holder_line("another-host.example", "999999999", holder))

      assert {:error, %{message: "another load is recording" <> _}} =
               Load.run(f.export, f.model, f.target, ledger_dir: f.ledger)

      # a takeover in progress (its lock present) is not raced
      File.write!(lock, holder_line(host(), "999999999", holder))
      File.write!(lock <> ".takeover", holder_line(host(), System.pid(), holder))

      assert {:error, %{message: "another load is taking over" <> _}} =
               Load.run(f.export, f.model, f.target, ledger_dir: f.ledger)

      File.rm!(lock <> ".takeover")

      # a lock of this host whose process is gone is taken over, and released
      assert {:ok, _} = Load.run(f.export, f.model, f.target, ledger_dir: f.ledger)
      refute File.exists?(lock)

      # this OS process, but an Erlang process that died (a killed run)
      Process.exit(holder, :kill)
      File.write!(lock, holder_line(host(), System.pid(), holder))
      assert {:ok, _} = Load.run(f.export, f.model, f.target, ledger_dir: f.ledger)
      refute File.exists?(lock)
      assert Path.wildcard(lock <> "*") == []
    end
  end

  describe "forgetting (M3)" do
    test "a load forgets recorded join rows the target no longer holds", %{tmp_dir: dir} do
      f = loaded(dir)
      {:ok, delta} = delta(f)

      # The app removes Bob from Acme; a plain load of the delta (Bob not
      # listed) forgets that row.
      tables = Memory.tables(f.target)

      Agent.update(elem(f.target, 1).agent, fn s ->
        %{
          s
          | tables:
              Map.put(
                tables,
                "user_workspaces",
                Map.delete(tables["user_workspaces"], {F.bob(), F.workspace1()})
              )
        }
      end)

      {:ok, before} = Written.read(f.ledger, "memory")
      assert MapSet.member?(Written.pairs(before, members(f)), {F.bob(), F.workspace1()})

      # Ada's removal still blocks a plain load; acknowledge it by pruning
      # later. Here only the forgetting matters: a dry run forgets nothing.
      {:ok, _} = Load.dry_run(delta, f.model, f.target, ledger_dir: f.ledger)
      {:ok, same} = Written.read(f.ledger, "memory")
      assert Written.seq(same) == Written.seq(before)

      {:ok, _} = Load.run(f.export, f.model, f.target, ledger_dir: f.ledger)
      {:ok, reloaded} = Written.read(f.ledger, "memory")
      # the original export lists Bob again: rewritten, recorded again
      assert MapSet.member?(Written.pairs(reloaded, members(f)), {F.bob(), F.workspace1()})

      tables = Memory.tables(f.target)

      Agent.update(elem(f.target, 1).agent, fn s ->
        %{
          s
          | tables:
              Map.put(
                tables,
                "user_workspaces",
                Map.delete(tables["user_workspaces"], {F.bob(), F.workspace1()})
              )
        }
      end)

      rows = F.cut3_rows()
      [w1 | ws] = rows["workspace"]

      {:ok, no_bob} =
        delta(f, "no-bob", %{
          rows
          | "workspace" => [Map.put(w1, "Members", [F.ada(), F.gone_user()]) | ws]
        })

      {:ok, _} = Load.run(no_bob, f.model, f.target, ledger_dir: f.ledger)
      {:ok, forgot} = Written.read(f.ledger, "memory")
      refute MapSet.member?(Written.pairs(forgot, members(f)), {F.bob(), F.workspace1()})

      # The app adds Bob back: not the loader's row, so pruning keeps it
      # (it blocks until acknowledged).
      Memory.put_rows(f.target, "user_workspaces", %{
        {F.bob(), F.workspace1()} => %{
          "user_id" => F.bob(),
          "workspace_id" => F.workspace1(),
          "members_position" => 9
        }
      })

      {:ok, dry} = Load.dry_run(no_bob, f.model, f.target, prune: true, ledger_dir: f.ledger)
      assert dry.blocked == [:load_join_stale_member]

      {_, {:ok, _}} =
        prune!(f, no_bob, acknowledge_unowned: %{members(f) => [[F.bob(), F.workspace1()]]})

      assert Enum.any?(ws_rows(f.target), &(&1 == {F.bob(), F.workspace1(), nil, 9}))
      _ = delta
    end
  end

  describe "reused emails" do
    # Carol is deleted in Bubble and a new signup reuses her email.
    defp reused_rows do
      rows = F.cut3_rows()
      [ada, bob, _carol] = rows["user"]

      newcomer = %{
        "_id" => F.id(800),
        "Created Date" => "2024-09-01T00:00:00Z",
        "authentication" => %{
          "email" => %{"email" => "Carol@example.test", "email_confirmed" => false}
        }
      }

      [w1, w2] = rows["workspace"]

      %{
        rows
        | "user" => [ada, bob, newcomer],
          "workspace" => [w1, Map.put(w2, "members_list_user", [])]
      }
    end

    test "a pruned holder of a reused email loads with prune", %{tmp_dir: dir} do
      f = loaded(dir)
      {:ok, delta} = delta(f, "reused", reused_rows())

      {:ok, plain} = Load.dry_run(delta, f.model, f.target, ledger_dir: f.ledger)
      assert :load_email_conflict in plain.blocked

      # Carol's own lists go with her: 2 of the 3 Workspaces rows the
      # loader wrote, "most", named
      workspaces = key(f.project, "user", "workspaces_list_custom_workspace")
      {:ok, most} = Load.dry_run(delta, f.model, f.target, prune: true, ledger_dir: f.ledger)
      assert most.blocked == [:load_prune_mass_delete]
      assert diag(most, :load_prune_mass_delete, "user", "workspaces_list_custom_workspace")
      {dry, {:ok, _}} = prune!(f, delta, allow_mass_delete: [workspaces])
      refute diag(dry, :load_email_conflict, "user", "email")
      assert dry.prune.types["user"] == %{delete: 1, owned: 3, unowned: 0}

      users = Memory.tables(f.target)["user"]
      refute Map.has_key?(users, F.carol())
      assert users[F.id(800)]["email"] == "Carol@example.test"
    end

    test "a holder the loader did not write still blocks", %{tmp_dir: dir} do
      f = loaded(dir)
      app_user = F.id(801)

      Memory.put_rows(f.target, "user", %{
        app_user => %{"id" => app_user, "email" => "dora@example.test"}
      })

      rows =
        Map.update!(F.cut3_rows(), "user", fn [ada, bob, carol] ->
          [ada, bob, put_in(carol, ["authentication", "email", "email"], "dora@example.test")]
        end)

      {:ok, delta} = delta(f, "held", rows)
      {:ok, dry} = Load.dry_run(delta, f.model, f.target, prune: true, ledger_dir: f.ledger)
      assert dry.blocked == [:load_email_conflict]
      assert %{severity: :warning} = diag(dry, :load_prune_unowned, "user")
    end
  end

  describe "the written record (L1, L2)" do
    test "records IDs durably, replays its journal, and a read writes nothing", %{tmp_dir: dir} do
      ledger = Path.join(dir, "ledger")
      {:ok, _} = Written.read(ledger, "db")
      refute File.exists?(ledger)

      {:ok, w} = Written.open(ledger, "db", compact_every: 3)
      w = Written.bind(w, "m-1", "app", "https://x")
      w = Written.wrote(w, "task", ["a", "b"])
      w = Written.wrote(w, "task", ["b", "c"])
      w = Written.wrote_join(w, "j/t/f", [{"a", "x"}])
      w = Written.pruned(w, "task", ["a", "zz"])
      w = Written.wrote(w, "user", ["u"])
      # a crash: the journal is not compacted, its last line torn, and
      # the lock's process gone
      :file.close(w.journal)
      path = Written.path(ledger, "db")
      journal = String.replace_suffix(path, ".json", ".journal")
      File.write!(journal, "{\"seq\":", [:append])
      File.write!(path <> ".lock", holder_line(host(), "999999999", self()))

      {:ok, again} = Written.read(ledger, "db")
      assert Written.records(again, "task") == MapSet.new(["b", "c"])
      assert Written.records(again, "user") == MapSet.new(["u"])
      assert Written.pairs(again, "j/t/f") == MapSet.new([{"a", "x"}])
      assert Written.types(again) == ["task", "user"]
      assert Written.bound(again).marker == "m-1"

      # another target has its own record
      {:ok, other} = Written.read(ledger, "other-db")
      assert Written.types(other) == []

      {:ok, reopened} = Written.open(ledger, "db")
      assert {:error, _} = Written.open(ledger, "db")
      reopened = Written.pruned_join(reopened, "j/t/f", [{"a", "x"}])
      Written.close(reopened)
      {:ok, last} = Written.read(ledger, "db")
      assert Written.lists(last) == []
      assert Written.records(last, "task") == MapSet.new(["b", "c"])
      %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o777) == 0o600

      # rebinding to another marker (a recreated database) forgets it all
      {:ok, w} = Written.open(ledger, "db")
      w = Written.bind(w, "m-2", "app", "https://x")
      assert Written.empty?(w)
      Written.close(w)
    end

    test "a corrupt journal line, an event of another target, or a malformed record fail closed",
         %{tmp_dir: dir} do
      ledger = Path.join(dir, "ledger")
      {:ok, w} = Written.open(ledger, "db", compact_every: 100)
      w = Written.wrote(w, "task", ["a"])
      :file.close(w.journal)
      File.rm!(w.lock)
      path = Written.path(ledger, "db")
      journal = String.replace_suffix(path, ".json", ".journal")
      good = File.read!(journal)

      # a line in the middle that does not decode
      File.write!(journal, "not json\n" <> good)
      assert {:error, %{message: m}} = Written.read(ledger, "db")
      assert m =~ "corrupt"

      # an event of another target
      File.write!(journal, String.replace(good, ~s("target":"db"), ~s("target":"other")))
      assert {:error, _} = Written.read(ledger, "db")

      # an event of an unknown shape
      File.write!(journal, good <> ~s({"seq":99,"target":"db","wrote":"task","ids":[1]}\n))
      assert {:error, _} = Written.read(ledger, "db")

      # a malformed record
      File.rm!(journal)

      File.write!(
        path,
        Jason.encode!(%{
          "format" => "bubble_ex.load_written",
          "version" => 1,
          "target" => "db",
          "records" => %{"task" => [1, 2]}
        })
      )

      assert {:error, %{message: m}} = Written.read(ledger, "db")
      assert m =~ "unreadable"
    end

    test "the run ledger fails closed on a corrupt line too", %{tmp_dir: dir} do
      ids = %{export_sha256: "e", plan_sha256: "p", target: "t"}
      {:ok, l} = Ledger.open(dir, ids, compact_every: 100)
      l = Ledger.batch(l, "card", 5, %{inserted: 5, updated: 0, unchanged: 0})
      Ledger.close(l)
      [journal] = Path.wildcard(Path.join(dir, "*.journal"))
      File.write!(journal, "garbage\n" <> File.read!(journal))
      assert {:error, %{message: m}} = Ledger.open(dir, ids)
      assert m =~ "corrupt"
    end
  end
end
