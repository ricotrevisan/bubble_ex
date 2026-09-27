# End-to-end check of the data loader (BubbleEx.Load, WTF-357) against
# PostgreSQL, run by scripts/ash_compile_check.sh from the bubble_ex root
# (MIX_ENV=test) after the scratch project's migrations:
#
#     MIX_ENV=test mix run scripts/ash_compile_check/load.exs <scratch dir>
#
# For four fixtures (BubbleEx.Test.LoadFixture: `field_types`, every
# Bubble field kind; `cut2`, `combined` and `cut3`, the owner decision sets
# of BubbleEx.Test.DecidedFixture), into the databases AshPostgres migrated
# (ash_check_<fixture>, emptied first; invented data only):
#
#   * a dry run reports the per-type counts and the expected diagnostics
#     and writes nothing; a dry run against a schema that lacks the tables
#     reports load_schema_mismatch, and a real run against it is refused
#   * a run interrupted by a failing batch leaves its ledger; the rerun
#     resumes after the last recorded batch and ends in exactly the state
#     a clean load gives (compared row by row, as PostgreSQL's to_jsonb)
#   * rerunning a finished load changes nothing (0 inserted, 0 updated)
#   * a new export with one changed and one new record (a delta sync)
#     updates one and inserts one
#   * under a unique index on lower(email) (the Phoenix identity), two
#     users whose emails were swapped in the target load back (emails are
#     cleared first); an exported email held by a record the export does
#     not hold blocks the dry run and the run (load_email_conflict)
#   * stored values: trimmed and converted text references, dropped IDs
#     of deleted records, arrays, typed structs, option keys, dates at
#     microsecond precision, emails, integer/decimal refinements, and
#     files: copied with verified SHA-256, private ones private (0600, a
#     private reference), a failed one keeping its Bubble URL
#   * users' confirmed_at (WTF-413): a confirmed user's Created Date, nil
#     for an unconfirmed one; stable across the rerun and the delta sync;
#     a confirmation made in the target survives a delta sync while the
#     email is unchanged, and yields to Bubble's status when it changed
#   * join tables (cut 3, WTF-406): every list member is one row (a
#     repeated one once, a dangling one kept) with its list's column; two
#     mirrored lists sharing a table are written separately, so a member
#     of one list is never added to the other; the interrupted and resumed
#     load, the rerun and the delta sync compare them too, and a later
#     export that drops members moves positions but deletes nothing
#     (WTF-414 prunes)
#
# Before that, the loader's schema check (BubbleEx.Target.Ash.Loader)
# runs against every fixture database render.exs created (and, with
# BUBBLE_EX_PRIVATE_EXPORT, the private export's, faithful and with every
# cut-2 finding accepted: a schema-level check, no data): the column types
# the plan expects must be the ones AshPostgres migrated, with no
# load_schema_mismatch. Only counts are printed.
#
# It then writes loaded.json for scripts/ash_compile_check/loaded.exs,
# which reads the loaded records back through Ash in the scratch project
# (every value casts; derived calculations and aggregates compute from
# the loaded data). No Bubble app and no token are involved.

alias BubbleEx.Load
alias BubbleEx.Load.Storage.Local
alias BubbleEx.Target.Ash.Loader
alias BubbleEx.Test.LoadFixture, as: F

[scratch] = System.argv()
work = Path.join(scratch, "load")
File.rm_rf!(work)
File.mkdir_p!(work)

base =
  URI.parse(System.get_env("ASH_COMPILE_CHECK_DB", "ecto://postgres:postgres@localhost:5432"))

[user, password] = String.split(base.userinfo || "postgres:postgres", ":", parts: 2)

