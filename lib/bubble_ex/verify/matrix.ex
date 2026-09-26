defmodule BubbleEx.Verify.Matrix do
  @moduledoc """
  Privacy-matrix synthesis (V2 of the WTF-358 verification proposal, §3.2
  and §7): from an app's Model, the personas, seed records, `privacy_read`
  scenarios and expected `model`-oracle recordings that exercise every
  privacy rule, plus a coverage report.

      {:ok, matrix} = BubbleEx.Verify.Matrix.synthesize(model, app: "acme")
      matrix.seed          # BubbleEx.Verify.Seed
      matrix.scenarios     # [BubbleEx.Verify.Scenario]
      matrix.recordings    # [BubbleEx.Verify.Recording], oracle: model
      matrix.report        # coverage (see report/1)
      BubbleEx.Verify.Matrix.files(matrix)   # [{".wtf/verification/…", json}]

  ## Algorithm

  1. **Rules.** Every privacy-rule condition is compiled to IR and checked
     for what the interpreter evaluates (`BubbleEx.Verify.Interpreter`).
  2. **Personas** (`BubbleEx.Verify.Matrix.Personas`): anonymous, a
     logged-in user with no values, two members of world 1 (different
     role option), a member of world 2 and an admin-like user; every field
     chain a condition reads from `Current User` is given values, through
     persona-owned records (a role) and per-world anchors (a workspace).
  3. **Records.** Every covered type gets one record with every field
     empty. Then, for each supported rule in Model order: if no persona
     and record make its condition true, the solver
     (`BubbleEx.Verify.Matrix.Solver`) builds a record that does, for the
     first persona it can (members, then admin, then the empty user, then
     anonymous), chains included; the same for false. So each rule's true
     and false branches are exercised by some cell. A false branch is
     first sought where it holds without the fail-safe actor guard (a cell
     false only because the user is logged out says nothing about the
     condition); the `everyone` rule gets a cell where it applies and one
     where it does not, computed as the verdicts compute it
     (`Interpreter.everyone_applies/5`).
  4. **Observability and assumptions** (`BubbleEx.Verify.Matrix.Coverage`):
     records that make masked rules decide a verdict alone (mutation
     coverage: dropping or negating the rule changes a recorded verdict),
     and records whose verdict depends on each assumption flag, so V5 has
     something to calibrate.
  5. **Scenarios**, one per (type, persona): a `search` of the type and a
     `get` of each of its records, observing `record_set`, `visible` and
     `visible_fields`. An op whose verdict an unsupported rule could decide
     is left out (the report counts it).
  6. **Recordings**: the interpreter's verdicts under the chosen
     assumptions, oracle `model` (never Bubble-verified, decision D2 on
     WTF-358). `dependencies` holds, per scenario op, the assumption flags
     its expected observations depend on.

  A rule is **solved** when the interpreter evaluates it and the seed has a
  cell (persona, record) where its condition holds and one where it does
  not; the `everyone` rule when the type's other rules are all supported
  and it both applies (no other rule holds) and does not somewhere (or,
  alone, applies). Deleted types, types whose rules the source lacks, and
  unsupported rules are listed with reasons.

  **Observable** is the stronger measure (`report.rules.observable`,
  `report.unobservable`): a solved rule can still decide nothing (it grants
  nothing, or other rules grant the same wherever it holds).

  Text values come from synthetic placeholders; a condition's own text
  literal is used only where a branch needs exactly it (equality,
  containment), and `report.seed_values_from_condition_literals` counts
  those seed values. Numbers compared by ordering take values either side
  of the literal.

  The expectations rest on the shared expression compiler: see
  `BubbleEx.Verify.Interpreter` ("scope of the cross-check") and
  `report.oracle_scope`.

  Output is deterministic: the same Model and options give the same
  documents. Seeds are synthetic (reserved-domain emails), keyed by symbolic
  keys and Bubble IDs, with canonical values.

  ## Options

    * `:app` - the Bubble app ID for the recordings' source (default: the
      Model's `bubble_id`)
    * `:seed_id` - default `"privacy_matrix"`
    * `:assumptions` - overrides of `BubbleEx.Verify.Interpreter.Assumptions`
    * `:recorded_at` (DateTime) and `:t0` (ms) of the recordings, default the
      Unix epoch (pass the run's time; the default keeps output reproducible)
    * `:bubble_ex` - the interpreter version in the recordings' source,
      default this library's
  """

  alias BubbleEx.{CanonicalJson, Error, Model}
  alias BubbleEx.Expression.IR
  alias BubbleEx.Model.Type
  alias BubbleEx.Verify.{Observation, Recording, Replay, Scenario, Seed}
  alias BubbleEx.Verify.Interpreter
  alias BubbleEx.Verify.Interpreter.{Assumptions, Dataset}
  alias BubbleEx.Verify.Matrix.{Coverage, Personas, Solver}

  @enforce_keys [:seed, :assumptions]
  defstruct [
    :seed,
    :assumptions,
    scenarios: [],
    recordings: [],
    dependencies: %{},
    rules: [],
    observability: [],
    flags: %{},
    joint: %{},
    skipped: %{gets: 0, searches: 0},
    report: %{}
  ]

  @type rule_status :: :solved | {:unsolved, atom(), String.t()}
  @type t :: %__MODULE__{
          seed: Seed.t(),
          assumptions: Assumptions.t(),
          scenarios: [Scenario.t()],
          recordings: [Recording.t()],
          dependencies: %{{String.t(), String.t()} => [atom()]},
          rules: [map()],
          observability: [map()],
          flags: %{atom() => :exercised | {:not_exercised, String.t()}},
          joint: %{atom() => %{atom() => pos_integer()}},
          skipped: %{gets: non_neg_integer(), searches: non_neg_integer()},
          report: map()
        }

  @solve_order ~w(w1_member w1_other w2_member admin logged_in_empty anonymous)

  @doc "Synthesizes the privacy matrix of `model`. See the moduledoc."
  @spec synthesize(Model.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def synthesize(model, opts \\ [])

  def synthesize(%Model{} = model, opts) do
    with {:ok, app} <- Replay.app(Keyword.get(opts, :app, model.bubble_id)),
         {:ok, interpreter} <-
           Interpreter.new(model, assumptions: Keyword.get(opts, :assumptions, [])) do
      {personas, ds} = Personas.build(interpreter)
      types = matrix_types(interpreter)

      ds =
        types
        |> Enum.reduce(ds, &empty_record/2)
        |> witnesses(interpreter, types, personas)
        |> then(&Coverage.isolate(interpreter, &1, personas))
        |> then(&Coverage.exercise_flags(interpreter, &1, personas))

      rules = coverage(interpreter, ds, personas)
      observability = Coverage.observability(interpreter, ds, personas, rules)

      with {:ok, seed} <- seed(Keyword.get(opts, :seed_id, "privacy_matrix"), personas, ds),
           {:ok, built} <- scenarios(interpreter, ds, personas, seed, types, app, opts) do
        {:ok, assemble(interpreter, ds, personas, seed, built, rules, observability)}
      end
    end
  end

  def synthesize(_, _), do: {:error, Error.new(:invalid_input, "expected a BubbleEx.Model")}

  defp assemble(interpreter, ds, personas, seed, built, rules, observability) do
    matrix = %__MODULE__{
      seed: seed,
      assumptions: interpreter.assumptions,
      scenarios: built.scenarios,
      recordings: built.recordings,
      dependencies: built.dependencies,
      skipped: built.skipped,
      rules: rules,
      observability: observability,
      flags: Coverage.flag_outcomes(interpreter, built.dependencies)
    }

    unexercised = for {flag, {:not_exercised, _}} <- matrix.flags, do: flag
    matrix = %{matrix | joint: Coverage.joint(interpreter, ds, personas, unexercised)}

    %{matrix | report: report(matrix, interpreter)}
  end

  defp matrix_types(interpreter) do
    for {id, %{status: status}} <- Enum.sort(interpreter.types),
        status in [:rules, :public],
        do: id
  end

  defp empty_record(type_id, ds),
    do: Dataset.put(ds, "e.#{Personas.slug(type_id)}", type_id, %{})

  # --- witnesses --------------------------------------------------------------------

  defp witnesses(ds, interpreter, types, personas) do
    ds =
      for type_id <- types,
          %{status: :rules, rules: rules} <- [Interpreter.type(interpreter, type_id)],
          %{status: :ok} = info <- rules,
          target <- [true, false],
          reduce: ds,
          do: (ds -> ensure(ds, interpreter, info, type_id, personas, target))

    # The everyone rule: a cell where it applies (no other rule holds, as
    # the verdicts compute it, record-value guard included) and one where
    # it does not.
    for type_id <- types,
        %{status: :rules, default: %{}, rules: [_ | _] = rules} <- [
          Interpreter.type(interpreter, type_id)
        ],
        Enum.all?(rules, &(&1.status == :ok)),
        target <- [true, false],
        reduce: ds,
        do: (ds -> ensure_everyone(ds, interpreter, rules, type_id, personas, target))
  end

  defp ensure_everyone(ds, interpreter, rules, type_id, personas, target) do
    applies? = fn ds, user, key ->
      Interpreter.everyone_applies(interpreter, ds, user, type_id, key) == target
    end

    found? =
      Enum.any?(Enum.sort(personas), fn {_, u} ->
        Enum.any?(Dataset.keys(ds, type_id), &applies?.(ds, u, &1))
      end)

    if found?,
      do: ds,
      else:
        first_found(personas, ds, fn user ->
          Solver.find(interpreter, ds, type_id, &applies?.(&1, user, &2),
            irs: Enum.map(rules, & &1.ir)
          )
        end)
  end

  # The dataset of the first persona (in solve order) for which `solve`
  # finds a record, or `default`.
  defp first_found(personas, default, solve) do
    Enum.find_value(@solve_order, default, fn persona ->
      case solve.(personas[persona]) do
        {:ok, ds, _key} -> ds
        :none -> nil
      end
    end)
  end

  # A false branch that holds only through the fail-safe actor guard
  # (`actor_empty_denies`) says nothing about the condition itself: look
  # for a false cell that stays false with the guard off, first.
  defp ensure(ds, interpreter, info, type_id, personas, false) do
    unguarded = unguarded(interpreter)

    if robust_false?(ds, interpreter, unguarded, info, type_id, personas) do
      ds
    else
      first_found(personas, nil, fn user ->
        goal = &false_either_way?(interpreter, unguarded, info, &1, user, &2)
        Solver.find(interpreter, ds, type_id, goal, irs: [info.ir], empty_first: true)
      end) || plain_ensure(ds, interpreter, info, type_id, personas, false)
    end
  end

  defp ensure(ds, interpreter, info, type_id, personas, target),
    do: plain_ensure(ds, interpreter, info, type_id, personas, target)

  defp unguarded(interpreter),
    do: %{interpreter | assumptions: %{interpreter.assumptions | actor_empty_denies: false}}

  defp robust_false?(ds, interpreter, unguarded, info, type_id, personas) do
    Enum.any?(Enum.sort(personas), fn {_, user} ->
      Enum.any?(
        Dataset.keys(ds, type_id),
        &false_either_way?(interpreter, unguarded, info, ds, user, &1)
      )
    end)
  end

  defp false_either_way?(interpreter, unguarded, info, ds, user, key) do
    match?({false, _}, Interpreter.eval_rule(interpreter, info, ds, user, key)) and
      match?({false, _}, Interpreter.eval_rule(unguarded, info, ds, user, key))
  end

  defp plain_ensure(ds, interpreter, info, type_id, personas, target) do
    if target in cells(ds, interpreter, info, type_id, personas),
      do: ds,
      else:
        Enum.find_value(
          @solve_order,
          ds,
          &solved(interpreter, info, ds, type_id, personas[&1], target)
        )
  end

  defp solved(interpreter, info, ds, type_id, user, target) do
    case Solver.solve(interpreter, info, ds, type_id, user, target) do
      {:ok, ds, _key} -> ds
      :none -> nil
    end
  end

  # The condition's value for every (persona, record of the type).
  defp cells(ds, interpreter, info, type_id, personas) do
    for {_persona, user} <- Enum.sort(personas),
        key <- Dataset.keys(ds, type_id),
        {b, _flags} when is_boolean(b) <- [
          Interpreter.eval_rule(interpreter, info, ds, user, key)
        ],
        uniq: true,
        do: b
  end

  # --- coverage --------------------------------------------------------------------

  defp coverage(interpreter, ds, personas) do
    for {type_id, info} <- Enum.sort(interpreter.types),
        rule <- info.type.rules do
      status = rule_status(info, rule, interpreter, ds, personas)

      %{
        type: type_id,
        rule: rule.id,
        default: rule.default?,
        status: status,
        robust_false: robust_false(status, rule, info, interpreter, ds, personas)
      }
    end
  end

  # Whether a solved conditional rule has a false cell that does not rest
  # on the fail-safe actor guard (nil for other rules).
  defp robust_false(:solved, %{default?: false} = rule, info, interpreter, ds, personas) do
    rinfo = Enum.find(info.rules, &(&1.rule.id == rule.id))
    robust_false?(ds, interpreter, unguarded(interpreter), rinfo, info.type.id, personas)
  end

  defp robust_false(_status, _rule, _info, _interpreter, _ds, _personas), do: nil

  defp rule_status(%{status: {:unknown, reason}} = info, _rule, _i, _ds, _p),
    do: {:unsolved, if(info.type.deleted, do: :deleted_type, else: :privacy_unavailable), reason}

  defp rule_status(info, %{default?: true}, interpreter, ds, personas) do
    case Enum.find(info.rules, &(&1.status != :ok)) do
      %{rule: rule} ->
        {:unsolved, :blocked_by_unsupported_rule, "rule #{rule.id} is unsupported"}

      nil ->
        everyone_status(info, interpreter, ds, personas)
    end
  end

  defp rule_status(info, rule, interpreter, ds, personas) do
    rinfo = Enum.find(info.rules, &(&1.rule.id == rule.id))

    case rinfo.status do
      {:unsupported, "no condition"} ->
        {:unsolved, :missing_condition, "no condition"}

      {:unsupported, "not compiled: " <> _ = why} ->
        {:unsolved, :not_compiled, why}

      {:unsupported, why} ->
        {:unsolved, :unsupported, why}

      :ok ->
        values = cells(ds, interpreter, rinfo, info.type.id, personas)

        cond do
          true not in values ->
            {:unsolved, :no_true_witness, "no persona and record make it hold"}

          false not in values ->
            {:unsolved, :no_false_witness, "every persona and record make it hold"}

          true ->
            :solved
        end
    end
  end

  # The everyone rule applies where no other rule holds.
  defp everyone_status(%{rules: []} = info, _interpreter, ds, _personas) do
    if Dataset.keys(ds, info.type.id) != [],
      do: :solved,
      else: {:unsolved, :no_true_witness, "no records"}
  end

  defp everyone_status(info, interpreter, ds, personas) do
    # The same computation the verdicts use (negated conditions, guards).
    applies =
      for {_persona, user} <- Enum.sort(personas),
          key <- Dataset.keys(ds, info.type.id),
          uniq: true,
          do: Interpreter.everyone_applies(interpreter, ds, user, info.type.id, key)

    cond do
      true not in applies -> {:unsolved, :no_true_witness, "another rule always holds"}
      false not in applies -> {:unsolved, :no_false_witness, "no other rule ever holds"}
      true -> :solved
    end
  end

  # --- seed ----------------------------------------------------------------------------

  defp seed(id, personas, ds) do
    Seed.new(
      id: id,
      personas: Map.new(personas, fn {p, user} -> {p, %{user: user}} end),
      records:
        for {key, r} <- Enum.sort(ds.records) do
          %{key: key, type: Type.record(r.type), fields: r.fields}
        end
    )
  end

  # --- scenarios and recordings ----------------------------------------------------------

  defp scenarios(interpreter, ds, personas, seed, types, app, opts) do
    seed_ref = %{id: seed.id, sha256: Seed.sha256(seed)}
    t0 = Keyword.get(opts, :t0, 0)

    common = %{
      app: app,
      version: Keyword.get_lazy(opts, :bubble_ex, &version/0),
      recorded_at:
        Keyword.get_lazy(opts, :recorded_at, fn -> DateTime.from_unix!(t0, :millisecond) end),
      t0: t0
    }

    acc = %{scenarios: [], recordings: [], dependencies: %{}, skipped: %{gets: 0, searches: 0}}

    sources = Map.new(types, &{&1, source_sha256(interpreter, &1)})

    pairs =
      for type_id <- types, {persona, user} <- Enum.sort(personas), do: {type_id, persona, user}

    result =
      Enum.reduce_while(pairs, {:ok, acc}, fn {type_id, persona, user}, {:ok, acc} ->
        cell = %{type: type_id, persona: persona, user: user, source: sources[type_id]}

        case scenario(interpreter, ds, seed, seed_ref, cell, common) do
          {:ok, built} -> {:cont, {:ok, merge(acc, built)}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, acc} <- result do
      {:ok,
       %{
         acc
         | scenarios: Enum.sort_by(acc.scenarios, & &1.id),
           recordings: Enum.sort_by(acc.recordings, & &1.scenario.id)
       }}
    end
  end

  defp merge(acc, built) do
    %{
      scenarios: built.scenarios ++ acc.scenarios,
      recordings: built.recordings ++ acc.recordings,
      dependencies: Map.merge(acc.dependencies, built.dependencies),
      skipped: %{
        gets: acc.skipped.gets + built.skipped.gets,
        searches: acc.skipped.searches + built.skipped.searches
      }
    }
  end

  defp scenario(interpreter, ds, seed, seed_ref, cell, common) do
    descriptor = Type.record(cell.type)
    id = "privacy_read.#{descriptor}.#{cell.persona}"
    {checks, skipped} = checks(interpreter, ds, cell, descriptor)
    empty = %{scenarios: [], recordings: [], dependencies: %{}, skipped: skipped}

    if checks == [],
      do: {:ok, empty},
      else: build(interpreter, seed, seed_ref, cell, common, {id, descriptor, checks, empty})
  end

  defp build(interpreter, seed, seed_ref, cell, common, {id, descriptor, checks, empty}) do
    rules =
      for r <- Interpreter.type(interpreter, cell.type).type.rules, do: "#{descriptor}/#{r.id}"

    with {:ok, scenario} <-
           Scenario.new(
             id: id,
             kind: :privacy_read,
             check: "privacy_read",
             seed: seed_ref,
             persona: cell.persona,
             subjects: %{type: descriptor},
             ops: Enum.map(checks, & &1.op),
             covers: %{rules: rules},
             source_sha256: cell.source
           ),
         {:ok, recording} <-
           Recording.for_scenario(scenario, seed,
             oracle: :model,
             source: %{app: common.app, bubble_ex: common.version},
             recorded_at: common.recorded_at,
             t0: common.t0,
             runs: 1,
             complete: true,
             observations: Enum.flat_map(checks, & &1.observations)
           ) do
      dependencies =
        for c <- checks, c.assumptions != [], into: %{}, do: {{id, c.op.id}, c.assumptions}

      {:ok, %{empty | scenarios: [scenario], recordings: [recording], dependencies: dependencies}}
    end
  end

  # The decided ops of one (type, persona): a search, then a get per
  # record, each with its expected observations and the assumptions they
  # depend on; and how many were left out as undecided.
  defp checks(interpreter, ds, cell, descriptor) do
    {:ok, search} = Interpreter.search(interpreter, ds, cell.user, cell.type)

    {known, unknown} =
      ds
      |> Dataset.keys(cell.type)
      |> Enum.map(fn key ->
        {:ok, access} = Interpreter.access(interpreter, ds, cell.user, key)
        access
      end)
      |> Enum.split_with(&Interpreter.determined?/1)

    searches = if search.unknown == [], do: [search_check(search, descriptor)], else: []
    gets = Enum.map(known, &get_check(&1, descriptor))
    {searches ++ gets, %{gets: length(unknown), searches: 1 - length(searches)}}
  end

  defp search_check(search, descriptor) do
    %{
      op: %{id: "search", op: :search, type: descriptor, sort: nil, observe: [:record_set]},
      observations: [
        %Observation{
          op: "search",
          kind: :record_set,
          value: %{ordered: false, records: Enum.sort(search.records)}
        }
      ],
      assumptions: search.assumptions
    }
  end

  defp get_check(access, descriptor) do
    op = "get." <> access.record

    %{
      op: %{
        id: op,
        op: :get,
        type: descriptor,
        record: access.record,
        observe: [:visible, :visible_fields]
      },
      observations: [
        %Observation{op: op, kind: :visible, record: access.record, value: access.visible},
        %Observation{
          op: op,
          kind: :visible_fields,
          record: access.record,
          value: Enum.sort(access.fields)
        }
      ],
      assumptions: access.assumptions
    }
  end

  # What a scenario's expectations are computed from: the type's fields and
  # its rules (compiled conditions, without source paths, and permissions).
  defp source_sha256(interpreter, type_id) do
    info = Interpreter.type(interpreter, type_id)

    CanonicalJson.sha256(%{
      "type" => type_id,
      "privacy" => Atom.to_string(info.type.privacy),
      "field_ids" => Enum.map(info.fields, & &1.id),
      "rules" =>
        for rule <- info.type.rules do
          compiled = Enum.find(info.rules, &(&1.rule.id == rule.id))

          %{
            "id" => rule.id,
            "condition" =>
              compiled && compiled.ir && compiled.ir |> IR.strip_paths() |> IR.to_map(),
            "permissions" => permissions(rule.permissions)
          }
        end
    })
  end

  defp permissions(nil), do: nil

  defp permissions(perms) do
    perms
    |> Map.from_struct()
    |> Map.delete(:extra)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp version, do: :bubble_ex |> Application.spec(:vsn) |> to_string()

  # --- report --------------------------------------------------------------------------

  @doc """
  The coverage report of a matrix (also in `matrix.report`):

    * `rules` - `total`, `conditional`, `everyone`, `solved`, `unsolved`,
      `solved_percent` (of all rules, one decimal), `observable`,
      `observable_percent` (mutation coverage) and
      `false_branch_only_via_actor_guard` (solved rules whose only false
      cells rest on the fail-safe actor guard)
    * `unobservable` / `unobservable_by_reason` - rules no mutant changes a
      recorded verdict of: `unsolved`, `grants_nothing`, `masked`,
      `undecided_type`
    * `seed_values_from_condition_literals`, `oracle_scope`
    * `unsolved` - `%{type, rule, reason, detail}` per unsolved rule
      (Bubble IDs); `unsolved_by_reason` counts them
    * `types` - `total`, `with_rules`, `public`, `deleted`, `unavailable`
    * `personas`, `records`, `scenarios`, `checks` (ops: one per search and
      per get), `observations`, `skipped` (ops left out as undetermined)
    * `assumptions` - the assumptions in force, per flag the number of ops
      whose expectations depend on it (`dependent_checks`), and per flag
      whether some check depends on it and if not why (`outcomes`); for
      flags a fail-safe hedge hides, the checks that depend on them with
      the hedge lifted (`jointly_dependent_checks`)
  """
  @spec report(t(), Interpreter.t()) :: map()
  def report(%__MODULE__{} = matrix, %Interpreter{} = interpreter) do
    unsolved =
      for %{status: {:unsolved, reason, detail}} = r <- matrix.rules,
          do: %{type: r.type, rule: r.rule, reason: reason, detail: detail}

    unobservable =
      for %{status: {:unobservable, reason, detail}} = r <- matrix.observability,
          do: %{type: r.type, rule: r.rule, reason: reason, detail: detail}

    total = length(matrix.rules)
    solved = total - length(unsolved)
    observable = total - length(unobservable)
    infos = Map.values(interpreter.types)

    %{
      rules: %{
        total: total,
        conditional: Enum.count(matrix.rules, &(not &1.default)),
        everyone: Enum.count(matrix.rules, & &1.default),
        solved: solved,
        unsolved: length(unsolved),
        solved_percent: percent(solved, total),
        observable: observable,
        observable_percent: percent(observable, total),
        false_branch_only_via_actor_guard: Enum.count(matrix.rules, &(&1[:robust_false] == false))
      },
      unsolved: unsolved,
      unsolved_by_reason: Enum.frequencies_by(unsolved, &Atom.to_string(&1.reason)),
      unobservable: unobservable,
      unobservable_by_reason: Enum.frequencies_by(unobservable, &Atom.to_string(&1.reason)),
      types: %{
        total: length(infos),
        with_rules: Enum.count(infos, &(&1.status == :rules)),
        public: Enum.count(infos, &(&1.status == :public)),
        deleted: Enum.count(infos, & &1.type.deleted),
        unavailable:
          Enum.count(infos, &(not &1.type.deleted and match?({:unknown, _}, &1.status)))
      },
      seed_values_from_condition_literals: literal_values(matrix.seed, interpreter),
      oracle_scope:
        "model: expectations from the interpreter over the shared expression compiler's IR; " <>
          "agreement with the Ash policies covers IR-to-Ash lowering and the policy generator, " <>
          "not the compiler (typing, lowering to IR); never Bubble-verified",
      personas: map_size(matrix.seed.personas),
      records: length(matrix.seed.records),
      scenarios: length(matrix.scenarios),
      checks: matrix.scenarios |> Enum.map(&length(&1.ops)) |> Enum.sum(),
      observations: matrix.recordings |> Enum.map(&length(&1.observations)) |> Enum.sum(),
      skipped: matrix.skipped,
      assumptions: %{
        in_force: Assumptions.to_map(matrix.assumptions),
        changed: Assumptions.changed(matrix.assumptions),
        outcomes: Map.new(matrix.flags, &outcome(&1, matrix.joint)),
        jointly_dependent_checks:
          Map.new(matrix.joint, fn {flag, partners} ->
            {Atom.to_string(flag), Map.new(partners, fn {p, n} -> {Atom.to_string(p), n} end)}
          end),
        dependent_checks:
          matrix.dependencies
          |> Map.values()
          |> List.flatten()
          |> Enum.frequencies()
          |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      }
    }
  end

  defp outcome({flag, :exercised}, _joint), do: {Atom.to_string(flag), "exercised"}

  defp outcome({flag, {:not_exercised, why}}, joint) do
    case joint[flag] do
      nil ->
        {Atom.to_string(flag), "not exercised: " <> why}

      partners ->
        with_ = Enum.map_join(Enum.sort(partners), ", ", fn {p, n} -> "#{p} (#{n} checks)" end)
        {Atom.to_string(flag), "exercised only jointly with " <> with_}
    end
  end

  defp percent(_n, 0), do: 100.0
  defp percent(n, total), do: Float.round(n * 100 / total, 1)

  # Seed text values that equal a text literal of some condition: kept
  # only where a branch needs exactly them (the solver and personas prefer
  # synthetic values); counted so the owner sees them.
  defp literal_values(seed, interpreter) do
    literals =
      for {_, %{rules: rules}} <- interpreter.types,
          %{status: :ok, ir: ir} <- rules,
          text <- texts(ir),
          into: MapSet.new(),
          do: text

    seed.records
    |> Enum.flat_map(fn r -> Map.values(r.fields) end)
    |> Enum.flat_map(fn
      {:list, items} -> items
      v -> [v]
    end)
    |> Enum.count(
      &(match?({:text, t} when is_binary(t), &1) and MapSet.member?(literals, elem(&1, 1)))
    )
  end

  defp texts(%IR{op: :literal, args: [v]}) when is_binary(v), do: [v]
  defp texts(%IR{args: args}), do: Enum.flat_map(args, &texts/1)
  defp texts(list) when is_list(list), do: Enum.flat_map(list, &texts/1)
  defp texts(_), do: []

  @doc """
  The report without Bubble IDs (counts only), as JSON-ready string-keyed
  maps: what a committed snapshot of a private app may hold.
  """
  @spec counts(map()) :: map()
  def counts(report) do
    report
    |> Map.drop([:unsolved, :unobservable])
    |> Map.update!(:assumptions, &Map.drop(&1, [:in_force]))
    |> stringify()
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: Atom.to_string(atom)

  defp stringify(v), do: v

  # --- results ---------------------------------------------------------------------------

  @doc """
  A `privacy_read` `BubbleEx.Verify.Result` comparing a subject's
  `observations` of `scenario` (e.g. a target app's replay, V3) with the
  expected `model` recording: `pass` when every expected observation is
  matched, else `fail` with a diff (`record_visible`, `field_visible` per
  field, `record_set`). The oracle and evidence cite the recording, so
  `Result.evaluate/3` can count it as passing, never as Bubble-verified.

  ## Options

    * `:app` (required), `:ran_at` (required, DateTime)
    * `:actor` - default `"ci"`
    * `:ref` - the recording's evidence path, default
      `.wtf/verification/recordings/<scenario id>.json`
  """
  @spec result(Scenario.t(), Recording.t(), [Observation.t()], keyword()) ::
          {:ok, BubbleEx.Verify.Result.t()} | {:error, Error.t()}
  def result(%Scenario{} = scenario, %Recording{oracle: :model} = recording, observations, opts) do
    actual = Map.new(observations, &{Observation.key(&1), &1.value})
    sha = Recording.sha256(recording)

    diff =
      Enum.flat_map(
        recording.observations,
        &diff(&1, Map.get(actual, Observation.key(&1), :missing))
      )

    BubbleEx.Verify.Result.new(
      id: scenario.id,
      app: Keyword.fetch!(opts, :app),
      check: scenario.check,
      status: if(diff == [], do: :pass, else: :fail),
      subjects: scenario.subjects,
      scenario: %{
        id: scenario.id,
        sha256: Scenario.sha256(scenario),
        source_sha256: scenario.source_sha256,
        seed_sha256: recording.seed_sha256
      },
      oracle: %{kind: :model, sha256: sha, branch: nil},
      evidence: [
        %{
          kind: :recording,
          ref: Keyword.get(opts, :ref, ".wtf/verification/recordings/#{scenario.id}.json"),
          sha256: sha
        }
      ],
      diff: diff,
      actor: Keyword.get(opts, :actor, "ci"),
      ran_at: Keyword.fetch!(opts, :ran_at)
    )
  end

  def result(_scenario, _recording, _observations, _opts),
    do: {:error, Error.new(:invalid_input, "expected a scenario and its model recording")}

  defp diff(%Observation{value: v}, v), do: []

  # An unordered record set compares as a set.
  defp diff(%Observation{kind: :record_set, value: %{ordered: false} = v}, %{records: records})
       when is_list(records) do
    if Enum.sort(Enum.uniq(records)) == Enum.sort(v.records),
      do: [],
      else: [%{op: "record_set", expected: v.records, actual: records}]
  end

  defp diff(%Observation{kind: :visible, record: record, value: v}, actual),
    do: [%{op: "record_visible", record: record, expected: v, actual: present(actual)}]

  defp diff(%Observation{kind: :visible_fields, record: record, value: v}, actual) do
    got = if is_list(actual), do: actual, else: []

    for field <- Enum.sort(Enum.uniq(v ++ got)), field in v != field in got do
      %{
        op: "field_visible",
        record: record,
        field: field,
        expected: field in v,
        actual: field in got
      }
    end
  end

  defp diff(%Observation{kind: :record_set, value: v}, actual),
    do: [%{op: "record_set", expected: v.records, actual: if(is_map(actual), do: actual.records)}]

  defp present(:missing), do: nil
  defp present(v), do: v

  # --- files -----------------------------------------------------------------------------

  @doc """
  The matrix as owner-repo files (decision D6 on WTF-358), paths relative
  to the repository root: the seed, one scenario and one recording per
  (type, persona), and `.wtf/verification/interpreter/<seed id>.json` with
  the assumptions in force, the per-op dependencies and the coverage
  report.
  """
  @spec files(t()) :: [{String.t(), String.t()}]
  def files(%__MODULE__{} = matrix) do
    root = ".wtf/verification"

    [{"#{root}/seeds/#{matrix.seed.id}.json", Seed.to_json(matrix.seed)}] ++
      for(
        s <- matrix.scenarios,
        do: {"#{root}/scenarios/privacy_read/#{s.id}.json", Scenario.to_json(s)}
      ) ++
      for(
        r <- matrix.recordings,
        do: {"#{root}/recordings/#{r.scenario.id}.json", Recording.to_json(r)}
      ) ++
      [
        {"#{root}/interpreter/#{matrix.seed.id}.json",
         CanonicalJson.encode(interpreter_doc(matrix))}
      ]
  end

  defp interpreter_doc(matrix) do
    %{
      "format" => "bubble_ex.verify.interpreter",
      "seed" => %{"id" => matrix.seed.id, "sha256" => Seed.sha256(matrix.seed)},
      "assumptions" => Assumptions.to_map(matrix.assumptions),
      "dependencies" =>
        matrix.dependencies
        |> Enum.sort()
        |> Enum.map(fn {{scenario, op}, flags} ->
          %{
            "scenario" => scenario,
            "op" => op,
            "assumptions" => Enum.map(flags, &Atom.to_string/1)
          }
        end),
      "report" => stringify(matrix.report)
    }
  end
end
