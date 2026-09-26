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
               confirmed_column: false
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
            {:load_auth_status_unmapped, "user", nil},
            {:load_auth_provider_unmigrated, "user", nil}
          ],
          do: assert(MapSet.member?(codes, code), inspect(code))

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

      text = dir |> Path.join("l/*") |> Path.wildcard() |> Enum.map_join(&File.read!/1)
      refute text =~ "Ada@Example"
      refute text =~ "keeps spaces"
      {_file, state} = ledger_state(Path.join(dir, "l"))
      assert map_size(state["files"]) == 2
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

  test "deletes an export and nothing else", %{tmp_dir: dir} do
    {:ok, export} = F.export(:cut2, Path.join(dir, "e"))
    assert {:ok, n} = Export.delete(export.dir)
    assert n > 3
    refute File.exists?(export.dir)

    other = Path.join(dir, "notes")
    File.mkdir_p!(other)
    File.write!(Path.join(other, "keep.txt"), "x")
    assert {:error, _} = Export.delete(other)
    assert File.exists?(Path.join(other, "keep.txt"))

    File.write!(Path.join(other, "manifest.json"), ~s({"format":"other"}))
    assert {:error, _} = Export.delete(other)
  end

  test "the mix task deletes an export", %{tmp_dir: dir} do
    {:ok, export} = F.export(:cut2, Path.join(dir, "e"))
    ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Bubble.Export.Delete.run([export.dir]) end)
    refute File.exists?(export.dir)
    assert_raise Mix.Error, fn -> Mix.Tasks.Bubble.Export.Delete.run([dir]) end
  end
end