defmodule LoadCheck do
  def fail!(fixture, message), do: raise("load check (#{fixture}): #{message}")

  def check!(fixture, true, _message), do: fixture
  def check!(fixture, false, message), do: fail!(fixture, message)

  def eq!(fixture, actual, expected, what) do
    if actual == expected,
      do: fixture,
      else: fail!(fixture, "#{what}: expected #{inspect(expected)}, got #{inspect(actual)}")
  end

  def query(conn), do: fn sql, params -> Postgrex.query(conn, sql, params) end

  # Fails the Nth INSERT, as a crash mid-run would.
  def failing(conn, n) do
    counter = :counters.new(1, [])

    fn sql, params ->
      if String.starts_with?(sql, "INSERT") do
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == n,
          do: {:error, :injected_crash},
          else: Postgrex.query(conn, sql, params)
      else
        Postgrex.query(conn, sql, params)
      end
    end
  end

  def truncate(conn, plan) do
    tables =
      Enum.map_join(plan.tables ++ plan.joins, ", ", &~s("public"."#{&1.table}"))

    Postgrex.query!(conn, "TRUNCATE #{tables}", [])
  end

  # Every table (and join table) as PostgreSQL's to_jsonb of each row, by
  # primary key.
  def snapshot(conn, plan) do
    keys =
      Enum.map(plan.tables, &{&1.table, ~s("#{&1.key}")}) ++
        Enum.map(plan.joins, &{&1.table, ~s("#{&1.left.column}", "#{&1.right.column}")})

    Map.new(keys, fn {table, order} ->
      %{rows: rows} =
        Postgrex.query!(
          conn,
          "SELECT to_jsonb(t)::text FROM \"public\".\"#{table}\" t ORDER BY #{order}",
          []
        )

      {table, Enum.map(rows, fn [json] -> Jason.decode!(json) end)}
    end)
  end

  def row(snapshot, table, id), do: Enum.find(Map.fetch!(snapshot, table), &(&1["id"] == id))

  def codes(report),
    do:
      report.diagnostics
      |> Enum.map(&{&1.code, &1.subject[:type], &1.subject[:field]})
      |> MapSet.new()

  def total(report, key),
    do: report.types |> Map.values() |> Enum.map(&Map.get(&1, key, 0)) |> Enum.sum()
end

# --- the schema check over every fixture database ----------------------------------------

connect = fn database ->
  {:ok, conn} =
    Postgrex.start_link(
      hostname: base.host,
      port: base.port || 5432,
      username: URI.decode(user),
      password: URI.decode(password),
      database: database
    )

  conn
end

faithful = fn app ->
  fn ->
    {:ok, model} = BubbleEx.Model.build(app)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :unverified)
    {model, project}
  end
end

decided = fn set ->
  fn ->
    %{model: model} = BubbleEx.Test.DecidedFixture.build(set)

    {:ok, project} =
      if set == :locked,
        do: BubbleEx.Test.DecidedFixture.locked_project(privacy: :unverified),
        else: BubbleEx.Test.DecidedFixture.project(set, privacy: :unverified)

    {model, project}
  end
end

schema_fixtures =
  for {pattern, prefix} <- [
        {"test/support/model/*.json", ""},
        {"test/support/target/ash/*.json", "target_"},
        {"test/support/expression/*.json", "expr_"}
      ],
      path <- pattern |> Path.wildcard() |> Enum.sort() do
    {prefix <> Path.basename(path, ".json"), faithful.(path |> File.read!() |> Jason.decode!())}
  end ++
    for set <- [:combined, :locked, :count, :cut2, :cut3] do
      {"decided_#{set}", decided.(set)}
    end

private_fixtures =
  case System.get_env("BUBBLE_EX_PRIVATE_EXPORT") do
    path when path in [nil, ""] ->
      []

    path ->
      app = BubbleEx.Test.SplitExport.load(path)

      cut2 = fn ->
        {:ok, model} = BubbleEx.Model.build(app)
        {:ok, index} = BubbleEx.Index.build(app, model: model)
        {:ok, %{findings: findings}} = BubbleEx.Findings.analyze(app, model: model, index: index)
        {_records, applied, sha} = BubbleEx.Test.DecidedFixture.accept_cut2(findings, [], index)

        {:ok, project} =
          BubbleEx.Target.Ash.map(model, applied, privacy: :unverified, decisions_sha256: sha)

        {model, project}
      end

      cut3 = fn ->
        {:ok, model} = BubbleEx.Model.build(app)
        {:ok, index} = BubbleEx.Index.build(app, model: model)
        {:ok, %{findings: findings}} = BubbleEx.Findings.analyze(app, model: model, index: index)
        {_records, applied, sha} = BubbleEx.Test.DecidedFixture.accept_cut3(findings, [], index)

        {:ok, project} =
          BubbleEx.Target.Ash.map(model, applied, privacy: :unverified, decisions_sha256: sha)

        {model, project}
      end

      [{"private_app", faithful.(app)}, {"private_cut2", cut2}, {"private_cut3", cut3}]
  end

