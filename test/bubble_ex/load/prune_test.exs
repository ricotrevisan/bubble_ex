defmodule BubbleEx.Load.PruneTest do
  # Pruning (`prune: true`, WTF-414) over the :cut3 fixture in the
  # in-memory target: only rows the loader wrote (BubbleEx.Load.Written)
  # are deleted; the others are kept and reported. The same cases run
  # against PostgreSQL in scripts/ash_compile_check/load.exs.
  use ExUnit.Case, async: true

  alias BubbleEx.Load
  alias BubbleEx.Load.{Export, Report, Written}
  alias BubbleEx.Test.LoadFixture, as: F
  alias BubbleEx.Test.LoadMemoryTarget, as: Memory

  @moduletag :tmp_dir

  defp setup_cut3(dir) do
    {:ok, export} = F.export(:cut3, Path.join(dir, "export"))
    {:ok, project} = F.project(:cut3)

    %{
      export: export,
      project: project,
      model: F.model(:cut3),
      target: Memory.start(project),
      ledger: Path.join(dir, "ledger")
    }
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

  # A join row of the memory target, by its two IDs' columns.
  defp pair(project, type, field, row) do
    j = join(project, type, field)
    {row[j.left.column], row[j.right.column]}
  end

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

  # The second task is deleted in Bubble (and leaves Plan's Tasks); Ada and Bob
  # leave Acme's Members (Ada's Workspaces still list Acme).
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

  @app_task "1700000000000x000000000000000800"

  # Rows created in the app after the load: a task, and a membership of
  # Bob in Beta.
  defp app_rows(f) do
    Memory.put_rows(f.target, "task", %{@app_task => %{"id" => @app_task, "title" => "app"}})

    row = %{"user_id" => F.bob(), "workspace_id" => F.workspace2(), "members_position" => 5}

    Memory.put_rows(f.target, "user_workspaces", %{
      pair(f.project, "workspace", "members_list_user", row) => row
    })
  end

  describe "options" do
    test "prune needs a complete export and a ledger directory", %{tmp_dir: dir} do
      f = setup_cut3(dir)

      assert {:error, %{message: m}} =
               Load.run(f.export, f.model, f.target,
                 prune: true,
                 allow_partial: true,
                 ledger_dir: f.ledger
               )

      assert m =~ "allow_partial"
      assert {:error, %{message: m}} = Load.dry_run(f.export, f.model, f.target, prune: true)
      assert m =~ ":ledger_dir"

      {:ok, partial} =
        Export.write(Path.join(dir, "partial"), %{
          types: [
            %{type: "workspace", path: "workspace", rows: F.cut3_rows()["workspace"]},
            %{type: "task", path: "task", error: "not_found"}
          ]
        })

      assert {:error, %{message: m, context: %{types: ["task"]}}} =
               Load.dry_run(partial, f.model, f.target, prune: true, ledger_dir: f.ledger)

      assert m =~ "complete export"
      assert Memory.tables(f.target) == %{}
    end

    test "a type the loader wrote that the export lacks refuses to prune", %{tmp_dir: dir} do
      f = setup_cut3(dir)
      {:ok, _} = Load.run(f.export, f.model, f.target, ledger_dir: f.ledger)
      before = Memory.tables(f.target)

      {:ok, no_tasks} =
        F.export(:cut3, Path.join(dir, "no-tasks"), Map.delete(F.cut3_rows(), "task"))

      assert {:error, %{context: %{types: ["task"]}, message: m}} =
               Load.run(no_tasks, f.model, f.target, prune: true, ledger_dir: f.ledger)

      assert m =~ "delete all of their records"
      assert Memory.tables(f.target) == before
    end
  end

  describe "pruning" do
    test "the dry run reports the counts, and the run deletes exactly the loader's rows",
         %{tmp_dir: dir} do
      f = setup_cut3(dir)
      {:ok, _} = Load.run(f.export, f.model, f.target, ledger_dir: f.ledger)
      app_rows(f)
      {:ok, delta} = F.export(:cut3, Path.join(dir, "delta"), delta_rows())
      opts = [prune: true, ledger_dir: f.ledger]

      tasks = key(f.project, "project", "tasks_list_custom_task")
      members = key(f.project, "workspace", "members_list_user")

      # Without prune the stale members block, as before.
      {:ok, plain} = Load.dry_run(delta, f.model, f.target, ledger_dir: f.ledger)
      assert plain.blocked == [:load_join_stale_member]
      assert plain.prune == nil

      before = Memory.tables(f.target)
      {:ok, dry} = Load.dry_run(delta, f.model, f.target, opts)
      assert dry.blocked == []
      assert Memory.tables(f.target) == before

      assert dry.prune == %{
               types: %{"task" => %{delete: 1, unowned: 1}},
               joins: %{tasks => %{remove: 1, unowned: 0}, members => %{remove: 2, unowned: 1}}
             }

      assert %{severity: :info, details: %{count: 1, sample_ids: [todo2]}} =
               diag(dry, :load_prune_record, "task")

      assert todo2 == F.todo2()

      assert %{severity: :warning, details: %{count: 1, sample_ids: [@app_task]}} =
               diag(dry, :load_prune_unowned, "task")

      assert %{details: %{count: 2}} =
               diag(dry, :load_prune_join_member, "workspace", "members_list_user")

      # the app's membership: kept, a warning (not a block), its row listed
      unowned = diag(dry, :load_prune_unowned, "workspace", "members_list_user")
      assert unowned.severity == :warning
      assert [[_, _] = row] = unowned.details.stale_members.rows
      assert Enum.sort(row) == Enum.sort([F.bob(), F.workspace2()])
      refute diag(dry, :load_join_stale_member, "workspace", "members_list_user")

      {:ok, run} = Load.run(delta, f.model, f.target, opts)
      assert run.blocked == []

      assert run.prune == %{
               types: %{"task" => %{delete: 1, unowned: 1, deleted: 1, cleared: 0}},
               joins: %{
                 tasks => %{remove: 1, unowned: 0, deleted: 1, cleared: 0},
                 members => %{remove: 2, unowned: 1, deleted: 1, cleared: 1}
               }
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

      # The record forgets what was pruned.
      {:ok, written} = Written.read(f.ledger, "memory")
      refute MapSet.member?(Written.records(written, "task"), F.todo2())
      assert MapSet.member?(Written.records(written, "task"), F.todo1())
      refute MapSet.member?(Written.records(written, "task"), @app_task)

      # Idempotent: a rerun prunes nothing more and keeps the app's rows.
      {:ok, again} = Load.run(delta, f.model, f.target, opts)
      assert again.prune.types == %{"task" => %{delete: 0, unowned: 1, deleted: 0, cleared: 0}}
      assert again.prune.joins == %{members => %{remove: 0, unowned: 1, deleted: 0, cleared: 0}}
      assert Memory.tables(f.target) == tables

      text = run |> Report.to_map() |> Jason.encode!()
      refute text =~ "Acme"
      refute text =~ "Review"
    end

    test "a crash mid-prune resumes and never deletes a row the loader did not write",
         %{tmp_dir: dir} do
      f = setup_cut3(dir)
      opts = [prune: true, ledger_dir: f.ledger, batch_size: 1]
      {:ok, _} = Load.run(f.export, f.model, f.target, ledger_dir: f.ledger)
      app_rows(f)
      {:ok, delta} = F.export(:cut3, Path.join(dir, "delta"), delta_rows())

      # The same prune, uninterrupted, on another target.
      clean = Memory.start(f.project)
      clean_ledger = Path.join(dir, "clean-ledger")
      {:ok, _} = Load.run(f.export, f.model, clean, ledger_dir: clean_ledger)
      app_rows(%{f | target: clean})

      {:ok, _} =
        Load.run(delta, f.model, clean, prune: true, ledger_dir: clean_ledger, batch_size: 1)

      # The 3rd prune batch fails: two are done.
      Memory.fail_prune(f.target, 3)
      assert {:error, %{context: %{reason: :injected}}} = Load.run(delta, f.model, f.target, opts)
      mid = Memory.tables(f.target)
      assert mid["task"][@app_task]
      assert Enum.any?(ws_rows(f.target), &(&1 == {F.bob(), F.workspace2(), nil, 5}))

      Memory.fail_prune(f.target, nil)
      {:ok, resumed} = Load.run(delta, f.model, f.target, opts)
      assert Memory.tables(f.target) == Memory.tables(clean)

      # counts over the run, the interrupted invocation's included
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
      {:ok, delta} = F.export(:cut3, Path.join(dir, "delta"), delta_rows())
      before = Memory.tables(f.target)

      {:ok, run} = Load.run(delta, f.model, f.target, prune: true, ledger_dir: f.ledger)
      assert run.prune.types == %{"task" => %{delete: 0, unowned: 1, deleted: 0, cleared: 0}}
      assert Memory.tables(f.target)["task"] == before["task"]
      assert diag(run, :load_prune_unowned, "workspace", "members_list_user").details.count == 2
      assert length(ws_rows(f.target)) == 5
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
      f = setup_cut3(dir)
      {:ok, _} = Load.run(f.export, f.model, f.target, ledger_dir: f.ledger)
      {:ok, delta} = F.export(:cut3, Path.join(dir, "reused"), reused_rows())

      {:ok, plain} = Load.dry_run(delta, f.model, f.target, ledger_dir: f.ledger)
      assert :load_email_conflict in plain.blocked

      {:ok, dry} = Load.dry_run(delta, f.model, f.target, prune: true, ledger_dir: f.ledger)
      assert dry.blocked == []
      refute diag(dry, :load_email_conflict, "user", "email")
      assert dry.prune.types["user"] == %{delete: 1, unowned: 0}

      {:ok, _} = Load.run(delta, f.model, f.target, prune: true, ledger_dir: f.ledger)
      users = Memory.tables(f.target)["user"]
      refute Map.has_key?(users, F.carol())
      assert users[F.id(800)]["email"] == "Carol@example.test"
    end

    test "a holder the loader did not write still blocks", %{tmp_dir: dir} do
      f = setup_cut3(dir)
      {:ok, _} = Load.run(f.export, f.model, f.target, ledger_dir: f.ledger)
      app_user = F.id(801)

      Memory.put_rows(f.target, "user", %{
        app_user => %{"id" => app_user, "email" => "dora@example.test"}
      })

      rows =
        Map.update!(F.cut3_rows(), "user", fn [ada, bob, carol] ->
          [ada, bob, put_in(carol, ["authentication", "email", "email"], "dora@example.test")]
        end)

      {:ok, delta} = F.export(:cut3, Path.join(dir, "held"), rows)
      {:ok, dry} = Load.dry_run(delta, f.model, f.target, prune: true, ledger_dir: f.ledger)
      assert dry.blocked == [:load_email_conflict]
      assert %{severity: :warning} = diag(dry, :load_prune_unowned, "user")
    end
  end

  describe "the written record" do
    test "records IDs durably, replays its journal, and a read writes nothing", %{tmp_dir: dir} do
      ledger = Path.join(dir, "ledger")
      {:ok, _} = Written.read(ledger, "db")
      refute File.exists?(ledger)

      {:ok, w} = Written.open(ledger, "db", compact_every: 3)
      w = Written.wrote(w, "task", ["a", "b"])
      w = Written.wrote(w, "task", ["b", "c"])
      w = Written.wrote_join(w, "j/t/f", [{"a", "x"}])
      w = Written.pruned(w, "task", ["a", "zz"])
      w = Written.wrote(w, "user", ["u"])
      # a crash: the journal is not compacted, and its last line is torn
      :file.close(w.journal)
      path = Written.path(ledger, "db")
      File.write!(String.replace_suffix(path, ".json", ".journal"), "{\"seq\":", [:append])

      {:ok, again} = Written.read(ledger, "db")
      assert Written.records(again, "task") == MapSet.new(["b", "c"])
      assert Written.records(again, "user") == MapSet.new(["u"])
      assert Written.pairs(again, "j/t/f") == MapSet.new([{"a", "x"}])
      assert Written.types(again) == ["task", "user"]

      # another target has its own record
      {:ok, other} = Written.read(ledger, "other-db")
      assert Written.types(other) == []

      {:ok, reopened} = Written.open(ledger, "db")
      reopened = Written.pruned_join(reopened, "j/t/f", [{"a", "x"}])
      Written.close(reopened)
      {:ok, last} = Written.read(ledger, "db")
      assert Written.lists(last) == []
      assert Written.records(last, "task") == MapSet.new(["b", "c"])
      %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end
  end
end
