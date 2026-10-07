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
     (`Interpreter.everyone_applies/5`) under the target's reading of its
     reach (exclusive, record values guarded): in Bubble's it reaches
     every user (WTF-467), but the generated policies negate the other
     rules.
  4. **Observability and assumptions** (`BubbleEx.Verify.Matrix.Coverage`):
     records that make masked rules decide a verdict alone (mutation
     coverage: dropping or negating the rule changes a recorded verdict),
     and records whose verdict depends on each assumption flag, so V5 has
     something to calibrate (up to three per type for the flags
     calibration has not settled, `Assumptions.unsettled/0`). Then every
     field a rule's permissions govern (listed, or all under "view all")
     that no condition reads and that has no default gets a synthetic
     value where a record leaves it empty, because the Data API omits
     empty fields: an empty governed field is a visibility no Bubble
     recording can check (`report.governed_fields` counts what is left).
  5. **Scenarios**, one per (type, persona): a `search` of the type, per
     field some rule keeps out of searches (non-filterable) a `search`
     constrained on it (`constrain`: a constraint every value meets, so
     only the records where the persona may search by it are found,
     `Interpreter.search/5`), and a `get` of each of its records,
     observing `record_set`, `visible` and `visible_fields`. An op whose verdict an unsupported rule could
     decide, under Bubble's reading or the target's, is left out (the
     report counts it).
  6. **Recordings**: the interpreter's verdicts under the chosen
     assumptions (by default Bubble's reading, as calibrated), oracle
     `model` (never Bubble-verified, decision D2 on WTF-358).
     `dependencies` holds, per scenario op, the assumption flags its
     expected observations depend on.
  7. **Intended differences** (`BubbleEx.Verify.Difference`, WTF-426):
     every observation where the generated policies' reading
     (`Interpreter.target/1`) is stricter than the recording by the
     owner's decision, with the flags and rules responsible
     (`differences`; a flag is responsible when its target reading alone
     changes Bubble's verdict, or the target's verdict needs it). An observation where the two readings differ
     otherwise (another flag, or less strict) is an *unintended*
     difference (`unintended`, counted in the report): the generated
     tests fail on it.

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
      (the defaults are Bubble's reading)
    * `:recorded_at` (DateTime) and `:t0` (ms) of the recordings, default the
      Unix epoch (pass the run's time; the default keeps output reproducible)
    * `:bubble_ex` - the interpreter version in the recordings' source,
      default this library's
  """

  alias BubbleEx.{CanonicalJson, Error, Model}
  alias BubbleEx.Expression.IR
  alias BubbleEx.Model.Type
  alias BubbleEx.Verify.{Difference, Observation, Recording, Replay, Scenario, Seed}
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
    differences: [],
    unintended: [],
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
          differences: [Difference.t()],
          unintended: [%{scenario: String.t(), op: String.t()}],
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
        |> fill_governed(interpreter, personas)

      rules = coverage(interpreter, ds, personas)
      observability = Coverage.observability(interpreter, ds, personas, rules)

      with {:ok, seed} <-
             seed(Keyword.get(opts, :seed_id, "privacy_matrix"), personas, ds, interpreter),
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
      differences: Difference.sort(built.differences),
      unintended: Enum.sort_by(built.unintended, &{&1.scenario, &1.op}),
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

  # --- governed fields ---------------------------------------------------------------

  # Fills the empty governed fields no condition reads (so no verdict
  # changes) with synthetic scalar values: the Data API shows only fields
  # that hold a value.
  # Persona users keep exactly the values their persona defines.
  defp fill_governed(ds, interpreter, personas) do
    users = personas |> Map.values() |> MapSet.new()
    read = condition_fields(interpreter)

    for {key, %{type: type_id, fields: fields}} <- Enum.sort(ds.records),
        not MapSet.member?(users, key),
        %{status: :rules} = info <- [Interpreter.type(interpreter, type_id)],
        field <- governed(info),
        not Map.has_key?(fields, field),
        unfilled(interpreter, read, type_id, field) == nil,
        {:ok, value} <- [synthetic(interpreter.model, type_id, field)],
        reduce: ds,
        do: (ds -> Dataset.set(ds, key, field, value))
  end

  # Why an empty governed field is left empty, or nil.
  defp unfilled(interpreter, read, type_id, field) do
    cond do
      MapSet.member?(read, field) -> :condition_reads
      Map.has_key?(Map.get(interpreter.defaults, type_id, %{}), field) -> :default
      synthetic(interpreter.model, type_id, field) == :none -> :no_synthetic_value
      true -> nil
    end
  end

  # Non-built-in fields some rule (or the everyone rule) lets someone view.
  defp governed(info) do
    builtin = for %{id: id, builtin: true} <- info.fields, into: MapSet.new(), do: id
    rules = Enum.map(info.rules, & &1.rule) ++ List.wrap(info.default)

    rules
    |> Enum.flat_map(fn
      %{permissions: %{view_all: true}} ->
        MapSet.to_list(info.field_ids)

      %{permissions: %{} = p} ->
        Enum.filter(p.view_fields || [], &MapSet.member?(info.field_ids, &1))

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(builtin, &1))
    |> Enum.sort()
  end

  # Every field ID a supported condition reads, on any type.
  defp condition_fields(interpreter) do
    for {_, %{rules: rules}} <- interpreter.types,
        %{ir: %IR{} = ir} <- rules,
        field <- ir_fields(ir),
        into: MapSet.new(),
        do: field
  end

  defp ir_fields(%IR{op: :field, args: [base, _type, field]}) when is_binary(field),
    do: [field | ir_fields(base)]

  defp ir_fields(%IR{args: args}), do: Enum.flat_map(args, &ir_fields/1)
  defp ir_fields(_), do: []

  defp synthetic(model, type_id, field) do
    with {:ok, %{type: %Type{} = type}} <- Model.field(model, type_id, field),
         {:ok, v} <- synthetic_value(model, type) do
      {:ok, if(type.cardinality == :many, do: {:list, [v]}, else: v)}
    else
      _ -> :none
    end
  end

  defp synthetic_value(_model, %Type{kind: :scalar, base: :text}), do: {:ok, {:text, "sample"}}
  defp synthetic_value(_model, %Type{kind: :scalar, base: :number}), do: {:ok, {:number, 1.0}}
  defp synthetic_value(_model, %Type{kind: :scalar, base: :boolean}), do: {:ok, {:boolean, true}}

  defp synthetic_value(_model, %Type{kind: :scalar, base: :date}),
    do: {:ok, {:date, 1_759_363_200_000}}

  defp synthetic_value(model, %Type{kind: :option, target: set}) do
    keys =
      case Model.option_set(model, set) do
        %{values: values} -> for v <- values, not v.deleted, is_binary(v.key), do: v.key
        _ -> []
      end

    case keys do
      [key | _] -> {:ok, {:option, key}}
      [] -> :none
    end
  end

  defp synthetic_value(_model, _type), do: :none

  # Governed field slots of the seed's records, how many hold a value,
  # and why the others are empty.
  defp governed_report(seed, interpreter) do
    read = condition_fields(interpreter)
    users = seed.personas |> Map.values() |> Enum.map(& &1.user) |> MapSet.new()

    slots =
      for r <- seed.records,
          type_id = Dataset.type_id(r.type),
          %{status: :rules} = info <- [Interpreter.type(interpreter, type_id)],
          field <- governed(info) do
        cond do
          r.fields[field] not in [nil, {:text, ""}, {:list, []}] -> :held
          Map.has_key?(r.fields, field) -> :explicitly_empty
          MapSet.member?(users, r.key) -> :persona
          true -> unfilled(interpreter, read, type_id, field) || :other
        end
      end

    unchecked = Enum.reject(slots, &(&1 == :held))

    %{
      slots: length(slots),
      held: length(slots) - length(unchecked),
      unchecked: length(unchecked),
      unchecked_by_reason:
        unchecked |> Enum.frequencies() |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    }
  end

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
    # it does not, as the target reads it (`exclusive/1`).
    interpreter = exclusive(interpreter)

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

  # A branch that holds only through how empty user-side values compare
  # (`actor_empty_denies`: a cell true only because an empty user value
  # equals an empty record value, or false only because the fail-safe
  # guard denies it) says nothing about the condition itself: look for a
  # cell with the same value under both readings, first. The cells where
  # the readings differ are the intended differences.
  defp ensure(ds, interpreter, info, type_id, personas, target) do
    other = other_reading(interpreter)

    if robust?(ds, interpreter, other, info, type_id, personas, target) do
      ds
    else
      first_found(personas, nil, fn user ->
        goal = &either_reading?(interpreter, other, info, &1, user, &2, target)
        Solver.find(interpreter, ds, type_id, goal, irs: [info.ir], empty_first: not target)
      end) || plain_ensure(ds, interpreter, info, type_id, personas, target)
    end
  end

  defp other_reading(interpreter),
    do: %{
      interpreter
      | assumptions: Assumptions.flip(interpreter.assumptions, :actor_empty_denies)
    }

  defp robust?(ds, interpreter, other, info, type_id, personas, target) do
    Enum.any?(Enum.sort(personas), fn {_, user} ->
      Enum.any?(
        Dataset.keys(ds, type_id),
        &either_reading?(interpreter, other, info, ds, user, &1, target)
      )
    end)
  end

  defp either_reading?(interpreter, other, info, ds, user, key, target) do
    match?({^target, _}, Interpreter.eval_rule(interpreter, info, ds, user, key)) and
      match?({^target, _}, Interpreter.eval_rule(other, info, ds, user, key))
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
        robust_false: robust(status, rule, info, interpreter, ds, personas, false),
        robust_true: robust(status, rule, info, interpreter, ds, personas, true)
      }
    end
  end

  # Whether a solved conditional rule has a `target` cell that does not
  # rest on how empty user-side values compare (nil for other rules).
  defp robust(:solved, %{default?: false} = rule, info, interpreter, ds, personas, target) do
    rinfo = Enum.find(info.rules, &(&1.rule.id == rule.id))
    other = other_reading(interpreter)
    robust?(ds, interpreter, other, rinfo, info.type.id, personas, target)
  end

  defp robust(_status, _rule, _info, _interpreter, _ds, _personas, _target), do: nil

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
    # The same computation the verdicts use (negated conditions, guards),
    # as the target reads it (`exclusive/1`).
    interpreter = exclusive(interpreter)

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

  # The everyone rule's branches are the target's: it applies only where
  # no rule lacking its grant holds, record-value guard included. In
  # Bubble's reading (WTF-467) it reaches every user and has no branch
  # left, but the generated policies negate the other rules, and the cells
  # where that negation fails are where they are stricter than Bubble.
  defp exclusive(%Interpreter{assumptions: %{everyone_exclusive: true}} = interpreter),
    do: interpreter

  defp exclusive(%Interpreter{} = interpreter) do
    target = Assumptions.target()
    flags = Map.take(target, [:everyone_exclusive, :everyone_guards_record_values])
    %{interpreter | assumptions: Map.merge(interpreter.assumptions, flags)}
  end

  # --- seed ----------------------------------------------------------------------------

  defp seed(id, personas, ds, interpreter) do
    Seed.new(
      id: id,
      personas: Map.new(personas, fn {p, user} -> {p, %{user: user}} end),
      records:
        for {key, r} <- Enum.sort(ds.records) do
          %{key: key, type: Type.record(r.type), fields: as_created(r, interpreter)}
        end
    )
  end

  # A record's fields as Bubble stores them after creation: a field it
  # omits holds its default (`defaults_applied_at_creation`), written out;
  # an explicitly empty field with a default stays `null` (the loader must
  # clear it); other empty fields are omitted. A default the interpreter
  # cannot express stays omitted (verdicts reading it are unknown).
  defp as_created(record, interpreter) do
    defaults = Map.get(interpreter.defaults, record.type, %{})
    set = Map.reject(record.fields, fn {f, v} -> is_nil(v) and not Map.has_key?(defaults, f) end)

    if interpreter.assumptions.defaults_applied_at_creation,
      do:
        Enum.reduce(defaults, set, fn
          {f, {:ok, v}}, acc -> Map.put_new(acc, f, v)
          {_f, :unmodeled}, acc -> acc
        end),
      else: set
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

    acc = %{
      scenarios: [],
      recordings: [],
      dependencies: %{},
      differences: [],
      unintended: [],
      skipped: %{gets: 0, searches: 0}
    }

    readings = readings(interpreter)

    sources = Map.new(types, &{&1, source_sha256(interpreter, &1)})

    pairs =
      for type_id <- types, {persona, user} <- Enum.sort(personas), do: {type_id, persona, user}

    result =
      Enum.reduce_while(pairs, {:ok, acc}, fn {type_id, persona, user}, {:ok, acc} ->
        cell = %{
          type: type_id,
          persona: persona,
          user: user,
          source: sources[type_id],
          readings: readings
        }

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
      differences: built.differences ++ acc.differences,
      unintended: built.unintended ++ acc.unintended,
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

    empty = %{
      scenarios: [],
      recordings: [],
      dependencies: %{},
      differences: [],
      unintended: [],
      skipped: skipped
    }

    if checks == [],
      do: {:ok, empty},
      else:
        build(
          interpreter,
          seed,
          seed_ref,
          Map.put(cell, :ds, ds),
          common,
          {id, descriptor, checks, empty}
        )
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
      # With defaults applied at creation the seed writes every modeled
      # default out: no recording can depend on that flag.
      unobservable =
        if interpreter.assumptions.defaults_applied_at_creation,
          do: [:defaults_applied_at_creation],
          else: []

      dependencies =
        for c <- checks,
            flags = c.assumptions -- unobservable,
            flags != [],
            into: %{},
            do: {{id, c.op.id}, flags}

      {differences, unintended} = differences(checks, id, cell, cell.ds)

      {:ok,
       %{
         empty
         | scenarios: [scenario],
           recordings: [recording],
           dependencies: dependencies,
           differences: differences,
           unintended: unintended
       }}
    end
  end

  # The decided ops of one (type, persona): a search, then a get per
  # record, each with its expected observations and the assumptions they
  # depend on; and how many were left out as undecided.
  # An op is decided when both Bubble's reading and the target's decide
  # it (an unsupported rule can leave either undecided).
  defp checks(interpreter, ds, cell, descriptor) do
    target = cell.readings.target
    {:ok, search} = Interpreter.search(interpreter, ds, cell.user, cell.type)
    {:ok, target_search} = Interpreter.search(target, ds, cell.user, cell.type)

    {known, unknown} =
      ds
      |> Dataset.keys(cell.type)
      |> Enum.map(fn key ->
        {:ok, access} = Interpreter.access(interpreter, ds, cell.user, key)
        {:ok, target_access} = Interpreter.access(target, ds, cell.user, key)
        {access, target_access}
      end)
      |> Enum.split_with(fn {a, t} ->
        Interpreter.determined?(a) and Interpreter.determined?(t)
      end)

    known = Enum.map(known, &elem(&1, 0))

    searches =
      if search.unknown == [] and target_search.unknown == [],
        do: [search_check(search, descriptor)],
        else: []

    fields = Interpreter.type(interpreter, cell.type).nonfilterable

    constrained =
      for {field, i} <- Enum.with_index(fields, 1),
          {:ok, s} = Interpreter.search(interpreter, ds, cell.user, cell.type, field),
          {:ok, t} = Interpreter.search(target, ds, cell.user, cell.type, field),
          s.unknown == [] and t.unknown == [],
          do: constrained_check(s, descriptor, field, i)

    gets = Enum.map(known, &get_check(&1, descriptor))

    {searches ++ constrained ++ gets,
     %{
       gets: length(unknown),
       searches: 1 + length(fields) - length(searches) - length(constrained)
     }}
  end

  defp search_check(search, descriptor) do
    %{
      verdict: {:search, search.records},
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

  # Op IDs are symbols; field IDs may hold spaces (built-in fields).
  defp constrained_check(search, descriptor, field, i) do
    op = "search.#{i}." <> String.replace(field, ~r/[^A-Za-z0-9_.:\-]/, "_")

    %{
      verdict: {:search, field, search.records},
      op: %{
        id: op,
        op: :search,
        type: descriptor,
        sort: nil,
        constrain: field,
        observe: [:record_set]
      },
      observations: [
        %Observation{
          op: op,
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
      verdict: {:get, access.record, access.visible, Enum.sort(access.fields)},
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

  # --- intended differences ------------------------------------------------------------

  # The three readings a cell is compared under: Bubble's (the matrix's
  # assumptions), the target's (the generated policies) and Bubble's with
  # only the policy's flags at their target reading.
  defp readings(interpreter) do
    {:ok, intended} =
      Interpreter.with_assumptions(interpreter, Difference.intended(interpreter.assumptions))

    # Per policy flag on which the two differ: Bubble's reading with only
    # that flag at its target reading, and the intended reading with only
    # that flag at Bubble's: which flags a case rests on.
    per_flag =
      for flag <- Difference.flags(:rule_conditions),
          interpreter.assumptions[flag] != intended.assumptions[flag] do
        {flag, with_flag(interpreter, flag, intended.assumptions[flag]),
         with_flag(intended, flag, interpreter.assumptions[flag])}
      end

    %{
      bubble: interpreter,
      target: Interpreter.target(interpreter),
      intended: intended,
      per_flag: per_flag
    }
  end

  defp with_flag(interpreter, flag, value) do
    {:ok, one} =
      Interpreter.with_assumptions(interpreter, Map.put(interpreter.assumptions, flag, value))

    one
  end

  # The policy flags a case rests on (`observe` of a reading): those whose
  # target reading alone changes what Bubble's reading shows, and those
  # without whose target reading the intended one would not show what it
  # does; when neither tells, the minimal set that explains it.
  defp responsible(cell, observe) do
    bubble = observe.(cell.readings.bubble)
    intended = observe.(cell.readings.intended)

    flags =
      for {flag, alone, without} <- cell.readings.per_flag,
          observe.(alone) != bubble or observe.(without) != intended,
          do: flag

    if flags == [], do: minimal_set(cell, observe, intended), else: Enum.sort(flags)
  end

  # When no flag alone tells: the smallest set of the policy's flags whose
  # target readings, together, give the intended observation (fewest flags
  # first, then in order). The whole set always does: intended is Bubble's
  # reading with every policy flag at its target reading.
  defp minimal_set(cell, observe, intended) do
    flags = Enum.map(cell.readings.per_flag, &elem(&1, 0))
    bubble = cell.readings.bubble

    Enum.find_value(1..max(length(flags), 1)//1, flags, fn size ->
      Enum.find(subsets(flags, size), fn set ->
        target = Map.new(set, &{&1, Difference.policy()[&1].target})
        observe.(with_flags(bubble, target)) == intended
      end)
    end)
    |> Enum.sort()
  end

  defp with_flags(interpreter, flags) do
    {:ok, i} =
      Interpreter.with_assumptions(interpreter, Map.merge(interpreter.assumptions, flags))

    i
  end

  defp subsets(_list, 0), do: [[]]
  defp subsets([], _size), do: []

  defp subsets([h | t], size),
    do: Enum.map(subsets(t, size - 1), &[h | &1]) ++ subsets(t, size)

  # Per op of a scenario: where the target's verdict differs from the
  # recorded one, an intended difference per observation (stricter, and
  # the policy's flags alone explain it) or an unintended one.
  defp differences(checks, scenario_id, cell, ds) do
    Enum.reduce(checks, {[], []}, fn check, {cases, unintended} ->
      case op_difference(check, scenario_id, cell, ds) do
        :same -> {cases, unintended}
        {:intended, more} -> {cases ++ more, unintended}
        :unintended -> {cases, unintended ++ [%{scenario: scenario_id, op: check.op.id}]}
      end
    end)
  end

  defp op_difference(%{verdict: {:get, key, visible, fields}, op: op}, scenario_id, cell, ds) do
    bubble = {visible, fields}
    target = get_verdict(cell.readings.target, ds, cell.user, key)

    cond do
      target == bubble ->
        :same

      target != get_verdict(cell.readings.intended, ds, cell.user, key) or
          not stricter_get?(bubble, target) ->
        :unintended

      true ->
        rules = changed_rules(cell, ds, key)
        {tv, tf} = target
        flags = responsible(cell, &get_verdict(&1, ds, cell.user, key))
        base = %{difference(scenario_id, op.id, cell, key, rules) | flags: flags}

        {:intended,
         if(tv != visible, do: [%{base | kind: :visible, bubble: visible, target: tv}], else: []) ++
           if(tf != fields,
             do: [%{base | kind: :visible_fields, bubble: fields, target: tf}],
             else: []
           )}
    end
  end

  defp op_difference(%{verdict: {:search, records}} = check, scenario_id, cell, ds),
    do: op_difference(%{check | verdict: {:search, nil, records}}, scenario_id, cell, ds)

  defp op_difference(%{verdict: {:search, field, records}, op: op}, scenario_id, cell, ds) do
    target = search_records(cell.readings.target, ds, cell.user, cell.type, field)
    bubble = Enum.sort(records)

    cond do
      target == bubble ->
        :same

      not is_list(target) or
        target != search_records(cell.readings.intended, ds, cell.user, cell.type, field) or
          not Difference.stricter?(:record_set, %{records: bubble}, %{records: target}) ->
        :unintended

      true ->
        rules = Enum.flat_map(bubble -- target, &changed_rules(cell, ds, &1)) |> Enum.uniq()
        flags = responsible(cell, &search_records(&1, ds, cell.user, cell.type, field))

        {:intended,
         [
           %{
             difference(scenario_id, op.id, cell, nil, Enum.sort(rules))
             | kind: :record_set,
               flags: flags,
               bubble: %{ordered: false, records: bubble},
               target: %{ordered: false, records: target}
           }
         ]}
    end
  end

  defp difference(scenario_id, op_id, cell, key, rules) do
    %Difference{
      scenario: scenario_id,
      op: op_id,
      kind: nil,
      record: key,
      type: cell.type,
      persona: cell.persona,
      bubble: nil,
      target: nil,
      flags: Difference.flags(:rule_conditions),
      rules: rules
    }
  end

  defp get_verdict(interpreter, ds, user, key) do
    {visible, fields, unknown, _searchable} = Interpreter.observe(interpreter, ds, user, key)
    if unknown == [], do: {visible, Enum.sort(fields)}, else: {visible, :unknown}
  end

  defp stricter_get?({bv, bf}, {tv, tf}) when is_boolean(tv) and is_list(tf),
    do: Difference.stricter?(:visible, bv, tv) and Difference.stricter?(:visible_fields, bf, tf)

  defp stricter_get?(_bubble, _target), do: false

  defp search_records(interpreter, ds, user, type_id, field) do
    {:ok, search} =
      if field,
        do: Interpreter.search(interpreter, ds, user, type_id, field),
        else: Interpreter.search(interpreter, ds, user, type_id)

    if search.unknown == [], do: Enum.sort(search.records), else: :unknown
  end

  # The rules of the record's type whose outcome for the user differs
  # between Bubble's reading and the intended one: conditions, and the
  # everyone rule's reach.
  defp changed_rules(cell, ds, key) do
    %{bubble: bubble, intended: intended} = cell.readings
    info = Interpreter.type(bubble, cell.type)

    conditional =
      for %{status: :ok} = r <- info.rules,
          outcome(Interpreter.eval_rule(bubble, r, ds, cell.user, key)) !=
            outcome(Interpreter.eval_rule(intended, r, ds, cell.user, key)),
          do: r.rule.id

    everyone =
      if grants_something?(info.default) and info.rules != [] and
           Enum.all?(info.rules, &(&1.status == :ok)) and
           Interpreter.everyone_applies(bubble, ds, cell.user, cell.type, key) !=
             Interpreter.everyone_applies(intended, ds, cell.user, cell.type, key),
         do: ["everyone"],
         else: []

    Enum.sort(conditional) ++ everyone
  end

  defp grants_something?(%{permissions: %{} = p}),
    do: p.view_all == true or (p.view_fields || []) != [] or p.search_for == true

  defp grants_something?(_default), do: false

  defp outcome({b, _flags}) when is_boolean(b), do: b
  defp outcome(_), do: :unknown

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

  defp deleted_type?(%Interpreter{types: types}, type_id),
    do: match?(%{type: %{deleted: true}}, Map.get(types, type_id))

  defp version, do: :bubble_ex |> Application.spec(:vsn) |> to_string()

  # --- report --------------------------------------------------------------------------

  @doc """
  The coverage report of a matrix (also in `matrix.report`):

    * `rules` - the rules of live data types (not flagged `deleted` /
      `%del` in the app): `total`, `conditional`, `everyone`, `solved`,
      `unsolved`, `solved_percent` (one decimal), `observable`,
      `observable_percent` (mutation coverage),
      `false_branch_only_via_actor_guard` and
      `true_branch_only_via_empty_actor` (solved rules whose only false,
      or true, cells rest on how empty user-side values compare:
      `actor_empty_denies`)
    * `deleted_type_rules` - the rules of data types the app flags deleted,
      kept apart because they protect nothing: `total`, `solved`,
      `unsolved` (they are unsolved as `deleted_type`)
    * `unobservable` / `unobservable_by_reason` - rules no mutant changes a
      recorded verdict of: `unsolved`, `grants_nothing`, `masked`,
      `undecided_type`
    * `seed_values_from_condition_literals`, `oracle_scope`
    * `governed_fields` - field slots (record x non-built-in field some
      rule lets someone view) in the seed: `slots`, `held` (non-empty) and
      `unchecked` (empty, so a Bubble recording cannot show whether they
      are visible: the Data API omits empty fields), by reason
      (`condition_reads`: a witness may need it empty; `default`,
      `explicitly_empty`, `persona`, `no_synthetic_value`: a reference,
      file or other value the matrix does not invent)
    * `unsolved` - `%{type, rule, reason, detail}` per unsolved rule
      (Bubble IDs); `unsolved_by_reason` counts them
    * `types` - `total`, `with_rules`, `public`, `deleted`, `unavailable`
    * `personas`, `records`, `scenarios`, `checks` (ops: one per search and
      per get), `observations`, `skipped` (ops left out as undetermined)
    * `assumptions` - the assumptions in force, per flag the number of ops
      whose expectations depend on it (`dependent_checks`), and per flag
      whether some check depends on it and if not why (`outcomes`); for
      flags a fail-safe hedge hides, the checks that depend on them with
      the hedge lifted (`jointly_dependent_checks`); per flag the last
      calibration's verdict (`calibration`, `Assumptions.evidence/0`) and
      the flags it has not settled (`unsettled`)
    * `differences` - where the generated policies are stricter than Bubble
      by design (`BubbleEx.Verify.Difference`): the policy's flags, and the
      observations, scenarios, types and rules concerned; `unintended`
      counts the ops where the two readings differ otherwise
    * `intended_differences` - the owner's list (`Difference.summary/1`:
      per type and rule, Bubble IDs); `unintended_differences` the
      unintended ops (`%{scenario, op}`)
  """
  @spec report(t(), Interpreter.t()) :: map()
  def report(%__MODULE__{} = matrix, %Interpreter{} = interpreter) do
    unsolved =
      for %{status: {:unsolved, reason, detail}} = r <- matrix.rules,
          do: %{type: r.type, rule: r.rule, reason: reason, detail: detail}

    unobservable =
      for %{status: {:unobservable, reason, detail}} = r <- matrix.observability,
          do: %{type: r.type, rule: r.rule, reason: reason, detail: detail}

    # Coverage counts only the rules of live types: a deleted type's rules
    # protect nothing. "Deleted" is the app's own flag on the type.
    {deleted_rules, live_rules} =
      Enum.split_with(matrix.rules, &deleted_type?(interpreter, &1.type))

    live_key = MapSet.new(live_rules, &{&1.type, &1.rule})
    live? = &MapSet.member?(live_key, {&1.type, &1.rule})

    total = length(live_rules)
    live_unsolved = Enum.count(unsolved, live?)
    solved = total - live_unsolved
    observable = total - Enum.count(unobservable, live?)
    deleted_unsolved = length(unsolved) - live_unsolved
    infos = Map.values(interpreter.types)

    %{
      rules: %{
        total: total,
        conditional: Enum.count(live_rules, &(not &1.default)),
        everyone: Enum.count(live_rules, & &1.default),
        solved: solved,
        unsolved: live_unsolved,
        solved_percent: percent(solved, total),
        observable: observable,
        observable_percent: percent(observable, total),
        false_branch_only_via_actor_guard: Enum.count(live_rules, &(&1[:robust_false] == false)),
        true_branch_only_via_empty_actor: Enum.count(live_rules, &(&1[:robust_true] == false))
      },
      deleted_type_rules: %{
        total: length(deleted_rules),
        solved: length(deleted_rules) - deleted_unsolved,
        unsolved: deleted_unsolved
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
      defaults: defaults_report(matrix.seed, interpreter),
      explicit_empties: explicit_empties(matrix.seed),
      governed_fields: governed_report(matrix.seed, interpreter),
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
      differences: %{
        policy: Difference.flags(:rule_conditions),
        observations: length(matrix.differences),
        scenarios: matrix.differences |> Enum.map(& &1.scenario) |> Enum.uniq() |> length(),
        types: matrix.differences |> Enum.map(& &1.type) |> Enum.uniq() |> length(),
        rules:
          matrix.differences
          |> Enum.flat_map(fn d -> for r <- d.rules, do: {d.type, r} end)
          |> Enum.uniq()
          |> length(),
        unintended: length(matrix.unintended)
      },
      intended_differences: Difference.summary(matrix.differences),
      unintended_differences: matrix.unintended,
      assumptions: %{
        in_force: Assumptions.to_map(matrix.assumptions),
        changed: Assumptions.changed(matrix.assumptions),
        calibration:
          Map.new(Assumptions.evidence(), fn {flag, e} -> {Atom.to_string(flag), e.status} end),
        unsettled: Assumptions.unsettled(),
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

  # Fields with a default (modeled or not), seed values equal to their
  # field's default (applied on creation, or chosen), and defaulted fields
  # the seed keeps explicitly empty.
  defp defaults_report(seed, interpreter) do
    entries = interpreter.defaults |> Map.values() |> Enum.flat_map(&Map.values/1)

    %{
      fields: length(entries),
      unmodeled: Enum.count(entries, &(&1 == :unmodeled)),
      seed_values_equal_to_default:
        Enum.count(
          for r <- seed.records,
              {f, v} <- r.fields,
              v != nil,
              default?(interpreter, r, f, v),
              do: f
        ),
      explicit_empties: length(explicit_empties(seed))
    }
  end

  defp default?(interpreter, record, field, value) do
    type = Dataset.type_id(record.type)
    get_in(interpreter.defaults, [type, field]) == {:ok, value}
  end

  # Defaulted fields a seed record holds explicitly empty: Bubble would
  # store the default on creation, so a loader must create the record and
  # then clear them (V4); whether Bubble can store them empty on creation
  # is unverified.
  defp explicit_empties(seed) do
    for r <- seed.records,
        {f, nil} <- Enum.sort(r.fields),
        do: %{record: r.key, type: r.type, field: f}
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
    |> Map.drop([
      :unsolved,
      :unobservable,
      :explicit_empties,
      :intended_differences,
      :unintended_differences
    ])
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
  `observations` of `scenario` (e.g. the generated Ash tests,
  `BubbleEx.Target.Ash.MatrixTests`, V3) with the expected recording. The
  oracle and evidence cite the recording, so `Result.evaluate/3` can count
  it as passing; as Bubble-verified only with a `bubble` recording (its
  replay branch is the oracle's), never with the `model` one.

  The subject is held to the **target policy**: the recording with the
  scenario's intended differences applied (`:differences`,
  `BubbleEx.Verify.Difference.apply/2`). The status is

    * `pass` - the observations match the recording
    * `intended_difference` - they match the target policy, which is
      stricter than the recording by design: the diff (against the
      recording) lists each difference with its `intended` flags and
      `rules`
    * `fail` - anything else, with the diff against the target policy
      (entries where the target is stricter than Bubble say so in
      `detail`)

  Against a `bubble` recording both sides are compared as the Data API
  shows them (`BubbleEx.Verify.DataApi.project/2`): fields restricted to
  those the record holds, and a readable record with no held field as
  ID-only. That needs the `:seed`.

  ## Options

    * `:app` (required), `:ran_at` (required, DateTime)
    * `:differences` - the intended differences (`BubbleEx.Verify.Difference`
      cases; those of other scenarios are ignored), default none
    * `:seed` - the scenario's seed, required with a `bubble` recording
    * `:held_only` - compare through the Data API's view; default true for
      a `bubble` recording, false for a `model` one
    * `:actor` - default `"ci"`
    * `:ref` - the recording's evidence path, default
      `.wtf/verification/recordings/<scenario id>.json`
  """
  @spec result(Scenario.t(), Recording.t(), [Observation.t()], keyword()) ::
          {:ok, BubbleEx.Verify.Result.t()} | {:error, Error.t()}
  def result(%Scenario{} = scenario, %Recording{} = recording, observations, opts) do
    cases = Difference.for_scenario(Keyword.get(opts, :differences, []), scenario.id)

    with {:ok, view, held} <- view(recording, opts) do
      expected = view.(recording.observations)

      target =
        if held,
          do: view.(Difference.to_target(recording.observations, cases, held)),
          else: Difference.to_target(recording.observations, cases)

      actual = observations |> view.() |> Map.new(&{Observation.key(&1), &1.value})

      {status, diff} = compare(expected, target, actual, cases, held)
      sha = Recording.sha256(recording)

      BubbleEx.Verify.Result.new(
        id: scenario.id,
        app: Keyword.fetch!(opts, :app),
        check: scenario.check,
        status: status,
        subjects: scenario.subjects,
        scenario: %{
          id: scenario.id,
          sha256: Scenario.sha256(scenario),
          source_sha256: scenario.source_sha256,
          seed_sha256: recording.seed_sha256
        },
        oracle: %{
          kind: recording.oracle,
          sha256: sha,
          branch: if(recording.oracle == :bubble, do: recording.source.branch)
        },
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
  end

  def result(_scenario, _recording, _observations, _opts),
    do: {:error, Error.new(:invalid_input, "expected a scenario and its recording")}

  # How observations are compared: as recorded, or as the Data API shows
  # them (default for Bubble recordings).
  defp view(recording, opts) do
    held_only = Keyword.get(opts, :held_only, recording.oracle == :bubble)

    case {held_only, opts[:seed]} do
      {false, _} ->
        {:ok, & &1, nil}

      {true, %Seed{} = seed} ->
        held = BubbleEx.Verify.DataApi.held_map(seed)
        {:ok, &BubbleEx.Verify.DataApi.project(&1, held), held}

      {true, _} ->
        {:error,
         Error.new(
           :invalid_input,
           "comparing through the Data API's view (a bubble recording) needs the seed"
         )}
    end
  end

  defp compare(expected, target, actual, cases, held) do
    against = fn observations ->
      Enum.flat_map(observations, &diff(&1, Map.get(actual, Observation.key(&1), :missing)))
    end

    case {against.(target), against.(expected)} do
      {[], []} ->
        {:pass, []}

      {[], diff} ->
        annotated =
          for e <- diff,
              c = Difference.explaining(cases, e, held),
              do: Difference.annotate(e, c)

        if length(annotated) == length(diff),
          do: {:intended_difference, annotated},
          else: {:fail, diff}

      {diff, _} ->
        {:fail, Enum.map(diff, &stricter_detail(&1, cases))}
    end
  end

  # A failing entry where the target is stricter than Bubble by design.
  defp stricter_detail(entry, cases) do
    if Enum.any?(cases, &(&1.record == entry[:record])) do
      flags = cases |> Enum.flat_map(& &1.flags) |> Enum.uniq() |> Enum.join(", ")
      Map.put(entry, :detail, "the target policy is stricter than Bubble here (#{flags})")
    else
      entry
    end
  end

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
  (type, persona), `.wtf/verification/differences/<seed id>.json` with
  the intended differences (`BubbleEx.Verify.Difference`), and
  `.wtf/verification/interpreter/<seed id>.json` with the assumptions in
  force, the per-op dependencies and the coverage report.
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
        {"#{root}/differences/#{matrix.seed.id}.json",
         Difference.to_json(matrix.differences, %{
           id: matrix.seed.id,
           sha256: Seed.sha256(matrix.seed)
         })},
        {"#{root}/interpreter/#{matrix.seed.id}.json",
         CanonicalJson.encode(interpreter_doc(matrix))}
      ]
  end

  defp interpreter_doc(matrix) do
    %{
      "format" => "bubble_ex.verify.interpreter",
      "seed" => %{"id" => matrix.seed.id, "sha256" => Seed.sha256(matrix.seed)},
      "assumptions" => Assumptions.to_map(matrix.assumptions),
      "target_assumptions" => Assumptions.to_map(Assumptions.target()),
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