{tables, columns} =
  Enum.reduce(schema_fixtures ++ private_fixtures, {0, 0}, fn {name, build}, {tables, columns} ->
    {model, project} = build.()
    conn = connect.("ash_check_" <> name)
    {Loader, config} = Loader.target(project, query: LoadCheck.query(conn))
    {:ok, plan} = Loader.plan(config, model)
    {:ok, diags} = Loader.check_schema(config, plan)
    GenServer.stop(conn)

    case Enum.filter(diags, &(&1.code == :load_schema_mismatch)) do
      [] ->
        :ok

      found ->
        LoadCheck.fail!(
          name,
          "#{length(found)} schema mismatches, e.g. #{inspect(hd(found).details)}"
        )
    end

    {tables + length(plan.tables) + length(plan.joins),
     columns + Enum.sum(Enum.map(plan.tables, &(length(&1.columns) + 1))) +
       Enum.sum(Enum.map(plan.joins, &(2 + length(&1.sides))))}
  end)

IO.puts(
  "load schema check passed: #{length(schema_fixtures ++ private_fixtures)} databases, " <>
    "#{tables} tables and #{columns} columns typed as the loader expects"
)

# --- loading the fixture exports ------------------------------------------------------------

fixtures = [
  {:field_types, "ash_check_field_types", "Fixtures.FieldTypes"},
  {:cut2, "ash_check_decided_cut2", "Fixtures.DecidedCut2"},
  {:combined, "ash_check_decided_combined", "Fixtures.DecidedCombined"},
  {:cut3, "ash_check_decided_cut3", "Fixtures.DecidedCut3"}
]

# Diagnostics each fixture's data must produce ({code, type, field}).
expected_codes = %{
  field_types: [
    {:load_invalid_record_id, "task", nil},
    {:load_unmapped_key, "task", nil},
    {:load_type_mismatch, "task", "estimate_number"},
    {:load_type_mismatch, "task", "done_boolean"},
    {:load_type_mismatch, "task", "scores_list_number"},
    {:load_unknown_option, "task", "labels_list_option_status"},
    {:load_option_by_label, "task", "status_option_status"},
    {:load_file_failed, "task", "files_list_file"},
    {:load_file_not_bubble, "task", "files_list_file"},
    {:load_file_url_in_text, "task", "notes_list_text"},
    {:load_dangling_reference, "task", "subtasks_list_custom_task"},
    {:load_dangling_reference, "task", "owner_user"},
    {:load_confirmed_at_migrated, "user", nil},
    {:load_auth_provider_unmigrated, "user", nil}
  ],
  cut2: [
    {:load_duplicate_record, "card", nil},
    {:load_type_mismatch, "card", "points_number"},
    {:load_invalid_reference, "card", "blocker_ids_list_text"},
    {:load_dangling_reference, "card", "blocker_ids_list_text"},
    {:load_dangling_reference, "card", "assignee_id_text"},
    {:load_deleted_ids_dropped, "board", "watchers_list_user"},
    {:load_derived_drift, "board", "watcher_count_number"},
    {:load_derived_drift, "board", "card_count_number"},
    {:load_derived_drift, "card", "board_card_count_number"},
    {:load_reverse_list_drift, "board", "cards_list_custom_card"}
  ],
  combined: [
    {:load_derived_drift, "project", "sort_workspace_name_text"},
    {:load_type_mismatch, "project", "task_count_number"}
  ],
  cut3: [
    {:load_join_duplicate, "project", "tasks_list_custom_task"},
    {:load_dangling_reference, "project", "tasks_list_custom_task"},
    {:load_dangling_reference, "workspace", "members_list_user"},
    {:load_join_asymmetric, "workspace", "members_list_user"},
    {:load_join_asymmetric, "user", "workspaces_list_custom_workspace"},
    {:load_join_asymmetric, "project", "viewers_list_user"},
    {:load_join_asymmetric, "user", "favorites_list_custom_project"}
  ]
}

