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
     and false branches are exercised by some cell.
  4. **Scenarios**, one per (type, persona): a `search` of the type and a
     `get` of each of its records, observing `record_set`, `visible` and
     `visible_fields`. An op whose verdict an unsupported rule could decide
     is left out (the report counts it).
  5. **Recordings**: the interpreter's verdicts under the chosen
     assumptions, oracle `model` (never Bubble-verified, decision D2 on
     WTF-358). `dependencies` holds, per scenario op, the assumption flags
     its expected observations depend on.

  A rule is **solved** when the interpreter evaluates it and the seed has a
  cell (persona, record) where its condition holds and one where it does
  not; the `everyone` rule when the type's other rules are all supported
  and it both applies (no other rule holds) and does not somewhere (or,
  alone, applies). Deleted types, types whose rules the source lacks, and
  unsupported rules are listed with reasons.

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
  alias BubbleEx.Verify.Matrix.{Personas, Solver}

  @enforce_keys [:seed, :assumptions]
  defstruct [
    :seed,
    :assumptions,
    scenarios: [],
    recordings: [],
    dependencies: %{},
    rules: [],
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
          rules: [
            %{type: String.t(), rule: String.t(), default: boolean(), status: rule_status()}
          ],
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
      ds = types |> Enum.reduce(ds, &empty_record/2) |> witnesses(interpreter, types, personas)
      rules = coverage(interpreter, ds, personas)

      with {:ok, seed} <- seed(Keyword.get(opts, :seed_id, "privacy_matrix"), personas, ds),
           {:ok, built} <- scenarios(interpreter, ds, personas, seed, types, app, opts) do
        matrix = %__MODULE__{
          seed: seed,
          assumptions: interpreter.assumptions,
          scenarios: built.scenarios,
          recordings: built.recordings,
          dependencies: built.dependencies,
          skipped: built.skipped,
          rules: rules
        }

        {:ok, %{matrix | report: report(matrix, interpreter)}}
      end
    end
  end

  def synthesize(_, _), do: {:error, Error.new(:invalid_input, "expected a BubbleEx.Model")}

  defp matrix_types(interpreter) do
    for {id, %{status: status}} <- Enum.sort(interpreter.types),
        status in [:rules, :public],
        do: id
  end

  defp empty_record(type_id, ds),
    do: Dataset.put(ds, "e.#{Personas.slug(type_id)}", type_id, %{})

  # --- witnesses --------------------------------------------------------------------

  defp witnesses(ds, interpreter, types, personas) do
    for type_id <- types,
        %{status: :rules, rules: rules} <- [Interpreter.type(interpreter, type_id)],
        %{status: :ok} = info <- rules,
        target <- [true, false],
        reduce: ds,
        do: (ds -> ensure(ds, interpreter, info, type_id, personas, target))
  end

  defp ensure(ds, interpreter, info, type_id, personas, target) do
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
      %{
        type: type_id,
        rule: rule.id,
        default: rule.default?,
        status: rule_status(info, rule, interpreter, ds, personas)
      }
    end
  end

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
    applies =
      for {_persona, user} <- Enum.sort(personas),
          key <- Dataset.keys(ds, info.type.id),
          uniq: true do
        not Enum.any?(info.rules, fn r ->
          match?({true, _}, Interpreter.eval_rule(interpreter, r, ds, user, key))
        end)
      end

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

    * `rules` - `total`, `conditional`, `everyone`, `solved`, `unsolved`
      and `solved_percent` (of all rules, one decimal)
    * `unsolved` - `%{type, rule, reason, detail}` per unsolved rule
      (Bubble IDs); `unsolved_by_reason` counts them
    * `types` - `total`, `with_rules`, `public`, `deleted`, `unavailable`
    * `personas`, `records`, `scenarios`, `checks` (ops: one per search and
      per get), `observations`, `skipped` (ops left out as undetermined)
    * `assumptions` - the assumptions in force, and per flag the number of
      ops whose expectations depend on it
  """
  @spec report(t(), Interpreter.t()) :: map()
  def report(%__MODULE__{} = matrix, %Interpreter{} = interpreter) do
    unsolved =
      for %{status: {:unsolved, reason, detail}} = r <- matrix.rules,
          do: %{type: r.type, rule: r.rule, reason: reason, detail: detail}

    total = length(matrix.rules)
    solved = total - length(unsolved)
    infos = Map.values(interpreter.types)

    %{
      rules: %{
        total: total,
        conditional: Enum.count(matrix.rules, &(not &1.default)),
        everyone: Enum.count(matrix.rules, & &1.default),
        solved: solved,
        unsolved: length(unsolved),
        solved_percent: if(total == 0, do: 100.0, else: Float.round(solved * 100 / total, 1))
      },
      unsolved: unsolved,
      unsolved_by_reason: Enum.frequencies_by(unsolved, &Atom.to_string(&1.reason)),
      types: %{
        total: length(infos),
        with_rules: Enum.count(infos, &(&1.status == :rules)),
        public: Enum.count(infos, &(&1.status == :public)),
        deleted: Enum.count(infos, & &1.type.deleted),
        unavailable:
          Enum.count(infos, &(not &1.type.deleted and match?({:unknown, _}, &1.status)))
      },
      personas: map_size(matrix.seed.personas),
      records: length(matrix.seed.records),
      scenarios: length(matrix.scenarios),
      checks: matrix.scenarios |> Enum.map(&length(&1.ops)) |> Enum.sum(),
      observations: matrix.recordings |> Enum.map(&length(&1.observations)) |> Enum.sum(),
      skipped: matrix.skipped,
      assumptions: %{
        in_force: Assumptions.to_map(matrix.assumptions),
        changed: Assumptions.changed(matrix.assumptions),
        dependent_checks:
          matrix.dependencies
          |> Map.values()
          |> List.flatten()
          |> Enum.frequencies()
          |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      }
    }
  end

  @doc """
  The report without Bubble IDs (counts only), as JSON-ready string-keyed
  maps: what a committed snapshot of a private app may hold.
  """
  @spec counts(map()) :: map()
  def counts(report) do
    report
    |> Map.drop([:unsolved])
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
