defmodule BubbleEx.Verify.MatrixTest do
  # Privacy-matrix synthesis (WTF-382): personas, seeds, scenarios and
  # model recordings for the policy and expression fixture apps.
  use ExUnit.Case, async: true

  alias BubbleEx.Decision.Resolved
  alias BubbleEx.Model
  alias BubbleEx.Test.{ExpressionFixture, PermutedJson}
  alias BubbleEx.Verify
  alias BubbleEx.Verify.{Difference, Interpreter, Matrix, Recording, Result, Scenario, Seed}
  alias BubbleEx.Verify.Interpreter.Dataset
  alias BubbleEx.Verify.Matrix.Personas

  @policy_app "test/support/target/ash/policies.json" |> File.read!() |> Jason.decode!()

  setup_all do
    {:ok, pmodel} = Model.build(@policy_app)
    {:ok, policies} = Matrix.synthesize(pmodel, app: "fixture-app")
    emodel = ExpressionFixture.model()
    {:ok, expression} = Matrix.synthesize(emodel, app: "fixture-app")
    %{pmodel: pmodel, policies: policies, emodel: emodel, expression: expression}
  end

  defp unsolved(matrix),
    do: for(%{status: {:unsolved, reason, _}} = r <- matrix.rules, do: {r.type, r.rule, reason})

  test "every rule the interpreter evaluates is solved; the rest are itemized",
       %{policies: policies, expression: expression} do
    assert unsolved(policies) == [
             {"doc", "raw_", :not_compiled},
             {"doc", "everyone", :blocked_by_unsupported_rule},
             {"memo", "raw_", :not_compiled},
             {"memo", "everyone", :blocked_by_unsupported_rule}
           ]

    assert unsolved(expression) == [
             {"archived_thing", "old_", :deleted_type},
             {"archived_thing", "everyone", :deleted_type},
             {"task", "m_raw_", :not_compiled},
             {"task", "everyone", :blocked_by_unsupported_rule}
           ]

    assert %{total: 43, solved: 39, conditional: 38, everyone: 5} =
             expression.report.rules

    assert expression.report.unsolved_by_reason == %{
             "blocked_by_unsupported_rule" => 1,
             "deleted_type" => 2,
             "not_compiled" => 1
           }
  end

  test "each solved conditional rule holds for some cell and fails for another",
       %{emodel: model, expression: matrix} do
    {:ok, interpreter} = Interpreter.new(model)
    {:ok, ds} = Dataset.from_seed(matrix.seed)

    for %{status: :solved, default: false, type: type, rule: rule} <- matrix.rules do
      values =
        for {_, %{user: user}} <- matrix.seed.personas,
            key <- Dataset.keys(ds, type),
            {:ok, b, _} <- [Interpreter.condition(interpreter, ds, user, type, rule, key)],
            uniq: true,
            do: b

      assert Enum.sort(values) == [false, true], "#{type}/#{rule}"
    end
  end

  test "the six personas, with reserved-domain emails", %{policies: matrix} do
    assert matrix.seed.personas |> Map.keys() |> Enum.sort() == Enum.sort(Personas.ids())
    assert matrix.seed.personas["anonymous"] == %{user: nil}
    assert matrix.seed.personas["admin"] == %{user: "u.admin"}

    admin = Seed.record(matrix.seed, "u.admin")
    assert admin.fields["email"] == {:text, "admin@replay.wtf.invalid"}
    assert admin.fields["admin_boolean"] == {:boolean, true}
    assert Seed.record(matrix.seed, "u.logged_in_empty").fields |> Map.keys() == ["email"]

    # the board rule reads Current User's team's lead: the persona's own
    # team, whose lead is its world's first persona.
    team = "u.w1_member.team_custom_team"
    assert Seed.record(matrix.seed, "u.w1_member").fields["team_custom_team"] == {:ref, team}
    assert Seed.record(matrix.seed, team).type == "custom.team"
    assert Seed.record(matrix.seed, team).fields["lead_user"] == {:ref, "u.w1_member"}

    assert Seed.record(matrix.seed, "u.w2_member.team_custom_team").fields["lead_user"] ==
             {:ref, "u.w2_member"}
  end

  test "governed fields no condition reads hold a value; the rest are counted",
       %{policies: matrix} do
    g = matrix.report.governed_fields
    assert g.slots == g.held + g.unchecked
    assert g.unchecked == g.unchecked_by_reason |> Map.values() |> Enum.sum()
    refute Map.has_key?(g.unchecked_by_reason, "other")
    # a board's name is governed and read by no condition
    assert Seed.record(matrix.seed, "e.board").fields["name_text"] == {:text, "sample"}
    assert Matrix.counts(matrix.report)["governed_fields"]["slots"] == g.slots
  end

  test "documents validate and fit together", %{policies: policies, expression: expression} do
    for matrix <- [policies, expression] do
      assert {:ok, seed} = Seed.from_json(Seed.to_json(matrix.seed))
      assert seed == matrix.seed
      assert length(matrix.scenarios) == length(matrix.recordings)

      for {scenario, recording} <- Enum.zip(matrix.scenarios, matrix.recordings) do
        assert {:ok, ^scenario} = Scenario.from_json(Scenario.to_json(scenario))
        assert :ok = Scenario.check_seed(scenario, matrix.seed)
        assert :ok = Recording.check_scenario(recording, scenario)
        assert recording.oracle == :model and recording.complete
        assert recording.source.app == "fixture-app"
        assert recording.scenario.sha256 == Scenario.sha256(scenario)
        assert scenario.kind == :privacy_read and scenario.check == "privacy_read"
        assert {:ok, _} = Verify.decode(Recording.to_json(recording))
      end
    end
  end

  test "recordings are the interpreter's verdicts on the seed", %{pmodel: model, policies: matrix} do
    {:ok, interpreter} = Interpreter.new(model)
    {:ok, ds} = Dataset.from_seed(matrix.seed)

    for {scenario, recording} <- Enum.zip(matrix.scenarios, matrix.recordings),
        user = matrix.seed.personas[scenario.persona].user,
        obs <- recording.observations do
      case obs.kind do
        :record_set ->
          type = Dataset.type_id(scenario.subjects.type)

          {:ok, search} =
            case Scenario.op(scenario, obs.op) do
              %{constrain: field} -> Interpreter.search(interpreter, ds, user, type, field)
              _ -> Interpreter.search(interpreter, ds, user, type)
            end

          assert obs.value == %{ordered: false, records: search.records}

        :visible ->
          assert {:ok, %{visible: v}} = Interpreter.access(interpreter, ds, user, obs.record)
          assert obs.value == v

        :visible_fields ->
          assert {:ok, %{fields: f}} = Interpreter.access(interpreter, ds, user, obs.record)
          assert obs.value == f
      end
    end
  end

  test "undecided cells are left out and counted", %{policies: matrix} do
    # doc and memo have an uncompilable rule
    assert matrix.skipped.gets > 0

    # anonymous: every doc is unknown or partly unknown under the target's
    # reading (raw_ grants view_all), so there is no scenario, although
    # Bubble's decides some (an empty owner equals the logged-out user, so
    # owner_ grants view_all); an admin's is fully decided.
    ids = Enum.map(matrix.scenarios, & &1.id)
    refute "privacy_read.custom.doc.anonymous" in ids
    assert "privacy_read.custom.doc.admin" in ids
    refute "privacy_read.custom.memo.admin" in ids
    assert matrix.report.checks == matrix.scenarios |> Enum.map(&length(&1.ops)) |> Enum.sum()
  end

  test "a field some rule keeps out of searches gets a constrained search per persona",
       %{pmodel: model, policies: matrix} do
    {:ok, interpreter} = Interpreter.new(model)
    {:ok, ds} = Dataset.from_seed(matrix.seed)

    notes =
      for {s, r} <- Enum.zip(matrix.scenarios, matrix.recordings),
          s.subjects.type == "custom.note",
          do: {s, r}

    assert notes != []

    # note.text: the everyone rule lists it as non-filterable; the expected
    # records are those the persona finds and may search by it
    for {s, r} <- notes do
      assert %{op: :search, constrain: "text_text", observe: [:record_set]} =
               Scenario.op(s, "search.1.text_text")

      user = matrix.seed.personas[s.persona].user
      {:ok, found} = Interpreter.search(interpreter, ds, user, "note", "text_text")
      observed = Enum.find(r.observations, &(&1.op == "search.1.text_text"))
      assert observed.value == %{ordered: false, records: Enum.sort(found.records)}
    end

    assert matrix.dependencies
           |> Map.values()
           |> List.flatten()
           |> Enum.member?(:non_filterable_constraint_excludes)

    # doc.body: only where raw_ (unsupported) cannot decide it, as for an admin
    personas =
      for s <- matrix.scenarios,
          op <- s.ops,
          Map.get(op, :constrain) == "body_text",
          do: s.persona

    assert "admin" in personas
    refute "anonymous" in personas

    # an unconstrained search carries no constrain member (unchanged hashes)
    {scenario, _} = hd(notes)
    [search | _] = scenario |> Scenario.to_map() |> Map.fetch!("ops")
    assert search["op"] == "search" and not Map.has_key?(search, "constrain")
    assert {:ok, ^scenario} = scenario |> Scenario.to_map() |> Scenario.from_map()
  end

  test "dependencies name the assumptions an op's expectations rest on", %{policies: matrix} do
    # board's lead_ rule: This's owner is Current User's team's lead. Under
    # Bubble's reading the empty board is visible to a logged-out user (an
    # empty owner is an empty lead); it would be hidden if empty user-side
    # values denied, or if empty never equaled empty.
    assert matrix.dependencies[{"privacy_read.custom.board.anonymous", "get.e.board"}] ==
             [:actor_empty_denies, :empty_equals_empty]

    assert Enum.all?(matrix.dependencies, fn {_, flags} -> flags != [] end)
    assert matrix.report.assumptions.changed == []
  end

  test "assumptions change the expectations and are reported", %{pmodel: model, policies: default} do
    {:ok, flipped} =
      Matrix.synthesize(model,
        app: "fixture-app",
        assumptions: [no_visible_field_unreadable: false]
      )

    assert flipped.report.assumptions.changed == [:no_visible_field_unreadable]
    assert Seed.sha256(flipped.seed) == Seed.sha256(default.seed)

    refute Enum.map(flipped.recordings, &Recording.sha256/1) ==
             Enum.map(default.recordings, &Recording.sha256/1)

    assert {:error, %{kind: :invalid_input}} =
             Matrix.synthesize(model, app: "fixture-app", assumptions: [x: true])

    assert {:error, %{kind: :invalid_input}} = Matrix.synthesize(model, app: "Not An App")
    assert {:error, %{kind: :invalid_input}} = Matrix.synthesize(:nope)
  end

  test "deterministic, and independent of the source's member order", %{policies: matrix} do
    :rand.seed(:exsss, {3, 8, 2})
    {:ok, shuffled} = @policy_app |> PermutedJson.encode() |> Jason.decode!() |> Model.build()
    {:ok, again} = Matrix.synthesize(shuffled, app: "fixture-app")
    assert Matrix.files(again) == Matrix.files(matrix)
  end

  test "files: owner-repo paths, and a counts-only report", %{policies: matrix} do
    files = Matrix.files(matrix)
    paths = Enum.map(files, &elem(&1, 0))

    assert ".wtf/verification/seeds/privacy_matrix.json" in paths

    assert ".wtf/verification/scenarios/privacy_read/privacy_read.custom.doc.w1_member.json" in paths

    assert ".wtf/verification/recordings/privacy_read.custom.doc.w1_member.json" in paths

    {_, interpreter} = List.last(files)
    doc = Jason.decode!(interpreter)
    assert doc["format"] == "bubble_ex.verify.interpreter"
    assert doc["assumptions"]["actor_empty_denies"] == false
    assert doc["target_assumptions"]["actor_empty_denies"] == true
    assert doc["dependencies"] != []

    {_, differences} =
      Enum.find(files, fn {path, _} ->
        path == ".wtf/verification/differences/privacy_matrix.json"
      end)

    assert {:ok, %{seed: %{id: "privacy_matrix"}, cases: cases}} =
             Difference.from_json(differences)

    assert cases == matrix.differences

    counts = Matrix.counts(matrix.report)
    refute Map.has_key?(counts, "unsolved")
    refute Map.has_key?(counts, "intended_differences")

    assert counts["differences"]["policy"] ==
             Enum.map(Difference.flags(:rule_conditions), &Atom.to_string/1)

    assert counts["rules"]["total"] == 14
    refute counts |> Jason.encode!() |> String.contains?("raw_")
  end

  test "seeds are as Bubble stores records after creation: defaults written, explicit empties null" do
    {:ok, model} =
      "test/support/target/ash/policy_defaults.json"
      |> File.read!()
      |> Jason.decode!()
      |> Model.build()

    {:ok, matrix} = Matrix.synthesize(model, app: "fixture-app")
    {:ok, interpreter} = Interpreter.new(model)
    {:ok, ds} = Dataset.from_seed(matrix.seed)

    # every modeled default is written out wherever a record omitted it
    for r <- matrix.seed.records,
        {field, {:ok, _}} <- Map.get(interpreter.defaults, Dataset.type_id(r.type), %{}),
        do: assert(Map.has_key?(r.fields, field), "#{r.key}.#{field}")

    assert Seed.record(matrix.seed, "e.memo").fields["open_boolean"] == {:boolean, true}
    # an unmodeled default is never guessed
    refute Map.has_key?(Seed.record(matrix.seed, "e.note").fields, "weird_text")

    # an explicitly empty defaulted field stays null, and is reported
    assert %{fields: 3, unmodeled: 1, explicit_empties: n} = matrix.report.defaults
    assert n > 0 and length(matrix.report.explicit_empties) == n

    for %{record: key, field: f} <- matrix.report.explicit_empties,
        do: assert(Seed.record(matrix.seed, key).fields[f] == nil)

    refute Map.has_key?(Matrix.counts(matrix.report), "explicit_empties")
    # the seed writes defaults out: no recording can depend on the flag
    assert {:not_exercised, "the seed writes every modeled default out" <> _} =
             matrix.flags[:defaults_applied_at_creation]

    refute Enum.any?(matrix.dependencies, fn {_, f} -> :defaults_applied_at_creation in f end)

    # the recordings are what the interpreter reads from the seed file
    for rec <- matrix.recordings,
        %{kind: :visible, record: key, value: v} <- rec.observations do
      persona = Enum.find(matrix.scenarios, &(&1.id == rec.scenario.id)).persona
      user = matrix.seed.personas[persona].user
      {:ok, access} = Interpreter.access(interpreter, ds, user, key)
      assert access.visible == v
    end
  end

  test "result/4: a subject matching the model recording passes, never Bubble-verified",
       %{policies: matrix} do
    scenario = Enum.find(matrix.scenarios, &(&1.id == "privacy_read.custom.note.w1_member"))
    recording = Enum.find(matrix.recordings, &(&1.scenario.id == scenario.id))
    now = ~U[2026-10-02 09:15:00Z]
    opts = [app: "fixture-app", ran_at: now]

    assert {:ok, %Result{status: :pass, diff: []} = pass} =
             Matrix.result(scenario, recording, recording.observations, opts)

    assert {:ok, %{passing: true, bubble_verified: false}} =
             Result.evaluate(pass, %Resolved{entries: []},
               now: now,
               app: "fixture-app",
               recording: recording
             )

    leaked =
      Enum.map(recording.observations, fn
        %{kind: :visible_fields} = o -> %{o | value: Enum.sort(["leak_text" | o.value])}
        o -> o
      end)

    assert {:ok, %Result{status: :fail, diff: diff}} =
             Matrix.result(scenario, recording, leaked, opts)

    assert diff != []
    assert Enum.all?(diff, &(&1.op == "field_visible" and &1.field == "leak_text" and &1.actual))

    missing = Enum.reject(recording.observations, &(&1.kind == :record_set))

    assert {:ok, %Result{status: :fail, diff: diff}} =
             Matrix.result(scenario, recording, missing, opts)

    # the search, and the search constrained on note's non-filterable text
    assert length(diff) == 2
    assert Enum.all?(diff, &match?(%{op: "record_set", actual: nil}, &1))
  end

  describe "observability (mutation coverage) and assumption coverage" do
    test "observable rules change a recorded verdict when dropped or negated",
         %{pmodel: model, policies: matrix} do
      {:ok, interpreter} = Interpreter.new(model)
      {:ok, ds} = Dataset.from_seed(matrix.seed)
      recorded = recorded_cells(matrix)

      for %{status: :observable, type: type, rule: rule} <- matrix.observability do
        mutants =
          if rule == "everyone",
            do: [Interpreter.mutate(interpreter, type, rule, :drop)],
            else: for(m <- [:drop, :negate], do: Interpreter.mutate(interpreter, type, rule, m))

        assert Enum.any?(recorded[type] || [], fn {user, key} ->
                 base = Interpreter.observe(interpreter, ds, user, key)
                 Enum.any?(mutants, &(Interpreter.observe(&1, ds, user, key) != base))
               end),
               "#{type}/#{rule}"
      end

      # note's everyone rule reaches every user in Bubble (WTF-467): what
      # hidden_ and mine_ grant, it grants anyway
      assert matrix.report.rules.observable == 6

      assert matrix.report.unobservable_by_reason == %{
               "grants_nothing" => 1,
               "masked" => 2,
               "undecided_type" => 1,
               "unsolved" => 4
             }

      assert %{type: "board", rule: "everyone", reason: :grants_nothing} in Enum.map(
               matrix.report.unobservable,
               &Map.take(&1, [:type, :rule, :reason])
             )
    end

    test "the everyone rule's status uses the target's reach", %{
      pmodel: model,
      policies: matrix
    } do
      # Bubble's everyone rule reaches every user (WTF-467); its branches
      # are those of the target's reading: exclusive, record values guarded
      {:ok, interpreter} =
        Interpreter.new(model,
          assumptions: [everyone_exclusive: true, everyone_guards_record_values: true]
        )

      {:ok, ds} = Dataset.from_seed(matrix.seed)

      for %{status: :solved, default: true, type: type} <- matrix.rules,
          Interpreter.type(interpreter, type).rules != [] do
        reach =
          for {_, %{user: user}} <- matrix.seed.personas,
              key <- Dataset.keys(ds, type),
              uniq: true,
              do: Interpreter.everyone_applies(interpreter, ds, user, type, key)

        assert true in reach and false in reach, type
      end
    end

    test "every flag reports whether a check depends on it", %{policies: matrix} do
      assert map_size(matrix.flags) == 18
      # doc's body is non-filterable for the public rule: its constrained
      # searches depend on the flag
      assert matrix.flags[:non_filterable_constraint_excludes] == :exercised
      # moot in Bubble's reading: the everyone rule is not exclusive (WTF-467)
      assert {:not_exercised, "moot with everyone_exclusive off" <> _} =
               matrix.flags[:everyone_guards_record_values]

      assert {:not_exercised, "seeds cannot hold" <> _} = matrix.flags[:dangling_ref_is_empty]

      for {flag, :exercised} <- matrix.flags do
        assert Enum.any?(matrix.dependencies, fn {_, flags} -> flag in flags end), "#{flag}"
      end

      outcomes = matrix.report.assumptions.outcomes
      assert outcomes["everyone_exclusive"] == "exercised"
      assert matrix.report.rules.false_branch_only_via_actor_guard == 0
      assert matrix.report.rules.true_branch_only_via_empty_actor == 0
      assert Enum.all?(matrix.rules, &(&1.robust_false in [true, nil]))
      assert Enum.all?(matrix.rules, &(&1.robust_true in [true, nil]))
    end

    test "counts carry no Bubble IDs of unobservable rules", %{policies: matrix} do
      counts = Matrix.counts(matrix.report)
      refute Map.has_key?(counts, "unobservable")
      assert counts["rules"]["observable"] == 6
      assert counts["oracle_scope"] =~ "not the compiler"
    end
  end

  test "result/4 compares an unordered record set as a set", %{policies: matrix} do
    scenario = Enum.find(matrix.scenarios, &(&1.id == "privacy_read.custom.note.w1_member"))
    recording = Enum.find(matrix.recordings, &(&1.scenario.id == scenario.id))
    opts = [app: "fixture-app", ran_at: ~U[2026-10-02 09:15:00Z]]

    reordered =
      Enum.map(recording.observations, fn
        %{kind: :record_set, value: v} = o ->
          %{o | value: %{v | records: Enum.reverse(v.records)}}

        o ->
          o
      end)

    assert {:ok, %Result{status: :pass}} = Matrix.result(scenario, recording, reordered, opts)
  end

  describe "intended differences: the target policy is stricter than Bubble (WTF-426)" do
    # Several flags can apply to one case: each case names those its
    # verdict rests on, never the whole policy by default, and Bubble's
    # reading with just those at their target reading gives the case's
    # target value.
    test "each case names the flags that explain it; several may apply", %{
      pmodel: model,
      policies: matrix
    } do
      {:ok, bubble} = Interpreter.new(model)
      {:ok, ds} = Dataset.from_seed(matrix.seed)
      all = Difference.flags(:rule_conditions)

      assert Enum.any?(matrix.differences, &match?([_, _ | _], &1.flags))
      refute Enum.any?(matrix.differences, &(&1.flags == all))

      for %{kind: kind} = c <- matrix.differences, kind in [:visible, :visible_fields] do
        overrides = Map.new(c.flags, &{&1, Difference.policy()[&1].target})

        {:ok, reading} =
          Interpreter.with_assumptions(bubble, Map.merge(bubble.assumptions, overrides))

        user = matrix.seed.personas[c.persona].user
        {:ok, access} = Interpreter.access(reading, ds, user, c.record)
        value = if kind == :visible, do: access.visible, else: access.fields
        assert value == c.target, "#{c.scenario} #{c.op} #{kind} #{inspect(c.flags)}"
      end
    end

    test "every case is stricter, explained by the policy's flags, and none is unintended",
         %{pmodel: model, policies: matrix} do
      {:ok, bubble} = Interpreter.new(model)
      target = Interpreter.target(bubble)
      {:ok, ds} = Dataset.from_seed(matrix.seed)

      assert matrix.differences != []
      assert matrix.unintended == []
      assert matrix.report.differences.unintended == 0
      assert matrix.report.differences.observations == length(matrix.differences)

      for c <- matrix.differences do
        assert c.flags != [] and c.flags -- Difference.flags(:rule_conditions) == []
        assert c.bubble != c.target
        assert Difference.stricter?(c.kind, c.bubble, c.target)
        user = matrix.seed.personas[c.persona].user

        # bubble is the recording's value; target what the policies' reading gives
        recording = Enum.find(matrix.recordings, &(&1.scenario.id == c.scenario))

        assert Enum.any?(
                 recording.observations,
                 &(&1.op == c.op and &1.kind == c.kind and &1.value == c.bubble)
               )

        case c.kind do
          :visible ->
            assert {:ok, %{visible: v}} = Interpreter.access(target, ds, user, c.record)
            assert v == c.target

          :visible_fields ->
            assert {:ok, %{fields: f}} = Interpreter.access(target, ds, user, c.record)
            assert f == c.target

          :record_set ->
            scenario = Enum.find(matrix.scenarios, &(&1.id == c.scenario))

            {:ok, search} =
              case Scenario.op(scenario, c.op) do
                %{constrain: field} -> Interpreter.search(target, ds, user, c.type, field)
                _ -> Interpreter.search(target, ds, user, c.type)
              end

            assert Enum.sort(search.records) == c.target.records
        end
      end

      # the logged-out user sees the empty board through lead_ in Bubble only
      assert %Difference{
               kind: :visible,
               bubble: true,
               target: false,
               rules: ["lead_"],
               flags: [:actor_empty_denies]
             } =
               Enum.find(
                 matrix.differences,
                 &(&1.scenario == "privacy_read.custom.board.anonymous" and &1.op == "get.e.board" and
                     &1.kind == :visible)
               )

      assert [%{type: "board", rule: "lead_", flags: [:actor_empty_denies]} | _] =
               matrix.report.intended_differences
    end

    # WTF-467: Bubble reads an empty yes/no as no. `x is no` on an empty x
    # grants in Bubble, not in the policies (`x == false`): stricter, an
    # intended difference. `x is not no` is the other way round: the
    # policies' `is_distinct_from(x, false)` grants where Bubble does not,
    # an unintended difference the generated tests fail on.
    test "an empty yes/no: `is no` is stricter by policy, `is not no` is not" do
      condition = fn next ->
        %{
          "type" => "InjectedValue",
          "next" => %{"type" => "Message", "name" => "flag_boolean", "next" => next}
        }
      end

      type = fn next ->
        %{
          "display" => "T",
          "fields" => %{"flag_boolean" => %{"display" => "Flag", "value" => "boolean"}},
          "privacy_role" => %{
            "everyone" => %{
              "display" => "everyone",
              "permissions" => %{"view_all" => false, "search_for" => false}
            },
            "r_" => %{
              "display" => "R",
              "condition" => condition.(next),
              "permissions" => %{"view_all" => true, "search_for" => true}
            }
          }
        }
      end

      is_no = %{"type" => "Message", "name" => "is_false"}

      {:ok, model} =
        Model.build(%{
          "_id" => "yes_no",
          "user_types" => %{
            "is_no" => type.(is_no),
            "is_not_no" => type.(Map.put(is_no, "next", is_no))
          }
        })

      {:ok, matrix} = Matrix.synthesize(model, app: "fixture-app")

      assert matrix.differences != []

      assert Enum.all?(
               matrix.differences,
               &(&1.type == "is_no" and &1.flags == [:empty_yes_no_is_no] and &1.rules == ["r_"])
             )

      assert matrix.unintended != []
      assert Enum.all?(matrix.unintended, &(&1.scenario =~ ".is_not_no."))
      assert matrix.report.differences.unintended == length(matrix.unintended)
    end

    test "the structural list names every rule reading the current user", %{pmodel: model} do
      list = Difference.structural(model)
      actor = [:actor_empty_denies, :logged_out_user_is_empty]
      # each entry names its own flags (Difference.rule_flags/1)
      assert %{type: "board", rule: "lead_", flags: actor} in list
      assert %{type: "doc", rule: "owner_", flags: actor} in list
      # doc's everyone rule grants a field every other rule grants too: its
      # reach is `always` in both readings
      refute Enum.any?(list, &(&1.type == "doc" and &1.rule == "everyone"))
      # note's everyone rule grants what hidden_ lacks: Bubble reaches every
      # user with it, the policies only those hidden_ does not match (WTF-467)
      assert %{type: "note", rule: "everyone", flags: Difference.everyone_flags()} in list
      assert Enum.all?(list, &(&1.flags in [actor, Difference.everyone_flags()]))
      refute Enum.any?(list, &(&1.type == "note" and &1.rule == "hidden_"))
    end

    test "result/4 holds the subject to the target policy", %{policies: matrix} do
      id = "privacy_read.custom.board.anonymous"
      scenario = Enum.find(matrix.scenarios, &(&1.id == id))
      recording = Enum.find(matrix.recordings, &(&1.scenario.id == id))
      cases = Difference.for_scenario(matrix.differences, id)
      assert cases != []
      now = ~U[2026-10-02 09:15:00Z]
      opts = [app: "fixture-app", ran_at: now, differences: matrix.differences]
      evaluate = [now: now, app: "fixture-app", recording: recording]

      # the subject is stricter exactly where the policy says: reported, passing
      stricter = Difference.to_target(recording.observations, cases)

      assert {:ok, %Result{status: :intended_difference, diff: diff} = result} =
               Matrix.result(scenario, recording, stricter, opts)

      assert Enum.all?(diff, &(&1.intended == ["actor_empty_denies"] and &1.rules != []))
      assert {:ok, ^result} = result |> Result.to_json() |> Result.from_json()

      assert {:ok, %{passing: true, bubble_verified: false, intended: ^diff}} =
               Result.evaluate(result, %Resolved{}, [
                 {:differences, matrix.differences} | evaluate
               ])

      assert [%{result: ^id, intended: ["actor_empty_denies"]} | _] =
               Result.intended_differences([result])

      # without the difference record, or with another scenario's, it does not count
      assert {:error, %{kind: :invalid_input}} = Result.evaluate(result, %Resolved{}, evaluate)

      assert {:error, %{kind: :invalid_input}} =
               Result.evaluate(result, %Resolved{}, [{:differences, []} | evaluate])

      # a subject granting what Bubble grants there fails: the leak is not the policy
      assert {:ok, %Result{status: :fail, diff: [_ | _] = diff}} =
               Matrix.result(scenario, recording, recording.observations, opts)

      assert Enum.all?(diff, &(&1[:detail] =~ "stricter than Bubble"))

      # without the differences the stricter subject fails
      assert {:ok, %Result{status: :fail}} =
               Matrix.result(scenario, recording, stricter, Keyword.delete(opts, :differences))
    end

    test "evaluate/3 with the recording refuses a diff that leaves out a recorded case",
         %{policies: matrix} do
      {id, _} =
        matrix.differences
        |> Enum.group_by(& &1.scenario, &{&1.op, &1.record})
        |> Enum.find(fn {_, ops} -> ops |> Enum.uniq() |> length() > 1 end)

      scenario = Enum.find(matrix.scenarios, &(&1.id == id))
      recording = Enum.find(matrix.recordings, &(&1.scenario.id == id))
      cases = Difference.for_scenario(matrix.differences, id)
      now = ~U[2026-10-02 09:15:00Z]

      {:ok, %Result{status: :intended_difference} = full} =
        Matrix.result(scenario, recording, Difference.to_target(recording.observations, cases),
          app: "fixture-app",
          ran_at: now,
          differences: matrix.differences
        )

      evaluate = [now: now, app: "fixture-app", differences: matrix.differences]

      assert {:ok, %{passing: true}} =
               Result.evaluate(full, %Resolved{}, [{:recording, recording} | evaluate])

      # drop every entry of one record: still listed, but incomplete
      dropped = hd(full.diff)[:record] || hd(full.diff)[:op]
      kept = Enum.reject(full.diff, &((&1[:record] || &1[:op]) == dropped))
      assert kept != []
      {:ok, truncated} = full |> Map.from_struct() |> Map.put(:diff, kept) |> Result.new()

      assert {:ok, %{passing: true}} = Result.evaluate(truncated, %Resolved{}, evaluate)

      assert {:error, %{message: "the result's diff leaves out" <> _}} =
               Result.evaluate(truncated, %Resolved{}, [{:recording, recording} | evaluate])
    end

    test "a hidden record from a fields case needs the held fields; a missing op never counts" do
      fields = %Difference{
        scenario: "s",
        op: "get.r",
        kind: :visible_fields,
        record: "r",
        type: "t",
        bubble: ["Created Date", "title_text"],
        target: ["Created Date"],
        flags: [:actor_empty_denies]
      }

      hidden = %{op: "record_visible", record: "r", expected: true, actual: false}
      # without the Data API's view, fewer fields never hide the record
      assert Difference.explaining([fields], hidden) == nil
      # the target still shows a held field: the record is not ID-only
      assert Difference.explaining([fields], hidden, %{"r" => ["Created Date"]}) == nil
      # no held field left: ID-only, so hidden through the Data API
      assert Difference.explaining([%{fields | target: ["body_text"]}], hidden, %{
               "r" => ["Created Date"]
             })

      visible = %{fields | kind: :visible, bubble: true, target: false}
      assert Difference.explaining([visible], hidden) == visible
      assert Difference.explaining([visible], %{hidden | actual: nil}) == nil

      assert {:error, _} =
               Result.new(
                 id: "s",
                 app: "fixture-app",
                 check: "privacy_read",
                 status: :intended_difference,
                 scenario: %{
                   id: "s",
                   sha256: String.duplicate("a", 64),
                   source_sha256: String.duplicate("b", 64),
                   seed_sha256: String.duplicate("c", 64)
                 },
                 oracle: %{kind: :model, sha256: String.duplicate("d", 64)},
                 diff: [Map.merge(%{hidden | actual: nil}, %{intended: ["actor_empty_denies"]})],
                 actor: "ci",
                 ran_at: ~U[2026-10-02 09:15:00Z]
               )
    end

    test "an intended difference must be stricter and name the policy's flags" do
      base = %{
        id: "privacy_read.custom.board.anonymous",
        scenario: %{
          id: "privacy_read.custom.board.anonymous",
          sha256: String.duplicate("a", 64),
          source_sha256: String.duplicate("b", 64),
          seed_sha256: String.duplicate("c", 64)
        },
        oracle: %{kind: :model, sha256: String.duplicate("d", 64)},
        app: "fixture-app",
        check: "privacy_read",
        status: :intended_difference,
        actor: "ci",
        ran_at: ~U[2026-10-02 09:15:00Z]
      }

      entry = %{op: "record_visible", record: "e.board", expected: true, actual: false}

      assert {:ok, _} =
               Result.new(
                 Map.put(base, :diff, [Map.put(entry, :intended, ["actor_empty_denies"])])
               )

      assert {:error, _} = Result.new(Map.put(base, :diff, [entry]))

      assert {:error, _} =
               Result.new(
                 Map.put(base, :diff, [
                   %{entry | expected: false, actual: true}
                   |> Map.put(:intended, ["actor_empty_denies"])
                 ])
               )

      assert {:error, _} =
               Result.new(
                 Map.put(base, :diff, [Map.put(entry, :intended, ["empty_equals_empty"])])
               )

      assert {:error, _} =
               Result.new(
                 base
                 |> Map.put(:check, "row_counts")
                 |> Map.put(:diff, [Map.put(entry, :intended, ["actor_empty_denies"])])
               )
    end
  end

  defp recorded_cells(matrix) do
    for scenario <- matrix.scenarios,
        %{op: :get, record: key} <- scenario.ops,
        reduce: %{} do
      acc ->
        type = Dataset.type_id(scenario.subjects.type)
        user = matrix.seed.personas[scenario.persona].user
        Map.update(acc, type, [{user, key}], &[{user, key} | &1])
    end
  end
end
