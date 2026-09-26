defmodule BubbleEx.Verify.MatrixTest do
  # Privacy-matrix synthesis (WTF-382): personas, seeds, scenarios and
  # model recordings for the policy and expression fixture apps.
  use ExUnit.Case, async: true

  alias BubbleEx.Decision.Resolved
  alias BubbleEx.Model
  alias BubbleEx.Test.{ExpressionFixture, PermutedJson}
  alias BubbleEx.Verify
  alias BubbleEx.Verify.{Interpreter, Matrix, Recording, Result, Scenario, Seed}
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

    assert %{total: 38, solved: 34, conditional: 33, everyone: 5} =
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
          {:ok, search} =
            Interpreter.search(interpreter, ds, user, Dataset.type_id(scenario.subjects.type))

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

    # anonymous: every doc is either unknown or partly unknown (raw_ grants
    # view_all), so there is no scenario; an admin's is fully decided.
    ids = Enum.map(matrix.scenarios, & &1.id)
    refute "privacy_read.custom.doc.anonymous" in ids
    assert "privacy_read.custom.doc.admin" in ids
    refute "privacy_read.custom.memo.admin" in ids
    assert matrix.report.checks == matrix.scenarios |> Enum.map(&length(&1.ops)) |> Enum.sum()
  end

  test "dependencies name the assumptions an op's expectations rest on", %{policies: matrix} do
    # board's lead_ rule: This's owner is Current User's team's lead. The
    # empty board is hidden from a logged-out user; it would be readable
    # with no fields if such records were, and visible outright if the
    # user's empty values compared (an empty owner is an empty lead).
    assert matrix.dependencies[{"privacy_read.custom.board.anonymous", "get.e.board"}] ==
             [:actor_empty_denies, :no_visible_field_unreadable]

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
    assert doc["assumptions"]["actor_empty_denies"] == true
    assert doc["dependencies"] != []

    counts = Matrix.counts(matrix.report)
    refute Map.has_key?(counts, "unsolved")
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
    assert matrix.flags[:defaults_applied_at_creation] == :exercised

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

    assert {:ok, %Result{status: :fail, diff: [%{op: "record_set", actual: nil}]}} =
             Matrix.result(scenario, recording, missing, opts)
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

      assert matrix.report.rules.observable == 8

      assert matrix.report.unobservable_by_reason == %{
               "grants_nothing" => 1,
               "undecided_type" => 1,
               "unsolved" => 4
             }

      assert %{type: "board", rule: "everyone", reason: :grants_nothing} in Enum.map(
               matrix.report.unobservable,
               &Map.take(&1, [:type, :rule, :reason])
             )
    end

    test "the everyone rule's status uses the verdicts' own reach", %{
      pmodel: model,
      policies: matrix
    } do
      {:ok, interpreter} = Interpreter.new(model)
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
      assert map_size(matrix.flags) == 16
      assert matrix.flags[:everyone_guards_record_values] == :exercised
      assert {:not_exercised, "seeds cannot hold" <> _} = matrix.flags[:dangling_ref_is_empty]

      for {flag, :exercised} <- matrix.flags do
        assert Enum.any?(matrix.dependencies, fn {_, flags} -> flag in flags end), "#{flag}"
      end

      outcomes = matrix.report.assumptions.outcomes
      assert outcomes["everyone_exclusive"] == "exercised"
      assert matrix.report.rules.false_branch_only_via_actor_guard == 0
      assert Enum.all?(matrix.rules, &(&1.robust_false in [true, nil]))
    end

    test "counts carry no Bubble IDs of unobservable rules", %{policies: matrix} do
      counts = Matrix.counts(matrix.report)
      refute Map.has_key?(counts, "unobservable")
      assert counts["rules"]["observable"] == 8
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
