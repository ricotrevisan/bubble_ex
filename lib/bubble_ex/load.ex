defmodule BubbleEx.Load do
  @moduledoc """
  Loads a Bubble app's data into a migrated target (WTF-357): rows, list
  fields, users and files, from an export (`BubbleEx.Load.Export`) into the
  database a target adapter (`BubbleEx.Load.Target`) points at.
  Stack-neutral: the Model says what Bubble stores, the adapter's
  `BubbleEx.Load.Plan` says where it goes. `BubbleEx.Target.Ash.Loader` is
  the first adapter (Ash on PostgreSQL).

      {:ok, export} = BubbleEx.Load.Export.open("exports/mm-137")
      target = BubbleEx.Target.Ash.Loader.target(project, query: &MyApp.Repo.query/2)
      # Serve copied files from a separate origin (see BubbleEx.Load.Storage).
      storage = BubbleEx.Load.Storage.Local.new(root: "/srv/uploads", public_url: "https://files.example.com")

      {:ok, report} = BubbleEx.Load.dry_run(export, model, target)
      {:ok, report} = BubbleEx.Load.run(export, model, target, storage: storage, ledger_dir: "loads")

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
       batch in the ledger (`BubbleEx.Load.Ledger`).
    5. **Report** (`BubbleEx.Load.Report`): counts, and diagnostics for all
       that does not fit.

  A **dry run** (`dry_run/4`) does steps 1, 2 and the conversion of step 4
  without writing anything (no database write, no file copy, no ledger):
  per-type counts, schema mismatches, dangling-reference counts per field,
  type mismatches, drift of derived fields.

  ## Semantics

    * **Records.** The Bubble `_id` is the primary key (WTF-338); an `_id`
      not shaped `<digits>x<digits>` loads as given and is reported, a row
      without one is reported and skipped.
    * **Idempotent upsert.** A row inserts a new record or replaces the
      plan's columns of the existing one; an identical record is left
      untouched. Re-running the same export changes nothing; loading a new
      export of the same app (a delta sync at cutover) writes only what
      changed. Records deleted in Bubble since an earlier load are not
      deleted from the target.
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
      back). The rows upsert idempotently. Nothing is deleted: a member
      removed from a list in Bubble since an earlier load keeps its row
      (WTF-414 prunes by the ledger's written pairs).
    * **Derived fields** (`derive_*` decisions: calculations, aggregates,
      `has_many`) have no column and are not loaded; where the stored
      Bubble value differs from the derived one it is reported as drift.
      A list replaced by a `has_many` reports the records it lists that do
      not point back, and those pointing back it does not list.
    * **Users** (WTF-355) load without any password material: the email
      (the `email` field or the Data API's `authentication.email.email`),
      trimmed, and the email-confirmed status where the target has a
      column for it (else reported; it stays in the export). Emails equal
      ignoring case stop a real run (the target's identity is unique), and
      so does an exported email that the target gives a record the export
      does not hold (e.g. a user deleted in Bubble whose email a new
      signup reused: `:load_email_conflict`, IDs only). Users whose email
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
       project (`query: &Repo.query/2`), against a staging database first.
    5. At cutover, freeze writes in Bubble, export again and load the new
       export into the same database: only what changed is written.

    6. After the cutover, delete the export:
       `mix bubble.export.delete exports/mm-137` (`Export.delete/1`).

  The export holds personal data (users' emails and whatever the app
  stores) and BubbleEx does not encrypt it: it must live on an encrypted
  disk (never a repository, a synced folder or a shared machine) and be
  deleted after the cutover (step 6).
  """

  alias BubbleEx.{Diagnostic, Error, Model}
  alias BubbleEx.Load.{Convert, Export, Files, Issues, Joins, Ledger, Plan, Report, Scan}

  @blocking [
    :load_schema_mismatch,
    :load_duplicate_email,
    :load_email_conflict,
    :load_ambiguous_key
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

  A real run that is blocked (see `BubbleEx.Load.Report`) returns
  `{:error, %Error{kind: :invalid_input, context: %{blocked: codes, report: report}}}`
  and writes nothing. A failed write returns the adapter's error with
  the ledger kept for a resume.
  """
  @spec run(Export.t() | Path.t(), Model.t(), target(), [option() | {:dry_run, boolean()}]) ::
          {:ok, Report.t()} | {:error, Error.t()}
  def run(export, %Model{} = model, {tmod, tconf}, opts \\ []) do
    dry? = Keyword.get(opts, :dry_run, false)

    with {:ok, export} <- open(export),
         :ok <- Scan.check_keys(model, Keyword.get(opts, :keys, %{})),
         {:ok, plan} <- tmod.plan(tconf, model),
         :ok <- check_plan(plan, model),
         {:ok, identity} <- identity(tmod, tconf, opts),
         {:ok, schema_diags} <- tmod.check_schema(tconf, plan),
         opts = Keyword.put(opts, :app_hosts, app_hosts(export, opts)),
         scan = Scan.run(export, model, plan, opts),
         {:ok, issues, clears} <- emails(scan, plan, {tmod, tconf}, schema_diags) do
      issues = Scan.drift(%{scan | issues: issues}, plan, model)
      issues = auth_status(issues, scan, plan)
      {joins, issues} = Joins.build(plan, scan, issues)

      state = %{
        export: export,
        model: model,
        plan: plan,
        scan: scan,
        target: {tmod, tconf},
        opts: opts,
        dry?: dry?,
        identity: identity,
        schema: schema_diags,
        issues: issues,
        joins: joins,
        clears: clears
      }

      blocked = blocked(state)

      cond do
        dry? -> {:ok, dry(state, blocked)}
        blocked != [] -> {:error, blocked_error(dry(state, blocked), blocked)}
        true -> load(state)
      end
    end
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

  # The exported users' emails against the target's (its unique email
  # identity): an email held by a target record the export does not hold
  # blocks the run (`:load_email_conflict`); users whose email changes
  # are cleared first (`clears`), so swaps and reuses between exported
  # users cannot collide within or across batches.
  defp emails(
         scan,
         %Plan{auth: %Plan.Auth{type: type, email_column: column}} = plan,
         {tmod, tconf}
       )
       when is_binary(column) do
    table = Plan.table(plan, type)

    with {:ok, existing} <- tmod.existing(tconf, table, column) do
      exported = Map.get(scan.ids, type, MapSet.new())
      target = Map.new(existing, fn {id, email} -> {id, fold(email)} end)
      holders = Enum.group_by(target, &elem(&1, 1), &elem(&1, 0))

      conflicts =
        for {id, %{email: email}} <- scan.auth,
            email != nil,
            holder <- Map.get(holders, email, []),
            holder != id,
            not MapSet.member?(exported, holder),
            uniq: true,
            do: id

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

      {:ok, issues, Enum.sort(clears)}
    end
  end

  defp emails(scan, _plan, _target), do: {:ok, scan.issues, []}

  # Not read when the schema check failed (the table may not exist; the
  # run is blocked anyway).
  defp emails(scan, plan, target, schema) do
    if Enum.any?(schema, &(&1.code == :load_schema_mismatch)),
      do: {:ok, scan.issues, []},
      else: emails(scan, plan, target)
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

  defp auth_status(issues, _scan, %Plan{auth: %Plan.Auth{confirmed_column: c}}) when is_binary(c),
    do: issues

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
    Error.new(:invalid_input, "the load is blocked: #{Enum.join(blocked, ", ")}", %{
      blocked: blocked,
      report: report
    })
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

  defp load(state) do
    ids = %{
      export_sha256: state.export.sha256,
      plan_sha256: Plan.sha256(state.plan),
      target: run_identity(state)
    }

    with {:ok, ledger} <- Ledger.open(Keyword.get(state.opts, :ledger_dir), ids),
         # A finished run starts over: every row is re-applied, changing
         # nothing that did not change.
         ledger = if(Ledger.complete?(ledger), do: Ledger.restart(ledger), else: ledger),
         {:ok, refs, ledger} <- copy_files(state, ledger),
         :ok <- clear_emails(state) do
      {tmod, tconf} = state.target

      result =
        convert_all(
          state,
          %{files: refs},
          fn table, batch, ledger ->
            write(table.type, &tmod.upsert(tconf, table, &1), batch, ledger)
          end,
          ledger
        )

      with {:ok, issues, ledger} <- result,
           {:ok, ledger} <- load_joins(state, ledger) do
        ledger = Ledger.complete(ledger)
        {:ok, report(state, issues, [], files_summary(state, refs), ledger)}
      else
        {:error, error, ledger} ->
          Ledger.close(ledger)
          {:error, error}
      end
    end
  end

  # The join tables (after every data type's table), one list at a time:
  # its rows upserted in batches recorded in the ledger under
  # `<join ID>/<type>/<field>`. Nothing is deleted (WTF-414).
  defp load_joins(state, ledger) do
    {tmod, tconf} = state.target
    size = Keyword.get(state.opts, :batch_size, 500)

    Enum.reduce_while(state.joins, {:ok, ledger}, fn built, {:ok, ledger} ->
      upsert = &tmod.upsert_join(tconf, built.join, built.side, &1)

      built.rows
      |> Enum.with_index()
      |> Enum.chunk_every(size)
      |> Enum.reduce_while({:ok, ledger}, &write_batch(built.key, upsert, &1, &2))
      |> case do
        {:ok, ledger} ->
          {:cont, {:ok, Ledger.type_complete(ledger, built.key, length(built.rows))}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp write_batch(key, upsert, batch, {:ok, ledger}) do
    case write(key, upsert, batch, ledger) do
      {:ok, ledger} -> {:cont, {:ok, ledger}}
      {:error, error} -> {:halt, {:error, error, ledger}}
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
  defp write(key, upsert, batch, ledger) do
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
        ledger =
          if last + 1 > done, do: Ledger.batch(ledger, key, last + 1, counts), else: ledger

        {:ok, Ledger.resumed(ledger, key, resumed)}

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

  defp finish_table(state, table, %Ledger{} = ledger) do
    rows = get_in(state.scan.types, [table.type, :rows]) || 0
    Ledger.type_complete(ledger, table.type, rows)
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

    json =
      case {auth?, state.plan.auth} do
        {true, %Plan.Auth{confirmed_column: c}} when is_binary(c) ->
          Map.put(json, c, Scan.confirmed(row))

        _ ->
          json
      end

    {json, issues}
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