loaded =
  for {which, database, namespace} <- fixtures do
    fixture = Atom.to_string(which)

    {:ok, conn} =
      Postgrex.start_link(
        hostname: base.host,
        port: base.port || 5432,
        username: URI.decode(user),
        password: URI.decode(password),
        database: database
      )

    model = F.model(which)
    {:ok, project} = F.project(which, privacy: :unverified)
    dir = Path.join(work, fixture)
    {:ok, export} = F.export(which, Path.join(dir, "export"))
    target = Loader.target(project, query: LoadCheck.query(conn))
    {Loader, config} = target
    {:ok, plan} = Loader.plan(config, model)
    storage = Local.new(root: Path.join(dir, "storage"), public_url: "https://files.example.test")
    # field_types has a key no field names ("Legacy Field"): allowed here.
    base_opts = if which == :field_types, do: [allow_unmapped_keys: true], else: []
    ledger = Path.join(dir, "ledger")
    opts = [storage: storage, ledger_dir: ledger, batch_size: 1] ++ base_opts

    LoadCheck.truncate(conn, plan)

    # --- dry run: counts and diagnostics, nothing written ---------------------------
    {:ok, dry} = Load.dry_run(export, model, target, base_opts)
    LoadCheck.eq!(fixture, dry.blocked, [], "dry run blocked")
    codes = LoadCheck.codes(dry)

    for code <- Map.fetch!(expected_codes, which),
        not MapSet.member?(codes, code),
        do:
          LoadCheck.fail!(
            fixture,
            "dry run lacks #{inspect(code)}: #{inspect(MapSet.to_list(codes))}"
          )

    empty = LoadCheck.snapshot(conn, plan) |> Map.values() |> Enum.all?(&(&1 == []))
    LoadCheck.check!(fixture, empty, "the dry run wrote rows")
    LoadCheck.check!(fixture, not File.exists?(ledger), "the dry run wrote a ledger")

    # --- a schema lacking the tables: reported, and a real run refused ------------------
    wrong = Loader.target(project, query: LoadCheck.query(conn), schema: "no_such_schema")
    {:ok, wrong_dry} = Load.dry_run(export, model, wrong, base_opts)
    LoadCheck.eq!(fixture, wrong_dry.blocked, [:load_schema_mismatch], "missing schema")
    {:error, refused} = Load.run(export, model, wrong, opts)
    LoadCheck.eq!(fixture, refused.context.blocked, [:load_schema_mismatch], "refused run")

    # --- interrupted, then resumed ------------------------------------------------------------
    crashing = Loader.target(project, query: LoadCheck.failing(conn, 3))
    {:error, crash} = Load.run(export, model, crashing, opts)
    LoadCheck.eq!(fixture, crash.context[:reason], :injected_crash, "crash error")
    partial = LoadCheck.snapshot(conn, plan) |> Map.values() |> List.flatten() |> length()
    LoadCheck.eq!(fixture, partial, 2, "rows written before the crash (batch size 1)")

    {:ok, resumed} = Load.run(export, model, target, opts)
    records = LoadCheck.total(resumed, :records)
    LoadCheck.eq!(fixture, LoadCheck.total(resumed, :resumed), 2, "rows resumed")
    LoadCheck.eq!(fixture, LoadCheck.total(resumed, :inserted), records, "inserted over the run")
    after_resume = LoadCheck.snapshot(conn, plan)

    # --- a finished load, rerun: nothing changes ------------------------------------------------
    {:ok, rerun} = Load.run(export, model, target, opts)
    LoadCheck.eq!(fixture, LoadCheck.total(rerun, :inserted), 0, "rerun inserted")
    LoadCheck.eq!(fixture, LoadCheck.total(rerun, :updated), 0, "rerun updated")
    LoadCheck.eq!(fixture, LoadCheck.total(rerun, :unchanged), records, "rerun unchanged")
    LoadCheck.eq!(fixture, LoadCheck.snapshot(conn, plan), after_resume, "state after a rerun")

    # --- a clean load gives the same state as the resumed one -------------------------------------
    LoadCheck.truncate(conn, plan)

    {:ok, clean} =
      Load.run(export, model, target, [storage: storage, batch_size: 500] ++ base_opts)

    LoadCheck.eq!(fixture, LoadCheck.total(clean, :inserted), records, "clean load inserted")
    snapshot = LoadCheck.snapshot(conn, plan)
    LoadCheck.eq!(fixture, snapshot, after_resume, "clean load vs resumed load")

    # --- a delta sync: one changed record, one new ---------------------------------------------------
    rows = F.rows(which)
    {type, [first | rest]} = rows |> Enum.sort() |> List.first()
    newcomer = %{"_id" => F.id(900), "Created Date" => "2024-09-01T00:00:00Z"}
    changed = Map.put(first, "Modified Date", "2025-01-01T00:00:00Z")
    delta_rows = Map.put(rows, type, [changed, newcomer | rest])
    {:ok, delta_export} = F.export(which, Path.join(dir, "delta"), delta_rows)
    {:ok, delta} = Load.run(delta_export, model, target, opts)
    LoadCheck.eq!(fixture, LoadCheck.total(delta, :inserted), 1, "delta inserted")
    LoadCheck.eq!(fixture, LoadCheck.total(delta, :updated), 1, "delta updated")
    LoadCheck.truncate(conn, plan)
    {:ok, _} = Load.run(export, model, target, [storage: storage] ++ base_opts)

    # --- emails against a unique index (as the Phoenix project's identity) ---------------------
    Postgrex.query!(conn, "DROP INDEX IF EXISTS load_check_email", [])
    set_email = ~s[UPDATE "public"."user" SET email = $2 WHERE id = $1]
    Postgrex.query!(conn, set_email, [F.ada(), "bob@example.test"])
    Postgrex.query!(conn, set_email, [F.bob(), "ada@example.test"])

    Postgrex.query!(
      conn,
      ~s[CREATE UNIQUE INDEX load_check_email ON "public"."user" (lower(email))],
      []
    )

    {:ok, swapped} =
      Load.run(export, model, target, [storage: storage, batch_size: 1] ++ base_opts)

    LoadCheck.eq!(fixture, swapped.blocked, [], "email swap")

    %{rows: emails} =
      Postgrex.query!(
        conn,
        ~s[SELECT id, email FROM "public"."user" WHERE id = ANY($1) ORDER BY id],
        [[F.ada(), F.bob()]]
      )

    LoadCheck.eq!(
      fixture,
      emails,
      [[F.ada(), "Ada@Example.test"], [F.bob(), "bob@example.test"]],
      "swapped back"
    )

    # Carol is new in the export, and a record the export does not hold
    # (a user deleted in Bubble) has her email in the target.
    Postgrex.query!(conn, ~s[DELETE FROM "public"."user" WHERE id = $1], [F.carol()])

    Postgrex.query!(
      conn,
      ~s[INSERT INTO "public"."user" (id, email) VALUES ($1, 'CAROL@example.test')],
      [F.id(500)]
    )

    {:ok, conflict} = Load.dry_run(export, model, target, base_opts)

    LoadCheck.eq!(
      fixture,
      conflict.blocked,
      [:load_email_conflict],
      "email held by a deleted user"
    )

    {:error, _} = Load.run(export, model, target, [storage: storage] ++ base_opts)
    Postgrex.query!(conn, ~s[DELETE FROM "public"."user" WHERE id = $1], [F.id(500)])
    Postgrex.query!(conn, "DROP INDEX load_check_email", [])
    {:ok, _} = Load.run(export, model, target, [storage: storage] ++ base_opts)

    # --- stored values -----------------------------------------------------------------------------
    user = LoadCheck.row(snapshot, "user", F.ada())
    LoadCheck.eq!(fixture, user["email"], "Ada@Example.test", "ada's email (trimmed)")
    bob = LoadCheck.row(snapshot, "user", F.bob())
    LoadCheck.eq!(fixture, bob["email"], "bob@example.test", "bob's email (from authentication)")

    # confirmed_at (WTF-413): Bubble's confirmed flag, as the Created Date.
    carol = LoadCheck.row(snapshot, "user", F.carol())
    LoadCheck.eq!(fixture, user["confirmed_at"], "2024-01-01T10:00:00", "ada's confirmed_at")
    LoadCheck.eq!(fixture, bob["confirmed_at"], nil, "bob's confirmed_at (unconfirmed)")
    LoadCheck.eq!(fixture, carol["confirmed_at"], "2024-01-03T10:00:00", "carol's confirmed_at")

    LoadCheck.check!(
      fixture,
      not MapSet.member?(codes, {:load_auth_status_unmapped, "user", nil}),
      "the confirmed status is mapped"
    )

    # Bob (unconfirmed in Bubble) and Carol confirm in the target (a
    # magic-link sign-in); a delta sync changes Carol's email and unconfirms
    # her. Bob keeps his confirmation (email unchanged), Carol takes Bubble's.
    Postgrex.query!(
      conn,
      ~s[UPDATE "public"."user" SET confirmed_at = '2026-09-20T00:00:00Z' WHERE id = ANY($1)],
      [[F.bob(), F.carol()]]
    )

    confirm_rows =
      Map.update!(F.rows(which), "user", fn [ada, bob, carol] ->
        carol =
          carol
          |> put_in(["authentication", "email", "email"], "carol2@example.test")
          |> put_in(["authentication", "email", "email_confirmed"], false)

        [ada, bob, carol]
      end)

    {:ok, confirm_export} = F.export(which, Path.join(dir, "confirm"), confirm_rows)
    {:ok, synced} = Load.run(confirm_export, model, target, [storage: storage] ++ base_opts)
    LoadCheck.eq!(fixture, synced.types["user"].updated, 1, "confirmation sync: users updated")
    after_sync = LoadCheck.snapshot(conn, plan)
    confirmed = &(LoadCheck.row(after_sync, "user", &1)["confirmed_at"])
    LoadCheck.eq!(fixture, confirmed.(F.bob()), "2026-09-20T00:00:00", "bob keeps his confirmation")
    LoadCheck.eq!(fixture, confirmed.(F.carol()), nil, "carol, new email, takes Bubble's status")
    LoadCheck.eq!(fixture, confirmed.(F.ada()), "2024-01-01T10:00:00", "ada unchanged")

    # Back to the export's state for what follows.
    LoadCheck.truncate(conn, plan)
    {:ok, _} = Load.run(export, model, target, [storage: storage] ++ base_opts)

    case which do
      :field_types ->
        t = LoadCheck.row(snapshot, "task", F.task1())
        LoadCheck.eq!(fixture, t["title"], "  keeps spaces ", "text verbatim")

        LoadCheck.eq!(
          fixture,
          t["labels"],
          ["open", "closed"],
          "option keys (a label mapped, an unknown dropped)"
        )

        LoadCheck.eq!(fixture, t["status"], "open", "option by label")

        LoadCheck.eq!(
          fixture,
          t["dates"],
          ["2024-01-01T00:00:00.5", "2024-01-01T00:00:00"],
          "list of dates"
        )

        LoadCheck.eq!(fixture, t["created_date"], "2024-02-02T08:30:00.123", "microseconds")
        LoadCheck.eq!(fixture, t["scores"], [1.0, 3.5], "numbers (a text dropped)")

        LoadCheck.eq!(
          fixture,
          t["place"],
          %{"formatted_address" => "1 Main St", "lat" => 50.85, "lng" => 4.35},
          "address"
        )

        LoadCheck.eq!(
          fixture,
          t["window"],
          %{"start" => "2024-03-01T00:00:00.000000Z", "end" => "2024-04-01T00:00:00.000000Z"},
          "date range"
        )

        LoadCheck.eq!(fixture, t["watchers"], [F.ada(), F.gone_user()], "dangling IDs kept")

        LoadCheck.check!(
          fixture,
          String.starts_with?(t["attachment"], "private/"),
          "private file reference"
        )

        LoadCheck.check!(
          fixture,
          String.starts_with?(t["cover"], "https://files.example.test/"),
          "public file URL"
        )

        [private, lost, external] = t["files"]
        LoadCheck.eq!(fixture, private, t["attachment"], "one private file, one reference")
        LoadCheck.eq!(fixture, lost, F.missing_url(), "a failed file keeps its Bubble URL")
        LoadCheck.eq!(fixture, external, F.external_url(), "a URL outside Bubble is kept")
        stored = Path.join([dir, "storage", t["attachment"]])
        %File.Stat{mode: mode} = File.stat!(stored)
        LoadCheck.eq!(fixture, Bitwise.band(mode, 0o777), 0o600, "private file mode")
        LoadCheck.eq!(fixture, File.read!(stored), "%PDF private contract", "private file bytes")
        LoadCheck.eq!(fixture, clean.files.copied, 2, "files copied")
        t2 = LoadCheck.row(snapshot, "task", F.task2())

        LoadCheck.eq!(
          fixture,
          {t2["title"], t2["estimate"], t2["done"]},
          {"", nil, nil},
          "empty text kept, mismatches empty"
        )

      :cut2 ->
        b1 = LoadCheck.row(snapshot, "board", F.board1())
        LoadCheck.eq!(fixture, b1["watchers"], [F.ada()], "counted list without deleted IDs")
        LoadCheck.check!(fixture, not Map.has_key?(b1, "cards"), "a has_many list has no column")
        c1 = LoadCheck.row(snapshot, "card", F.card1())
        LoadCheck.eq!(fixture, c1["assignee_id"], F.ada(), "text reference trimmed")

        LoadCheck.eq!(
          fixture,
          c1["blockers"],
          [F.card2(), F.gone_card()],
          "list of text references"
        )

        LoadCheck.eq!(fixture, c1["title"], "One", "the latest copy of a duplicate")
        c2 = LoadCheck.row(snapshot, "card", F.card2())

        LoadCheck.eq!(
          fixture,
          {c2["assignee_id"], c2["points"]},
          {nil, nil},
          "empty reference, mismatch"
        )

      :combined ->
        p1 = LoadCheck.row(snapshot, "initiative", F.initiative1())
        LoadCheck.eq!(fixture, p1["task_count"], 2, "integer refinement")
        p2 = LoadCheck.row(snapshot, "initiative", F.initiative2())
        LoadCheck.eq!(fixture, p2["task_count"], nil, "a fraction in an integer column")
        t1 = LoadCheck.row(snapshot, "todo_item", F.todo1())
        LoadCheck.eq!(fixture, t1["points"], 1.25, "decimal refinement")

      :cut3 ->
        p1 = LoadCheck.row(snapshot, "project", F.initiative1())
        LoadCheck.check!(fixture, not Map.has_key?(p1, "tasks"), "a joined list has no column")

        LoadCheck.eq!(
          fixture,
          Enum.map(snapshot["project_tasks"], &{&1["task_id"], &1["position"]}) |> Enum.sort(),
          Enum.sort([{F.todo1(), 0}, {F.todo2(), 1}, {F.gone_task(), 3}]),
          "a list's rows: a repeated member once, a dangling one kept, positions"
        )

        ws = fn snap ->
          snap["user_workspaces"]
          |> Enum.map(&{&1["user_id"], &1["workspace_id"], &1["workspaces_position"], &1["members_position"]})
          |> Enum.sort()
        end

        LoadCheck.eq!(
          fixture,
          ws.(snapshot),
          Enum.sort([
            {F.ada(), F.workspace1(), 0, 0},
            {F.bob(), F.workspace1(), nil, 1},
            {F.gone_user(), F.workspace1(), nil, 2},
            {F.carol(), F.workspace2(), 0, 0},
            {F.carol(), F.workspace1(), 1, nil}
          ]),
          "a shared table: each list's own column, nothing added to the other list"
        )

        # A later export drops Bob from Acme's members: positions move, no
        # row is deleted and the other list's column is untouched.
        rows = F.cut3_rows()
        [w1 | rest] = rows["workspace"]
        rows = %{rows | "workspace" => [Map.put(w1, "Members", [F.ada(), F.gone_user()]) | rest]}
        {:ok, dropped} = F.export(which, Path.join(dir, "dropped"), rows)
        {:ok, _} = Load.run(dropped, model, target, [storage: storage] ++ base_opts)

        LoadCheck.eq!(
          fixture,
          ws.(LoadCheck.snapshot(conn, plan)),
          Enum.sort([
            {F.ada(), F.workspace1(), 0, 0},
            {F.bob(), F.workspace1(), nil, 1},
            {F.gone_user(), F.workspace1(), nil, 1},
            {F.carol(), F.workspace2(), 0, 0},
            {F.carol(), F.workspace1(), 1, nil}
          ]),
          "the membership rows after the delta (none deleted)"
        )

        # back to the fixture's state for loaded.exs
        LoadCheck.truncate(conn, plan)
        {:ok, _} = Load.run(export, model, target, [storage: storage] ++ base_opts)
    end

    GenServer.stop(conn)

    IO.puts(
      "load check passed (#{fixture}): #{records} records, dry run, resume, rerun, delta sync"
    )

    {which, namespace}
  end

