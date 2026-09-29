defmodule BubbleEx.Load do
  @moduledoc """
  Loads a Bubble app's data into a migrated target (WTF-357): rows, list
  fields, users and files, from an export (`BubbleEx.Load.Export`) into the
  database a target adapter (`BubbleEx.Load.Target`) points at.
  Stack-neutral: the Model says what Bubble stores, the adapter's
  `BubbleEx.Load.Plan` says where it goes. `BubbleEx.Target.Ash.Loader` is
  the first adapter (Ash on PostgreSQL).

      {:ok, export} = BubbleEx.Load.Export.open("exports/mm-137")
      # :checkout keeps a real run on the connection that holds its lock.
      target =
        BubbleEx.Target.Ash.Loader.target(project,
          query: &MyApp.Repo.query/2,
          checkout: &MyApp.Repo.checkout/1
        )
      # Serve copied files from a separate origin (see BubbleEx.Load.Storage).
      storage = BubbleEx.Load.Storage.Local.new(root: "/srv/uploads", public_url: "https://files.example.com")

      {:ok, report} = BubbleEx.Load.dry_run(export, model, target)
      {:ok, report} = BubbleEx.Load.run(export, model, target, storage: storage, ledger_dir: "loads")

      # At cutover, a new complete export of the same app: dry-run and read
      # report.prune, then prune exactly that plan, confirmed by its hash.
      {:ok, dry} = BubbleEx.Load.dry_run(final, model, target, prune: true, ledger_dir: "loads")
      {:ok, report} =
        BubbleEx.Load.run(final, model, target,
          storage: storage, ledger_dir: "loads", prune: [expect: dry.prune.sha256])

  ## Steps

    1. **Open** the export and check its checksums; ask the adapter for its
       plan and check its schema (read-only). A schema mismatch stops a
       real run before anything is written.
    2. **Scan** every exported row: counts per type, record IDs (for
       dangling references), the one copy of a duplicated `_id` that loads
       (latest Modified Date), users' emails, the Bubble files the file
       fields reference, and the stored values derived fields need.
    3. **Files** (real run): copy the referenced files from the export to
       the target storage with verified SHA-256 (`BubbleEx.Load.Files`);
       private files stay private. Failures are collected, not fatal.
    4. **Rows**: convert each row by the plan (`BubbleEx.Load.Convert`) and
       upsert it in batches (`:batch_size`, default 500), recording each
       batch in the ledger (`BubbleEx.Load.Ledger`) and the IDs it wrote
       in the target's written record (`BubbleEx.Load.Written`).
    5. **Prune** (`prune: true` only, WTF-414): after every upsert, delete
       what the export no longer holds among the rows the loader wrote
       (see "Pruning").
    6. **Report** (`BubbleEx.Load.Report`): counts, and diagnostics for all
       that does not fit. A report whose `blocked` lists
       `:load_join_stale_member` (join rows a list no longer holds) loads
       with `prune: true`: see step 5 of a live run below.

  A **dry run** (`dry_run/4`) does steps 1, 2 and the conversion of step 4
  without writing anything (no database write, no file copy, no ledger):
  per-type counts, schema mismatches, dangling-reference counts per field,
  type mismatches, drift of derived fields, and with `prune: true` what
  pruning would delete and keep (the report's `prune`).

  ## Semantics

    * **Records.** The Bubble `_id` is the primary key (WTF-338); an `_id`
      not shaped `<digits>x<digits>` loads as given and is reported, a row
      without one is reported and skipped.
    * **Idempotent upsert.** A row inserts a new record or replaces the
      plan's columns of the existing one; an identical record is left
      untouched. Re-running the same export changes nothing; loading a new
      export of the same app (a delta sync at cutover) writes only what
      changed. Records deleted in Bubble since an earlier load are not
      deleted from the target, unless the run prunes (`prune: true`).
    * **Resumable.** With `:ledger_dir`, an interrupted run (an error, a
      crash, a killed process) resumes after the last recorded batch and
      file. The ledger is keyed by the export, the plan, the database, the
      storage and the `:keys` map. A completed ledger makes the next run start
      over (it re-applies every row, changing nothing).
    * **References** (WTF-338) keep their Bubble IDs, dangling ones
      included (no foreign key), and dangling references are counted per
      field. `text_to_reference` fields are converted: trimmed, empty to
      nil, non-IDs reported and nil.
    * **Lists** load as arrays, order kept. A list whose count an owner
      decision derives as its length (`derive_count`) loses the IDs of
      records the export does not hold, as Bubble's `:count` does not
      count them.
    * **Join tables** (`normalize_list_to_join`, `membership_policy`
      decisions; `BubbleEx.Load.Plan.Join`): a list normalized to a join
      loads as one row per member, after every data type's table, keyed by
      the two record IDs, with the list's membership column set (the
      member's index in the list, or true). A repeated member is one row
      (`:load_join_duplicate`); a dangling one is kept, like a reference
      (WTF-338), and reported. Two mirrored lists sharing a join table are
      written separately, each setting only its own column, so a member of
      one never becomes a member of the other (`:load_join_asymmetric`
      counts the members one list holds that the other does not list
      back). The rows upsert idempotently. Without `prune: true` nothing
      is deleted: a member removed from a list in Bubble since an earlier
      load keeps its row, and with it any access a privacy rule grants
      through the list; each such row (including one whose owner was
      deleted in Bubble) is reported (`:load_join_stale_member`, an error:
      counts, sample owner IDs, and in its details `stale_members` the
      stale rows, `[left ID, right ID]`, up to
      `BubbleEx.Load.Issues.stale_rows/0` (`rows_total` counts them all,
      `truncated` says the list was capped), with the join's table and
      columns; the message names no record) and blocks a real run before any
      writes. With `prune: true` the rows the loader wrote are pruned
      (their list's column cleared, the row deleted when no list holds
      it) and the others kept and reported (see "Pruning"). An
      `allow_partial` run in which an owner type failed to export blocks
      too when that type owns a join's list: none of its stored members
      is in the export, so every one reads as stale (and pruning refuses
      a partial export).
    * **Derived fields** (`derive_*` decisions: calculations, aggregates,
      `has_many`) have no column and are not loaded; where the stored
      Bubble value differs from the derived one it is reported as drift.
      A list replaced by a `has_many` reports the records it lists that do
      not point back, and those pointing back it does not list.
    * **Users** (WTF-355) load without any password material: the email
      (the `email` field or the Data API's `authentication.email.email`),
      trimmed, and the email-confirmed status where the target has a
      column for it (else reported; it stays in the export). That column
      is a timestamp, AshAuthentication's `confirmed_at` (WTF-413): Bubble
      keeps only a flag (`authentication.email.email_confirmed`), so a
      confirmed user gets their **Created Date**, a migrated value
      (`:load_confirmed_at_migrated`, info), not a confirmation time; a
      confirmed user without a readable Created Date loads unconfirmed
      (nil, `:load_confirmed_at_undated`; a magic-link sign-in confirms
      them). Unconfirmed users, and users without the flag, get nil. A nil
      never clears a stored confirmation while the user's email is
      unchanged (a confirmation made in the target, e.g. by a magic-link
      sign-in, survives a delta sync); a user whose email changed takes
      Bubble's status. The Created Date, unlike the load time, keeps
      reruns idempotent. Emails equal
      ignoring case stop a real run (the target's identity is unique), and
      so does an exported email that the target gives a record the export
      does not hold (e.g. a user deleted in Bubble whose email a new
      signup reused: `:load_email_conflict`, IDs only), unless pruning
      deletes that record (`prune:`, a user the loader wrote): its email
      is cleared before any row is written and the record deleted after
      the upserts. Until the run completes, that old record stays without
      an email (a run interrupted before its prune leaves it so; rerun
      it). Users whose email
      changes (swaps included) lose their old email first, in one
      statement before any row is written, so no batch collides. That
      statement and the batches are separate writes (the loader only has
      a query function, not a transaction): until the run completes those
      users have no email and cannot sign in. **Keep the app closed
      during a load, and rerun until it completes before reopening it**
      (a rerun restores every email). Users
      with other sign-in methods are reported. Known limitation: an email
      that changes only in case is not cleared first (a `citext` column
      treats it as unchanged).
    * **Keys.** A Data API key is a field's ID or display name. A key that
      names no field (`:load_unmapped_key`: a wrong key format would load
      whole columns empty, and a delta sync would overwrite good data)
      blocks a real run unless `allow_unmapped_keys: true`; a key naming
      two fields (`:load_ambiguous_key`) blocks it until the owner's
      `:keys` map says which. `:keys` must name live fields.
    * **Text** loses NUL characters, which PostgreSQL cannot store
      (`:load_nul_stripped`, with the record IDs).
    * **Files**: see `BubbleEx.Load.Files`.

  Nothing that does not fit is dropped silently: each case is a `:load`
  diagnostic with a count and a few sample record IDs.

  ## Pruning (WTF-414)

  Pruning is an explicit opt-in for a new complete export of an app
  already loaded into the target (a delta sync at cutover). It deletes
  **only rows the loader itself wrote**: the Bubble IDs (and join rows)
  recorded in the target's written record (`BubbleEx.Load.Written`, in the
  `:ledger_dir`, across the target's runs) that the export no longer
  holds. A record the loader never wrote (created in the app after
  go-live, or loaded before WTF-414 recorded writes) is never deleted: it
  is reported (`:load_prune_unowned`, a warning).

  **A wrong export deletes real data**, so pruning is confirmed and
  guarded, before anything is written:

    * **Two steps.** `prune: true` plans and reports only: a dry run
      reports the plan in `report.prune` (per type and list: what it
      deletes, what the loader wrote, what it keeps) and its hash
      `report.prune.sha256`. A real run needs `prune: [expect: <that
      hash>]` and prunes only that plan (a bare `prune: true`, or a plan
      that changed since, is refused). A resumed run prunes what is left
      of the plan its ledger recorded under the same hash.
    * **The export must be the target's.** Refused for an export of
      another app or version (the manifest's `app` and `source.base_url`
      must be those the record was loaded from), without a readable
      `created_at`, or older than an export already loaded; with
      `allow_partial`, on an export in which a type failed, without
      `:ledger_dir`; and when the export lacks a type the loader wrote.
    * **The database must be the record's**: its load marker (the
      adapter's `marker/2`, a random UUID the first real load creates in
      `bubble_ex_load_target`) must be the one the record holds; a
      database recreated at the same address has another, or none. The
      marker and the other bindings guard against **accidents** (a wrong
      export, a recreated database), not against someone with write access
      to the database or the ledger directory: a clone of the database
      (`pg_dump` and restore) carries the marker too, so a record and its
      clone both match it. Prune only a database you know is the one the
      record was written into.
    * **Not most of a type or list.** When a type or a join list would
      lose all, or more than half, of the rows the loader wrote there,
      the run blocks (`:load_prune_mass_delete`) unless its type or list
      key is named in `prune: [allow_mass_delete: [...]]`. **An export
      read with a token that is not an admin token (or with privacy rules
      that hide records from it) silently lacks the records it cannot
      see**, and would prune them: export with the admin token.
    * **One run at a time**: a real run holds the target's lock (the
      adapter's `with_lock/2`, a PostgreSQL advisory lock) from planning
      to its last write, and the written record's file lock.

  What it does:

    * **Records**: the target's keys the loader wrote that the export does
      not hold are deleted (`:load_prune_record`, info).
    * **Join memberships**, per list: a member the loader wrote that the
      list no longer holds (`:load_prune_join_member`, info) loses that
      list's membership column; its row is deleted only when no other
      list's column is still set. A stale member the loader did not write
      still blocks (`:load_join_stale_member`) unless the caller names it
      in `prune: [acknowledge_unowned: %{list key => [[left ID, right
      ID], ...]}]` (then kept, `:load_prune_unowned`).
    * **Reused emails**: a pruned user holding an exported email is not a
      `:load_email_conflict`; its email is cleared before the upserts.
    * **Order and safety**: done after every upsert and join write, the
      lists first, then the records, in batches of `:batch_size`, each one
      statement (all or nothing). Each batch is forgotten in the written
      record, and counted in the run's ledger, after it succeeded; a join
      row a load finds gone is forgotten too, so a row the app adds back
      is not the loader's. A crash can only leave rows undeleted, never
      delete a row the loader did not write; rerun with the same `expect`
      to resume.

  ## Safety

    * The loader reads only the export and writes only to the target and
      the storage it is given, and to the ledger directory. It never calls
      Bubble; `BubbleEx.Load.DataApi` makes the export, read-only.
    * Reports, diagnostics and ledgers hold counts, Bubble IDs, field IDs,
      Bubble file URLs and storage references, never a stored value or a
      credential. Adapter errors carry no stored values.

  ## A live run (needs Rico's approval; not done by any test)

  No test contacts Bubble or uses a token. A live run against an app (e.g.
  mm-137) would be:

    1. In Bubble, enable the Data API for every data type to migrate
       (Settings → API) and create an admin API token. The export reads
       with that token, which bypasses privacy rules: it must see every
       record. Export from the live database, ideally in a write freeze.
    2. Export, read-only (GET requests only), the token from the
       environment, never a flag or a file:

           BUBBLE_API_TOKEN=... mix run -e '
             app = File.read!("app.json") |> Jason.decode!()
             {:ok, model} = BubbleEx.Model.build(app)
             {:ok, _} = BubbleEx.Load.DataApi.export(model, "exports/mm-137",
               app_url: "https://<app host>", version: "live")'

       It resumes if interrupted (rerun the same command). Check the
       export's manifest: every type `complete`, the files' `failed` count.
    3. Generate the project from the same Model and decisions, migrate its
       database, then dry-run and read the report (schema mismatches,
       dangling references, drift, duplicate emails).
    4. Run with a `:ledger_dir` and the target storage, from the generated
       project (`query: &Repo.query/2, checkout: &Repo.checkout/1`),
       against a staging database first.
    5. At cutover, freeze writes in Bubble (and keep the app closed) and
       export again, completely, with the admin token. WTF-414 has
       landed: the cutover path is pruning. Dry-run the new export with
       `prune: true` and the same `:ledger_dir`, and read `report.prune`
       (the records and memberships it deletes, per type and list), the
       `:load_prune_unowned` warnings (rows it keeps: the loader did not
       write them) and anything blocked (`:load_prune_mass_delete`,
       `:load_join_stale_member`). Then load it into the same database
       with `prune: [expect: report.prune.sha256]` (plus any
       `allow_mass_delete` or `acknowledge_unowned` you decided on): only
       what changed is written, then records deleted in Bubble and
       members removed from normalized lists are pruned. Rerun with the
       same options until it completes if it is interrupted. An
       `allow_partial` export cannot prune: re-export the failed types
       instead.

    6. After the cutover, delete the export:
       `mix bubble.export.delete exports/mm-137` (`Export.delete/1`).

  The export holds personal data (users' emails and whatever the app
  stores) and BubbleEx does not encrypt it: it must live on an encrypted
  disk (never a repository, a synced folder or a shared machine) and be
  deleted after the cutover (step 6).
  """

  alias BubbleEx.{Diagnostic, Error, Model}

  alias BubbleEx.Load.{
    Convert,
    Export,
    Files,
    Issues,
    Joins,
    Ledger,
    Plan,
    Prune,
    Report,
    Scan,
    Written
  }

  @blocking [
    :load_schema_mismatch,
    :load_duplicate_email,
    :load_email_conflict,
    :load_join_stale_member,
    :load_ambiguous_key,
    :load_prune_mass_delete
  ]

  @type target :: {module(), term()}
  @type option ::
          {:storage, {module(), term()}}
          | {:ledger_dir, Path.t()}
          | {:batch_size, pos_integer()}
          | {:allow_partial, boolean()}
          | {:keys, %{String.t() => %{String.t() => String.t()}}}
          | {:target_identity, String.t()}
          | {:file_concurrency, pos_integer()}
          | {:file_timeout, pos_integer()}
          | {:allow_unmapped_keys, boolean()}
          | {:app_hosts, [String.t()]}
          | {:prune, boolean()}

  @doc "A dry run: `run/4` writing nothing."
  @spec dry_run(Export.t() | Path.t(), Model.t(), target(), [option()]) ::
          {:ok, Report.t()} | {:error, Error.t()}
  def dry_run(export, model, target, opts \\ []),
    do: run(export, model, target, Keyword.put(opts, :dry_run, true))

  @doc """
  Loads `export` (an opened export or its directory) into `target`.

  ## Options

    * `:dry_run` - write nothing (see `dry_run/4`)
    * `:storage` - `{module, config}` of a `BubbleEx.Load.Storage`; required
      for a real run when the rows reference Bubble files
    * `:ledger_dir` - where the run's ledger lives, to resume an
      interrupted run; without it a run keeps its ledger in memory
    * `:batch_size` - rows per upsert (default 500)
    * `:allow_partial` - load an export in which some types failed
    * `:keys` - `%{type => %{row key => field ID}}`: Data API keys the Model
      does not name (by default a key is a field ID or display name)
    * `:target_identity` - overrides the adapter's database identity in
      the ledger key
    * `:file_concurrency` - files copied at once (default 8)
    * `:file_timeout` - ms one file copy may take (default 300,000)
    * `:allow_unmapped_keys` - load despite row keys that name no field
    * `:app_hosts` - the app's own hosts besides the export's Data API
      host (custom domains), where its private files live
    * `:prune` - delete what the export no longer holds among the rows
      the loader wrote (WTF-414; see "Pruning"): `true` to plan it (a dry
      run), `[expect: sha256]` to prune the plan a dry run reported, with
      `:allow_mass_delete` (type names or join list keys) and
      `:acknowledge_unowned` (`%{list key => [[left, right], ...]}`).
      Needs a complete export (refused with `allow_partial`) and
      `:ledger_dir`

  A real run that is blocked (see `BubbleEx.Load.Report`) returns
  `{:error, %Error{kind: :invalid_input, context: %{blocked: codes, report: report}}}`
  and writes nothing. A failed write returns the adapter's error with
  the ledger kept for a resume.
  """
  @spec run(Export.t() | Path.t(), Model.t(), target(), [option() | {:dry_run, boolean()}]) ::
          {:ok, Report.t()} | {:error, Error.t()}
  def run(export, %Model{} = model, {tmod, tconf}, opts \\ []) do
    # A real run holds the target's lock (the adapter's `with_lock/2`, a
    # PostgreSQL advisory lock) from planning to the last write.
    if Keyword.get(opts, :dry_run, false),
      do: plan_run(export, model, {tmod, tconf}, opts, true),
      else: tmod.with_lock(tconf, fn -> plan_run(export, model, {tmod, tconf}, opts, false) end)
  end

  defp plan_run(export, model, {tmod, tconf} = target, opts, dry?) do
    with {:ok, export} <- open(export),
         {:ok, settings} <- Prune.options(opts),
         :ok <- check_prune_options(settings, export, opts, dry?),
         :ok <- Scan.check_keys(model, Keyword.get(opts, :keys, %{})),
         {:ok, plan} <- tmod.plan(tconf, model),
         :ok <- check_plan(plan, model),
         {:ok, identity} <- identity(tmod, tconf, opts),
         {:ok, schema_diags} <- tmod.check_schema(tconf, plan),
         opts = Keyword.put(opts, :app_hosts, app_hosts(export, opts)),
         scan = Scan.run(export, model, plan, opts),
         {:ok, written, marker} <- read_written(settings, dry?, opts, identity, target),
         :ok <- check_binding(settings, written, marker, export, opts),
         {:ok, prune} <-
           plan_prune(settings, written, marker, export, plan, scan, target, schema_diags),
         {:ok, issues, clears} <- emails(scan, plan, target, schema_diags, prune),
         {joins, issues} = Joins.build(plan, scan, issues),
         {:ok, issues, prune, forget} <-
           stale_members(joins, target, schema_diags, issues, prune, written) do
      issues = if prune, do: Prune.issues(prune, joins, issues), else: issues
      issues = Scan.drift(%{scan | issues: issues}, plan, model)
      issues = auth_status(issues, scan, plan)

      state = %{
        export: export,
        model: model,
        plan: plan,
        scan: scan,
        target: target,
        opts: opts,
        dry?: dry?,
        identity: identity,
        schema: schema_diags,
        issues: issues,
        joins: joins,
        clears: clears,
        prune: prune,
        prune_sha: prune && Prune.sha256(prune, export, identity),
        written: written,
        forget: forget
      }

      finish(state, blocked(state))
    end
  end

  defp finish(%{dry?: true} = state, blocked), do: {:ok, dry(state, blocked)}

  defp finish(state, []) do
    with :ok <- confirm_prune(state), do: load(state)
  end

  # A blocked real run's report omits the plan's hash: only a dry run
  # yields what confirms a prune.
  defp finish(state, blocked),
    do: {:error, blocked_error(dry(%{state | prune_sha: nil}, blocked), blocked)}

  defp check_prune_options(nil, _export, _opts, _dry?), do: :ok

  defp check_prune_options(settings, export, opts, dry?),
    do: Prune.check_options(export, opts, settings, dry?)

  # The written record (`BubbleEx.Load.Written`) and the target's marker,
  # read only: for pruning, and for a real run that records into it.
  defp read_written(settings, dry?, opts, identity, {tmod, tconf}) do
    dir = Keyword.get(opts, :ledger_dir)

    if settings != nil or (not dry? and dir not in [nil, ""]) do
      with {:ok, written} <- Written.read(dir, identity),
           {:ok, marker} <- tmod.marker(tconf, :read),
           do: {:ok, written, marker}
    else
      {:ok, nil, nil}
    end
  end

  # Pruning checks the export and the database are the record's
  # (`Prune.check_binding/4`). Any real run recording into the record of
  # this database refuses an export of another app or version: its IDs
  # would join the record, and a later prune would treat them as this
  # app's.
  defp check_binding(nil, nil, _marker, _export, _opts), do: :ok

  defp check_binding(nil, written, marker, export, _opts) do
    b = Written.bound(written)

    cond do
      Written.empty?(written) or b.marker != marker ->
        :ok

      b.app != export.manifest["app"] or
          b.base_url != get_in(export.manifest, ["source", "base_url"]) ->
        {:error,
         Error.new(
           :invalid_input,
           "the export is of another app or version (app, source.base_url) than the one " <>
             "loaded into this target",
           %{reason: :app}
         )}

      true ->
        :ok
    end
  end

  defp check_binding(_settings, written, marker, export, opts),
    do: Prune.check_binding(written, marker, export, opts)

  # A real pruning run prunes only the plan the caller confirmed
  # (`prune: [expect: <the dry run's report.prune.sha256>]`), or, resuming,
  # what is left of the plan its run's ledger recorded under that hash.
  defp confirm_prune(%{prune: nil}), do: :ok

  defp confirm_prune(state) do
    path =
      Path.join(
        Keyword.fetch!(state.opts, :ledger_dir),
        Ledger.run_key(state.export.sha256, Plan.sha256(state.plan), run_identity(state)) <>
          ".json"
      )

    confirmed =
      case Ledger.read(path) do
        {:ok, data} -> Ledger.confirmed_prune(data)
        {:error, _} -> nil
      end

    Prune.confirm(state.prune, state.prune_sha, confirmed)
  end

  defp open(%Export{} = export), do: {:ok, export}
  defp open(dir) when is_binary(dir), do: Export.open(dir)

  defp open(_),
    do: {:error, Error.new(:invalid_input, "expected a BubbleEx.Load.Export or its directory")}

  # The app's own hosts, where its private files live: the export's Data
  # API host, and any the caller names (custom domains).
  defp app_hosts(export, opts) do
    exported =
      case get_in(export.manifest, ["source", "base_url"]) do
        url when is_binary(url) -> List.wrap(URI.parse(url).host)
        _ -> []
      end

    Enum.uniq(exported ++ Enum.map(Keyword.get(opts, :app_hosts, []), &String.downcase/1))
  end

  # With `prune:`: what pruning deletes and keeps (`BubbleEx.Load.Prune`),
  # from the rows the loader wrote (`BubbleEx.Load.Written`, read only) and
  # the target's keys. Not read when the schema check failed.
  defp plan_prune(nil, _written, _marker, _export, _plan, _scan, _target, _schema),
    do: {:ok, nil}

  defp plan_prune(settings, written, marker, export, plan, scan, target, schema) do
    if Enum.any?(schema, &(&1.code == :load_schema_mismatch)),
      do: {:ok, %Prune{written: written, marker: marker, options: settings}},
      else: Prune.plan(written, marker, settings, plan, scan, export, target)
  end

  # The exported users' emails against the target's (its unique email
  # identity): an email held by a target record the export does not hold
  # blocks the run (`:load_email_conflict`), unless pruning deletes that
  # record (a user deleted in Bubble whose email a new signup reused);
  # users whose email changes, and such pruned holders, are cleared first
  # (`clears`), so swaps and reuses cannot collide within or across
  # batches.
  defp emails(
         scan,
         %Plan{auth: %Plan.Auth{type: type, email_column: column}} = plan,
         {tmod, tconf},
         prune
       )
       when is_binary(column) do
    table = Plan.table(plan, type)
    pruned = Prune.deleting(prune, type)

    with {:ok, existing} <- tmod.existing(tconf, table, column) do
      exported = Map.get(scan.ids, type, MapSet.new())
      target = Map.new(existing, fn {id, email} -> {id, fold(email)} end)
      holders = Enum.group_by(target, &elem(&1, 1), &elem(&1, 0))

      held =
        for {id, %{email: email}} <- scan.auth,
            email != nil,
            holder <- Map.get(holders, email, []),
            holder != id,
            not MapSet.member?(exported, holder),
            do: {id, holder}

      conflicts =
        for {id, holder} <- held, not MapSet.member?(pruned, holder), uniq: true, do: id

      reused = for {_id, holder} <- held, MapSet.member?(pruned, holder), uniq: true, do: holder

      issues =
        conflicts
        |> Enum.sort()
        |> Enum.reduce(
          scan.issues,
          &Issues.add(&2, :load_email_conflict, type, "email", &1, :held)
        )

      clears =
        for {id, old} <- target,
            MapSet.member?(exported, id),
            old != get_in(scan.auth, [id, :email]),
            do: id

      {:ok, issues, Enum.sort(clears ++ reused)}
    end
  end

  defp emails(scan, _plan, _target, _prune), do: {:ok, scan.issues, []}

  # Not read when the schema check failed (the table may not exist; the
  # run is blocked anyway).
  defp emails(scan, plan, target, schema, prune) do
    if Enum.any?(schema, &(&1.code == :load_schema_mismatch)),
      do: {:ok, scan.issues, []},
      else: emails(scan, plan, target, prune)
  end

  # Members a list held at an earlier load that it no longer holds: the
  # target's rows of the list that the export does not give it, including
  # rows whose owner is absent from the complete delta export. They keep
  # any access a rule grants through the list, so each blocks a real run
  # before writes (`:load_join_stale_member`, the owner's ID), unless the
  # run prunes and the loader wrote it (then pruned) or the caller
  # acknowledged it (`acknowledge_unowned`: kept, a warning;
  # `BubbleEx.Load.Prune`). Recorded rows the target no longer holds are
  # forgotten (`forget`). Not read when the schema check failed.
  defp stale_members(joins, {tmod, tconf}, schema, issues, prune, written) do
    if Enum.any?(schema, &(&1.code == :load_schema_mismatch)) do
      {:ok, issues, prune, %{}}
    else
      Enum.reduce_while(joins, {:ok, issues, prune, %{}}, fn built, acc ->
        tconf
        |> tmod.join_members(built.join, built.side, :all)
        |> members_step(built, written, acc)
      end)
    end
  end

  defp members_step({:ok, stored}, built, written, {:ok, issues, prune, forget}) do
    {issues, prune} = stale_step(stored, built, issues, prune)
    {:cont, {:ok, issues, prune, forget_missing(forget, written, built.key, stored)}}
  end

  defp members_step({:error, _} = error, _built, _written, _acc), do: {:halt, error}

  defp stale_step(stored, built, issues, nil),
    do: {add_stale(issues, built, stale(built, stored)), nil}

  defp stale_step(stored, built, issues, prune) do
    {prune, blocking} = Prune.stale(prune, built, stale(built, stored), stored)
    {add_stale(issues, built, blocking), prune}
  end

  defp forget_missing(forget, nil, _key, _stored), do: forget

  defp forget_missing(forget, written, key, stored) do
    case Prune.missing(written, key, stored) do
      [] -> forget
      pairs -> Map.put(forget, key, pairs)
    end
  end

  defp stale(%{join: join, rows: rows}, stored) do
    loaded = MapSet.new(rows, &{&1[join.left.column], &1[join.right.column]})
    stored |> Enum.reject(&MapSet.member?(loaded, &1)) |> Enum.sort()
  end

  defp add_stale(issues, _built, []), do: issues

  defp add_stale(issues, built, stale) do
    %{join: join, side: side} = built

    issues =
      Enum.reduce(stale, issues, fn {l, r}, issues ->
        owner = if side.owner == :left, do: l, else: r
        Issues.add(issues, :load_join_stale_member, side.type, side.field, owner, :not_listed_now)
      end)

    # The stale rows, capped (details only: the message names no record),
    # for pruning by hand, or to acknowledge (`acknowledge_unowned`). Its
    # list's rows are those of `table` whose `membership_column` marks a
    # member.
    Issues.put_details(
      issues,
      :load_join_stale_member,
      side.type,
      side.field,
      Issues.stale_members(join, side, stale)
    )
  end

  defp fold(nil), do: nil
  defp fold(email), do: email |> String.trim() |> String.downcase()

  defp identity(tmod, tconf, opts) do
    case Keyword.get(opts, :target_identity) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> tmod.identity(tconf)
    end
  end

  # Every table, column and joined list of the plan names a live data
  # type and field of the Model.
  defp check_plan(%Plan{tables: tables} = plan, model) do
    fields =
      for(
        t <- tables,
        f <- [nil | Enum.map(t.columns, & &1.field) ++ Enum.map(t.derived, & &1.field)],
        do: {t.type, f}
      ) ++ for(j <- plan.joins, side <- j.sides, do: {side.type, side.field})

    missing =
      for {type, f} <- fields,
          not known?(model, type, f),
          do: if(f, do: "#{type}.#{f}", else: type)

    if missing == [],
      do: :ok,
      else:
        {:error,
         Error.new(:invalid_input, "the load plan does not match the Model", %{
           missing: Enum.take(missing, 20)
         })}
  end

  defp known?(model, type, nil), do: Model.data_type(model, type) != nil
  defp known?(model, type, "_id"), do: Model.data_type(model, type) != nil
  defp known?(model, type, field), do: Model.field(model, type, field) != :error

  defp auth_status(issues, _scan, %Plan{auth: nil}), do: issues

  defp auth_status(issues, scan, %Plan{auth: %Plan.Auth{type: t, confirmed_column: c}})
       when is_binary(c) do
    dated = Enum.count(scan.auth, fn {_id, a} -> is_binary(a.confirmed_at) end)

    scan.auth
    |> Enum.filter(fn {_id, a} -> a.confirmed_at == :undated end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.reduce(
      Issues.add_count(issues, :load_confirmed_at_migrated, t, nil, dated),
      &Issues.add(&2, :load_confirmed_at_undated, t, nil, &1, nil)
    )
  end

  defp auth_status(issues, scan, %Plan{auth: %Plan.Auth{type: t}}) do
    known = Enum.count(scan.auth, fn {_id, a} -> is_boolean(a.confirmed) end)
    Issues.add_count(issues, :load_auth_status_unmapped, t, nil, known)
  end

  defp blocked(state) do
    partial =
      if Keyword.get(state.opts, :allow_partial, false), do: [], else: [:load_export_partial]

    partial =
      if Keyword.get(state.opts, :allow_unmapped_keys, false),
        do: partial,
        else: [:load_unmapped_key | partial]

    (state.schema ++ Issues.diagnostics(state.issues))
    |> Enum.filter(&(&1.code in (@blocking ++ partial)))
    |> Enum.map(& &1.code)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp blocked_error(report, blocked) do
    Error.new(
      :invalid_input,
      "the load is blocked: #{Enum.join(blocked, ", ")}#{hint(blocked)}",
      %{
        blocked: blocked,
        report: report
      }
    )
  end

  # Stale join members block a delta load unless it prunes them.
  defp hint(blocked) do
    if :load_join_stale_member in blocked,
      do:
        " (stale join members: load with prune: true to remove those the loader wrote; " <>
          "see the :load_join_stale_member diagnostics' details.stale_members)",
      else: ""
  end

  # --- dry run --------------------------------------------------------------------

  defp dry(state, blocked) do
    files = would_copy(state)

    {:ok, issues, nil} =
      convert_all(state, %{files: files}, fn _table, _rows, acc -> {:ok, acc} end)

    report(state, issues, blocked, files_summary(state, files), nil)
  end

  # The files a real run would copy: those the export fetched.
  defp would_copy(state) do
    for %{"url" => url, "status" => "ok"} <- Export.files(state.export),
        MapSet.member?(state.scan.files, url),
        into: %{},
        do: {url, url}
  end

  # --- real run -----------------------------------------------------------------------

  # The written record is locked first (before the run's ledger), and
  # both are closed on every way out.
  defp load(state) do
    ids = %{
      export_sha256: state.export.sha256,
      plan_sha256: Plan.sha256(state.plan),
      target: run_identity(state)
    }

    with {:ok, written} <- open_written(state),
         {:ok, ledger} <- open_ledger(state, ids, written) do
      state |> load_opened(ledger, written) |> closed()
    end
  end

  defp open_ledger(state, ids, written) do
    with {:error, _} = error <- Ledger.open(Keyword.get(state.opts, :ledger_dir), ids) do
      Written.close(written)
      error
    end
  end

  defp closed({:error, error, {ledger, written}}) do
    Written.close(written)
    Ledger.close(ledger)
    {:error, error}
  end

  defp closed(result), do: result

  defp load_opened(state, ledger, written) do
    # A finished run starts over: every row is re-applied, changing
    # nothing that did not change.
    ledger = if Ledger.complete?(ledger), do: Ledger.restart(ledger), else: ledger
    ledger = confirm_in_ledger(state, ledger)
    {tmod, tconf} = state.target

    with {:ok, refs, ledger} <- copy_files(state, ledger) |> opened(ledger, written),
         :ok <- clear_emails(state) |> opened(ledger, written),
         {:ok, issues, acc} <-
           convert_all(
             state,
             %{files: refs},
             fn table, batch, acc ->
               write(table.type, &tmod.upsert(tconf, table, &1), recorder(table), batch, acc)
             end,
             {ledger, written}
           ),
         {:ok, acc} <- load_joins(state, acc),
         {:ok, {ledger, written}} <- prune(state, acc) do
      written |> Written.loaded(state.export.manifest["created_at"]) |> Written.close()
      ledger = Ledger.complete(ledger)
      {:ok, report(state, issues, [], files_summary(state, refs), ledger)}
    end
  end

  # A step's plain error, with the handles to close.
  defp opened({:error, %Error{} = error}, ledger, written), do: {:error, error, {ledger, written}}
  defp opened(result, _ledger, _written), do: result

  # Records the IDs of a table's written rows (`BubbleEx.Load.Written`).
  defp recorder(table),
    do: fn written, rows ->
      Written.wrote(written, table.type, Enum.map(rows, & &1[table.key]))
    end

  # Opens the written record (locked), bound to the database's marker
  # (created by the first real load) and the export's app and base URL,
  # with the join rows found gone forgotten. Refused when the record
  # changed since it was planned from (another run in between).
  defp open_written(state) do
    dir = Keyword.get(state.opts, :ledger_dir)
    {tmod, tconf} = state.target

    result =
      with {:ok, written} <- Written.open(dir, state.identity) do
        if dir != nil and state.written != nil and
             Written.seq(written) != Written.seq(state.written) do
          Written.close(written)

          {:error,
           Error.new(
             :invalid_input,
             "the written record changed while the run was planned; rerun"
           )}
        else
          bind(written, dir, tmod, tconf, state)
        end
      end

    result
  end

  defp bind(written, nil, _tmod, _tconf, _state), do: {:ok, written}

  defp bind(written, _dir, tmod, tconf, state) do
    case tmod.marker(tconf, :ensure) do
      {:ok, marker} when is_binary(marker) ->
        manifest = state.export.manifest

        written =
          written
          |> Written.bind(marker, manifest["app"], get_in(manifest, ["source", "base_url"]))
          |> then(
            &Enum.reduce(state.forget, &1, fn {k, pairs}, w ->
              Written.pruned_join(w, k, pairs)
            end)
          )

        {:ok, written}

      {:ok, _} ->
        Written.close(written)
        {:error, Error.new(:request_failed, "the target did not create its load marker")}

      error ->
        Written.close(written)
        error
    end
  end

  # A pruning run records the plan it was confirmed with, once, so a
  # resumed run prunes only what is left of it.
  defp confirm_in_ledger(%{prune: nil}, ledger), do: ledger

  defp confirm_in_ledger(%{prune: prune}, ledger) do
    expect = prune.options.expect

    case Ledger.confirmed_prune(ledger) do
      %{"sha256" => ^expect} -> ledger
      _ -> Ledger.prune_plan(ledger, expect, prune.records, prune.lists)
    end
  end

  # After every upsert: what the export no longer holds among the rows the
  # loader wrote (`prune: true`, `BubbleEx.Load.Prune`).
  defp prune(%{prune: nil}, acc), do: {:ok, acc}

  defp prune(state, acc),
    do:
      Prune.run(
        state.prune,
        state.target,
        state.plan,
        state.joins,
        Keyword.get(state.opts, :batch_size, 500),
        acc
      )

  # The join tables (after every data type's table), one list at a time:
  # its rows upserted in batches recorded in the ledger under
  # `<join ID>/<type>/<field>`. Nothing is deleted here (see `prune/2`).
  defp load_joins(state, acc) do
    {tmod, tconf} = state.target
    size = Keyword.get(state.opts, :batch_size, 500)

    Enum.reduce_while(state.joins, {:ok, acc}, fn built, {:ok, acc} ->
      upsert = &tmod.upsert_join(tconf, built.join, built.side, &1)
      %{left: %{column: l}, right: %{column: r}} = built.join
      record = &Written.wrote_join(&1, built.key, Enum.map(&2, fn row -> {row[l], row[r]} end))

      built.rows
      |> Enum.with_index()
      |> Enum.chunk_every(size)
      |> Enum.reduce_while({:ok, acc}, &write_batch(built.key, upsert, record, &1, &2))
      |> case do
        {:ok, {ledger, written}} ->
          {:cont, {:ok, {Ledger.type_complete(ledger, built.key, length(built.rows)), written}}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp write_batch(key, upsert, record, batch, {:ok, acc}) do
    case write(key, upsert, record, batch, acc) do
      {:ok, acc} -> {:cont, {:ok, acc}}
      {:error, error} -> {:halt, {:error, error, acc}}
    end
  end

  # The ledger's target: the database, the storage and the key map, so a
  # ledger never claims rows or files written elsewhere or read otherwise.
  defp run_identity(state) do
    storage =
      case Keyword.get(state.opts, :storage) do
        {mod, config} -> mod.identity(config)
        nil -> "none"
      end

    keys = state.opts |> Keyword.get(:keys, %{}) |> BubbleEx.CanonicalJson.sha256()
    Enum.join([state.identity, "storage:" <> storage, "keys:" <> keys], "\n")
  end

  # The first phase of an email change: exported users whose email changes
  # lose their old one before any row is written.
  defp clear_emails(%{clears: []}), do: :ok

  defp clear_emails(%{plan: %Plan{auth: auth} = plan, target: {tmod, tconf}, clears: ids}),
    do: tmod.clear(tconf, Plan.table(plan, auth.type), auth.email_column, ids)

  defp copy_files(state, ledger) do
    cond do
      MapSet.size(state.scan.files) == 0 ->
        {:ok, %{}, ledger}

      Keyword.get(state.opts, :storage) == nil ->
        {:error,
         Error.new(:invalid_input, "the rows reference Bubble files: pass a :storage", %{
           files: MapSet.size(state.scan.files)
         })}

      true ->
        # Each file is recorded in the ledger as it completes.
        {refs, _failed, ledger} =
          Files.copy(state.export, Keyword.fetch!(state.opts, :storage), state.scan.files,
            done: Ledger.files(ledger),
            concurrency: Keyword.get(state.opts, :file_concurrency, 8),
            timeout: Keyword.get(state.opts, :file_timeout, 300_000),
            acc: ledger,
            on_result: fn
              {:ok, url, ref}, ledger -> Ledger.file_copied(ledger, url, ref)
              {:failed, _url, _reason}, ledger -> ledger
            end
          )

        {:ok, refs, ledger}
    end
  end

  # Writes one batch of `{row, index}` of a table (or join table) keyed
  # `key` in the ledger with `upsert`, skipping the rows the ledger has.
  # The written rows go to `Written` (`record`) once the batch succeeded,
  # before the ledger counts it: a crash in between replays the batch.
  defp write(key, upsert, record, batch, {ledger, written}) do
    done = Ledger.rows_done(ledger, key)
    {skip, todo} = Enum.split_with(batch, fn {_row, idx} -> idx < done end)
    last = batch |> List.last() |> elem(1)

    rows = Enum.map(todo, &elem(&1, 0))
    resumed = length(skip)

    result =
      if rows == [],
        do: {:ok, %{inserted: 0, updated: 0, unchanged: 0}},
        else: upsert.(rows)

    case result do
      {:ok, counts} ->
        written = if rows == [], do: written, else: record.(written, rows)

        ledger =
          if last + 1 > done, do: Ledger.batch(ledger, key, last + 1, counts), else: ledger

        {:ok, {Ledger.resumed(ledger, key, resumed), written}}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, _} ->
        {:error, Error.new(:request_failed, "the target refused a batch", %{type: key})}
    end
  end

  # --- conversion ------------------------------------------------------------------------

  # Converts every winning row of every table, handing each batch of
  # `{row, stream index}` (winners only, possibly empty) to `sink`.
  defp convert_all(state, ctx, sink, acc \\ nil) do
    ctx =
      Map.merge(ctx, %{ids: state.scan.ids, app_hosts: Keyword.get(state.opts, :app_hosts, [])})

    size = Keyword.get(state.opts, :batch_size, 500)

    Enum.reduce_while(state.plan.tables, {:ok, state.issues, acc}, fn table, {:ok, issues, acc} ->
      case convert_table(state, table, ctx, size, sink, issues, acc) do
        {:ok, issues, acc} -> {:cont, {:ok, issues, finish_table(state, table, acc)}}
        {:error, error, acc} -> {:halt, {:error, error, acc}}
      end
    end)
  end

  defp finish_table(_state, _table, nil), do: nil

  defp finish_table(state, table, {%Ledger{} = ledger, written}) do
    rows = get_in(state.scan.types, [table.type, :rows]) || 0
    {Ledger.type_complete(ledger, table.type, rows), written}
  end

  defp convert_table(state, table, ctx, size, sink, issues, acc) do
    winners = Map.get(state.scan.winners, table.type, %{})
    keys = Map.get(state.scan.keys, table.type, %{})
    fields = model_fields(state.model, table)
    auth? = match?(%Plan{auth: %Plan.Auth{type: t}} when t == table.type, state.plan)

    state.export
    |> Export.rows(table.type)
    |> Stream.with_index()
    |> Stream.filter(fn {row, idx} -> Map.get(winners, row["_id"]) == idx end)
    |> Stream.chunk_every(size)
    |> Enum.reduce_while({:ok, issues, acc}, fn chunk, {:ok, issues, acc} ->
      {batch, issues} =
        Enum.map_reduce(chunk, issues, fn {row, idx}, issues ->
          {json, issues} = convert_row(state, table, keys, fields, auth?, row, ctx, issues)
          {{json, idx}, issues}
        end)

      case sink.(table, batch, acc) do
        {:ok, acc} -> {:cont, {:ok, issues, acc}}
        {:error, error} -> {:halt, {:error, error, acc}}
      end
    end)
  end

  defp model_fields(model, table) do
    Map.new(table.columns, fn c ->
      {:ok, field} = Model.field(model, table.type, c.field)
      {c.field, field}
    end)
  end

  defp convert_row(state, table, keys, fields, auth?, row, ctx, issues) do
    id = row["_id"]
    {values, _deleted, _unknown, _ambiguous} = Scan.fields(row, keys)

    {pairs, issues} =
      Enum.map_reduce(table.columns, issues, fn column, issues ->
        {v, found} =
          if auth? and column.field == "email",
            do: email(Scan.email(row, values)),
            else:
              Convert.value(
                Map.fetch!(fields, column.field),
                column,
                Map.get(values, column.field),
                ctx
              )

        {v, nul?} = Convert.strip_nul(v)
        found = if nul?, do: [{:load_nul_stripped, :nul} | found], else: found

        issues =
          Enum.reduce(found, issues, fn {code, detail}, acc ->
            Issues.add(acc, code, table.type, column.field, id, detail)
          end)

        {{column.column, v}, issues}
      end)

    json = Map.new([{table.key, id} | pairs])

    case {auth?, state.plan.auth} do
      {true, %Plan.Auth{confirmed_column: c}} when is_binary(c) ->
        at = with :undated <- Scan.confirmed_at(row, values), do: nil
        {Map.put(json, c, at), issues}

      _ ->
        {json, issues}
    end
  end

  defp email(nil), do: {nil, []}

  defp email(e) when is_binary(e) do
    case String.trim(e) do
      "" -> {nil, []}
      e -> if String.contains?(e, "@"), do: {e, []}, else: {nil, [{:load_invalid_email, :no_at}]}
    end
  end

  defp email(_), do: {nil, [{:load_type_mismatch, :text}]}

  # --- report -----------------------------------------------------------------------------

  defp files_summary(state, refs) do
    private = Enum.count(state.scan.files, &(Files.visibility(&1) == :private))

    %{
      referenced: MapSet.size(state.scan.files),
      public: MapSet.size(state.scan.files) - private,
      private: private,
      copied: map_size(refs),
      failed: MapSet.size(state.scan.files) - map_size(refs)
    }
  end

  defp report(state, issues, blocked, files, ledger) do
    types =
      Map.new(state.plan.tables, fn t ->
        scanned = Map.get(state.scan.types, t.type, %{rows: 0, invalid: 0})
        records = state.scan.winners |> Map.get(t.type, %{}) |> map_size()

        base = %{
          rows: scanned.rows,
          records: records,
          duplicates: scanned.rows - scanned.invalid - records,
          invalid: scanned.invalid
        }

        {t.type, Map.merge(base, written(ledger, t.type))}
      end)

    %Report{
      dry_run: state.dry?,
      blocked: blocked,
      run: if(match?(%Ledger{}, ledger), do: Ledger.run(ledger)),
      export_sha256: state.export.sha256,
      plan_sha256: Plan.sha256(state.plan),
      target: state.identity,
      types: types,
      joins:
        Map.new(state.joins, fn built ->
          {built.key, Map.merge(%{rows: length(built.rows)}, written(ledger, built.key))}
        end),
      files: files,
      prune: Prune.summary(state.prune, state.prune_sha, state.plan, state.joins, ledger),
      auth: auth_summary(state),
      diagnostics: Diagnostic.normalize(state.schema ++ Issues.diagnostics(issues))
    }
  end

  defp written(%Ledger{} = ledger, type) do
    counts = Ledger.type_counts(ledger, type)

    %{
      inserted: counts["inserted"] || 0,
      updated: counts["updated"] || 0,
      unchanged: counts["unchanged"] || 0,
      resumed: Map.get(ledger.resumed, type, 0)
    }
  end

  defp written(_ledger, _type), do: %{}

  defp auth_summary(%{plan: %Plan{auth: nil}}), do: %{}

  defp auth_summary(%{plan: %Plan{auth: auth}, scan: scan}) do
    users = Map.values(scan.auth)

    %{
      users: length(users),
      with_email: Enum.count(users, & &1.email),
      confirmed: Enum.count(users, &(&1.confirmed == true)),
      unconfirmed: Enum.count(users, &(&1.confirmed == false)),
      unknown: Enum.count(users, &is_nil(&1.confirmed)),
      confirmed_column: is_binary(auth.confirmed_column)
    }
  end
end
