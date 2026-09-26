defmodule Mix.Tasks.Wtf.Task do
  @shortdoc "Work the migration plan (.wtf/plan.json): next, show, claim, complete, audit…"
  @moduledoc """
  Works the migration plan of a project generated from a Bubble app, in
  the owner's repository (WTF-375, WTF-359 Q3). The plan is
  `.wtf/plan.json`; each task's state is a file under `.wtf/tasks/`
  (`BubbleEx.Tasks.State`), committed with the code. Every verifier runs
  locally (`BubbleEx.Target.Phoenix.Checks`). A dev-only tool: it refuses
  to run with `MIX_ENV=prod`.

      mix wtf.task next [--n 5] [--agent A] [--actor agent|reviewer|owner|…] [--json]
      mix wtf.task show ID [--json]
      mix wtf.task claim ID --agent A [--ttl 2h]
      mix wtf.task release ID --agent A
      mix wtf.task complete ID --agent A [--evidence PATH]… [--attest N=TEXT]…
                                          [--waive N=REASON]… [--app APP_ID]
                                          [--reviewer-waivers R]…
      mix wtf.task review ID --reviewer R --summary TEXT
      mix wtf.task note ID --agent A (--needs-decision TEXT | --info TEXT | --resolve N)
      mix wtf.task audit [ID…] [--evidence PATH]… [--app APP_ID] [--reviewer-waivers R]… [--json]
      mix wtf.task sync NEW_PLAN.json      # diff against .wtf/plan.json, then replace it
      mix wtf.task sync --from OLD_PLAN.json   # .wtf/plan.json is already the new plan

  Every command takes `--root DIR` (default: the current directory).

  ## Threat model: advisory only

  Every verdict of `complete` and `audit` is **advisory** ("advisory: not
  verified" in the output, `mode: advisory` in the state and in `audit
  --json`). The plan, the manifest, the task states, the results, the
  tests and the code are all files the agent being verified can edit, so
  a verdict is that agent's own claim: good for coordinating agents and
  catching honest mistakes, not for proving anything to anyone else.
  Reviewer labels and git author emails are spoofable hints. A verdict
  others can rely on (WTF-signed plans and results, CI verification,
  reviews as pull-request approvals) is WTF-411, "WTF trusted
  verification anchor". `--reviewer-waivers` only tells
  `BubbleEx.Verify.Result.evaluate/3` whose reviewer waivers to count.

    * `next` - ready top-level tasks in plan order: not done, claimed by
      someone else or blocked by a needs-decision note, with every blocking
      dependency done. Non-blocking `coordinate` dependencies are shown
    * `show` - the task, its criteria, subjects, residue, decisions,
      dependencies, subtasks, claim, notes, review, evidence and why it
      needs re-verifying
    * `claim` - a time-limited claim (default two hours; `--ttl 90m`)
    * `complete` - runs every criterion's check and records the task done
      with its evidence, or prints what failed and records nothing
      (exit status 1). `--evidence` takes `BubbleEx.Verify.Result` files
      or directories of them, and other artifacts (recorded by path and
      SHA-256); `.wtf/verification/results/` is always read. `--app` is
      the Bubble app ID results must be for. Only attested criteria may be
      waived, with a reason
    * `review` - an independent reviewer's review: refused when the
      reviewer implemented the task (or what the acceptance task reviews)
    * `note` - `--needs-decision` blocks the task until the owner decides
      (`--resolve N`); `--info` does not
    * `audit` - re-runs the checks of done tasks; failing ones become
      `needs_reverify` (exit status 1)
    * `sync` - applies a new plan (`BubbleEx.Plan.diff/2`): done tasks
      that changed, or depend on a change, become `needs_reverify`;
      removed tasks' states become `removed`. Writes only `.wtf/`
  """
  use Mix.Task

  alias BubbleEx.Plan.Task
  alias BubbleEx.Tasks
  alias BubbleEx.Tasks.{State, Store}

  @switches [
    root: :string,
    n: :integer,
    agent: :string,
    actor: :string,
    json: :boolean,
    ttl: :string,
    evidence: :keep,
    attest: :keep,
    waive: :keep,
    app: :string,
    reviewer_waivers: :keep,
    trusted_reviewer: :keep,
    reviewer: :string,
    summary: :string,
    needs_decision: :string,
    info: :string,
    resolve: :integer,
    from: :string
  ]

  @impl Mix.Task
  def run(argv) do
    if Mix.env() == :prod,
      do: Mix.raise("mix wtf.task is a development tool; not in MIX_ENV=prod")

    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if Keyword.has_key?(opts, :trusted_reviewer),
      do: Mix.raise("--trusted-reviewer was renamed --reviewer-waivers (nothing here is trusted)")

    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")

    root = Keyword.get(opts, :root, ".")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    command(args, root, opts, now)
  end

  defp command(["sync" | rest], root, opts, now), do: sync(rest, root, opts, now)

  defp command([cmd | rest], root, opts, now) do
    board = ok!(Tasks.load(root))
    command(cmd, rest, board, opts, now)
  end

  defp command([], _root, _opts, _now), do: usage()

  defp command("next", [], board, opts, now) do
    actor = opts[:actor] && actor!(opts[:actor])

    entries =
      Tasks.next(board, n: Keyword.get(opts, :n, 5), agent: opts[:agent], actor: actor, now: now)

    if opts[:json] do
      entries
      |> Enum.map(&%{&1 | task: task_map(&1.task)})
      |> json!()
    else
      if entries == [], do: info("no ready task")
      Enum.each(entries, &print_next/1)
    end
  end

  defp command("show", [id], board, opts, now) do
    shown = ok!(Tasks.show(board, id, now: now, agent: opts[:agent]))
    if opts[:json], do: json!(shown_map(shown)), else: print_show(shown)
  end

  defp command("claim", [id], board, opts, now) do
    state = ok!(Tasks.claim(board, id, opts[:agent], now: now, ttl: ttl!(opts[:ttl])))

    info(
      "#{id} claimed by #{state.claim.agent} until #{DateTime.to_iso8601(state.claim.expires_at)}"
    )
  end

  defp command("release", [id], board, opts, _now) do
    ok!(Tasks.release(board, id, opts[:agent]))
    info("#{id} released")
  end

  defp command("complete", [id], board, opts, now) do
    case Tasks.complete(
           board,
           id,
           check_opts(opts, now) ++
             [agent: opts[:agent], attest: attest!(opts), waive: waive!(opts)]
         ) do
      {:ok, report} ->
        print_report(report)
        print_ignored(report.ignored_results)
        info("#{id} done (#{mode(report.mode)})")

      {:error, %{context: %{report: report}} = e} ->
        print_report(report)
        print_ignored(report.ignored_results)
        Mix.raise("#{e.message} (#{mode(report.mode)})")

      {:error, e} ->
        Mix.raise(Exception.message(e))
    end
  end

  defp command("review", [id], board, opts, now) do
    ok!(Tasks.review(board, id, opts[:reviewer], opts[:summary], now: now))
    info("#{id} reviewed by #{opts[:reviewer]}")
  end

  defp command("note", [id], board, opts, now) do
    by = opts[:agent]

    cond do
      opts[:resolve] ->
        ok!(Tasks.resolve_note(board, id, opts[:resolve], by: by, now: now))
        info("note #{opts[:resolve]} of #{id} resolved")

      opts[:needs_decision] ->
        state =
          ok!(
            Tasks.note(board, id,
              by: by,
              now: now,
              kind: :needs_decision,
              text: opts[:needs_decision]
            )
          )

        info(
          "#{id}: needs-decision note #{length(state.notes)}; the task is blocked until it is resolved"
        )

      opts[:info] ->
        state = ok!(Tasks.note(board, id, by: by, now: now, kind: :info, text: opts[:info]))
        info("#{id}: note #{length(state.notes)}")

      true ->
        usage()
    end
  end

  defp command("audit", ids, board, opts, now) do
    audit_opts = check_opts(opts, now) ++ if(ids == [], do: [], else: [tasks: ids])
    result = ok!(Tasks.audit(board, audit_opts))

    if opts[:json] do
      json!(%{
        mode: result.mode,
        ignored_results: result.ignored_results,
        checked: result.checked,
        flipped: result.flipped,
        reports: Enum.map(result.reports, &report_map/1)
      })
    else
      print_audit(result)
      print_ignored(result.ignored_results)
      info(mode(result.mode))
    end

    if result.flipped != [],
      do:
        Mix.raise(
          "audit: #{length(result.flipped)} tasks need re-verifying (#{mode(result.mode)})"
        )
  end

  defp command(_cmd, _args, _board, _opts, _now), do: usage()

  defp sync(args, root, opts, now) do
    {old, new, write?} =
      case {args, opts[:from]} do
        {[path], nil} ->
          {ok!(Store.read_plan(root)), ok!(Store.read_plan_file(path)), true}

        {[], from} when is_binary(from) ->
          {ok!(Store.read_plan_file(from)), ok!(Store.read_plan(root)), false}

        _ ->
          usage()
      end

    states = ok!(Store.read_states(root))
    board = %Tasks{root: root, plan: old, states: states}
    result = ok!(Tasks.sync(board, old, new, now: now, write_plan: write?))
    counts = result.diff.counts

    info(
      "plan #{short(result.diff.from)} -> #{short(result.diff.to)}: #{counts.changed} changed, " <>
        "#{counts.added} added, #{counts.removed} removed, #{counts.needs_reverify} need re-verifying"
    )

    for id <- result.reverify, do: info("  needs_reverify #{id}")
    for id <- result.removed, do: info("  removed #{id}")
    for id <- result.reopened, do: info("  reopened #{id}")
    if write?, do: info("wrote #{Store.plan_path()}")
  end

  defp print_ignored(refs) do
    for ref <- refs,
        do: info("ignored result (unsigned; names no criterion checked here): #{ref}")
  end

  defp mode(_),
    do:
      "advisory: not verified (the agent being verified can edit everything checked; " <>
        "trusted verification is WTF-411)"

  # --- options ----------------------------------------------------------------------

  defp check_opts(opts, now) do
    [
      now: now,
      evidence: Keyword.get_values(opts, :evidence),
      app: opts[:app],
      reviewers: Keyword.get_values(opts, :reviewer_waivers)
    ]
  end

  defp attest!(opts) do
    opts
    |> Keyword.get_values(:attest)
    |> Map.new(fn text ->
      case Regex.run(~r/\A(\d+)=(.*)\z/s, text) do
        [_, n, rest] -> {String.to_integer(n), rest}
        nil -> Mix.raise("--attest takes CRITERION=TEXT: name the criterion it attests")
      end
    end)
  end

  defp waive!(opts) do
    opts
    |> Keyword.get_values(:waive)
    |> Map.new(fn text ->
      case Regex.run(~r/\A(\d+)=(.+)\z/s, text) do
        [_, n, reason] -> {String.to_integer(n), reason}
        nil -> Mix.raise("--waive takes CRITERION=REASON")
      end
    end)
  end

  defp ttl!(nil), do: 2 * 60 * 60

  defp ttl!(text) do
    case Regex.run(~r/\A(\d+)([smh]?)\z/, text) do
      [_, n, unit] -> String.to_integer(n) * %{"" => 1, "s" => 1, "m" => 60, "h" => 3600}[unit]
      nil -> Mix.raise("--ttl takes a duration like 90m or 2h")
    end
  end

  @actors ~w(generator agent reviewer owner loader harness)
  defp actor!(actor) when actor in @actors, do: String.to_existing_atom(actor)

  defp actor!(actor),
    do: Mix.raise("unknown actor #{inspect(actor)}: one of #{Enum.join(@actors, ", ")}")

  # --- output -----------------------------------------------------------------------

  defp print_next(%{task: t, status: status, coordinate: coord}) do
    reverify = if status == :needs_reverify, do: ", needs_reverify", else: ""
    info("#{t.id}  [#{t.kind}, #{t.actor}#{reverify}]#{label(t)}")

    for c <- coord do
      done = if c.done, do: "done", else: "not done"
      info("    coordinate: #{c.from} calls #{c.task} (#{done}; re-run its tests after it)")
    end
  end

  defp print_audit(result) do
    for r <- result.reports, r.stale or r.task in result.flipped, do: print_audited(r)

    for id <- result.flipped -- Enum.map(result.reports, & &1.task),
        do: info("#{id}: a subtask failed")

    info(
      "audited #{length(result.checked)} done tasks; #{length(result.flipped)} need re-verifying"
    )
  end

  defp print_audited(%{stale: true} = r),
    do: info("#{r.task}: its source changed since it was verified")

  defp print_audited(r), do: print_report(r)

  defp print_show(%{task: t, state: s} = shown) do
    print_task(t, shown.status)
    print_criteria(t, s)
    print_links(shown)
    print_state(s)
    if shown.stale, do: info("  needs re-verifying: its source changed since it was verified")
    print_reverify(s.reverify)
  end

  defp print_task(t, status) do
    info("#{t.id}#{label(t)}")
    info("  kind #{t.kind}, actor #{t.actor}, plan status #{t.status}, status #{status}")
    if t.parent, do: info("  parent #{t.parent}")
    if t.closed_by, do: info("  closed by decision #{t.closed_by}")
    info("  subjects: " <> list(t.subjects))
    if t.decisions != [], do: info("  decisions: " <> list(t.decisions))
    for r <- t.residue, do: info("  residue: #{r.subject} #{r.reason}")
  end

  defp print_criteria(t, s) do
    info("  criteria:")

    for c <- t.criteria do
      recorded = Enum.find(s.evidence, &(&1["criterion"] == c.id))
      mark = if recorded, do: " [#{recorded["status"]}]", else: ""
      waivable = if c.waiver == :allowed, do: " (waivable)", else: ""
      info("    #{c.id}. #{c.check}#{args(c.args)}#{waivable}#{mark}")
    end
  end

  defp print_links(shown) do
    info("  depends on:")
    for d <- shown.depends_on, do: info("    #{d.task} (#{d.kind}, #{d.status})")
    if shown.subtasks != [], do: info("  subtasks:")
    for sub <- shown.subtasks, do: info("    #{sub.task} (#{sub.plan_status}, #{sub.status})")
    if shown.implementers != [], do: info("  implementers: " <> list(shown.implementers))
  end

  defp print_state(s) do
    if s.claim, do: info("  claimed by #{s.claim.agent} until #{time(s.claim.expires_at)}")
    if s.completed_by, do: info("  completed by #{s.completed_by} at #{time(s.completed_at)}")
    if s.review, do: info("  reviewed by #{s.review.reviewer}: #{s.review.summary}")
    for n <- s.notes, do: info("  note #{n.n} [#{n.kind}] #{n.by}: #{n.text}#{resolved(n)}")
  end

  defp resolved(%{resolved_at: nil}), do: ""
  defp resolved(n), do: " (resolved by #{n.resolved_by})"

  defp print_reverify(nil), do: :ok

  defp print_reverify(r) do
    info("  needs re-verifying (#{r["source"]}): #{list(r["reasons"] || [])}")
    for v <- r["via"] || [], do: info("    via #{v["task"]} (#{v["kind"]})")
    for {k, ids} <- r["changes"] || %{}, ids != [], do: info("    symbols #{k}: #{list(ids)}")
    failed = r["failed"] || []
    if failed != [], do: info("    failed criteria: #{Enum.join(failed, ", ")}")
  end

  defp time(dt), do: DateTime.to_iso8601(dt)

  defp print_report(%{task: id, outcomes: outcomes} = report) do
    for sub <- Map.get(report, :subtasks, []), do: print_report(sub)
    info("#{id} (advisory verdict):")

    for o <- outcomes do
      criterion = if o.criterion, do: "#{o.criterion}. ", else: ""
      detail = if o.detail, do: ": #{o.detail}", else: ""
      info("  #{status_mark(o.status)} #{criterion}#{o.check} (#{o.binding})#{detail}")
      if o.status == :fail and o.output, do: info(indent(o.output))
    end
  end

  defp status_mark(:pass), do: "PASS  "
  defp status_mark(:waived), do: "WAIVED"
  defp status_mark(:fail), do: "FAIL  "

  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("      | " <> &1))

  defp args(args) when map_size(args) == 0, do: ""

  defp args(args) do
    " " <>
      Enum.map_join(Enum.sort(args), " ", fn
        {k, v} when is_list(v) -> "#{k}=[#{Enum.map_join(v, ", ", &to_string/1)}]"
        {k, v} -> "#{k}=#{v}"
      end)
  end

  defp label(%Task{label: nil}), do: ""
  defp label(%Task{label: label}), do: "  (#{label})"

  defp list([]), do: "none"
  defp list(items), do: Enum.join(items, ", ")

  defp short(nil), do: "none"
  defp short(sha), do: String.slice(sha, 0, 12)

  defp task_map(%Task{} = t), do: t |> Map.from_struct() |> State.json()

  defp shown_map(shown) do
    %{shown | task: task_map(shown.task), state: State.to_map(shown.state)} |> State.json()
  end

  defp report_map(r), do: State.json(%{r | outcomes: r.outcomes})

  defp json!(value),
    do:
      value
      |> State.json()
      |> BubbleEx.CanonicalJson.ordered()
      |> Jason.encode!(pretty: true)
      |> info()

  defp info(text), do: Mix.shell().info(text)

  defp ok!({:ok, value}), do: value
  defp ok!({:error, %BubbleEx.Error{} = e}), do: Mix.raise(Exception.message(e))

  defp usage, do: Mix.raise("usage: see mix help wtf.task")
end
