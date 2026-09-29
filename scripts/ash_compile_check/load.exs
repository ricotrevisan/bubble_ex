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
#     export that reorders members succeeds; an export that drops one
#     reports the stale membership and is blocked before writing
#   * pruning (WTF-414, cut3): a delta that deletes a record and removes
#     members, dry-run with prune (the counts and the plan's hash, nothing
#     written; the app's membership blocks until acknowledged), then run
#     confirmed by that hash (a bare prune: true and another hash are
#     refused), interrupted mid-prune and resumed: only the rows the
#     loader wrote are deleted (a record and a membership created in the
#     app survive), a membership another list holds loses only its list's
#     column, and the result equals an uninterrupted prune; refused for an
#     export of another app or version or an older one, a present but
#     empty type (mass deletion), another database (its load marker) and
#     while another connection holds the target's advisory lock; on a pool
#     of 4 connections, a query function without :checkout is refused, and
#     while one run holds the lock three concurrent runs are refused, and
#     no advisory lock is left held; a user
#     deleted in Bubble whose email a new signup reused loads with prune
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

# Fail closed: the URL is required and names its port (never 5432 unless
# ASH_COMPILE_CHECK_ALLOW_5432=1), and only check databases are opened.
Code.require_file("scripts/check_db.exs")
base = URI.parse(CheckDb.url!())

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

  # Every connection is a pool of 4: a real run keeps its statements on
  # one connection through :checkout (DBConnection.run pins it for this
  # process; the query function uses the pinned one), as Repo.checkout/1
  # does for Repo.query/2.
  def query(pool),
    do: fn sql, params -> Postgrex.query(Process.get({__MODULE__, pool}, pool), sql, params) end

  def checkout(pool) do
    fn fun ->
      DBConnection.run(
        pool,
        fn conn ->
          Process.put({__MODULE__, pool}, conn)

          try do
            fun.()
          after
            Process.delete({__MODULE__, pool})
          end
        end,
        timeout: :infinity
      )
    end
  end

  def target(project, pool, opts \\ []) do
    Loader.target(
      project,
      [query: Keyword.get(opts, :query, query(pool)), checkout: checkout(pool)] ++
        Keyword.drop(opts, [:query])
    )
  end

  # Fails the Nth INSERT of rows (not the load marker's), as a crash
  # mid-run would.
  def failing(conn, n) do
    counter = :counters.new(1, [])
    pass = query(conn)

    fn sql, params ->
      if String.starts_with?(sql, "INSERT") and not String.contains?(sql, "bubble_ex_load_target") do
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == n,
          do: {:error, :injected_crash},
          else: pass.(sql, params)
      else
        pass.(sql, params)
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

connect_pool = fn database, size ->
  {:ok, conn} =
    Postgrex.start_link(
      hostname: base.host,
      port: base.port,
      username: URI.decode(user),
      password: URI.decode(password),
      database: CheckDb.database!(database),
      pool_size: size
    )

  conn
end

