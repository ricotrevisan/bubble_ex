defmodule BubbleEx.Tasks do
  @moduledoc """
  Works a `BubbleEx.Plan` in the owner's repository (WTF-375, WTF-359 Q3):
  the plan is `.wtf/plan.json`, each task's state a file under
  `.wtf/tasks/` (`BubbleEx.Tasks.State`), and every verifier runs locally.
  `mix wtf.task` is the command line over this module.

      {:ok, board} = BubbleEx.Tasks.load(".")
      BubbleEx.Tasks.next(board, n: 3, now: DateTime.utc_now())
      {:ok, _} = BubbleEx.Tasks.claim(board, "surface:page/bUwyg1", "agent-a", now: now)
      {:ok, report} = BubbleEx.Tasks.complete(board, "surface:page/bUwyg1", agent: "agent-a", now: now)

  ## Readiness

  A task is **done** when its state says so, or when the plan closed it
  (`status: :closed`, by an owner decision). A task is **ready** when it
  is not done, removed, blocked (an unresolved `needs_decision` note) or
  claimed by another agent, and every task it depends on is done, except
  along non-blocking `:coordinate` edges, which are shown as information
  (the callee's tests re-run after it: `rerun_after`). A done task whose
  `source_sha256` is no longer the plan's needs re-verifying even before
  `sync/3` says so. `next/2` lists ready top-level tasks in plan order;
  subtasks are worked through their parent.

  ## Completing

  `complete/3` binds every criterion of the task to a check and refuses
  completion unless each one passes (only `attested` criteria may be
  waived, with a reason). Code checks are the target's
  (`BubbleEx.Target.Phoenix.Checks`); these are task state:

    * `subtasks_done` - every subtask is done or closed; subtasks the plan
      closes automatically (`status: :auto`) are verified with their
      parent, and completed with it
    * `independent_review` - a review is recorded (`review/4`) by a
      reviewer who is not an implementer of `args.of` (an agent that
      claimed or completed it or one of its subtasks), and the completing
      agent is not one either
    * `decision_recorded` - the owner decision `args.key` is in effect in
      the plan (a task's `decisions` or `closed_by`); an undecided plugin
      stays open until a plan built with the decision is synced
    * `attested` - an attestation (`attest:`), a waiver with a reason
      (`waive:`, only where the criterion allows it) or, for a review
      against Bubble, the recorded review's summary

  The state records each criterion's binding, outcome and evidence files
  (path and SHA-256), never command output.

  ## Re-verifying

  `audit/2` re-runs the checks of done tasks and turns those failing into
  `needs_reverify`. `sync/3` compares a new plan with the current one
  (`BubbleEx.Plan.diff/2`) and marks the done tasks that need re-verifying
  (changed, or depending on a changed, added or removed task), and the
  removed ones; it writes only `.wtf/plan.json` and `.wtf/tasks/`. Owned
  code is never touched (WTF-359 Q1).
  """

  alias BubbleEx.{Error, Plan}
  alias BubbleEx.Plan.Task
  alias BubbleEx.Target.Phoenix.Checks
  alias BubbleEx.Tasks.{State, Store}
  alias BubbleEx.Verify.Result

  @enforce_keys [:root, :plan, :states]
  defstruct [:root, :plan, :states, by_id: %{}, children: %{}]

  @type t :: %__MODULE__{
          root: Path.t(),
          plan: Plan.t(),
          states: %{String.t() => State.t()},
          by_id: %{String.t() => Task.t()},
          children: %{String.t() => [Task.t()]}
        }

  @default_ttl 2 * 60 * 60
  @min_text 20
  @results_dir ".wtf/verification/results"

  # --- loading ----------------------------------------------------------------------

  @doc "Loads the plan and task states of the repository at `root`."
  @spec load(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def load(root) do
    with {:ok, plan} <- Store.read_plan(root),
         {:ok, states} <- Store.read_states(root) do
      {:ok, board(root, plan, states)}
    end
  end

  defp board(root, plan, states) do
    %__MODULE__{
      root: root,
      plan: plan,
      states: states,
      by_id: Map.new(plan.tasks, &{&1.id, &1}),
      children: Enum.group_by(Enum.filter(plan.tasks, & &1.parent), & &1.parent)
    }
  end

  @doc "The state of task `id` (a fresh open one when it has none)."
  @spec state(t(), String.t()) :: State.t()
  def state(%__MODULE__{states: states}, id), do: Map.get(states, id) || State.new(id)

  # --- status -----------------------------------------------------------------------

  @doc """
  The status of a task at `now`: `:closed` (by an owner decision), `:done`,
  `:needs_reverify`, `:removed`, `:blocked`, `:claimed` (by an agent other
  than `agent`), `:waiting` (on dependencies) or `:ready`.
  """
  @spec status(t(), Task.t(), DateTime.t(), String.t() | nil) :: atom()
  def status(board, %Task{} = task, now, agent \\ nil) do
    state = state(board, task.id)

    cond do
      task.status == :closed -> :closed
      state.status == :removed -> :removed
      state.status == :done and stale?(state, task) -> :needs_reverify
      state.status == :done -> :done
      true -> open_status(board, task, state, now, agent)
    end
  end

  defp open_status(board, task, state, now, agent) do
    cond do
      State.blocked?(state) -> :blocked
      claimed_by_other?(state, agent, now) -> :claimed
      waiting_on(board, task) != [] -> :waiting
      state.status == :needs_reverify -> :needs_reverify
      true -> :ready
    end
  end

  defp stale?(%State{basis: %{source_sha256: sha}}, %Task{source_sha256: current}),
    do: sha != current

  defp stale?(_state, _task), do: false

  defp claimed_by_other?(state, agent, now),
    do: State.claimed?(state, now) and state.claim.agent != agent

  @doc "Whether task `id` is done: completed (and not stale) or closed by the plan."
  @spec done?(t(), String.t()) :: boolean()
  def done?(board, id) do
    case board.by_id[id] do
      %Task{status: :closed} -> true
      %Task{} = task -> state(board, id).status == :done and not stale?(state(board, id), task)
      nil -> false
    end
  end

  @doc "The tasks `task` waits on: its blocking dependencies that are not done."
  @spec waiting_on(t(), Task.t()) :: [String.t()]
  def waiting_on(board, %Task{depends_on: deps}) do
    for %{task: on, kind: kind} <- deps,
        kind != :coordinate,
        not done?(board, on),
        uniq: true,
        do: on
  end

  # --- next -------------------------------------------------------------------------

  @doc """
  The next ready top-level tasks, in plan order. Options: `:now`
  (required), `:n` (default 5), `:agent` (its own claims count as ready),
  `:actor` (only tasks for that actor).
  """
  @spec next(t(), keyword()) :: [map()]
  def next(board, opts) do
    now = Keyword.fetch!(opts, :now)
    agent = opts[:agent]

    board.plan.tasks
    |> Enum.filter(&(is_nil(&1.parent) and (is_nil(opts[:actor]) or &1.actor == opts[:actor])))
    |> Enum.sort_by(&{&1.order || 0, &1.id})
    |> Enum.filter(&(status(board, &1, now, agent) in [:ready, :needs_reverify]))
    |> Enum.take(Keyword.get(opts, :n, 5))
    |> Enum.map(fn task ->
      %{
        task: task,
        status: status(board, task, now, agent),
        coordinate:
          for(
            t <- [task | Map.get(board.children, task.id, [])],
            %{task: on, kind: :coordinate} <- t.depends_on,
            uniq: true,
            do: %{from: t.id, task: on, done: done?(board, on)}
          )
      }
    end)
  end

  # --- show -------------------------------------------------------------------------

  @doc "Everything about task `id`: the task, its state, dependencies, subtasks and status."
  @spec show(t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def show(board, id, opts) do
    now = Keyword.fetch!(opts, :now)

    with {:ok, task} <- fetch(board, id) do
      state = state(board, id)

      {:ok,
       %{
         task: task,
         state: state,
         status: status(board, task, now, opts[:agent]),
         stale: stale?(state, task),
         depends_on:
           Enum.map(
             task.depends_on,
             &Map.put(&1, :status, status(board, board.by_id[&1.task], now))
           ),
         subtasks:
           board.children
           |> Map.get(id, [])
           |> Enum.map(&%{task: &1.id, plan_status: &1.status, status: status(board, &1, now)}),
         implementers: implementers(board, id)
       }}
    end
  end

  # --- claim ------------------------------------------------------------------------

  @doc """
  Claims task `id` for `agent` until `now + ttl` (`:ttl` seconds, default
  two hours). An agent renews its own claim; another agent's live claim,
  a blocked, done or closed task, or one still waiting on dependencies is
  refused.
  """
  @spec claim(t(), String.t(), String.t(), keyword()) :: {:ok, State.t()} | {:error, Error.t()}
  def claim(board, id, agent, opts) do
    now = Keyword.fetch!(opts, :now)
    ttl = Keyword.get(opts, :ttl, @default_ttl)

    with :ok <- label(agent, "agent"),
         {:ok, task} <- fetch(board, id),
         :ok <- workable(board, task, now, agent) do
      state = state(board, id)

      state = %State{
        state
        | claim: %{agent: agent, claimed_at: now, expires_at: DateTime.add(now, ttl, :second)},
          agents: Enum.sort(Enum.uniq([agent | state.agents]))
      }

      :ok = Store.put(board.root, state)
      {:ok, state}
    end
  end

  @doc "Releases `agent`'s claim on task `id`."
  @spec release(t(), String.t(), String.t()) :: {:ok, State.t()} | {:error, Error.t()}
  def release(board, id, agent) do
    with {:ok, _task} <- fetch(board, id) do
      case state(board, id) do
        %State{claim: %{agent: ^agent}} = state ->
          state = %State{state | claim: nil}
          :ok = Store.put(board.root, state)
          {:ok, state}

        _ ->
          error("#{agent} holds no claim on #{id}", %{task: id})
      end
    end
  end

  defp workable(board, task, now, agent) do
    case status(board, task, now, agent) do
      s when s in [:ready, :needs_reverify] ->
        :ok

      :closed ->
        error("#{task.id} is closed by the owner decision #{task.closed_by}", %{task: task.id})

      :done ->
        error("#{task.id} is done", %{task: task.id})

      :removed ->
        error("#{task.id} is no longer in the plan", %{task: task.id})

      :blocked ->
        error("#{task.id} is blocked on a needs-decision note", %{
          task: task.id,
          notes: Enum.map(State.open_decisions(state(board, task.id)), & &1.n)
        })

      :claimed ->
        claim = state(board, task.id).claim

        error("#{task.id} is claimed by #{claim.agent} until #{claim.expires_at}", %{
          task: task.id
        })

      :waiting ->
        error("#{task.id} waits on #{Enum.join(waiting_on(board, task), ", ")}", %{
          task: task.id,
          waiting_on: waiting_on(board, task)
        })
    end
  end

  # --- complete ---------------------------------------------------------------------

  @doc """
  Verifies every criterion of task `id` and, when all pass, records it as
  done by `:agent` with its evidence. Options:

    * `:agent` (required), `:now` (required)
    * `:evidence` - paths (files or directories) of `BubbleEx.Verify.Result`
      files and other artifacts; `.wtf/verification/results/` is always read
    * `:attest` - `%{criterion id | :all => text}`
    * `:waive` - `%{criterion id => reason}` (attested criteria only)
    * `:app` - the Bubble app ID results must be for; `:reviewers` - the
      reviewers whose waivers count; `:resolved` - the
      `BubbleEx.Decision.Resolved` a result's decision is checked against
    * `:cmd` - `(args, env) -> {output, status}` running `mix` in the
      repository (default `System.cmd/3`)

  Returns `{:ok, report}` when recorded, or `:invalid_input` with the
  `report` (`%{task, outcomes, subtasks}`) in the context when a
  criterion fails. Nothing is written then.
  """
  @spec complete(t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def complete(board, id, opts) do
    now = Keyword.fetch!(opts, :now)
    agent = opts[:agent]

    with :ok <- label(agent, "agent"),
         {:ok, task} <- fetch(board, id),
         :ok <- workable(board, task, now, agent),
         :ok <- not_implementer(board, task, agent),
         :ok <- waivable(task, Keyword.get(opts, :waive, %{})),
         {:ok, evidence} <- evidence(board.root, Keyword.get(opts, :evidence, [])) do
      ctx = context(board, opts, now, evidence)

      auto =
        for sub <- Map.get(board.children, id, []),
            sub.status == :auto,
            not done?(board, sub.id),
            do: sub

      {sub_reports, cache} =
        Enum.map_reduce(auto, %{}, fn sub, cache ->
          {outcomes, cache} = verify(board, sub, Map.put(ctx, :agent, agent), cache)
          {%{task: sub.id, outcomes: outcomes}, cache}
        end)

      verified = for r <- sub_reports, passed?(r.outcomes), into: MapSet.new(), do: r.task
      ctx = ctx |> Map.put(:agent, agent) |> Map.put(:verified_subtasks, verified)
      {outcomes, _cache} = verify(board, task, ctx, cache)

      report = %{task: id, outcomes: outcomes, subtasks: sub_reports}

      if passed?(outcomes) do
        record(board, task, agent, now, report, evidence.artifacts)
        {:ok, report}
      else
        error("#{id} is not complete: a criterion failed", %{report: report})
      end
    end
  end

  defp record(board, task, agent, now, report, artifacts) do
    for r <- report.subtasks do
      :ok = Store.put(board.root, done(board, board.by_id[r.task], agent, now, r.outcomes, []))
    end

    :ok = Store.put(board.root, done(board, task, agent, now, report.outcomes, artifacts))
  end

  defp context(board, opts, now, evidence) do
    root = board.root

    %{
      board: board,
      root: root,
      now: now,
      results: evidence.results,
      app: opts[:app],
      reviewers: Keyword.get(opts, :reviewers, []),
      resolved: opts[:resolved],
      attest: Keyword.get(opts, :attest, %{}),
      waive: Keyword.get(opts, :waive, %{}),
      checks: Keyword.get(opts, :checks, Checks),
      cmd:
        Keyword.get(opts, :cmd, fn args, env ->
          System.cmd("mix", args, cd: root, stderr_to_stdout: true, env: env)
        end),
      verified_subtasks: MapSet.new(),
      audit: false
    }
  end

  defp passed?(outcomes), do: Enum.all?(outcomes, &(&1.status in [:pass, :waived]))

  defp done(board, task, agent, now, outcomes, artifacts) do
    state = state(board, task.id)

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

    %State{
      state
      | status: :done,
        claim: nil,
        agents: Enum.sort(Enum.uniq([agent | state.agents])),
        completed_by: agent,
        completed_at: now,
        basis: %{plan_sha256: board.plan.plan_sha256, source_sha256: task.source_sha256},
        evidence: Enum.map(outcomes, &Map.delete(&1, :output)) ++ artifact_entry,
        reverify: nil
    }
  end

  # Runs every criterion of `task`: [%{criterion, check, status, binding, detail, refs, output}].
  defp verify(board, task, ctx, cache) do
    ctx = Map.put(ctx, :task, task)

    Enum.map_reduce(task.criteria, cache, fn criterion, cache ->
      {outcome, cache} = criterion(board, criterion, ctx, cache)
      {Map.merge(%{criterion: criterion.id, check: criterion.check}, outcome), cache}
    end)
  end

  defp criterion(board, %{check: :subtasks_done}, ctx, cache) do
    pending =
      for sub <- Map.get(board.children, ctx.task.id, []),
          not done?(board, sub.id),
          not MapSet.member?(ctx.verified_subtasks, sub.id),
          do: sub.id

    {if(pending == [],
       do: ok("subtask states"),
       else: failed("subtask states", "not done: " <> Enum.join(pending, ", "))
     ), cache}
  end

  defp criterion(board, %{check: :independent_review, args: args}, ctx, cache) do
    of = args["of"] || ctx.task.id
    impl = implementers(board, of)
    review = state(board, ctx.task.id).review

    outcome =
      cond do
        review == nil ->
          failed("review record", "no review recorded (mix wtf.task review)")

        review.reviewer in impl ->
          failed("review record", "#{review.reviewer} implemented #{of}")

        not ctx.audit and ctx.agent in impl ->
          failed("review record", "#{ctx.agent} implemented #{of}")

        true ->
          ok("review record", "reviewed by #{review.reviewer}")
      end

    {outcome, cache}
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

  defp criterion(board, %{check: :attested} = c, ctx, cache) do
    {attested(board, c, ctx), cache}
  end

  defp criterion(_board, criterion, ctx, cache), do: ctx.checks.run(criterion, ctx, cache)

  defp attested(board, %{id: n} = criterion, ctx) do
    case if(ctx.audit, do: recorded(board, ctx.task.id, n)) do
      nil -> attestation(board, criterion, ctx, Map.get(ctx.waive, n))
      recorded -> recorded
    end
  end

  # Waivers were checked against the criteria (only waivable ones) up front.
  defp attestation(_board, _criterion, _ctx, waive) when is_binary(waive) do
    if text?(waive),
      do: %{ok("waiver", waive) | status: :waived},
      else: failed("waiver", "a waiver needs a reason of at least #{@min_text} characters")
  end

  defp attestation(board, %{id: n, args: args}, ctx, nil) do
    attest = Map.get(ctx.attest, n) || Map.get(ctx.attest, :all)
    review = state(board, ctx.task.id).review

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

  # An attestation from the last completion: an audit cannot re-attest.
  defp recorded(board, id, n) do
    Enum.find_value(state(board, id).evidence, fn
      %{"criterion" => ^n, "status" => status} = e when status in ["pass", "waived"] ->
        %{
          status: String.to_existing_atom(status),
          binding: e["binding"],
          detail: e["detail"],
          refs: [],
          output: nil
        }

      _ ->
        nil
    end)
  end

  defp text?(text), do: is_binary(text) and String.length(String.trim(text)) >= @min_text

  defp ok(binding, detail \\ nil),
    do: %{status: :pass, binding: binding, detail: detail, refs: [], output: nil}

  defp failed(binding, detail),
    do: %{status: :fail, binding: binding, detail: detail, refs: [], output: nil}

  @doc """
  The implementers of task `id`: every agent that claimed or completed it
  or one of its subtasks. An independent reviewer is none of them.
  """
  @spec implementers(t(), String.t()) :: [String.t()]
  def implementers(board, id) do
    [id | Enum.map(Map.get(board.children, id, []), & &1.id)]
    |> Enum.flat_map(&state(board, &1).agents)
    |> Enum.uniq()
    |> Enum.sort()
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
          who <- implementers(board, args["of"] || task.id),
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

  # --- evidence ---------------------------------------------------------------------

  @doc false
  # %{results: [{ref, sha256, %Result{}}] (latest per result id), artifacts: [%{ref, sha256}]}
  def evidence(root, paths) do
    default = Path.join(root, @results_dir)

    files =
      (if(File.dir?(default), do: [default], else: []) ++ paths)
      |> Enum.flat_map(&expand/1)
      |> Enum.uniq()

    Enum.reduce_while(files, {:ok, %{results: [], artifacts: []}}, fn path, {:ok, acc} ->
      case read_evidence(root, path) do
        {:ok, {:result, entry}} -> {:cont, {:ok, %{acc | results: [entry | acc.results]}}}
        {:ok, {:artifact, ref}} -> {:cont, {:ok, %{acc | artifacts: [ref | acc.artifacts]}}}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, %{results: results, artifacts: artifacts}} ->
        {:ok,
         %{
           results:
             results
             |> Enum.group_by(fn {_, _, r} -> r.id end)
             |> Enum.map(fn {_, rs} ->
               Enum.max_by(rs, fn {_, _, r} -> r.ran_at end, DateTime)
             end)
             |> Enum.sort_by(&elem(&1, 0)),
           artifacts: artifacts |> Enum.uniq() |> Enum.sort_by(& &1.ref)
         }}

      error ->
        error
    end
  end

  defp expand(path) do
    cond do
      File.dir?(path) -> path |> Path.join("**/*.json") |> Path.wildcard() |> Enum.sort()
      File.regular?(path) -> [path]
      true -> [{:missing, path}]
    end
  end

  defp read_evidence(_root, {:missing, path}), do: error("no evidence at #{path}", %{path: path})

  defp read_evidence(root, path) do
    bytes = File.read!(path)
    sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    ref = ref(root, path)

    case Jason.decode(bytes) do
      {:ok, %{"format" => format}} when format == "bubble_ex.verify.result" ->
        case Result.from_json(bytes) do
          {:ok, result} -> {:ok, {:result, {ref, sha, result}}}
          {:error, e} -> {:error, %{e | message: "#{ref}: #{e.message}"}}
        end

      _ ->
        {:ok, {:artifact, %{ref: ref, sha256: sha}}}
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

  # --- review and notes -------------------------------------------------------------

  @doc """
  Records `reviewer`'s review of task `id` (`summary`: what was compared,
  at least #{@min_text} characters). A reviewer who implemented the task,
  or what an acceptance task reviews (`independent_review` `of`), is
  refused. Options: `:now` (required).
  """
  @spec review(t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, State.t()} | {:error, Error.t()}
  def review(board, id, reviewer, summary, opts) do
    now = Keyword.fetch!(opts, :now)

    with :ok <- label(reviewer, "reviewer"),
         {:ok, task} <- fetch(board, id),
         :ok <-
           if(text?(summary),
             do: :ok,
             else: error("a review summary needs at least #{@min_text} characters")
           ) do
      reviewed =
        [id | for(%{check: :independent_review, args: a} <- task.criteria, a["of"], do: a["of"])]

      impl = Enum.flat_map(reviewed, &implementers(board, &1))

      if reviewer in impl do
        error(
          "#{reviewer} implemented #{Enum.join(reviewed, ", ")}; a review must be independent",
          %{
            task: id
          }
        )
      else
        state = %State{
          state(board, id)
          | review: %{reviewer: reviewer, at: now, summary: summary}
        }

        :ok = Store.put(board.root, state)
        {:ok, state}
      end
    end
  end

  @doc """
  Adds a note to task `id`: `kind: :needs_decision` blocks the task until
  resolved (an agent's blocker for the owner, WTF-359 §4.3), `:info` does
  not. Options: `:now`, `:by`, `:kind` (default `:info`), `:text`.
  """
  @spec note(t(), String.t(), keyword()) :: {:ok, State.t()} | {:error, Error.t()}
  def note(board, id, opts) do
    now = Keyword.fetch!(opts, :now)
    by = opts[:by]
    text = opts[:text]
    kind = Keyword.get(opts, :kind, :info)

    with :ok <- label(by, "by"),
         {:ok, _task} <- fetch(board, id),
         :ok <-
           if(is_binary(text) and String.trim(text) != "",
             do: :ok,
             else: error("a note needs text")
           ),
         :ok <- if(kind in [:info, :needs_decision], do: :ok, else: error("unknown note kind")) do
      state = state(board, id)

      note = %{
        n: length(state.notes) + 1,
        kind: kind,
        text: String.trim(text),
        by: by,
        at: now,
        resolved_by: nil,
        resolved_at: nil
      }

      state = %State{state | notes: state.notes ++ [note]}
      :ok = Store.put(board.root, state)
      {:ok, state}
    end
  end

  @doc "Resolves note `n` of task `id` (a decision was made). Options: `:now`, `:by`."
  @spec resolve_note(t(), String.t(), pos_integer(), keyword()) ::
          {:ok, State.t()} | {:error, Error.t()}
  def resolve_note(board, id, n, opts) do
    now = Keyword.fetch!(opts, :now)
    by = opts[:by]

    with :ok <- label(by, "by"),
         {:ok, _task} <- fetch(board, id) do
      state = state(board, id)

      case Enum.find(state.notes, &(&1.n == n)) do
        %{resolved_at: nil} ->
          notes = Enum.map(state.notes, &resolve(&1, n, by, now))
          state = %State{state | notes: notes}
          :ok = Store.put(board.root, state)
          {:ok, state}

        nil ->
          error("#{id} has no note #{n}")

        _ ->
          error("note #{n} of #{id} is already resolved")
      end
    end
  end

  defp resolve(%{n: n} = note, n, by, now), do: %{note | resolved_by: by, resolved_at: now}
  defp resolve(note, _n, _by, _now), do: note

  # --- audit ------------------------------------------------------------------------

  @doc """
  Re-runs the criteria of done tasks (all, or `:tasks`) and marks those
  failing, or whose `source_sha256` changed, `needs_reverify` (reason
  `audit`, with the failed criteria). Takes `complete/3`'s evidence and
  check options; attestations are the recorded ones. Returns
  `%{checked: [ids], flipped: [ids], reports: [%{task, outcomes}]}`.
  """
  @spec audit(t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def audit(board, opts) do
    now = Keyword.fetch!(opts, :now)

    ids =
      case opts[:tasks] do
        nil -> for task <- board.plan.tasks, state(board, task.id).status == :done, do: task.id
        ids -> ids
      end

    with {:ok, tasks} <- fetch_all(board, ids),
         {:ok, evidence} <- evidence(board.root, Keyword.get(opts, :evidence, [])) do
      ctx = board |> context(opts, now, evidence) |> Map.merge(%{audit: true, agent: nil})

      {reports, _cache} = Enum.map_reduce(tasks, %{}, &audit_task(board, &1, ctx, &2))

      flipped =
        for r <- reports, r.stale or not passed?(r.outcomes) do
          :ok = Store.put(board.root, flip(state(board, r.task), r, board.plan, now))
          r.task
        end

      {:ok, %{checked: Enum.map(reports, & &1.task), flipped: flipped, reports: reports}}
    end
  end

  defp audit_task(board, task, ctx, cache) do
    if stale?(state(board, task.id), task) do
      {%{task: task.id, stale: true, outcomes: []}, cache}
    else
      {outcomes, cache} = verify(board, task, ctx, cache)
      {%{task: task.id, stale: false, outcomes: outcomes}, cache}
    end
  end

  defp flip(state, report, plan, now) do
    reverify = %{
      source: "audit",
      at: now,
      plan_sha256: plan.plan_sha256,
      reasons: if(report.stale, do: ["source_changed"], else: ["criteria_failed"]),
      failed: for(o <- report.outcomes, o.status == :fail, do: o.criterion)
    }

    %State{state | status: :needs_reverify, reverify: reverify}
  end

  # --- sync -------------------------------------------------------------------------

  @doc """
  Applies a plan change to the task states: `BubbleEx.Plan.diff/2` of `old`
  and `new` (plans or their decoded JSON). Done tasks that need
  re-verifying become `needs_reverify` (with the diff's reasons, `via` and
  symbol changes); states of removed tasks become `removed`, and come back
  `open` if their task returns. With `write_plan: true`, `new` becomes
  `.wtf/plan.json`. Only `.wtf/` is written. Options: `:now` (required).
  """
  @spec sync(t(), Plan.t(), Plan.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def sync(board, %Plan{} = old, %Plan{} = new, opts) do
    now = Keyword.fetch!(opts, :now)

    with {:ok, diff} <- Plan.diff(old, new) do
      changes =
        for entry <- diff.tasks,
            state = board.states[entry.task],
            state != nil,
            updated = apply_entry(state, entry, new, now),
            updated != state,
            do: updated

      if opts[:write_plan], do: :ok = Store.write_plan(board.root, new)
      Enum.each(changes, &(:ok = Store.put(board.root, &1)))

      {:ok,
       %{
         diff: diff,
         reverify: for(s <- changes, s.status == :needs_reverify, do: s.task),
         removed: for(s <- changes, s.status == :removed, do: s.task),
         reopened: for(s <- changes, s.status == :open, do: s.task)
       }}
    end
  end

  defp apply_entry(%State{status: status} = state, %{needs_reverify: true} = entry, new, now)
       when status in [:done, :needs_reverify] do
    %State{
      state
      | status: :needs_reverify,
        reverify: %{
          source: "sync",
          at: now,
          plan_sha256: new.plan_sha256,
          reasons: Enum.map(entry.reasons, &Atom.to_string/1),
          via: entry.via,
          changes: entry.changes
        }
    }
  end

  defp apply_entry(%State{status: status} = state, %{status: :removed}, _new, _now)
       when status != :removed,
       do: %State{state | status: :removed, claim: nil}

  defp apply_entry(%State{status: :removed} = state, %{status: s}, _new, _now) when s != :removed,
    do: %State{state | status: :open, basis: nil, reverify: nil}

  defp apply_entry(state, _entry, _new, _now), do: state

  # --- helpers ----------------------------------------------------------------------

  defp fetch(board, id) do
    case board.by_id[id] do
      nil -> error("no task #{inspect(id)} in the plan", %{task: id})
      task -> {:ok, task}
    end
  end

  defp fetch_all(board, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case fetch(board, id) do
        {:ok, task} -> {:cont, {:ok, [task | acc]}}
        e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, tasks} -> {:ok, Enum.reverse(tasks)}
      e -> e
    end
  end

  # Agent and reviewer labels: short, printable, no whitespace.
  defp label(value, name) do
    if is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._@+:\/-]{0,99}\z/, value),
      do: :ok,
      else: error("#{name} must be a label (letters, digits and . _ @ + : / -)", %{value: value})
  end

  defp error(message, context \\ %{}), do: {:error, Error.new(:invalid_input, message, context)}
end
