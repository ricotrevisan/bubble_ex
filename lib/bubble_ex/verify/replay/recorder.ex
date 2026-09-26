defmodule BubbleEx.Verify.Replay.Recorder do
  @moduledoc """
  Records scenarios on a Bubble replay branch (V4 of WTF-358): `oracle:
  bubble` recordings (`BubbleEx.Verify.Recording`) made by running every
  scenario twice, each time from a fresh seed, with differential masks.

      {:ok, plan} = Recorder.plan(client, seed, scenarios, opts)
      # review plan.calls, then:
      {:ok, result} = Recorder.record(client, seed, scenarios, [plan_sha256: plan.sha256] ++ opts)
      result.files      # [{".wtf/verification/recordings/<id>.json", json}], credential-scanned
      result.report     # runs, calls, cleanup, unstable, calibration, …

  `record_matrix/3` does the same for a `BubbleEx.Verify.Matrix`.

  **One run** = preflight (first run only) → seed
  (`BubbleEx.Verify.Replay.Seeder`, ledger) → every scenario's ops as their
  personas → cleanup of the run's ledger, always, even after a failure.
  Ops supported: `get` and `search` (Data API, the persona's token or
  none) and `call_api_workflow` observing `status` and `response`. Other
  ops and observations (`db_diff`, `step_trace`, pages) are V7/V8 and
  refused up front.

  **Dry run first (§6.1 rule 3).** `plan/4` makes no call: it validates
  the scenarios against the seed and the target, estimates the calls and
  hashes the run's inputs. `record/4` needs that hash (`:plan_sha256`) and
  refuses when the estimate exceeds the client's remaining budget.

  **Recordings.** Per scenario: `oracle: bubble`, the target's app and
  branch, `runs` = the runs made, `t0` and `recorded_at` from the first
  run, the scenario and seed hashes, `stats.calls`, the differential masks
  (`BubbleEx.Verify.Replay.Differential`). A recording is `complete` only
  when every run observed every op and nothing was unstable; an incomplete
  one is kept for diagnosis and is never an oracle (V1 rules). Every
  recording passes `Recording.check_scenario/2` and the credential scan
  (`BubbleEx.Verify.Replay.CredentialScan`, with the run's admin token,
  passwords and persona tokens) before it is returned; one that fails is
  dropped and listed under `report.refused`.

  **Calibration.** `report.calibration` lists, per scenario op, the
  interpreter assumption flags (`BubbleEx.Verify.Interpreter.Assumptions`)
  its recorded observations can confirm or refute: the Matrix's
  `dependencies` (`:dependencies` option), plus `dangling_ref_is_empty`
  for ops that read a record (or search a type, or act as a user) holding a
  reference to a record deleted after seeding.

  ## Options

    * `:plan_sha256` - required by `record/4` (from `plan/4`)
    * `:runs` - at least 2 (default 2)
    * `:kit` - `BubbleEx.Verify.Replay.Kit` (workflow names)
    * `:delete_after_seed` - seed keys to delete right after seeding
    * `:dependencies` - `%{{scenario ID, op ID} => [flag]}`
    * `:run_id` - prefix of the runs' IDs (lowercase letters, digits, `-`;
      default random); run `n` is `<run_id>-<n>`
    * `:now` - a 0-arity function returning a `DateTime` (tests)
  """

  alias BubbleEx.{CanonicalJson, Error}
  alias BubbleEx.Verify.{Check, Observation, Recording, Scenario, Seed, Value}

  alias BubbleEx.Verify.Replay.{
    Client,
    Codec,
    CredentialScan,
    Differential,
    Kit,
    Ledger,
    Names,
    Seeder,
    Session
  }

  @supported %{
    get: [:visible, :visible_fields, :values],
    search: [:record_set],
    call_api_workflow: [:status, :response]
  }

  @doc "The dry run: validation, the call estimate and the plan hash. No calls."
  @spec plan(Client.t(), Seed.t(), [Scenario.t()], keyword()) ::
          {:ok, %{sha256: String.t(), calls: pos_integer(), cleanup_calls: non_neg_integer()}}
          | {:error, Error.t()}
  def plan(%Client{} = client, %Seed{} = seed, scenarios, opts \\ []) do
    with {:ok, runs} <- runs(opts),
         :ok <- validate(client, seed, scenarios, opts) do
      per_run = seeding_calls(seed, opts) + op_calls(client, seed, scenarios)
      types = types(seed, scenarios)
      kit = Keyword.get(opts, :kit, %Kit{})

      {:ok,
       %{
         sha256:
           CanonicalJson.sha256(%{
             "app" => client.target.app,
             "branch" => client.target.branch,
             "seed_sha256" => Seed.sha256(seed),
             "scenarios" => scenarios |> Enum.map(&[&1.id, Scenario.sha256(&1)]) |> Enum.sort(),
             "runs" => runs,
             "kit" => [kit.signup, kit.login],
             "delete_after_seed" => opts |> Keyword.get(:delete_after_seed, []) |> Enum.sort(),
             "max_calls" => client.max_calls
           }),
         calls: 1 + length(types) + runs * per_run,
         cleanup_calls: runs * length(seed.records),
         runs: runs
       }}
    end
  end

  @doc "Records `scenarios`. See the moduledoc."
  @spec record(Client.t(), Seed.t(), [Scenario.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def record(%Client{} = client, %Seed{} = seed, scenarios, opts \\ []) do
    with {:ok, plan} <- plan(client, seed, scenarios, opts),
         :ok <- confirmed(plan, opts),
         :ok <- affordable(client, plan),
         {:ok, run_id} <- run_id(opts),
         {:ok, preflight} <- Kit.preflight(client, kit(opts), types(seed, scenarios)) do
      if preflight.ok? do
        {:ok, run(client, seed, scenarios, plan, run_id, preflight, opts)}
      else
        {:error,
         Error.new(:invalid_input, "the replay kit is not complete on the branch", %{
           preflight: preflight.checks
         })}
      end
    end
  end

  @doc "Records a `BubbleEx.Verify.Matrix`'s seed and scenarios, with its dependencies."
  @spec record_matrix(Client.t(), struct(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def record_matrix(%Client{} = client, %{seed: seed, scenarios: scenarios} = matrix, opts) do
    record(client, seed, scenarios, Keyword.put_new(opts, :dependencies, matrix.dependencies))
  end

  @doc "`plan/4` for a `BubbleEx.Verify.Matrix`."
  @spec plan_matrix(Client.t(), struct(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def plan_matrix(%Client{} = client, %{seed: seed, scenarios: scenarios}, opts \\ []),
    do: plan(client, seed, scenarios, opts)

  defp kit(opts), do: Keyword.get(opts, :kit, %Kit{})

  # --- validation -------------------------------------------------------------------

  defp runs(opts) do
    case Keyword.get(opts, :runs, 2) do
      n when is_integer(n) and n >= 2 and n <= 5 ->
        {:ok, n}

      n ->
        {:error,
         Error.new(:invalid_input, "a Bubble recording needs 2 to 5 runs (double recording)", %{
           runs: n
         })}
    end
  end

  defp run_id(opts) do
    id =
      Keyword.get_lazy(opts, :run_id, fn ->
        4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
      end)

    if is_binary(id) and id =~ ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/,
      do: {:ok, id},
      else:
        {:error, Error.new(:invalid_input, "run_id must be short lowercase letters and digits")}
  end

  defp confirmed(plan, opts) do
    if Keyword.get(opts, :plan_sha256) == plan.sha256,
      do: :ok,
      else:
        {:error,
         Error.new(:invalid_input, "run the dry run first: :plan_sha256 must match plan/4", %{
           reason: :plan_not_confirmed
         })}
  end

  defp affordable(client, plan) do
    remaining = client.max_calls - Client.calls(client)

    cond do
      plan.calls > remaining ->
        {:error,
         Error.new(:invalid_input, "the planned calls exceed the replay budget", %{
           reason: :over_budget,
           planned: plan.calls,
           remaining: remaining
         })}

      plan.cleanup_calls > client.cleanup_max_calls ->
        {:error,
         Error.new(:invalid_input, "cleanup would exceed its budget", %{
           reason: :over_budget,
           planned: plan.cleanup_calls
         })}

      true ->
        :ok
    end
  end

  defp validate(client, seed, scenarios, opts) do
    keys = MapSet.new(seed.records, & &1.key)

    with :ok <- each_ok(scenarios, &Scenario.check_seed(&1, seed)),
         :ok <- each_ok(scenarios, &supported/1),
         :ok <- names_known(client.names, seed, scenarios) do
      case Enum.reject(Keyword.get(opts, :delete_after_seed, []), &MapSet.member?(keys, &1)) do
        [] ->
          :ok

        missing ->
          {:error,
           Error.new(:invalid_input, "delete_after_seed names records not in the seed", %{
             keys: missing
           })}
      end
    end
  end

  defp each_ok(items, fun) do
    Enum.find_value(items, :ok, fn item ->
      case fun.(item) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp supported(%Scenario{} = s) do
    bad =
      for op <- s.ops,
          allowed = Map.get(@supported, op.op, []),
          allowed == [] or Enum.any?(op.observe, &(&1 not in allowed)),
          do: op.id

    if bad == [],
      do: :ok,
      else:
        {:error,
         Error.new(:invalid_input, "the replay driver cannot record these ops yet", %{
           scenario: s.id,
           ops: bad
         })}
  end

  defp names_known(names, seed, scenarios) do
    types = types(seed, scenarios)

    with :ok <- each_ok(types, &ok(Names.type_path(names, &1))) do
      each_ok(seed.records, fn record ->
        record.fields
        |> Map.keys()
        |> Enum.reject(&(&1 in ["Created By", "Created Date", "Modified Date", "_id"]))
        |> each_ok(&ok(Names.field_key(names, record.type, &1)))
      end)
    end
  end

  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error

  defp types(seed, scenarios) do
    (Enum.map(seed.records, & &1.type) ++
       for(s <- scenarios, op <- s.ops, type = Map.get(op, :type), do: type))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp seeding_calls(seed, opts) do
    {users, records} = Enum.split_with(seed.records, &(&1.type == "user"))

    refs =
      Enum.count(records, fn r -> Enum.any?(r.fields, fn {_, v} -> Value.refs(v) != [] end) end)

    3 * length(users) + length(records) + refs + length(Keyword.get(opts, :delete_after_seed, []))
  end

  defp op_calls(client, seed, scenarios) do
    counts = Enum.frequencies_by(seed.records, & &1.type)

    for s <- scenarios, op <- s.ops, reduce: 0 do
      acc ->
        case op.op do
          :search -> acc + div(Map.get(counts, op.type, 0), client.page_size) + 1
          _ -> acc + 1
        end
    end
  end

  # --- runs ---------------------------------------------------------------------------

  defp run(client, seed, scenarios, plan, run_id, preflight, opts) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)

    runs =
      Enum.reduce_while(1..plan.runs, [], fn n, acc ->
        result = one_run(client, seed, scenarios, "#{run_id}-#{n}", now, opts)
        acc = acc ++ [result]
        if result.error, do: {:halt, acc}, else: {:cont, acc}
      end)

    secrets = Client.secrets(client) ++ Enum.flat_map(runs, &Session.secrets(&1.session))
    class = fn s -> s.check |> Check.fetch() |> elem(1) |> elem(1) end

    built =
      Enum.map(scenarios, fn s ->
        build(s, seed, runs, plan.runs, class.(s), client, secrets)
      end)

    %{
      recordings: for(%{recording: r} <- built, r, do: r),
      files:
        for(
          %{recording: r, json: json} <- built,
          r,
          do: {".wtf/verification/recordings/#{r.scenario.id}.json", json}
        ),
      ledgers: Enum.map(runs, & &1.ledger),
      report: report(client, preflight, runs, built, seed, scenarios, opts)
    }
  end

  defp report(client, preflight, runs, built, seed, scenarios, opts) do
    %{
      app: client.target.app,
      branch: client.target.branch,
      preflight: preflight,
      calls: Client.calls(client),
      cleanup_calls: Client.cleanup_calls(client),
      runs: Enum.map(runs, &run_summary/1),
      complete: for(%{recording: %{complete: true} = r} <- built, do: r.scenario.id),
      incomplete: for(%{incomplete: why} = b <- built, why, do: %{scenario: b.id, why: why}),
      unstable:
        for(%{unstable: [_ | _] = u} = b <- built, do: %{scenario: b.id, observations: u}),
      needs_review: for(%{share: share} = b <- built, share > 0.2, do: b.id),
      refused: for(%{refused: r} = b <- built, r, do: %{scenario: b.id, error: r}),
      leftovers: Enum.flat_map(runs, & &1.leftovers),
      calibration: calibration(seed, scenarios, opts)
    }
  end

  defp run_summary(r) do
    %{
      run_id: r.run_id,
      seeded: length(r.ledger.entries),
      error: r.error && error_summary(r.error),
      leftovers: r.leftovers
    }
  end

  defp error_summary(%Error{kind: kind, message: message, context: context}),
    do: %{kind: kind, message: message, reason: Map.get(context, :reason)}

  defp one_run(client, seed, scenarios, run_id, now, opts) do
    started = now.() |> DateTime.truncate(:second)

    {seeded, state} =
      case Seeder.seed(client, seed, run_id,
             kit: kit(opts),
             delete_after_seed: opts[:delete_after_seed] || []
           ) do
        {:ok, state} -> {:ok, state}
        {:error, error, state} -> {{:error, error}, state}
      end

    observed =
      case seeded do
        :ok -> Map.new(scenarios, &{&1.id, observe(client, seed, &1, state)})
        {:error, _} -> Map.new(scenarios, &{&1.id, {:error, :seeding_failed, 0}})
      end

    {ledger, leftovers} = cleanup(client, state.ledger)

    error =
      case seeded do
        {:error, error} ->
          error

        :ok ->
          Enum.find_value(observed, fn
            {_id, {:error, %Error{context: %{reason: :budget_exhausted}} = e, _}} -> e
            _ -> nil
          end)
      end

    %{
      run_id: run_id,
      started: started,
      observed: observed,
      ledger: ledger,
      session: state.session,
      leftovers: leftovers,
      error: error
    }
  end

  # Deletes every live ledger entry, newest first; what fails is reported.
  defp cleanup(client, ledger) do
    Enum.reduce(Ledger.live(ledger), {ledger, []}, fn entry, {ledger, left} ->
      case Client.delete_seeded(client, ledger, entry.key) do
        {:ok, ledger} ->
          {ledger, left}

        {:error, error} ->
          {ledger, left ++ [%{key: entry.key, type: entry.type, id: entry.id, kind: error.kind}]}
      end
    end)
  end

  # --- observing ------------------------------------------------------------------------

  defp observe(client, seed, scenario, state) do
    before = Client.calls(client)

    result =
      Enum.reduce_while(scenario.ops, {:ok, []}, fn op, {:ok, acc} ->
        case run_op(client, seed, scenario, op, state) do
          {:ok, obs} -> {:cont, {:ok, acc ++ obs}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    calls = Client.calls(client) - before

    case result do
      {:ok, obs} -> {:ok, obs, calls}
      {:error, error} -> {:error, error, calls}
    end
  end

  defp auth(seed, scenario, op, state) do
    persona = Map.get(op, :persona) || scenario.persona

    case seed.personas[persona] do
      %{user: nil} ->
        {:ok, :none}

      %{user: user} ->
        case Session.token(state.session, user) do
          nil -> {:error, Error.new(:invalid_input, "persona has no token", %{persona: persona})}
          token -> {:ok, {:user, token}}
        end
    end
  end

  defp run_op(client, seed, scenario, %{op: :get} = op, state) do
    with {:ok, auth} <- auth(seed, scenario, op, state),
         %{} = entry <- Ledger.fetch(state.ledger, op.record) || missing(op.record),
         {:ok, answer} <- Client.get(client, op.type, entry.id, auth) do
      {:ok, get_observations(client.names, seed, op, answer, state.ledger)}
    end
  end

  defp run_op(client, seed, scenario, %{op: :search} = op, state) do
    ids =
      for %{type: type, state: :created, id: id} <- state.ledger.entries, type == op.type, do: id

    with {:ok, auth} <- auth(seed, scenario, op, state),
         {:ok, sort} <- sort(client.names, op),
         {:ok, results} <- Client.search(client, op.type, auth, ids: ids, sort: sort) do
      keys =
        results
        |> Enum.map(&Ledger.key_for_id(state.ledger, &1["_id"]))
        |> Enum.reject(&is_nil/1)

      records = if sort, do: keys, else: keys |> Enum.uniq() |> Enum.sort()

      {:ok,
       [
         %Observation{
           op: op.id,
           kind: :record_set,
           value: %{ordered: sort != nil, records: records}
         }
       ]}
    end
  end

  defp run_op(client, seed, scenario, %{op: :call_api_workflow} = op, state) do
    with {:ok, auth} <- workflow_auth(seed, scenario, op, state),
         {:ok, params} <- params(op.params, state.ledger),
         {:ok, %{status: status, body: body}} <-
           Client.call_workflow(client, op.workflow, params, auth) do
      body = if body == :invalid_json, do: nil, else: body

      {:ok,
       Enum.flat_map(op.observe, fn
         :status -> [%Observation{op: op.id, kind: :status, value: status}]
         :response -> [%Observation{op: op.id, kind: :response, value: body}]
       end)}
    end
  end

  defp missing(key),
    do: {:error, Error.new(:invalid_input, "the op's record was not seeded", %{record: key})}

  defp workflow_auth(_seed, _scenario, %{auth: :none}, _state), do: {:ok, :none}
  defp workflow_auth(_seed, _scenario, %{auth: :admin}, _state), do: {:ok, :admin}
  defp workflow_auth(seed, scenario, op, state), do: auth(seed, scenario, op, state)

  defp params(params, ledger) do
    Enum.reduce_while(Enum.sort(params), {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case encode_param(value, ledger) do
        {:ok, json} -> {:cont, {:ok, Map.put(acc, name, json)}}
        error -> {:halt, error}
      end
    end)
  end

  defp encode_param(nil, _ledger), do: {:ok, nil}
  defp encode_param(value, ledger), do: Codec.encode(value, ledger)

  defp sort(_names, %{sort: nil}), do: {:ok, nil}

  defp sort(names, %{sort: %{field: field, descending: desc}, type: type}) do
    with {:ok, key} <- Names.field_key(names, type, field),
         do: {:ok, %{key: key, descending: desc}}
  end

  defp get_observations(names, seed, op, answer, ledger) do
    record = Seed.record(seed, op.record)

    {visible, fields} =
      case answer do
        {:found, body} -> {true, decode_fields(names, op.type, body, record, ledger)}
        :not_found -> {false, %{}}
      end

    Enum.map(op.observe, fn
      :visible ->
        %Observation{op: op.id, kind: :visible, record: op.record, value: visible}

      :visible_fields ->
        %Observation{
          op: op.id,
          kind: :visible_fields,
          record: op.record,
          value: fields |> Map.keys() |> Enum.sort()
        }

      :values ->
        %Observation{op: op.id, kind: :values, record: op.record, value: fields}
    end)
  end

  # Data API keys to field IDs (unmapped keys and `_id` are left out) and
  # their values.
  defp decode_fields(names, type, body, record, ledger) do
    hints = if record, do: record.fields, else: %{}

    for {key, raw} <- body,
        key != "_id",
        field = Names.field_id(names, type, key),
        field != nil,
        into: %{},
        do: {field, Codec.decode(raw, field, Map.get(hints, field), ledger)}
  end

  # --- assembly -------------------------------------------------------------------------

  defp build(scenario, seed, runs, planned, class, client, secrets) do
    per_run = Enum.map(runs, & &1.observed[scenario.id])
    calls = per_run |> Enum.map(&elem(&1, 2)) |> Enum.sum()
    failed = Enum.find(per_run, &match?({:error, _, _}, &1))

    {observations, masks, unstable, incomplete} =
      cond do
        failed != nil ->
          first = with {:ok, obs, _} <- hd(per_run), do: obs
          obs = if is_list(first), do: first, else: []
          {obs, [], [], failure(elem(failed, 1))}

        length(runs) < planned ->
          [{:ok, obs, _} | _] = per_run
          {obs, [], [], :runs_missing}

        true ->
          merged = Differential.merge(Enum.map(per_run, &elem(&1, 1)), class)
          why = if merged.unstable == [], do: nil, else: :unstable
          {merged.observations, merged.masks, merged.unstable, why}
      end

    first = hd(runs)

    attrs = [
      oracle: :bubble,
      source: %{app: client.target.app, branch: client.target.branch},
      recorded_at: first.started,
      t0: DateTime.to_unix(first.started, :millisecond),
      runs: length(runs),
      complete: incomplete == nil,
      masks: masks,
      observations: observations,
      stats: %{calls: calls, workload_units: nil}
    ]

    base = %{id: scenario.id, incomplete: incomplete, unstable: unstable, refused: nil}

    with {:ok, recording} <- Recording.for_scenario(scenario, seed, attrs),
         :ok <- Recording.check_scenario(recording, scenario),
         json = Recording.to_json(recording),
         :ok <- CredentialScan.check(json, secrets) do
      share = Differential.masked_share(%{observations: observations, masks: masks})
      Map.merge(base, %{recording: recording, json: json, share: share})
    else
      {:error, %Error{} = error} ->
        Map.merge(base, %{recording: nil, json: nil, share: 0.0, refused: error_summary(error)})
    end
  end

  defp failure(:seeding_failed), do: :seeding_failed
  defp failure(%Error{context: %{reason: :budget_exhausted}}), do: :budget_exhausted
  defp failure(%Error{kind: kind}), do: kind

  # --- calibration -----------------------------------------------------------------------

  defp calibration(seed, scenarios, opts) do
    deps = Keyword.get(opts, :dependencies, %{})
    deleted = MapSet.new(Keyword.get(opts, :delete_after_seed, []))
    dangling = dangling_holders(seed, deleted)

    for s <- scenarios,
        op <- s.ops,
        flags = flags(s, op, seed, deps, dangling),
        flags != [] do
      %{scenario: s.id, op: op.id, flags: flags, observes: op.observe}
    end
  end

  defp flags(s, op, seed, deps, dangling) do
    persona_user =
      seed.personas |> Map.get(Map.get(op, :persona) || s.persona, %{}) |> Map.get(:user)

    dangles? =
      MapSet.member?(dangling, Map.get(op, :record)) or
        MapSet.member?(dangling, persona_user) or
        (op.op == :search and
           Enum.any?(seed.records, &(&1.type == op.type and MapSet.member?(dangling, &1.key))))

    (Map.get(deps, {s.id, op.id}, []) ++ if(dangles?, do: [:dangling_ref_is_empty], else: []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Records (still live) holding a reference to a deleted one.
  defp dangling_holders(seed, deleted) do
    for r <- seed.records,
        not MapSet.member?(deleted, r.key),
        Enum.any?(r.fields, fn {_, v} ->
          Enum.any?(Value.refs(v), &MapSet.member?(deleted, &1))
        end),
        into: MapSet.new(),
        do: r.key
  end
end