# What loaded.exs reads back through Ash: every resource of each fixture,
# and derived values computed from the loaded data.
checks = [
  %{
    fixture: "cut2",
    resource: "Fixtures.DecidedCut2.Board",
    id: F.board1(),
    expect: %{"watcher_count" => 1, "card_count" => 2, "name" => "Roadmap"}
  },
  %{
    fixture: "cut2",
    resource: "Fixtures.DecidedCut2.Board",
    id: F.board2(),
    expect: %{"watcher_count" => 0, "card_count" => 1}
  },
  %{
    fixture: "cut2",
    resource: "Fixtures.DecidedCut2.Card",
    id: F.card1(),
    expect: %{"board_watcher_count" => 1, "board_card_count" => 2, "tags" => ["a", "b"]}
  },
  %{
    fixture: "cut2",
    resource: "Fixtures.DecidedCut2.User",
    id: F.ada(),
    expect: %{"confirmed_at" => "2024-01-01T10:00:00.000000Z"}
  },
  %{
    fixture: "cut2",
    resource: "Fixtures.DecidedCut2.User",
    id: F.bob(),
    expect: %{"confirmed_at" => nil}
  },
  %{
    fixture: "combined",
    resource: "Fixtures.DecidedCombined.Initiative",
    id: F.initiative1(),
    expect: %{"team_name" => "Acme", "task_count" => 2}
  },
  %{
    fixture: "combined",
    resource: "Fixtures.DecidedCombined.Task",
    id: F.todo1(),
    expect: %{"points" => "1.25"}
  },
  %{
    fixture: "cut3",
    resource: "Fixtures.DecidedCut3.Workspace",
    id: F.workspace1(),
    expect: %{"name" => "Acme"},
    # members through the private twin (the public one is filtered by the
    # actor's grants, and there is none): the Members rows whose user
    # exists, not Carol (only her Workspaces list Acme)
    relationships: %{"members_for_privacy" => Enum.sort([F.ada(), F.bob()])}
  },
  %{
    fixture: "cut3",
    resource: "Fixtures.DecidedCut3.Project",
    id: F.initiative1(),
    expect: %{"title" => "Plan"},
    relationships: %{"tasks_for_privacy" => Enum.sort([F.todo1(), F.todo2()])}
  },
  %{
    fixture: "field_types",
    resource: "Fixtures.FieldTypes.Task",
    id: F.task1(),
    expect: %{
      "status" => "open",
      "labels" => ["open", "closed"],
      "estimate" => 2.0,
      "place" => %{"formatted_address" => "1 Main St", "lat" => 50.85, "lng" => 4.35}
    }
  }
]

File.write!(
  Path.join(scratch, "loaded.json"),
  Jason.encode!(%{domains: Enum.map(loaded, &elem(&1, 1)), checks: checks}, pretty: true)
)