connect = &connect_pool.(&1, 4)

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

    conn = connect.(database)

    model = F.model(which)
    {:ok, project} = F.project(which, privacy: :unverified)
    dir = Path.join(work, fixture)
    {:ok, export} = F.export(which, Path.join(dir, "export"))
    target = LoadCheck.target(project, conn)
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
    wrong = LoadCheck.target(project, conn, schema: "no_such_schema")
    {:ok, wrong_dry} = Load.dry_run(export, model, wrong, base_opts)
    LoadCheck.eq!(fixture, wrong_dry.blocked, [:load_schema_mismatch], "missing schema")
    {:error, refused} = Load.run(export, model, wrong, opts)
    LoadCheck.eq!(fixture, refused.context.blocked, [:load_schema_mismatch], "refused run")

    # --- interrupted, then resumed ------------------------------------------------------------
    crashing = LoadCheck.target(project, conn, query: LoadCheck.failing(conn, 3))
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
    confirmed = &LoadCheck.row(after_sync, "user", &1)["confirmed_at"]

    LoadCheck.eq!(
      fixture,
      confirmed.(F.bob()),
      "2026-09-20T00:00:00",
      "bob keeps his confirmation"
    )

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
          |> Enum.map(
            &{&1["user_id"], &1["workspace_id"], &1["workspaces_position"],
             &1["members_position"]}
          )
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

        # A legitimate delta reorders Acme's members without removing any.
        rows = F.cut3_rows()
        [w1 | rest] = rows["workspace"]

        reordered = %{
          rows
          | "workspace" => [Map.put(w1, "Members", [F.gone_user(), F.ada(), F.bob()]) | rest]
        }

        {:ok, reordered_export} = F.export(which, Path.join(dir, "reordered"), reordered)

        {:ok, reordered_report} =
          Load.run(reordered_export, model, target, [storage: storage] ++ base_opts)

        LoadCheck.eq!(fixture, reordered_report.blocked, [], "member reorder is allowed")

        LoadCheck.eq!(
          fixture,
          ws.(LoadCheck.snapshot(conn, plan)),
          Enum.sort([
            {F.ada(), F.workspace1(), 0, 1},
            {F.bob(), F.workspace1(), nil, 2},
            {F.gone_user(), F.workspace1(), nil, 0},
            {F.carol(), F.workspace2(), 0, 0},
            {F.carol(), F.workspace1(), 1, nil}
          ]),
          "reordered membership keeps the other list's column"
        )

        # A false flag is not a member, even though its join row exists.
        Postgrex.query!(
          conn,
          ~s[INSERT INTO "public"."favorite_project" ("project_id", "user_id", "viewers_listed") VALUES ($1, $2, false)],
          [F.initiative2(), F.ada()]
        )

        {:ok, false_flag} = Load.dry_run(reordered_export, model, target, base_opts)
        LoadCheck.eq!(fixture, false_flag.blocked, [], "false flag is not a stale member")

        Postgrex.query!(
          conn,
          ~s(DELETE FROM "public"."favorite_project" WHERE "project_id" = $1 AND "user_id" = $2),
          [F.initiative2(), F.ada()]
        )

        # Bob is absent in the next export. The stale row retains access;
        # the whole load, including scalar changes, must fail before writes.
        [w1 | rest] = reordered["workspace"]

        dropped_rows = %{
          reordered
          | "workspace" => [
              w1 |> Map.put("Members", [F.gone_user(), F.ada()]) |> Map.put("Name", "Changed")
              | rest
            ]
        }

        {:ok, dropped} = F.export(which, Path.join(dir, "dropped"), dropped_rows)
        before_blocked = LoadCheck.snapshot(conn, plan)
        {:ok, stale} = Load.dry_run(dropped, model, target, base_opts)

        LoadCheck.eq!(
          fixture,
          stale.blocked,
          [:load_join_stale_member],
          "stale dry run is blocked"
        )

        stale_members = fn report ->
          for d <- report.diagnostics,
              d.code == :load_join_stale_member,
              do: {d.subject.field, d.details.count, d.details.sample_ids}
        end

        LoadCheck.eq!(
          fixture,
          stale_members.(stale),
          [{"members_list_user", 1, [F.workspace1()]}],
          "the member no longer listed, reported from the PostgreSQL rows"
        )

        blocked_ledger = Path.join(dir, "blocked_ledger")

        {:error, refused} =
          Load.run(
            dropped,
            model,
            target,
            [storage: storage, ledger_dir: blocked_ledger, batch_size: 1] ++ base_opts
          )

        LoadCheck.eq!(fixture, refused.kind, :invalid_input, "stale run error")

        LoadCheck.eq!(
          fixture,
          refused.context.blocked,
          [:load_join_stale_member],
          "stale run blocked"
        )

        LoadCheck.eq!(fixture, refused.context.report.run, nil, "no run started")

        LoadCheck.eq!(
          fixture,
          stale_members.(refused.context.report),
          stale_members.(stale),
          "stale run report"
        )

        LoadCheck.eq!(
          fixture,
          LoadCheck.snapshot(conn, plan),
          before_blocked,
          "blocked run wrote no rows"
        )

        LoadCheck.check!(fixture, not File.exists?(blocked_ledger), "blocked run wrote a ledger")

        # A complete delta omitting Acme itself must also catch its rows.
        deleted_owner = %{
          reordered
          | "workspace" => Enum.reject(reordered["workspace"], &(&1["_id"] == F.workspace1()))
        }

        {:ok, deleted_export} = F.export(which, Path.join(dir, "deleted_owner"), deleted_owner)
        {:ok, missing} = Load.dry_run(deleted_export, model, target, base_opts)

        LoadCheck.eq!(
          fixture,
          stale_members.(missing),
          [{"members_list_user", 3, [F.workspace1()]}],
          "missing owner is stale"
        )

        # The earlier completed run's ledger exists; refusing the delta must
        # neither write rows nor create another ledger entry.
        ledger_before = File.ls!(ledger) |> Enum.sort()
        {:error, missing_run} = Load.run(deleted_export, model, target, opts)

        LoadCheck.eq!(
          fixture,
          missing_run.context.blocked,
          [:load_join_stale_member],
          "missing owner blocked"
        )

        LoadCheck.eq!(
          fixture,
          LoadCheck.snapshot(conn, plan),
          before_blocked,
          "missing owner wrote no rows"
        )

        LoadCheck.eq!(
          fixture,
          File.ls!(ledger) |> Enum.sort(),
          ledger_before,
          "missing owner wrote no ledger"
        )

        # --- pruning (WTF-414) ------------------------------------------------------------
        # The second task is deleted in Bubble (and leaves Plan's Tasks); Ada and Bob
        # leave Acme's Members (Ada's Workspaces still list Acme).
        rows = F.cut3_rows()
        [w1 | ws_rest] = rows["workspace"]
        [p1 | p_rest] = rows["project"]

        pruned_rows = %{
          rows
          | "workspace" => [Map.put(w1, "Members", [F.gone_user()]) | ws_rest],
            "project" => [Map.put(p1, "Tasks", [F.todo1(), F.todo1(), F.gone_task()]) | p_rest],
            "task" => Enum.reject(rows["task"], &(&1["_id"] == F.todo2()))
        }

        {:ok, prune_export} = F.export(which, Path.join(dir, "prune"), pruned_rows)
        app_task = F.id(800)

        # A load recording what it wrote, then rows created in the app
        # (a task, and Bob's membership of Beta), which pruning must keep.
        fresh_load = fn ledger_dir ->
          LoadCheck.truncate(conn, plan)

          {:ok, _} =
            Load.run(export, model, target, [storage: storage, ledger_dir: ledger_dir] ++ base_opts)

          Postgrex.query!(
            conn,
            ~s[INSERT INTO "public"."task" ("id", "title") VALUES ($1, 'app')],
            [app_task]
          )

          Postgrex.query!(
            conn,
            ~s[INSERT INTO "public"."user_workspaces" ("user_id", "workspace_id", "members_position") VALUES ($1, $2, 5)],
            [F.bob(), F.workspace2()]
          )
        end

        prune_ledger = Path.join(dir, "prune_ledger")
        fresh_load.(prune_ledger)
        before_prune = LoadCheck.snapshot(conn, plan)
        dry_opts = [ledger_dir: prune_ledger] ++ base_opts

        # Without prune the removed members block; so does, with it, the
        # app's membership (not the loader's) until acknowledged by name.
        {:ok, plain} = Load.dry_run(prune_export, model, target, dry_opts)
        LoadCheck.eq!(fixture, plain.blocked, [:load_join_stale_member], "delta without prune")
        {:ok, unacked} = Load.dry_run(prune_export, model, target, [prune: true] ++ dry_opts)
        LoadCheck.eq!(fixture, unacked.blocked, [:load_join_stale_member], "unowned member blocks")

        [members_key] =
          for k <- Map.keys(unacked.joins), String.ends_with?(k, "/workspace/members_list_user"), do: k

        [tasks_key] =
          for k <- Map.keys(unacked.joins),
              String.ends_with?(k, "/project/tasks_list_custom_task"),
              do: k

        ack = [acknowledge_unowned: %{members_key => [[F.bob(), F.workspace2()]]}]
        {:ok, prune_dry} = Load.dry_run(prune_export, model, target, [prune: ack] ++ dry_opts)
        LoadCheck.eq!(fixture, prune_dry.blocked, [], "prune dry run blocked")

        LoadCheck.eq!(
          fixture,
          Map.delete(prune_dry.prune, :sha256),
          %{
            types: %{"task" => %{delete: 1, owned: 2, unowned: 1}},
            joins: %{
              tasks_key => %{remove: 1, owned: 3, unowned: 0},
              members_key => %{remove: 2, owned: 4, unowned: 1}
            }
          },
          "prune dry run counts"
        )

        LoadCheck.check!(
          fixture,
          Enum.any?(prune_dry.diagnostics, &(&1.code == :load_prune_unowned and &1.severity == :warning)),
          "the app's rows are a warning"
        )

        LoadCheck.eq!(fixture, LoadCheck.snapshot(conn, plan), before_prune, "prune dry run wrote rows")
        confirmed = [prune: [expect: prune_dry.prune.sha256] ++ ack]
        prune_opts = [storage: storage, ledger_dir: prune_ledger, batch_size: 1] ++ base_opts

        # A bare prune: true, or another hash, does not prune.
        {:error, bare} = Load.run(prune_export, model, target, [prune: true] ++ prune_opts)
        LoadCheck.check!(fixture, bare.message =~ "expect", "a bare prune: true is refused")

        {:error, wrong} =
          Load.run(prune_export, model, target, [prune: [expect: String.duplicate("0", 64)] ++ ack] ++ prune_opts)

        LoadCheck.check!(fixture, wrong.message =~ "not the one confirmed", "another hash is refused")

        # The export must be the target's: not another app, not another
        # version, not older; not most of a type (a present but empty type).
        for {name, export_opts, reason} <- [
              {"other_app", [app: "another-app"], :app},
              {"other_version", [base_url: "https://acme.bubbleapps.io"], :base_url},
              {"older", [created_at: "2026-09-01T00:00:00Z"], :older_export}
            ] do
          {:ok, bad} = F.export(which, Path.join(dir, name), pruned_rows, export_opts)
          {:error, refused} = Load.dry_run(bad, model, target, [prune: ack] ++ dry_opts)
          LoadCheck.eq!(fixture, refused.context[:reason], reason, "#{name} refused")
        end

        {:ok, empty_tasks} = F.export(which, Path.join(dir, "empty_tasks"), Map.put(pruned_rows, "task", []))
        {:ok, mass} = Load.dry_run(empty_tasks, model, target, [prune: ack] ++ dry_opts)
        LoadCheck.check!(fixture, :load_prune_mass_delete in mass.blocked, "an empty type blocks")

        # The database must be the record's (its marker), and one run at a
        # time holds the target's advisory lock.
        %{rows: [[marker]]} = Postgrex.query!(conn, ~s[SELECT id::text FROM "public"."bubble_ex_load_target"], [])
        Postgrex.query!(conn, ~s[UPDATE "public"."bubble_ex_load_target" SET id = gen_random_uuid()], [])
        {:error, moved} = Load.dry_run(prune_export, model, target, [prune: ack] ++ dry_opts)
        LoadCheck.eq!(fixture, moved.context[:reason], :marker_mismatch, "another database refused")
        Postgrex.query!(conn, ~s[UPDATE "public"."bubble_ex_load_target" SET id = $1::text::uuid], [marker])

        holder = connect_pool.(database, 1)
        key = Loader.lock_key("public")
        Postgrex.query!(holder, "SELECT pg_advisory_lock($1)", [key])
        {:error, locked} = Load.run(prune_export, model, target, confirmed ++ prune_opts)
        LoadCheck.eq!(fixture, locked.context[:reason], :locked, "a held lock refuses the run")
        Postgrex.query!(holder, "SELECT pg_advisory_unlock($1)", [key])
        GenServer.stop(holder)
        LoadCheck.eq!(fixture, LoadCheck.snapshot(conn, plan), before_prune, "refused runs wrote rows")

        # On a real pool of 4 connections: a pooled query function alone
        # (Repo.query/2 without :checkout) is refused; with it, while one
        # run holds the lock, runs started meanwhile (other connections of
        # the pool) are refused, and no lock is left held afterwards.
        LoadCheck.truncate(conn, plan)
        pooled_only = Loader.target(project, query: fn sql, p -> Postgrex.query(conn, sql, p) end)
        {:error, bare} = Load.run(export, model, pooled_only, [ledger_dir: Path.join(dir, "pool0")] ++ base_opts)
        LoadCheck.eq!(fixture, bare.context[:reason], :checkout, "a pooled query function without :checkout")

        parent = self()
        pinned = LoadCheck.query(conn)

        pausing =
          LoadCheck.target(project, conn,
            query: fn sql, params ->
              if String.starts_with?(sql, "INSERT") and not String.contains?(sql, "bubble_ex_load_target") and
                   Process.get(:paused) == nil do
                Process.put(:paused, true)
                send(parent, {:holding, self()})
                receive do: (:go -> :ok)
              end

              pinned.(sql, params)
            end
          )

        first =
          Task.async(fn ->
            Load.run(export, model, pausing, [ledger_dir: Path.join(dir, "pool1")] ++ base_opts)
          end)

        receive do
          {:holding, runner} ->
            others =
              for n <- 2..4 do
                Task.async(fn ->
                  Load.run(export, model, target, [ledger_dir: Path.join(dir, "pool#{n}")] ++ base_opts)
                end)
              end

            reasons = others |> Task.await_many(60_000) |> Enum.map(fn {:error, e} -> e.context[:reason] end)
            LoadCheck.eq!(fixture, reasons, [:locked, :locked, :locked], "concurrent runs on a pool")
            send(runner, :go)
        after
          60_000 -> LoadCheck.fail!(fixture, "the first pooled run never wrote")
        end

        {:ok, _} = Task.await(first, 120_000)

        %{rows: [[advisory]]} =
          Postgrex.query!(conn, "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory'", [])

        LoadCheck.eq!(fixture, advisory, 0, "no advisory lock left held")
        {:ok, _} = Load.run(export, model, target, [ledger_dir: Path.join(dir, "pool1")] ++ base_opts)

        # back to the state the prune checks start from
        fresh_load.(prune_ledger)

        # Interrupted: the 3rd prune statement fails (a crash mid-prune).
        counter = :counters.new(1, [])

        pass = LoadCheck.query(conn)

        crashing_prune =
          LoadCheck.target(project, conn,
            query: fn sql, params ->
              if String.starts_with?(sql, "DELETE") or String.starts_with?(sql, "WITH b AS") do
                :counters.add(counter, 1, 1)

                if :counters.get(counter, 1) == 3,
                  do: {:error, :injected_crash},
                  else: pass.(sql, params)
              else
                pass.(sql, params)
              end
            end
          )

        {:error, prune_crash} = Load.run(prune_export, model, crashing_prune, confirmed ++ prune_opts)
        LoadCheck.eq!(fixture, prune_crash.context[:reason], :injected_crash, "prune crash error")
        mid = LoadCheck.snapshot(conn, plan)

        LoadCheck.check!(
          fixture,
          LoadCheck.row(mid, "task", app_task) != nil and
            Enum.any?(mid["user_workspaces"], &(&1["user_id"] == F.bob() and &1["workspace_id"] == F.workspace2())),
          "a crash mid-prune kept the app's rows"
        )

        # Resumed under the same confirmation (the run's ledger holds the plan).
        {:ok, pruned} = Load.run(prune_export, model, target, confirmed ++ prune_opts)
        LoadCheck.eq!(fixture, pruned.blocked, [], "prune run blocked")

        LoadCheck.eq!(
          fixture,
          pruned.prune.types["task"].deleted + pruned.prune.joins[tasks_key].deleted +
            pruned.prune.joins[members_key].deleted + pruned.prune.joins[members_key].cleared,
          4,
          "pruned over the interrupted and resumed run"
        )

        after_prune = LoadCheck.snapshot(conn, plan)

        LoadCheck.eq!(
          fixture,
          after_prune["task"] |> Enum.map(& &1["id"]) |> Enum.sort(),
          Enum.sort([F.todo1(), app_task]),
          "only the loader's deleted record is gone; the app's task survives"
        )

        LoadCheck.eq!(
          fixture,
          after_prune["project_tasks"] |> Enum.map(& &1["task_id"]) |> Enum.sort(),
          Enum.sort([F.todo1(), F.gone_task()]),
          "the removed task's membership row is deleted"
        )

        LoadCheck.eq!(
          fixture,
          ws.(after_prune),
          Enum.sort([
            {F.ada(), F.workspace1(), 0, nil},
            {F.gone_user(), F.workspace1(), nil, 0},
            {F.bob(), F.workspace2(), nil, 5},
            {F.carol(), F.workspace2(), 0, 0},
            {F.carol(), F.workspace1(), 1, nil}
          ]),
          "memberships cleared per list: Ada keeps her Workspaces column, Bob's Acme row is deleted, the app's row is kept"
        )

        # The same prune, uninterrupted, gives the same state.
        prune! = fn exp, ledger_dir, settings ->
          opts = [storage: storage, ledger_dir: ledger_dir] ++ base_opts
          {:ok, d} = Load.dry_run(exp, model, target, [prune: settings] ++ opts)
          LoadCheck.eq!(fixture, d.blocked, [], "dry run before a prune")
          Load.run(exp, model, target, [prune: [expect: d.prune.sha256] ++ settings] ++ opts)
        end

        clean_ledger = Path.join(dir, "prune_clean_ledger")
        fresh_load.(clean_ledger)
        {:ok, _} = prune!.(prune_export, clean_ledger, ack)
        LoadCheck.eq!(fixture, LoadCheck.snapshot(conn, plan), after_prune, "resumed vs uninterrupted prune")

        # Rerunning changes nothing.
        {:ok, again} = prune!.(prune_export, clean_ledger, ack)
        LoadCheck.eq!(fixture, again.prune.types["task"], %{delete: 0, owned: 1, unowned: 1, deleted: 0, cleared: 0}, "prune rerun")
        LoadCheck.eq!(fixture, LoadCheck.snapshot(conn, plan), after_prune, "prune rerun state")

        # A user deleted in Bubble whose email a new signup reused, under a
        # unique index on lower(email): blocked without prune, loads with it.
        reuse_ledger = Path.join(dir, "reuse_ledger")
        LoadCheck.truncate(conn, plan)
        {:ok, _} = Load.run(export, model, target, [storage: storage, ledger_dir: reuse_ledger] ++ base_opts)

        Postgrex.query!(
          conn,
          ~s[CREATE UNIQUE INDEX load_check_email ON "public"."user" (lower(email))],
          []
        )

        [ada, bob, _carol] = rows["user"]
        [w1, w2] = rows["workspace"]

        newcomer = %{
          "_id" => F.id(801),
          "Created Date" => "2024-09-01T00:00:00Z",
          "authentication" => %{
            "email" => %{"email" => "Carol@example.test", "email_confirmed" => false}
          }
        }

        reused_rows = %{
          rows
          | "user" => [ada, bob, newcomer],
            "workspace" => [w1, Map.put(w2, "members_list_user", [])]
        }

        {:ok, reused_export} = F.export(which, Path.join(dir, "reused"), reused_rows)

        {:ok, reused_plain} =
          Load.dry_run(reused_export, model, target, [ledger_dir: reuse_ledger] ++ base_opts)

        LoadCheck.check!(
          fixture,
          :load_email_conflict in reused_plain.blocked,
          "a reused email blocks without prune"
        )

        # Carol's own Workspaces rows go with her: 2 of 3, named.
        [workspaces_key] =
          for k <- Map.keys(reused_plain.joins),
              String.ends_with?(k, "/user/workspaces_list_custom_workspace"),
              do: k

        {:ok, reused} = prune!.(reused_export, reuse_ledger, allow_mass_delete: [workspaces_key])
        LoadCheck.eq!(fixture, reused.prune.types["user"].deleted, 1, "the old holder pruned")

        %{rows: reused_emails} =
          Postgrex.query!(conn, ~s[SELECT id, email FROM "public"."user" ORDER BY id], [])

        LoadCheck.eq!(
          fixture,
          reused_emails,
          [
            [F.ada(), "Ada@Example.test"],
            [F.bob(), "bob@example.test"],
            [F.id(801), "Carol@example.test"]
          ],
          "the reused email loads with prune"
        )

        Postgrex.query!(conn, "DROP INDEX load_check_email", [])

        # back to the fixture's state for loaded.exs
        LoadCheck.truncate(conn, plan)
        {:ok, _} = Load.run(export, model, target, [storage: storage] ++ base_opts)
    end

    GenServer.stop(conn)

    IO.puts(
      "load check passed (#{fixture}): #{records} records, dry run, resume, rerun, delta sync" <>
        if(which == :cut3,
          do: ", prune (dry run and hash, refusals, advisory lock on a pool of 4, interrupted and resumed, app rows kept, reused email)",
          else: ""
        )
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
