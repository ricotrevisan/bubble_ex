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

    * `subtasks_done` - every subtask is closed by the plan or passes its
      own criteria in the same run (automatic subtasks are completed with
      their parent; a subtask's recorded state is never taken on trust)
    * `independent_review` - a current review (its `basis` still matches
      the task's source and the reviewed evidence) by someone who did not
      implement `args.of`; the completing agent did not either
    * `decision_recorded` - the owner decision `args.key` is in effect in
      the plan (a task's `decisions` or `closed_by`); an undecided plugin
      stays open until a plan built with the decision is synced
    * `attested` - an attestation (`attest:`, naming the criterion), a
      waiver with a reason (`waive:`, only where the criterion allows it)
      or, for a review against Bubble, the recorded review's summary

  The state records each criterion's binding, outcome and evidence files
  (path and SHA-256), never command output, and the run's `mode`.

  ## Trust

  Everything in the owner's repository (`.wtf/plan.json`,
  `.wtf/generated.json`, `.wtf/tasks/`, results) is writable by the agent
  being verified, and `plan_sha256` is a hash anyone can recompute. So:

    * **advisory** (no `:key`) - the default. Every check runs, but a
      result is the agent's own claim: it is recorded as `mode:
      advisory`, and nothing may be reported as verified from it.
      Reviewer independence compares self-declared labels
    * **trusted** (`key:` = the plan signing key, held by WTF and the
      owner's CI as `WTF_PLAN_SIGNING_KEY`, never in the repository) -
      the plan and the manifest are the bytes `.wtf/plan.sig` signs
      (`BubbleEx.Plan.sign/2`), so an edited plan (a task marked closed, a
      criterion made waivable) or manifest (an entry deleted) is refused
      before anything runs, and closed tasks are closed only if the signed
      plan says so; only results signed with the key count, all of them
      (no newest-wins); implementers and reviewers are git authors of the
      commits that changed the state files (`BubbleEx.Tasks.Git`), and a
      review counts only when its author did not implement what it
      reviews; attestations, waivers and advisory bindings
      (`BubbleEx.Target.Phoenix.Checks`: source-only traceability,
      step-order comments) count only on such a review; stored
      attestations and subtask states are never reused

  Git author emails are as trustworthy as the repository host makes them
  (protected branches, verified commits). The verdict to rely on is
  `audit --trusted` run by CI over committed history; `complete` in a
  trusted run checks what exists before the completion is committed.
  Claims coordinate agents within a clone and race across clones until
  merged; completion never relies on them.

  ## Re-verifying

  `audit/2` re-runs the checks of done tasks (subtasks first) and turns
  those failing into `needs_reverify`, with their parents, dropping their
  reviews. `sync/3` compares a new plan with the current one
  (`BubbleEx.Plan.diff/2`) and marks the done tasks that need re-verifying
  (changed, or depending on a changed, added or removed task; their
  reviews are dropped), and the removed ones. It writes the states first
  and the plan last, each atomically, and only under `.wtf/`. Owned
  code is never touched (WTF-359 Q1).
  """

  alias BubbleEx.{Error, Plan}
  alias BubbleEx.Plan.Task
  alias BubbleEx.Tasks.{State, Store, Verifier}

  @enforce_keys [:root, :plan, :states]
  defstruct [:root, :plan, :states, :trust, by_id: %{}, children: %{}]

  @type t :: %__MODULE__{
          root: Path.t(),
          plan: Plan.t(),
          states: %{String.t() => State.t()},
          by_id: %{String.t() => Task.t()},
          children: %{String.t() => [Task.t()]},
          trust: nil | %{key: binary(), manifest: binary() | nil}
        }

  @default_ttl 2 * 60 * 60
  @min_text 20

  # --- loading ----------------------------------------------------------------------

  @doc "Loads the plan and task states of the repository at `root`."
  @spec load(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def load(root) do
    with {:ok, plan} <- Store.read_plan(root),
         {:ok, states} <- Store.read_states(root) do
      {:ok, board(root, plan, states)}
    end
  end

  defp board(root, plan, states),
    do: with_plan(%__MODULE__{root: root, plan: plan, states: states}, plan)

  @doc false
  def with_plan(board, plan) do
    %{
      board
      | plan: plan,
        by_id: Map.new(plan.tasks, &{&1.id, &1}),
        children: Enum.group_by(Enum.filter(plan.tasks, & &1.parent), & &1.parent)
    }
  end

  @doc "The state of task `id` (a fresh open one when it has none)."
  @spec state(t(), String.t()) :: State.t()
  def state(%__MODULE__{states: states}, id) do
    case Map.fetch(states, id) do
      {:ok, %State{} = state} -> state
      _ -> State.new(id)
    end
  end

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

      state = %{
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
          state = %{state | claim: nil}
          :ok = Store.put(board.root, state)
          {:ok, state}

        _ ->
          error("#{agent} holds no claim on #{id}", %{task: id})
      end
    end
  end

  @doc false
  def workable(board, task, now, agent) do
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

  # --- complete and audit ---------------------------------------------------------

  @doc """
  Verifies every criterion of task `id` and, when all pass, records it as
  done by `:agent` with its evidence and the run's mode. Options:

    * `:agent` (required), `:now` (required)
    * `:key` - the plan signing key: a trusted run (see "Trust"); without
      it the run is advisory
    * `:evidence` - paths (files or directories) of `BubbleEx.Verify.Result`
      files and other artifacts; `.wtf/verification/results/` is always read
    * `:attest` - `%{criterion id => text}`
    * `:waive` - `%{criterion id => reason}` (attested criteria only)
    * `:app` - the Bubble app ID results must be for; `:reviewers` - the
      reviewers whose waivers count; `:resolved` - the
      `BubbleEx.Decision.Resolved` a result's decision is checked against
    * `:cmd` - `(args, env) -> {output, status}` running `mix`, `:git` -
      `(args) -> {output, status}` running `git`, in the repository

  Returns `{:ok, report}` when recorded, or `:invalid_input` with the
  `report` (`%{task, mode, outcomes, subtasks}`) in the context when a
  criterion fails. Nothing is written then.
  """
  @spec complete(t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  defdelegate complete(board, id, opts), to: BubbleEx.Tasks.Verifier

  @doc """
  Re-runs the criteria of done tasks (all, or `:tasks`) and their done
  subtasks (first), and marks those failing, whose `source_sha256`
  changed, or whose subtask failed, `needs_reverify` (dropping their
  review). Takes `complete/3`'s options. Returns `%{mode, checked,
  flipped, reports}`.
  """
  @spec audit(t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  defdelegate audit(board, opts), to: BubbleEx.Tasks.Verifier

  @doc false
  defdelegate evidence(root, paths, key \\ nil), to: BubbleEx.Tasks.Verifier

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
      reviewed = Verifier.reviewed(board, task)
      impl = Enum.flat_map(reviewed, &state(board, &1).agents)

      if reviewer in impl do
        error(
          "#{reviewer} implemented #{Enum.join(reviewed, ", ")}; a review must be independent",
          %{
            task: id
          }
        )
      else
        state = %{
          state(board, id)
          | review: %{
              reviewer: reviewer,
              at: now,
              summary: summary,
              basis: Verifier.review_basis(board, task)
            }
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

      state = %{state | notes: state.notes ++ [note]}
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
          state = %{state | notes: notes}
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

      # States first, then the plan: a crash in between leaves the old plan
      # and flagged states, and running the same sync again is harmless.
      Enum.each(changes, &(:ok = Store.put(board.root, &1)))
      if opts[:write_plan], do: :ok = Store.write_plan(board.root, new)

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
    %{
      state
      | status: :needs_reverify,
        review: nil,
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
       do: %{state | status: :removed, claim: nil}

  defp apply_entry(%State{status: :removed} = state, %{status: s}, _new, _now) when s != :removed,
    do: %{state | status: :open, basis: nil, reverify: nil}

  defp apply_entry(state, _entry, _new, _now), do: state

  # --- helpers ----------------------------------------------------------------------

  @doc false
  def fetch(board, id) do
    case board.by_id[id] do
      nil -> error("no task #{inspect(id)} in the plan", %{task: id})
      task -> {:ok, task}
    end
  end

  defp text?(text), do: is_binary(text) and String.length(String.trim(text)) >= @min_text

  # Agent and reviewer labels: short, printable, no whitespace.
  @doc false
  def label(value, name) do
    if is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._@+:\/-]{0,99}\z/, value),
      do: :ok,
      else: error("#{name} must be a label (letters, digits and . _ @ + : / -)", %{value: value})
  end

  defp error(message, context \\ %{}), do: {:error, Error.new(:invalid_input, message, context)}
end
