defmodule BubbleEx.LoadTest do
  # The loader over fixture exports into an in-memory target (the Ash
  # adapter's plan, upsert semantics in an Agent). The same exports go into
  # PostgreSQL in scripts/ash_compile_check/load.exs.
  use ExUnit.Case, async: true

  alias BubbleEx.Load
  alias BubbleEx.Load.{Export, Ledger, Report}
  alias BubbleEx.Load.Storage.Local
  alias BubbleEx.Test.LoadFixture, as: F
  alias BubbleEx.Test.LoadMemoryTarget, as: Memory

  @moduletag :tmp_dir

  defp setup_fixture(which, dir, rows \\ nil) do
    {:ok, export} = F.export(which, Path.join(dir, "export"), rows)
    {:ok, project} = F.project(which)
    %{export: export, model: F.model(which), target: Memory.start(project), dir: dir}
  end

  defp storage(dir),
    do: Local.new(root: Path.join(dir, "storage"), public_url: "https://files.example.test")

  # The field_types fixture has a key no field names ("Legacy Field").
  @unmapped [allow_unmapped_keys: true]

  defp ledger_state(dir) do
    [file] = Path.wildcard(Path.join(dir, "*.json"))
    {:ok, state} = Ledger.read(file)
    {file, state}
  end

  defp codes(%Report{diagnostics: ds}),
    do: MapSet.new(ds, &{&1.code, &1.subject[:type], &1.subject[:field]})

  defp diag(%Report{diagnostics: ds}, code, type, field \\ nil),
    do:
      Enum.find(
        ds,
        &(&1.code == code and &1.subject[:type] == type and &1.subject[:field] == field)
      )

  defp total(report, key),
    do: report.types |> Map.values() |> Enum.map(&Map.get(&1, key, 0)) |> Enum.sum()

  describe "dry run" do
    test "reports counts and diagnostics and writes nothing", %{tmp_dir: dir} do
      f = setup_fixture(:cut2, dir)
      assert {:ok, report} = Load.dry_run(f.export, f.model, f.target)

      assert report.dry_run and report.blocked == [] and report.run == nil
      assert report.types["card"] == %{rows: 4, records: 3, duplicates: 1, invalid: 0}
      assert report.types["board"].records == 2

      assert report.auth == %{
               users: 3,
               with_email: 3,
               confirmed: 2,
               unconfirmed: 1,
               unknown: 0,
               confirmed_column: true
             }

      assert Memory.tables(f.target) == %{}
      refute File.exists?(Path.join(dir, "ledger"))

      codes = codes(report)

      for code <- [
            {:load_duplicate_record, "card", nil},
            {:load_type_mismatch, "card", "points_number"},
            {:load_invalid_reference, "card", "blocker_ids_list_text"},
            {:load_dangling_reference, "card", "blocker_ids_list_text"},
            {:load_dangling_reference, "card", "assignee_id_text"},
            {:load_deleted_ids_dropped, "board", "watchers_list_user"},
            {:load_derived_drift, "board", "watcher_count_number"},
            {:load_derived_drift, "board", "card_count_number"},
            {:load_derived_drift, "card", "board_card_count_number"},
            {:load_reverse_list_drift, "board", "cards_list_custom_card"},
            {:load_confirmed_at_migrated, "user", nil},
            {:load_auth_provider_unmigrated, "user", nil}
          ],
          do: assert(MapSet.member?(codes, code), inspect(code))

      # The target has a confirmed_at column (WTF-413).
      refute MapSet.member?(codes, {:load_auth_status_unmapped, "user", nil})
      assert diag(report, :load_confirmed_at_migrated, "user").details.count == 2

      # Stored copies that agree with the derived value are not drift.
      refute MapSet.member?(codes, {:load_derived_drift, "card", "board_watcher_count_number"})

      drift = diag(report, :load_reverse_list_drift, "board", "cards_list_custom_card")
      assert drift.details.pointing_back_not_listed == 1
      assert drift.details.sample_ids == [F.board2()]

      assert diag(report, :load_auth_provider_unmigrated, "user").details.providers == %{
               "google" => 1
             }

      assert Enum.all?(report.diagnostics, &(&1.stage == :load))
    end

    test "diagnostics hold counts and IDs, never stored values", %{tmp_dir: dir} do
      f = setup_fixture(:field_types, dir)
      {:ok, report} = Load.dry_run(f.export, f.model, f.target)
      text = report |> Report.to_map() |> Jason.encode!()

      for value <- [
            "Ada@Example",
            "ada@example",
            "keeps spaces",
            "Main St",
            "three",
            "two",
            "archived"
          ] do
        refute text =~ value, "the report holds #{inspect(value)}"
      end

      assert diag(report, :load_unmapped_key, "task").details.keys == %{"Legacy Field" => 1}
      assert diag(report, :load_invalid_record_id, "task").details.count == 1
    end
  end

  describe "run" do
    test "loads, converts and rewrites files", %{tmp_dir: dir} do
      f = setup_fixture(:field_types, dir)
      {:ok, report} = Load.run(f.export, f.model, f.target, [storage: storage(dir)] ++ @unmapped)

      assert total(report, :inserted) == 6
      assert report.files == %{referenced: 3, public: 2, private: 1, copied: 2, failed: 1}
      task = Memory.tables(f.target)["task"][F.task1()]

      assert "private/" <> _ = task["attachment"]
      assert "https://files.example.test/" <> _ = task["cover"]
      assert task["files"] == [task["attachment"], F.missing_url(), F.external_url()]
      assert task["labels"] == ["open", "closed"]
      assert task["status"] == "open"
      assert task["dates"] == ["2024-01-01T00:00:00.500000Z", "2024-01-01T00:00:00.000000Z"]

      assert task["window"] == %{
               "start" => "2024-03-01T00:00:00.000000Z",
               "end" => "2024-04-01T00:00:00.000000Z"
             }

      assert task["budget"] == %{"min" => 10.0, "max" => 20.5}
      assert task["watchers"] == [F.ada(), F.gone_user()]
      assert task["title"] == "  keeps spaces "

      private = Path.join([dir, "storage", task["attachment"]])
      assert File.read!(private) == "%PDF private contract"
      assert Bitwise.band(File.stat!(private).mode, 0o777) == 0o600

      "https://files.example.test/" <> public = task["cover"]
      assert File.exists?(Path.join([dir, "storage", "public", public]))
      assert Bitwise.band(File.stat!(Path.join([dir, "storage", "private"])).mode, 0o777) == 0o700

      users = Memory.tables(f.target)["user"]
      assert users[F.ada()]["email"] == "Ada@Example.test"
      assert users[F.bob()]["email"] == "bob@example.test"
    end

    test "confirmed users get their Created Date as confirmed_at, others nil (WTF-413)", %{
      tmp_dir: dir
    } do
      # Carol is confirmed but has no Created Date; a fourth user has no
      # confirmed flag at all.
      rows =
        F.cut2_rows()
        |> Map.update!("user", fn [ada, bob, carol] ->
          [
            ada,
            bob,
            Map.delete(carol, "Created Date"),
            %{"_id" => F.id(4), "Created Date" => "2024-01-04T10:00:00Z"}
          ]
        end)

      f = setup_fixture(:cut2, dir, rows)
      {:ok, report} = Load.run(f.export, f.model, f.target)
      users = Memory.tables(f.target)["user"]

      assert users[F.ada()]["confirmed_at"] == "2024-01-01T10:00:00.000000Z"
      assert users[F.bob()]["confirmed_at"] == nil
      # Confirmed but undated: loaded unconfirmed, reported.
      assert users[F.carol()]["confirmed_at"] == nil
      assert users[F.id(4)]["confirmed_at"] == nil

      undated = diag(report, :load_confirmed_at_undated, "user")
      assert undated.details.count == 1 and undated.details.sample_ids == [F.carol()]
      # Only the dated confirmations count as migrated.
      assert diag(report, :load_confirmed_at_migrated, "user").details.count == 1

      # Stable: a rerun leaves every user unchanged.
      {:ok, rerun} = Load.run(f.export, f.model, f.target)
      assert rerun.types["user"].updated == 0 and rerun.types["user"].inserted == 0
    end

    test "a delta sync keeps a target-side confirmation while the email is unchanged", %{
      tmp_dir: dir
    } do
      f = setup_fixture(:cut2, dir)
      {:ok, _} = Load.run(f.export, f.model, f.target)

      # Bob (unconfirmed in Bubble) and Carol confirm by magic link in the
      # target; Carol's email then changes in Bubble.
      signed_in = "2026-09-20T00:00:00.000000Z"

      for id <- [F.bob(), F.carol()] do
        row = Memory.tables(f.target)["user"][id]
        Memory.put_rows(f.target, "user", %{id => Map.put(row, "confirmed_at", signed_in)})
      end

      rows =
        Map.update!(F.cut2_rows(), "user", fn [ada, bob, carol] ->
          carol =
            carol
            |> put_in(["authentication", "email", "email"], "carol2@example.test")
            |> put_in(["authentication", "email", "email_confirmed"], false)

          [ada, bob, carol]
        end)

      {:ok, delta} = F.export(:cut2, Path.join(dir, "delta"), rows)
      {:ok, report} = Load.run(delta, f.model, f.target)
      users = Memory.tables(f.target)["user"]

      assert users[F.bob()]["confirmed_at"] == signed_in
      assert users[F.carol()]["email"] == "carol2@example.test"
      assert users[F.carol()]["confirmed_at"] == nil
      assert users[F.ada()]["confirmed_at"] == "2024-01-01T10:00:00.000000Z"
      # Bob is unchanged; Carol is updated.
      assert report.types["user"].updated == 1
    end

    test "derive_count lists lose deleted IDs; other references keep them", %{tmp_dir: dir} do
      f = setup_fixture(:cut2, dir)
      {:ok, _} = Load.run(f.export, f.model, f.target)
      tables = Memory.tables(f.target)

      assert tables["board"][F.board1()]["watchers"] == [F.ada()]
      refute Map.has_key?(tables["board"][F.board1()], "cards")
      card = tables["card"][F.card1()]
      assert card["assignee_id"] == F.ada()
      assert card["blockers"] == [F.card2(), F.gone_card()]
      assert card["title"] == "One"
      assert tables["card"][F.card3()]["assignee_id"] == F.gone_user()
      assert tables["card"][F.card2()]["assignee_id"] == nil
    end

    test "a rerun changes nothing; a delta sync writes only the changes", %{tmp_dir: dir} do
      f = setup_fixture(:cut2, dir)
      opts = [ledger_dir: Path.join(dir, "ledger")]
      {:ok, first} = Load.run(f.export, f.model, f.target, opts)
      before = Memory.tables(f.target)

      {:ok, again} = Load.run(f.export, f.model, f.target, opts)

      assert {total(again, :inserted), total(again, :updated), total(again, :unchanged)} ==
               {0, 0, total(first, :inserted)}

      assert Memory.tables(f.target) == before

      rows = F.cut2_rows()
      [b1 | rest] = rows["board"]

      rows =
        Map.put(rows, "board", [Map.put(b1, "Name", "Roadmap 2"), %{"_id" => F.id(300)} | rest])

      {:ok, delta_export} = F.export(:cut2, Path.join(dir, "delta"), rows)
      {:ok, delta} = Load.run(delta_export, f.model, f.target, opts)

      assert delta.types["board"] |> Map.take([:inserted, :updated, :unchanged]) == %{
               inserted: 1,
               updated: 1,
               unchanged: 1
             }

      assert delta.run != first.run
      assert Memory.tables(f.target)["board"][F.board1()]["name"] == "Roadmap 2"
    end

    test "resumes after an interruption and ends in the state of a clean load", %{tmp_dir: dir} do
      f = setup_fixture(:cut2, dir)
      ledger_dir = Path.join(dir, "ledger")
      opts = [ledger_dir: ledger_dir, batch_size: 1]

      Memory.fail_on(f.target, 4)

      assert {:error, %{context: %{reason: :injected}}} =
               Load.run(f.export, f.model, f.target, opts)

      {ledger_file, ledger} = ledger_state(ledger_dir)
      assert ledger["status"] == "running"
      # The crash was in the second table: the first is complete.
      assert ledger["types"]["board"]["complete"]
      assert ledger["types"]["card"]["rows_done"] == 1
      assert Bitwise.band(File.stat!(ledger_file).mode, 0o777) == 0o600
      assert Bitwise.band(File.stat!(ledger_dir).mode, 0o777) == 0o700

      Memory.fail_on(f.target, nil)
      {:ok, resumed} = Load.run(f.export, f.model, f.target, opts)
      assert total(resumed, :resumed) == 3
      assert resumed.types["board"].resumed == 2 and resumed.types["card"].resumed == 1
      assert total(resumed, :inserted) == 8

      clean = Memory.start(elem(F.project(:cut2), 1))
      {:ok, _} = Load.run(f.export, f.model, clean)
      assert Memory.tables(f.target) == Memory.tables(clean)
      assert {:ok, %{"status" => "complete"}} = Ledger.read(ledger_file)
    end

    test "a ledger holds counts and references, no values or credentials", %{tmp_dir: dir} do
      f = setup_fixture(:field_types, dir)

      {:ok, _} =
        Load.run(
          f.export,
          f.model,
          f.target,
          [storage: storage(dir), ledger_dir: Path.join(dir, "l")] ++ @unmapped
        )

      # the run's ledger and the written record (IDs only, WTF-414)
      text = dir |> Path.join("l/**/*.json") |> Path.wildcard() |> Enum.map_join(&File.read!/1)
      assert text =~ F.task1()
      refute text =~ "Ada@Example"
      refute text =~ "keeps spaces"
      {_file, state} = ledger_state(Path.join(dir, "l"))
      assert map_size(state["files"]) == 2
    end
  end

  describe "join tables (WTF-406)" do
    # The :cut3 decisions: Project's Tasks a join of its own (order kept);
    # Project's Viewers (a flag) and User's Favorites (order kept) one
    # table; Workspace's Members (a membership join) and User's Workspaces
    # one table (both orders kept). Each list has its own column.
    defp join_rows(target, table) do
      target
      |> Memory.tables()
      |> Map.get(table, %{})
      |> Map.values()
      |> Enum.sort_by(&Enum.sort/1)
    end

    defp side_key(project, type, field) do
      join =
        Enum.find(project.joins, fn j ->
          Enum.any?(j.join.sides, &(&1.type == type and &1.field == field))
        end)

      "#{join.join.id}/#{type}/#{field}"
    end

    test "each list loads as its own rows, idempotently, never adding to the mirrored list",
         %{tmp_dir: dir} do
      f = setup_fixture(:cut3, dir)
      {:ok, project} = F.project(:cut3)
      {:ok, dry} = Load.dry_run(f.export, f.model, f.target)

      tasks = side_key(project, "project", "tasks_list_custom_task")
      members = side_key(project, "workspace", "members_list_user")
      workspaces = side_key(project, "user", "workspaces_list_custom_workspace")
      assert dry.joins[tasks] == %{rows: 3}
      assert dry.joins[members] == %{rows: 4}
      assert dry.joins[workspaces] == %{rows: 3}
      assert Memory.tables(f.target) == %{}

      # a repeated member is one row; a dangling one is kept and reported
      assert diag(dry, :load_join_duplicate, "project", "tasks_list_custom_task").details.count ==
               1

      assert %{count: 1, missing: 1} =
               diag(dry, :load_dangling_reference, "project", "tasks_list_custom_task").details

      assert diag(dry, :load_dangling_reference, "workspace", "members_list_user")

      for {type, field} <- [
            {"workspace", "members_list_user"},
            {"user", "workspaces_list_custom_workspace"},
            {"project", "viewers_list_user"},
            {"user", "favorites_list_custom_project"}
          ] do
        assert %{severity: :info, details: %{count: 1}} =
                 diag(dry, :load_join_asymmetric, type, field)
      end

      {:ok, run} = Load.run(f.export, f.model, f.target)
      refute Enum.any?(run.diagnostics, &(&1.code == :load_join_stale_member))
      assert run.joins[tasks] == %{rows: 3, inserted: 3, updated: 0, unchanged: 0, resumed: 0}

      assert join_rows(f.target, "project_tasks") ==
               Enum.sort_by(
                 [
                   %{
                     "project_id" => F.initiative1(),
                     "task_id" => F.gone_task(),
                     "position" => 3
                   },
                   %{"project_id" => F.initiative1(), "task_id" => F.todo1(), "position" => 0},
                   %{"project_id" => F.initiative1(), "task_id" => F.todo2(), "position" => 1}
                 ],
                 &Enum.sort/1
               )

      # Bob views Plan but his Favorites do not list it: no favorites column
      fav = fn project, user ->
        Enum.find(
          join_rows(f.target, "favorite_project"),
          &(&1["project_id"] == project and &1["user_id"] == user)
        )
      end

      assert fav.(F.initiative1(), F.bob()) == %{
               "project_id" => F.initiative1(),
               "user_id" => F.bob(),
               "viewers_listed" => true
             }

      assert fav.(F.initiative1(), F.ada()) ==
               %{
                 "project_id" => F.initiative1(),
                 "user_id" => F.ada(),
                 "viewers_listed" => true,
                 "favorites_position" => 0
               }

      assert fav.(F.initiative2(), F.bob()) ==
               %{"project_id" => F.initiative2(), "user_id" => F.bob(), "favorites_position" => 0}

      ws = fn user, workspace ->
        row =
          Enum.find(
            join_rows(f.target, "user_workspaces"),
            &(&1["user_id"] == user and &1["workspace_id"] == workspace)
          )

        row && {row["workspaces_position"], row["members_position"]}
      end

      # Acme's Members list Bob, whose Workspaces do not: a member of one list only
      assert ws.(F.bob(), F.workspace1()) == {nil, 1}
      assert ws.(F.carol(), F.workspace1()) == {1, nil}
      assert ws.(F.ada(), F.workspace1()) == {0, 0}
      assert ws.(F.gone_user(), F.workspace1()) == {nil, 2}

      refute Map.has_key?(Memory.tables(f.target)["project"][F.initiative1()], "tasks")

      before = Memory.tables(f.target)
      {:ok, again} = Load.run(f.export, f.model, f.target)
      assert again.joins[members] == %{rows: 4, inserted: 0, updated: 0, unchanged: 4, resumed: 0}
      assert Memory.tables(f.target) == before
    end

    test "a later export with removed join members is blocked before any writes", %{tmp_dir: dir} do
      f = setup_fixture(:cut3, dir)
      {:ok, _} = Load.run(f.export, f.model, f.target)

      rows = F.cut3_rows()
      [w1 | rest] = rows["workspace"]
      # Bob leaves Acme's Members; Carol joins them
      w1 = Map.put(w1, "Members", [F.carol(), F.ada(), F.gone_user()])
      rows = %{rows | "workspace" => [w1 | rest]}
      {:ok, delta_export} = F.export(:cut3, Path.join(dir, "delta"), rows)

      # Dry-run reports the revocation without writing anything.
      before = Memory.tables(f.target)
      {:ok, dry} = Load.dry_run(delta_export, f.model, f.target)
      assert :load_join_stale_member in dry.blocked

      assert %{severity: :error, details: %{count: 1, sample_ids: [w], not_listed_now: 1}} =
               diag(dry, :load_join_stale_member, "workspace", "members_list_user")

      assert w == F.workspace1()
      refute diag(dry, :load_join_stale_member, "user", "workspaces_list_custom_workspace")

      # Every stale row is in the details, for pruning by hand; the message
      # names no record.
      stale = diag(dry, :load_join_stale_member, "workspace", "members_list_user")

      assert %{table: "user_workspaces", membership_column: "members_position", rows: [row]} =
               stale.details.stale_members

      assert Enum.sort(row) == Enum.sort([F.bob(), F.workspace1()])
      refute stale.message =~ F.bob()
      refute stale.message =~ F.workspace1()

      ledger_dir = Path.join(dir, "blocked-ledger")

      assert {:error, %BubbleEx.Error{kind: :invalid_input, context: context, message: message}} =
               Load.run(delta_export, f.model, f.target, ledger_dir: ledger_dir)

      assert :load_join_stale_member in context.blocked
      assert message =~ "prune: true"
      assert message =~ "details.stale_members"
      refute message =~ F.bob()
      assert context.report.blocked == dry.blocked
      assert diag(context.report, :load_join_stale_member, "workspace", "members_list_user")
      assert Memory.tables(f.target) == before
      refute File.exists?(ledger_dir)

      # Bob still has a membership row in the old target, so a successful
      # delta run must not certify that target as safe to serve.
      assert Enum.any?(join_rows(f.target, "user_workspaces"), fn row ->
               row["user_id"] == F.bob() and row["workspace_id"] == F.workspace1() and
                 row["members_position"] == 1
             end)
    end

    test "a deleted owner in a complete delta blocks before writes, even with an existing ledger",
         %{tmp_dir: dir} do
      f = setup_fixture(:cut3, dir)
      ledger_dir = Path.join(dir, "ledger")
      {:ok, _} = Load.run(f.export, f.model, f.target, ledger_dir: ledger_dir)
      before = Memory.tables(f.target)
      ledger_before = ledger_state(ledger_dir)

      rows = F.cut3_rows()

      rows = %{
        rows
        | "workspace" => Enum.reject(rows["workspace"], &(&1["_id"] == F.workspace1()))
      }

      {:ok, delta} = F.export(:cut3, Path.join(dir, "deleted-owner"), rows)

      {:ok, dry} = Load.dry_run(delta, f.model, f.target)
      assert :load_join_stale_member in dry.blocked

      assert %{details: %{count: 3, sample_ids: [owner]}} =
               diag(dry, :load_join_stale_member, "workspace", "members_list_user")

      assert owner == F.workspace1()

      assert {:error, %{context: %{blocked: blocked, report: report}}} =
               Load.run(delta, f.model, f.target, ledger_dir: ledger_dir)

      assert :load_join_stale_member in blocked
      assert report.run == nil
      assert Memory.tables(f.target) == before
      assert ledger_state(ledger_dir) == ledger_before
      refute Jason.encode!(Report.to_map(report)) =~ "Acme"
    end

    test "false flags are not members of a normalized list", %{tmp_dir: dir} do
      f = setup_fixture(:cut3, dir)
      {:ok, _} = Load.run(f.export, f.model, f.target)
      # The target can hold a join row whose boolean flag is false. It is
      # not a viewer, unlike a non-nil position (including position zero).
      Memory.put_rows(f.target, "favorite_project", %{
        {F.initiative2(), F.ada()} => %{
          "project_id" => F.initiative2(),
          "user_id" => F.ada(),
          "viewers_listed" => false
        }
      })

      {:ok, dry} = Load.dry_run(f.export, f.model, f.target)
      refute :load_join_stale_member in dry.blocked
      assert {:ok, _} = Load.run(f.export, f.model, f.target)

      Memory.put_rows(f.target, "favorite_project", %{
        {F.initiative2(), F.ada()} => %{
          "project_id" => F.initiative2(),
          "user_id" => F.ada(),
          "viewers_listed" => true
        }
      })

      {:ok, stale} = Load.dry_run(f.export, f.model, f.target)
      assert :load_join_stale_member in stale.blocked

      assert %{details: %{count: 1, sample_ids: [id]}} =
               diag(stale, :load_join_stale_member, "project", "viewers_list_user")

      assert id == F.initiative2()
    end

    test "an interrupted load resumes its join rows from the ledger", %{tmp_dir: dir} do
      f = setup_fixture(:cut3, dir)
      opts = [ledger_dir: Path.join(dir, "ledger"), batch_size: 1]
      records = 2 + 2 + 2 + 3

      # the 3rd join batch fails, after every data type's table
      Memory.fail_on(f.target, records + 3)
      assert {:error, _} = Load.run(f.export, f.model, f.target, opts)
      Memory.fail_on(f.target, nil)
      {:ok, resumed} = Load.run(f.export, f.model, f.target, opts)
      assert resumed.joins |> Map.values() |> Enum.map(& &1.resumed) |> Enum.sum() == 2

      clean = Memory.start(elem(F.project(:cut3), 1))
      {:ok, _} = Load.run(f.export, f.model, clean)
      assert Memory.tables(f.target) == Memory.tables(clean)
    end

    test "reports hold counts and IDs, never list values beyond IDs", %{tmp_dir: dir} do
      f = setup_fixture(:cut3, dir)
      {:ok, dry} = Load.dry_run(f.export, f.model, f.target)
      text = dry |> Report.to_map() |> Jason.encode!()
      refute text =~ "Acme"
      refute text =~ "Plan"
    end
  end

  describe "blocking" do
    test "duplicate emails stop a real run before any write", %{tmp_dir: dir} do
      rows = F.cut2_rows()
      [ada | others] = rows["user"]
      twin = Map.merge(ada, %{"_id" => F.id(8), "email" => "ADA@example.TEST"})
      f = setup_fixture(:cut2, dir, Map.put(rows, "user", [ada, twin | others]))

      {:ok, dry} = Load.dry_run(f.export, f.model, f.target)
      assert dry.blocked == [:load_duplicate_email]

      assert diag(dry, :load_duplicate_email, "user", "email").details.sample_ids ==
               Enum.sort([F.ada(), F.id(8)])

      assert {:error, %{context: %{blocked: [:load_duplicate_email]}}} =
               Load.run(f.export, f.model, f.target)

      assert Memory.tables(f.target) == %{}
    end

    test "an incomplete export needs allow_partial", %{tmp_dir: dir} do
      {:ok, project} = F.project(:cut2)

      {:ok, export} =
        Export.write(Path.join(dir, "partial"), %{
          types: [
            %{type: "board", path: "board", rows: F.cut2_rows()["board"]},
            %{type: "card", path: "card", error: "not_found"}
          ]
        })

      target = Memory.start(project)
      model = F.model(:cut2)

      assert {:error, %{context: %{blocked: [:load_export_partial]}}} =
               Load.run(export, model, target)

      assert {:ok, report} = Load.run(export, model, target, allow_partial: true)
      assert report.types["board"].inserted == 2
      assert MapSet.member?(codes(report), {:load_type_not_exported, "user", nil})
    end

    test "rows referencing Bubble files need a storage", %{tmp_dir: dir} do
      f = setup_fixture(:field_types, dir)
      assert {:error, %{message: message}} = Load.run(f.export, f.model, f.target, @unmapped)
      assert message =~ ":storage"
    end
  end

  describe "files" do
    test "a blob whose checksum changed is not copied; its field keeps the Bubble URL", %{
      tmp_dir: dir
    } do
      f = setup_fixture(:field_types, dir)
      entry = Enum.find(Export.files(f.export), &(&1["url"] == F.cdn_url()))
      File.write!(Export.blob_path(f.export, entry["sha256"]), "tampered")

      {:ok, report} = Load.run(f.export, f.model, f.target, [storage: storage(dir)] ++ @unmapped)
      assert report.files.copied == 1
      assert Memory.tables(f.target)["task"][F.task1()]["cover"] == F.cdn_url()
      assert diag(report, :load_file_failed, "task", "cover_image").details.count == 1
    end
  end

  describe "the export" do
    test "a tampered rows object does not open", %{tmp_dir: dir} do
      {:ok, export} = F.export(:cut2, Path.join(dir, "e"))
      object = Path.join(export.dir, Export.type(export, "card")["object"])
      File.write!(object, :zlib.gzip("{}\n"))
      assert {:error, %{message: message}} = Export.open(export.dir)
      assert message =~ "checksum"
    end

    test "is private to its owner", %{tmp_dir: dir} do
      {:ok, export} = F.export(:cut2, Path.join(dir, "e"))
      assert Bitwise.band(File.stat!(export.dir).mode, 0o777) == 0o700
      assert Bitwise.band(File.stat!(Path.join(export.dir, "manifest.json")).mode, 0o777) == 0o600
    end
  end

  describe "keys" do
    test "an unmapped key blocks a real run unless allowed", %{tmp_dir: dir} do
      f = setup_fixture(:field_types, dir)
      {:ok, dry} = Load.dry_run(f.export, f.model, f.target)
      assert dry.blocked == [:load_unmapped_key]

      assert {:error, %{context: %{blocked: [:load_unmapped_key]}}} =
               Load.run(f.export, f.model, f.target, storage: storage(dir))

      assert Memory.tables(f.target) == %{}
    end

    test "a display name two fields share is refused until the key map resolves it",
         %{tmp_dir: dir} do
      app =
        put_in(F.app(:cut2), ["user_types", "card", "fields", "status_text", "display"], "Title")

      {:ok, model} = BubbleEx.Model.build(app)
      {:ok, project} = BubbleEx.Target.Ash.map(model)
      {:ok, export} = F.export(:cut2, Path.join(dir, "e"))
      target = Memory.start(project)

      {:ok, dry} = Load.dry_run(export, model, target)
      assert :load_ambiguous_key in dry.blocked
      assert diag(dry, :load_ambiguous_key, "card").details.keys == %{"Title" => 4}

      keys = %{"card" => %{"Title" => "title_text", "Status" => "status_text"}}
      assert {:ok, report} = Load.run(export, model, target, keys: keys)
      assert report.blocked == []
      # (two fields named Title: the attributes are "title" and "title_2")
      row = Memory.tables(target)["card"][F.card1()]
      assert "One" in Map.values(row) and "doing" in Map.values(row)

      assert {:error, %{kind: :invalid_input}} =
               Load.run(export, model, target, keys: %{"card" => %{"Title" => "no_such_field"}})
    end

    test "the key map and the storage are part of the run key", %{tmp_dir: dir} do
      f = setup_fixture(:cut2, dir)
      ledger = Path.join(dir, "ledger")
      {:ok, a} = Load.run(f.export, f.model, f.target, ledger_dir: ledger)

      {:ok, b} =
        Load.run(f.export, f.model, f.target,
          ledger_dir: ledger,
          keys: %{"card" => %{"T" => "title_text"}}
        )

      {:ok, c} = Load.run(f.export, f.model, f.target, ledger_dir: ledger, storage: storage(dir))
      assert length(Enum.uniq([a.run, b.run, c.run])) == 3
    end
  end

  describe "emails against the target" do
    test "an email a record outside the export holds blocks the run", %{tmp_dir: dir} do
      f = setup_fixture(:cut2, dir)

      Memory.put_rows(f.target, "user", %{
        F.id(500) => %{"id" => F.id(500), "email" => "BOB@example.test"}
      })

      {:ok, dry} = Load.dry_run(f.export, f.model, f.target)
      assert dry.blocked == [:load_email_conflict]
      assert diag(dry, :load_email_conflict, "user", "email").details.sample_ids == [F.bob()]
      refute dry |> Report.to_map() |> Jason.encode!() =~ "bob@"

      assert {:error, %{context: %{blocked: [:load_email_conflict]}}} =
               Load.run(f.export, f.model, f.target)
    end

    test "users swapping emails load in two phases", %{tmp_dir: dir} do
      f = setup_fixture(:cut2, dir)

      Memory.put_rows(f.target, "user", %{
        F.ada() => %{"id" => F.ada(), "email" => "bob@example.test"},
        F.bob() => %{"id" => F.bob(), "email" => "ada@example.test"}
      })

      {:ok, report} = Load.run(f.export, f.model, f.target, batch_size: 1)
      assert report.blocked == []
      users = Memory.tables(f.target)["user"]
      assert users[F.ada()]["email"] == "Ada@Example.test"
      assert users[F.bob()]["email"] == "bob@example.test"
    end

    test "confirmed users get their Created Date as confirmed_at, others nil (WTF-413)", %{
      tmp_dir: dir
    } do
      # Carol is confirmed but has no Created Date; a fourth user has no
      # confirmed flag at all.
      rows =
        F.cut2_rows()
        |> Map.update!("user", fn [ada, bob, carol] ->
          [
            ada,
            bob,
            Map.delete(carol, "Created Date"),
            %{"_id" => F.id(4), "Created Date" => "2024-01-04T10:00:00Z"}
          ]
        end)

      f = setup_fixture(:cut2, dir, rows)
      {:ok, report} = Load.run(f.export, f.model, f.target)
      users = Memory.tables(f.target)["user"]

      assert users[F.ada()]["confirmed_at"] == "2024-01-01T10:00:00.000000Z"
      assert users[F.bob()]["confirmed_at"] == nil
      # Confirmed but undated: loaded unconfirmed, reported.
      assert users[F.carol()]["confirmed_at"] == nil
      assert users[F.id(4)]["confirmed_at"] == nil

      undated = diag(report, :load_confirmed_at_undated, "user")
      assert undated.details.count == 1 and undated.details.sample_ids == [F.carol()]
      # Only the dated confirmations count as migrated.
      assert diag(report, :load_confirmed_at_migrated, "user").details.count == 1

      # Stable: a rerun leaves every user unchanged.
      {:ok, rerun} = Load.run(f.export, f.model, f.target)
      assert rerun.types["user"].updated == 0 and rerun.types["user"].inserted == 0
    end

    test "a delta sync keeps a target-side confirmation while the email is unchanged", %{
      tmp_dir: dir
    } do
      f = setup_fixture(:cut2, dir)
      {:ok, _} = Load.run(f.export, f.model, f.target)

      # Bob (unconfirmed in Bubble) and Carol confirm by magic link in the
      # target; Carol's email then changes in Bubble.
      signed_in = "2026-09-20T00:00:00.000000Z"

      for id <- [F.bob(), F.carol()] do
        row = Memory.tables(f.target)["user"][id]
        Memory.put_rows(f.target, "user", %{id => Map.put(row, "confirmed_at", signed_in)})
      end

      rows =
        Map.update!(F.cut2_rows(), "user", fn [ada, bob, carol] ->
          carol =
            carol
            |> put_in(["authentication", "email", "email"], "carol2@example.test")
            |> put_in(["authentication", "email", "email_confirmed"], false)

          [ada, bob, carol]
        end)

      {:ok, delta} = F.export(:cut2, Path.join(dir, "delta"), rows)
      {:ok, report} = Load.run(delta, f.model, f.target)
      users = Memory.tables(f.target)["user"]

      assert users[F.bob()]["confirmed_at"] == signed_in
      assert users[F.carol()]["email"] == "carol2@example.test"
      assert users[F.carol()]["confirmed_at"] == nil
      assert users[F.ada()]["confirmed_at"] == "2024-01-01T10:00:00.000000Z"
      # Bob is unchanged; Carol is updated.
      assert report.types["user"].updated == 1
    end
  end

  test "NUL characters are stripped and reported", %{tmp_dir: dir} do
    rows = F.cut2_rows()
    [c1 | rest] = rows["card"]

    f =
      setup_fixture(:cut2, dir, Map.put(rows, "card", [Map.put(c1, "Title", "O\u0000ne") | rest]))

    {:ok, report} = Load.run(f.export, f.model, f.target)
    assert Memory.tables(f.target)["card"][F.card1()]["title"] == "One"

    assert diag(report, :load_nul_stripped, "card", "title_text").details.sample_ids == [
             F.card1()
           ]
  end

  describe "file failures" do
    test "a storage that raises, times out or fails to verify fails that file only",
         %{tmp_dir: dir} do
      f = setup_fixture(:field_types, dir)
      {Local, local} = storage(dir)
      test = self()

      behaviour = %{
        # the private contract raises; the cover never finishes
        put: fn meta, source ->
          case meta.visibility do
            :private ->
              raise "storage down"

            :public ->
              send(test, :slow) && Process.sleep(:infinity) && Local.put(local, meta, source)
          end
        end
      }

      storage = {BubbleEx.LoadTest.FlakyStorage, %{local: local, behaviour: behaviour}}
      ledger = Path.join(dir, "ledger")

      {:ok, report} =
        Load.run(
          f.export,
          f.model,
          f.target,
          [storage: storage, ledger_dir: ledger, file_timeout: 200] ++ @unmapped
        )

      assert report.files.copied == 0
      task = Memory.tables(f.target)["task"][F.task1()]
      assert task["attachment"] == F.private_url()
      assert task["cover"] == F.cdn_url()
      assert diag(report, :load_file_failed, "task", "cover_image").details.count == 1

      # verify fails: never counted as copied, never recorded
      failing = %{
        put: fn meta, source -> Local.put(local, meta, source) end,
        verify: fn _ref, _meta ->
          {:error,
           BubbleEx.Error.new(:request_failed, "x", %{reason: :storage_checksum_mismatch})}
        end
      }

      g = setup_fixture(:field_types, Path.join(dir, "g"))
      storage = {BubbleEx.LoadTest.FlakyStorage, %{local: local, behaviour: failing}}

      {:ok, report} =
        Load.run(
          g.export,
          g.model,
          g.target,
          [storage: storage, ledger_dir: Path.join(dir, "l2")] ++ @unmapped
        )

      assert report.files.copied == 0
      assert Memory.tables(g.target)["task"][F.task1()]["cover"] == F.cdn_url()
      {_, state} = ledger_state(Path.join(dir, "l2"))
      assert state["files"] == %{}
    end

    test "a changed export blob is refused even by a storage that verifies nothing",
         %{tmp_dir: dir} do
      f = setup_fixture(:field_types, dir)
      entry = Enum.find(Export.files(f.export), &(&1["url"] == F.cdn_url()))
      File.write!(Export.blob_path(f.export, entry["sha256"]), "tampered")
      {Local, local} = storage(dir)
      lax = %{verify: fn _ref, _meta -> :ok end}
      storage = {BubbleEx.LoadTest.FlakyStorage, %{local: local, behaviour: lax}}

      {:ok, report} = Load.run(f.export, f.model, f.target, [storage: storage] ++ @unmapped)
      assert report.files.copied == 1
      assert Memory.tables(f.target)["task"][F.task1()]["cover"] == F.cdn_url()
    end

    test "each copied file is in the ledger as soon as it is copied", %{tmp_dir: dir} do
      f = setup_fixture(:field_types, dir)
      {Local, local} = storage(dir)
      ledger = Path.join(dir, "ledger")
      test = self()

      # The cover copies; the private contract hangs, and the run is killed.
      hang = %{
        put: fn
          %{visibility: :public} = meta, source ->
            Local.put(local, meta, source)

          _meta, _source ->
            send(test, {:hanging, self()})
            Process.sleep(:infinity)
        end
      }

      storage = {BubbleEx.LoadTest.FlakyStorage, %{local: local, behaviour: hang}}
      opts = [storage: storage, ledger_dir: ledger, file_concurrency: 1] ++ @unmapped
      run = spawn(fn -> Load.run(f.export, f.model, f.target, opts) end)
      assert_receive {:hanging, _}, 5_000
      Process.exit(run, :kill)

      {_, state} = ledger_state(ledger)
      assert Map.keys(state["files"]) == [F.cdn_url()]
    end
  end

  test "a process killed mid-run resumes from its ledger", %{tmp_dir: dir} do
    f = setup_fixture(:cut2, dir)
    ledger = Path.join(dir, "ledger")
    test = self()

    Memory.on_upsert(f.target, fn table, _rows ->
      if table.type == "card" do
        send(test, {:mid_run, self()})
        Process.sleep(:infinity)
      end
    end)

    pid =
      spawn(fn -> Load.run(f.export, f.model, f.target, ledger_dir: ledger, batch_size: 1) end)

    assert_receive {:mid_run, ^pid}, 5_000
    Process.exit(pid, :kill)

    Memory.on_upsert(f.target, fn _, _ -> :ok end)
    {:ok, resumed} = Load.run(f.export, f.model, f.target, ledger_dir: ledger, batch_size: 1)
    assert resumed.types["board"].resumed == 2
    assert resumed.types["card"].resumed == 0

    clean = Memory.start(elem(F.project(:cut2), 1))
    {:ok, _} = Load.run(f.export, f.model, clean)
    assert Memory.tables(f.target) == Memory.tables(clean)
  end

  describe "the ledger" do
    test "replays its journal, compacts, and ignores a torn last line", %{tmp_dir: dir} do
      ids = %{export_sha256: "e", plan_sha256: "p", target: "t"}
      {:ok, l} = Ledger.open(dir, ids, compact_every: 3)
      l = Enum.reduce(1..7, l, &Ledger.file_copied(&2, "https://x/#{&1}", "ref#{&1}"))
      l = Ledger.batch(l, "card", 5, %{inserted: 5, updated: 0, unchanged: 0})
      Ledger.close(l)

      [snapshot] = Path.wildcard(Path.join(dir, "*.json"))
      journal = String.replace_suffix(snapshot, ".json", ".journal")
      File.write!(journal, ~s({"file":"https://x/torn"), [:append])

      {:ok, again} = Ledger.open(dir, ids, compact_every: 3)
      assert map_size(Ledger.files(again)) == 7
      assert Ledger.rows_done(again, "card") == 5
      Ledger.close(again)
    end

    test "a torn first line hides nothing appended later", %{tmp_dir: dir} do
      ids = %{export_sha256: "e", plan_sha256: "p", target: "t"}
      {:ok, l} = Ledger.open(dir, ids)
      Ledger.close(l)
      [snapshot] = Path.wildcard(Path.join(dir, "*.json"))
      File.write!(String.replace_suffix(snapshot, ".json", ".journal"), ~s({"file":"https://x/t))

      {:ok, l} = Ledger.open(dir, ids)
      l = Ledger.file_copied(l, "https://x/after", "ref")
      Ledger.close(l)

      {:ok, again} = Ledger.open(dir, ids)
      assert Ledger.files(again) == %{"https://x/after" => "ref"}
      Ledger.close(again)
    end

    test "events a snapshot covers are not counted twice", %{tmp_dir: dir} do
      ids = %{export_sha256: "e", plan_sha256: "p", target: "t"}
      {:ok, l} = Ledger.open(dir, ids)
      l = Ledger.batch(l, "card", 5, %{inserted: 5, updated: 0, unchanged: 0})
      Ledger.close(l)
      [snapshot] = Path.wildcard(Path.join(dir, "*.json"))
      journal = String.replace_suffix(snapshot, ".json", ".journal")
      kept = File.read!(journal)

      # Opening compacts the journal into the snapshot; a crash before
      # the journal was removed would leave it behind.
      {:ok, l} = Ledger.open(dir, ids)
      Ledger.close(l)
      File.write!(journal, kept)

      {:ok, again} = Ledger.open(dir, ids)
      assert Ledger.type_counts(again, "card")["inserted"] == 5
      Ledger.close(again)
    end

    test "leaves an existing directory's mode alone", %{tmp_dir: dir} do
      File.chmod!(dir, 0o755)
      {:ok, l} = Ledger.open(dir, %{export_sha256: "e", plan_sha256: "p", target: "t"})
      Ledger.close(l)
      assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o755
    end
  end

  test "the ledger's run key changes with the export, plan and target" do
    key = Ledger.run_key("a", "b", "c")
    assert key != Ledger.run_key("a2", "b", "c")
    assert key != Ledger.run_key("a", "b2", "c")
    assert key != Ledger.run_key("a", "b", "c2")
  end
end

defmodule BubbleEx.LoadTest.FlakyStorage do
  @moduledoc false
  # A storage whose put/verify are the test's functions (default: Local's).
  @behaviour BubbleEx.Load.Storage

  alias BubbleEx.Load.Storage.Local

  @impl true
  def identity(%{local: local}), do: "flaky:" <> Local.identity(local)

  @impl true
  def put(%{local: local, behaviour: b}, meta, source),
    do: Map.get(b, :put, &Local.put(local, &1, &2)).(meta, source)

  @impl true
  def verify(%{local: local, behaviour: b}, ref, meta),
    do: Map.get(b, :verify, &Local.verify(local, &1, &2)).(ref, meta)
end

defmodule BubbleEx.LoadExportDeleteTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Load.Export
  alias BubbleEx.Test.LoadFixture, as: F

  @moduletag :tmp_dir

  test "deletes an export", %{tmp_dir: dir} do
    {:ok, export} = F.export(:cut2, Path.join(dir, "e"))
    File.write!(Path.join([export.dir, "files", ".fetch-123"]), "partial")
    assert {:ok, %{deleted: n, left: []}} = Export.delete(export.dir)
    assert n > 4
    refute File.exists?(export.dir)
  end

  test "keeps and lists what is not the export's", %{tmp_dir: dir} do
    {:ok, export} = F.export(:cut2, Path.join(dir, "e"))
    File.write!(Path.join(export.dir, "notes.txt"), "keep")
    File.mkdir_p!(Path.join(export.dir, "rows/sub"))
    File.write!(Path.join(export.dir, "files/readme"), "keep")

    assert {:ok, %{left: left}} = Export.delete(export.dir)
    assert left == ["files", "files/readme", "notes.txt", "rows", "rows/sub"]
    assert File.read!(Path.join(export.dir, "notes.txt")) == "keep"
    refute File.exists?(Path.join(export.dir, "manifest.json"))
  end

  test "an interrupted export's directory loses only the export's files", %{tmp_dir: dir} do
    other = Path.join(dir, "work")
    File.mkdir_p!(Path.join(other, "rows"))
    File.write!(Path.join(other, "state.json"), "{}")
    File.write!(Path.join(other, "rows/task.part"), "x")
    File.write!(Path.join(other, "thesis.docx"), "precious")

    assert {:ok, %{deleted: 2, left: ["thesis.docx"]}} = Export.delete(other)
    assert File.read!(Path.join(other, "thesis.docx")) == "precious"
  end

  test "refuses a symbolic link and what is not an export", %{tmp_dir: dir} do
    {:ok, export} = F.export(:cut2, Path.join(dir, "e"))
    link = Path.join(dir, "link")
    File.ln_s!(export.dir, link)
    assert {:error, _} = Export.delete(link)
    assert File.exists?(Path.join(export.dir, "manifest.json"))

    # A link inside the export is not followed.
    outside = Path.join(dir, "outside.txt")
    File.write!(outside, "keep")
    File.ln_s!(outside, Path.join([export.dir, "files", String.duplicate("a", 64)]))
    assert {:ok, %{left: left}} = Export.delete(export.dir)
    assert left == ["files", "files/" <> String.duplicate("a", 64)]
    assert File.read!(outside) == "keep"

    notes = Path.join(dir, "notes")
    File.mkdir_p!(notes)
    File.write!(Path.join(notes, "manifest.json"), ~s({"format":"other"}))
    assert {:error, _} = Export.delete(notes)
    assert File.exists?(Path.join(notes, "manifest.json"))
  end

  test "the mix task deletes an export", %{tmp_dir: dir} do
    {:ok, export} = F.export(:cut2, Path.join(dir, "e"))
    ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Bubble.Export.Delete.run([export.dir]) end)
    refute File.exists?(export.dir)
    assert_raise Mix.Error, fn -> Mix.Tasks.Bubble.Export.Delete.run([dir]) end
  end
end
