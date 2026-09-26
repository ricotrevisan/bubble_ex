defmodule BubbleEx.Tasks.Verifier do
  @moduledoc """
  Runs the criteria of plan tasks for `BubbleEx.Tasks.complete/3` and
  `BubbleEx.Tasks.audit/2` (WTF-375). See `BubbleEx.Tasks` for the trust
  model; in short:

    * **advisory** (no key): every check runs, and the result is recorded
      as `advisory`. Anything in the repository, including the plan,
      the manifest, the task states and the results, is the agent's to
      edit, so an advisory result is the agent's own claim
    * **trusted** (`key:`): the plan and the manifest are read from the
      bytes whose signature verifies (`BubbleEx.Plan.Signature`); only
      signed results count, and all of them must pass (no newest-wins);
      reviews count only when git says a different author than the
      implementers recorded them (`BubbleEx.Tasks.Git`), and attestations,
      waivers and advisory bindings (source-only traceability,
      step-order comments) count only on such a review; subtasks are
      re-verified, never taken from their state
  """

  alias BubbleEx.{Error, Tasks}
  alias BubbleEx.Plan.Signature
  alias BubbleEx.Target.Phoenix.Checks
  alias BubbleEx.Tasks.{Git, State, Store}
  alias BubbleEx.Verify.Result

  @min_text 20
  @results_dir ".wtf/verification/results"

  # --- complete ---------------------------------------------------------------------

  @doc false
  def complete(board, id, opts) do
    now = Keyword.fetch!(opts, :now)
    agent = opts[:agent]

    with :ok <- Tasks.label(agent, "agent"),
         {:ok, board} <- trust(board, opts[:key]),
         {:ok, task} <- Tasks.fetch(board, id),
         :ok <- Tasks.workable(board, task, now, agent),
         :ok <- not_implementer(board, task, agent),
         :ok <- waivable(task, Keyword.get(opts, :waive, %{})),
         {:ok, evidence} <- evidence(board.root, Keyword.get(opts, :evidence, []), opts[:key]) do
      ctx = board |> context(opts, now, evidence) |> Map.put(:agent, agent)
      subtasks = Map.get(board.children, id, [])

      {sub_reports, {cache, passed}} =
        subtasks
        |> Enum.filter(
          &(&1.status != :closed and (&1.status == :auto or Tasks.done?(board, &1.id)))
        )
        |> Enum.map_reduce({%{}, MapSet.new()}, &verify_one(board, &1, ctx, &2))

      {outcomes, _cache} = verify(board, task, %{ctx | passed: passed}, cache)
      report = %{task: id, mode: mode(board), outcomes: outcomes, subtasks: sub_reports}

      if passed?(outcomes) do
        record_subtasks(board, sub_reports, agent, now)
        :ok = Store.put(board.root, done(board, task, agent, now, outcomes, evidence.artifacts))
        {:ok, report}
      else
        error("#{id} is not complete: a criterion failed", %{report: report})
      end
    end
  end

  defp record_subtasks(board, reports, agent, now) do
    for r <- reports, not Tasks.done?(board, r.task) do
      :ok = Store.put(board.root, done(board, board.by_id[r.task], agent, now, r.outcomes, []))
    end
  end

  defp verify_one(board, task, ctx, {cache, passed}) do
    {outcomes, cache} = verify(board, task, %{ctx | passed: passed}, cache)
    passed = if passed?(outcomes), do: MapSet.put(passed, task.id), else: passed
    {%{task: task.id, outcomes: outcomes}, {cache, passed}}
  end

  # --- audit ------------------------------------------------------------------------

  @doc false
  def audit(board, opts) do
    now = Keyword.fetch!(opts, :now)

    with {:ok, board} <- trust(board, opts[:key]),
         {:ok, tasks} <- audited(board, opts[:tasks]),
         {:ok, evidence} <- evidence(board.root, Keyword.get(opts, :evidence, []), opts[:key]) do
      ctx = board |> context(opts, now, evidence) |> Map.merge(%{audit: true, agent: nil})

      {reports, _acc} =
        Enum.map_reduce(tasks, {%{}, MapSet.new()}, &audit_one(board, &1, ctx, &2))

      failed = for r <- reports, r.stale or not passed?(r.outcomes), do: r
      # A subtask that fails takes its done parent with it.
      parents =
        for r <- failed,
            parent = board.by_id[r.task].parent,
            parent != nil,
            Tasks.state(board, parent).status == :done,
            parent not in Enum.map(failed, & &1.task),
            uniq: true,
            do: %{task: parent, stale: false, outcomes: [], subtask: r.task}

      flipped =
        for r <- failed ++ parents do
          :ok = Store.put(board.root, flip(Tasks.state(board, r.task), r, board.plan, now))
          r.task
        end

      {:ok,
       %{
         mode: mode(board),
         checked: Enum.map(reports, & &1.task),
         flipped: flipped,
         reports: reports
       }}
    end
  end

  defp audit_one(board, task, ctx, acc) do
    if stale?(board, task) do
      {%{task: task.id, stale: true, outcomes: []}, acc}
    else
      {report, acc} = verify_one(board, task, ctx, acc)
      {Map.put(report, :stale, false), acc}
    end
  end

  # Done tasks (or the given ones) and their done subtasks, subtasks first.
  defp audited(board, ids) do
    ids =
      ids ||
        for task <- board.plan.tasks, Tasks.state(board, task.id).status == :done, do: task.id

    with {:ok, tasks} <- fetch_all(board, ids) do
      subtasks =
        for t <- tasks,
            sub <- Map.get(board.children, t.id, []),
            Tasks.state(board, sub.id).status == :done,
            do: sub

      {:ok,
       Enum.uniq_by(
         subtasks ++ Enum.filter(tasks, & &1.parent) ++ Enum.reject(tasks, & &1.parent),
         & &1.id
       )}
    end
  end

  defp stale?(board, task) do
    case Tasks.state(board, task.id).basis do
      %{source_sha256: sha} -> sha != task.source_sha256
      _ -> false
    end
  end

  defp flip(state, report, plan, now) do
    reasons =
      cond do
        report.stale -> ["source_changed"]
        Map.has_key?(report, :subtask) -> ["subtask_failed"]
        true -> ["criteria_failed"]
      end

    reverify = %{
      source: "audit",
      at: now,
      plan_sha256: plan.plan_sha256,
      reasons: reasons,
      failed: for(o <- report.outcomes, o.status == :fail, do: o.criterion),
      subtask: report[:subtask]
    }

    # A review was of what no longer holds.
    %{state | status: :needs_reverify, reverify: reverify, review: nil}
  end

  # --- trust ------------------------------------------------------------------------

  # A trusted run swaps in the plan decoded from the verified bytes.
  defp trust(board, nil), do: {:ok, %{board | trust: nil}}

  defp trust(board, key) do
    with {:ok, %{plan: plan, manifest: manifest}} <- Store.read_trusted(board.root, key) do
      {:ok, board |> Tasks.with_plan(plan) |> Map.put(:trust, %{key: key, manifest: manifest})}
    end
  end

  defp mode(%{trust: nil}), do: :advisory
  defp mode(_board), do: :trusted

  defp context(board, opts, now, evidence) do
    root = board.root

    %{
      board: board,
      root: root,
      now: now,
      trusted: board.trust != nil,
      manifest: board.trust && board.trust.manifest,
      results: evidence.results,
      app: opts[:app],
      reviewers: Keyword.get(opts, :reviewers, []),
      resolved: opts[:resolved],
      attest: Keyword.get(opts, :attest, %{}),
      waive: Keyword.get(opts, :waive, %{}),
      checks: Keyword.get(opts, :checks, Checks),
      git: Keyword.get(opts, :git) || Git.cmd(root),
      cmd:
        Keyword.get(opts, :cmd, fn args, env ->
          System.cmd("mix", args, cd: root, stderr_to_stdout: true, env: env)
        end),
      passed: MapSet.new(),
      audit: false,
      agent: nil,
      task: nil
    }
  end

  # --- criteria ---------------------------------------------------------------------

  defp passed?(outcomes), do: Enum.all?(outcomes, &(&1.status in [:pass, :waived]))

  defp verify(board, task, ctx, cache) do
    ctx = %{ctx | task: task}

    Enum.map_reduce(task.criteria, cache, fn criterion, cache ->
      {outcome, cache} = criterion(board, criterion, ctx, cache)
      {outcome, cache} = vouch(board, outcome, ctx, cache)
      {Map.merge(%{criterion: criterion.id, check: criterion.check}, outcome), cache}
    end)
  end

  # In a trusted run an advisory binding counts only on an independent review.
  defp vouch(board, %{status: :pass, advisory: true} = outcome, %{trusted: true} = ctx, cache) do
    case independent(board, ctx.task, ctx, cache) do
      {{:ok, author}, cache} ->
        {%{outcome | detail: "#{outcome.detail}; vouched by the review of #{author}"}, cache}

      {{:error, why}, cache} ->
        {failed(outcome.binding, "advisory binding needs an independent review: #{why}"), cache}
    end
  end

  defp vouch(_board, outcome, _ctx, cache), do: {outcome, cache}

  defp criterion(board, %{check: :subtasks_done}, ctx, cache) do
    pending =
      for sub <- Map.get(board.children, ctx.task.id, []),
          sub.status != :closed,
          not MapSet.member?(ctx.passed, sub.id),
          do: sub.id

    {if(pending == [],
       do: ok("subtasks verified in this run"),
       else: failed("subtasks verified in this run", "not done: " <> Enum.join(pending, ", "))
     ), cache}
  end

  defp criterion(board, %{check: :independent_review}, ctx, cache) do
    case independent(board, ctx.task, ctx, cache) do
      {{:ok, who}, cache} -> {ok("review record", "reviewed by #{who}"), cache}
      {{:error, why}, cache} -> {failed("review record", why), cache}
    end
  end

  defp criterion(board, %{check: :decision_recorded, args: args}, _ctx, cache) do
    key = args["key"]

    effective =
      is_binary(key) and
        Enum.any?(board.plan.tasks, &(key in &1.decisions or &1.closed_by == key))

    {if(effective,
       do: ok("plan decisions", key),
       else: failed("plan decisions", "#{key || "the decision"} is not in effect in the plan")
     ), cache}
  end

  defp criterion(board, %{check: :attested} = c, ctx, cache), do: attested(board, c, ctx, cache)

  defp criterion(_board, criterion, ctx, cache) do
    {outcome, cache} = ctx.checks.run(criterion, ctx, cache)
    {Map.merge(%{advisory: false, raw: nil, output: nil, refs: []}, outcome), cache}
  end

  # Trusted: an attestation or waiver counts only on an independent review.
  defp attested(board, %{id: n} = c, %{trusted: true} = ctx, cache) do
    text = Map.get(ctx.waive, n) || Map.get(ctx.attest, n)

    case independent(board, ctx.task, ctx, cache) do
      {{:ok, author}, cache} ->
        outcome =
          ok("review by #{author}", text || Tasks.state(board, ctx.task.id).review.summary)

        {if(Map.has_key?(ctx.waive, n), do: %{outcome | status: :waived}, else: outcome), cache}

      {{:error, why}, cache} ->
        {failed("attestation", "#{c.args["about"]}: needs an independent review (#{why})"), cache}
    end
  end

  defp attested(board, %{id: n} = c, ctx, cache) do
    recorded = if ctx.audit, do: recorded(board, ctx.task.id, n)
    {recorded || attestation(board, c, ctx, Map.get(ctx.waive, n)), cache}
  end

  # Waivers were checked against the criteria (only waivable ones) up front.
  defp attestation(_board, _criterion, _ctx, waive) when is_binary(waive) do
    if text?(waive),
      do: %{ok("waiver", waive) | status: :waived},
      else: failed("waiver", "a waiver needs a reason of at least #{@min_text} characters")
  end

  defp attestation(board, %{id: n, args: args}, ctx, nil) do
    attest = Map.get(ctx.attest, n)
    review = Tasks.state(board, ctx.task.id).review

    cond do
      text?(attest) ->
        ok("attestation", attest)

      args["about"] == "reviewed_against_bubble" and review != nil ->
        ok("review record", review.summary)

      true ->
        failed(
          "attestation",
          "attest #{args["about"]} (--attest #{n}=...; at least #{@min_text} characters) " <>
            "or waive it with a reason"
        )
    end
  end

  # An attestation from the last completion: an advisory audit cannot re-attest.
  defp recorded(board, id, n) do
    Enum.find_value(Tasks.state(board, id).evidence, fn
      %{"criterion" => ^n, "status" => status} = e when status in ["pass", "waived"] ->
        %{ok(e["binding"], e["detail"]) | status: String.to_existing_atom(status)}

      _ ->
        nil
    end)
  end

  # --- independence -----------------------------------------------------------------

  @doc false
  # What a review of `task` covers: what its independent_review names
  # (else the task itself), with their subtasks.
  def reviewed(board, task) do
    of = for %{check: :independent_review, args: a} <- task.criteria, a["of"], do: a["of"]
    ids = if of == [], do: [task.id], else: of
    ids ++ for(id <- ids, sub <- Map.get(board.children, id, []), do: sub.id)
  end

  # {:ok, reviewer} when the task's review is current and independent.
  defp independent(board, task, ctx, cache) do
    review = Tasks.state(board, task.id).review
    reviewed = reviewed(board, task)

    cond do
      review == nil ->
        {{:error, "no review recorded (mix wtf.task review)"}, cache}

      not current?(board, task, review) ->
        {{:error, "the review is of other code or evidence; review again"}, cache}

      ctx.trusted ->
        by_git(task, reviewed, ctx, cache)

      true ->
        by_label(board, reviewed, review, ctx, cache)
    end
  end

  defp by_label(board, reviewed, review, ctx, cache) do
    impl = Enum.flat_map(reviewed, &Tasks.state(board, &1).agents)

    cond do
      review.reviewer in impl -> {{:error, "#{review.reviewer} implemented it"}, cache}
      not ctx.audit and ctx.agent in impl -> {{:error, "#{ctx.agent} implemented it"}, cache}
      true -> {{:ok, review.reviewer <> " (advisory label)"}, cache}
    end
  end

  # Implementers and the reviewer from committed history, never labels.
  # Reviewing oneself: the reviewer is not among the task's implementers.
  # Reviewing another task (acceptance): neither the reviewer nor whoever
  # completes this one implemented it, and it has a committed implementation.
  defp by_git(task, reviewed, ctx, cache) do
    {own, cache} = identities(ctx, task.id, cache)
    others = reviewed -- [task.id]

    {impl, cache} =
      Enum.flat_map_reduce(others, cache, fn id, cache ->
        {ids, cache} = identities(ctx, id, cache)
        {ids.implementers, cache}
      end)

    {impl, completers} =
      if others == [], do: {own.implementers, []}, else: {impl, own.implementers}

    author = Git.review_author(own, Tasks.state(ctx.board, task.id).review)

    cond do
      author == nil ->
        {{:error, "the review is not committed"}, cache}

      others != [] and impl == [] ->
        {{:error, "what it reviews has no committed implementation"}, cache}

      author in impl ->
        {{:error, "#{author} committed the implementation too"}, cache}

      (bad = Enum.find(completers, &(&1 in impl))) != nil ->
        {{:error, "#{bad} implemented it"}, cache}

      true ->
        {{:ok, author}, cache}
    end
  end

  defp identities(ctx, id, cache) do
    case cache do
      %{{:git, ^id} => ids} ->
        {ids, cache}

      _ ->
        ids = Git.identities(ctx.git, id)
        {ids, Map.put(cache, {:git, id}, ids)}
    end
  end

  # A review pins the task's source and the evidence of what it reviewed.
  defp current?(board, task, %{basis: basis}) do
    basis = State.json(basis)

    basis["source_sha256"] == task.source_sha256 and
      Enum.all?(basis["evidence"] || %{}, fn {id, sha} ->
        State.evidence_sha256(Tasks.state(board, id)) == sha
      end)
  end

  @doc false
  def review_basis(board, task) do
    %{
      source_sha256: task.source_sha256,
      evidence:
        for(
          id <- reviewed(board, task),
          Tasks.state(board, id).status == :done,
          into: %{},
          do: {id, State.evidence_sha256(Tasks.state(board, id))}
        )
    }
  end

  # Only attested criteria that allow it may be waived.
  defp waivable(task, waive) do
    allowed = for c <- task.criteria, c.waiver == :allowed, do: c.id

    case Map.keys(waive) -- allowed do
      [] -> :ok
      ns -> error("only attested criteria may be waived; #{task.id} cannot waive #{inspect(ns)}")
    end
  end

  # An acceptance task (independent_review) is never completed by an implementer.
  defp not_implementer(board, task, agent) do
    impl =
      for %{check: :independent_review, args: args} <- task.criteria,
          who <- Tasks.implementers(board, args["of"] || task.id),
          do: who

    if agent in impl,
      do:
        error(
          "#{agent} implemented what #{task.id} reviews; an independent reviewer completes it",
          %{
            task: task.id
          }
        ),
      else: :ok
  end

  defp done(board, task, agent, now, outcomes, artifacts) do
    state = Tasks.state(board, task.id)

    artifact_entry =
      if artifacts == [],
        do: [],
        else: [
          %{
            criterion: nil,
            check: :artifacts,
            status: :pass,
            binding: "--evidence",
            detail: nil,
            refs: artifacts
          }
        ]

    %{
      state
      | status: :done,
        claim: nil,
        agents: Enum.sort(Enum.uniq([agent | state.agents])),
        completed_by: agent,
        completed_at: now,
        basis: %{plan_sha256: board.plan.plan_sha256, source_sha256: task.source_sha256},
        evidence: Enum.map(outcomes, &Map.drop(&1, [:output, :raw])) ++ artifact_entry,
        reverify: nil,
        mode: mode(board)
    }
  end

  # --- evidence ---------------------------------------------------------------------

  @doc false
  # %{results: [{ref, sha256, %Result{}}], artifacts: [%{ref, sha256}], unsigned: [ref]}.
  # Advisory: the latest result per id. Trusted: every result signed with
  # the key (`<file>.sig`), all of them; unsigned ones are listed, not used.
  def evidence(root, paths, key \\ nil) do
    default = Path.join(root, @results_dir)

    files =
      (if(File.dir?(default), do: [default], else: []) ++ paths)
      |> Enum.flat_map(&expand/1)
      |> Enum.uniq()

    Enum.reduce_while(files, {:ok, %{results: [], artifacts: [], unsigned: []}}, fn path,
                                                                                    {:ok, acc} ->
      case read_evidence(root, path, key) do
        {:ok, {:result, entry}} -> {:cont, {:ok, %{acc | results: [entry | acc.results]}}}
        {:ok, {:unsigned, ref}} -> {:cont, {:ok, %{acc | unsigned: [ref | acc.unsigned]}}}
        {:ok, {:artifact, ref}} -> {:cont, {:ok, %{acc | artifacts: [ref | acc.artifacts]}}}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, acc} ->
        {:ok,
         %{
           results: acc.results |> latest(key) |> Enum.sort_by(&elem(&1, 0)),
           artifacts: acc.artifacts |> Enum.uniq() |> Enum.sort_by(& &1.ref),
           unsigned: Enum.sort(acc.unsigned)
         }}

      error ->
        error
    end
  end

  defp latest(results, key) when is_binary(key), do: results

  defp latest(results, nil) do
    results
    |> Enum.group_by(fn {_, _, r} -> r.id end)
    |> Enum.map(fn {_, rs} -> Enum.max_by(rs, fn {_, _, r} -> r.ran_at end, DateTime) end)
  end

  defp expand(path) do
    cond do
      File.dir?(path) -> path |> Path.join("**/*.json") |> Path.wildcard() |> Enum.sort()
      File.regular?(path) -> [path]
      true -> [{:missing, path}]
    end
  end

  defp read_evidence(_root, {:missing, path}, _key),
    do: error("no evidence at #{path}", %{path: path})

  defp read_evidence(root, path, key) do
    bytes = File.read!(path)
    sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    ref = ref(root, path)

    case Jason.decode(bytes) do
      {:ok, %{"format" => "bubble_ex.verify.result"}} ->
        if key != nil and not signed?(path, bytes, key),
          do: {:ok, {:unsigned, ref}},
          else: result(bytes, ref, sha)

      _ ->
        {:ok, {:artifact, %{ref: ref, sha256: sha}}}
    end
  end

  defp result(bytes, ref, sha) do
    case Result.from_json(bytes) do
      {:ok, result} -> {:ok, {:result, {ref, sha, result}}}
      {:error, e} -> {:error, %{e | message: "#{ref}: #{e.message}"}}
    end
  end

  defp signed?(path, bytes, key) do
    case File.read(path <> ".sig") do
      {:ok, mac} -> Signature.verify_file(bytes, "result", mac, key)
      _ -> false
    end
  end

  # Repository-relative; a file outside the repository is named by its basename only.
  defp ref(root, path) do
    root = Path.expand(root)
    abs = Path.expand(path)

    case Path.relative_to(abs, root) do
      ^abs -> Path.basename(abs)
      rel -> rel
    end
  end

  # --- helpers ----------------------------------------------------------------------

  defp fetch_all(board, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Tasks.fetch(board, id) do
        {:ok, task} -> {:cont, {:ok, [task | acc]}}
        e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, tasks} -> {:ok, Enum.reverse(tasks)}
      e -> e
    end
  end

  defp text?(text), do: is_binary(text) and String.length(String.trim(text)) >= @min_text

  defp ok(binding, detail \\ nil),
    do: %{
      status: :pass,
      binding: binding,
      detail: detail,
      refs: [],
      output: nil,
      advisory: false,
      raw: nil
    }

  defp failed(binding, detail),
    do: %{
      status: :fail,
      binding: binding,
      detail: detail,
      refs: [],
      output: nil,
      advisory: false,
      raw: nil
    }

  defp error(message, context \\ %{}), do: {:error, Error.new(:invalid_input, message, context)}
end
