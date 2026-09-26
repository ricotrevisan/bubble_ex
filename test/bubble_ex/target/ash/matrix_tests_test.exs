defmodule BubbleEx.Target.Ash.MatrixTestsTest do
  # Generated privacy-matrix tests (WTF-383). What the emitted module does
  # against PostgreSQL is checked by scripts/ash_compile_check.sh (it runs
  # them); here: the source's shape, determinism, the oracle choice, the
  # seed conversion and the results built from observations.
  use ExUnit.Case, async: true

  alias BubbleEx.Decision.Resolved
  alias BubbleEx.Model
  alias BubbleEx.Target.Ash
  alias BubbleEx.Target.Ash.MatrixTests
  alias BubbleEx.Verify.{Matrix, Observation, Recording, Result, Seed}

  @policy_app "test/support/target/ash/policies.json" |> File.read!() |> Jason.decode!()
  @opts [namespace: "Fixtures.TargetPolicies", repo: "Fixtures.TargetPoliciesRepo"]
  @now ~U[2026-10-02 09:15:00Z]

  setup_all do
    {:ok, model} = Model.build(@policy_app)
    {:ok, matrix} = Matrix.synthesize(model, app: "fixture-app")
    {:ok, project} = Ash.map(model, [], privacy: :unverified)
    {:ok, out} = MatrixTests.render(project, matrix, @opts)
    %{model: model, matrix: matrix, project: project, out: out}
  end

  defp scenario(matrix, id), do: Enum.find(matrix.scenarios, &(&1.id == id))
  defp recording(matrix, id), do: Enum.find(matrix.recordings, &(&1.scenario.id == id))

  test "one test per scenario, the seed keyed by Bubble IDs, observations in Bubble vocabulary",
       %{matrix: matrix, out: out} do
    {:ok, quoted} = Code.string_to_quoted(out.source)

    assert {:defmodule, _,
            [{:__aliases__, _, [:Fixtures, :TargetPolicies, :PrivacyMatrixTest]}, _]} = quoted

    assert out.module == "Fixtures.TargetPolicies.PrivacyMatrixTest"
    assert out.counts["scenarios"] == length(matrix.scenarios)
    assert out.counts["oracles"] == %{"model" => length(matrix.scenarios)}

    assert out.counts["observations"] ==
             matrix.recordings |> Enum.map(&length(&1.observations)) |> Enum.sum()

    for s <- matrix.scenarios, do: assert(out.source =~ ~s(test "#{s.id}"))

    # every seed record, with a Bubble-shaped primary key
    assert map_size(out.ids) == length(matrix.seed.records)
    assert Enum.all?(Map.values(out.ids), &(&1 =~ ~r/^\d{13}x\d{18}$/))
    assert out.source =~ ~s("u.w1_member" => "#{out.ids["u.w1_member"]}")

    # references are seeded as the referenced record's primary key
    assert out.source =~ ~s(owner_id: "#{out.ids["u.w1_member"]}")
    assert out.source =~ "Ash.Seed.seed!(resource, attributes)"
    assert out.source =~ "Fixtures.TargetPolicies.Privacy"
    assert out.source =~ "load_actor"
    assert out.source =~ "Ash.Query.for_read(resource, :search"
    assert out.source =~ "Ash.ForbiddenField"
    assert out.source =~ "never Bubble-verified"

    assert out.source =~
             ~s({"get.r.note.2", :visible_fields, "r.note.2", )
  end

  test "deterministic", %{project: project, matrix: matrix, out: out} do
    assert {:ok, ^out} = MatrixTests.render(project, matrix, @opts)
    assert MatrixTests.synthetic_id("a") == MatrixTests.synthetic_id("a")
    refute MatrixTests.synthetic_id("a") == MatrixTests.synthetic_id("b")
  end

  test "renders the same from the owner-repo files", %{project: project, matrix: matrix, out: out} do
    {:ok, plan} = matrix |> Matrix.files() |> MatrixTests.plan()
    assert {:ok, ^out} = MatrixTests.render(project, plan, @opts)
  end

  test "a ledger binds seed keys to Bubble IDs", %{project: project, matrix: matrix} do
    {:ok, out} = MatrixTests.render(project, matrix, @opts ++ [ledger: %{"u.admin" => "1x1"}])
    assert out.ids["u.admin"] == "1x1"
    assert out.source =~ ~s("u.admin" => "1x1")

    assert {:error, %{message: "two seed records share a primary key"}} =
             MatrixTests.render(
               project,
               matrix,
               @opts ++ [ledger: %{"u.admin" => "1x1", "e.user" => "1x1"}]
             )
  end

  test "needs policies: privacy: :omit is refused", %{model: model, matrix: matrix} do
    {:ok, omitted} = Ash.map(model, [], privacy: :omit)
    assert {:error, %{kind: :invalid_input}} = MatrixTests.render(omitted, matrix, @opts)
  end

  # The matrix with `key`'s fields changed, its recordings re-pinned to the
  # new seed (else they are stale).
  defp reseeded(matrix, key, fields) do
    records =
      Enum.map(matrix.seed.records, &if(&1.key == key, do: %{&1 | fields: fields}, else: &1))

    seed = %{matrix.seed | records: records}
    sha = Seed.sha256(seed)
    %{matrix | seed: seed, recordings: Enum.map(matrix.recordings, &%{&1 | seed_sha256: sha})}
  end

  test "a changed seed makes the model recordings stale", %{project: project, matrix: matrix} do
    stale = %{matrix | seed: %{matrix.seed | id: "other"}}

    assert {:error, %{message: "the recording is stale", context: %{reasons: [:seed_changed]}}} =
             MatrixTests.render(project, stale, @opts)
  end

  test "a seed value with no attribute or of another type is an error",
       %{project: project, matrix: matrix} do
    user = Enum.find(matrix.seed.records, &(&1.key == "u.w1_member"))
    unknown = reseeded(matrix, user.key, Map.put(user.fields, "no_such_field", {:text, "x"}))

    assert {:error, %{message: "no attribute for seed field", context: %{field: "no_such_field"}}} =
             MatrixTests.render(project, unknown, @opts)

    mistyped = reseeded(matrix, user.key, Map.put(user.fields, "admin_boolean", {:text, "yes"}))

    assert {:error,
            %{message: "cannot seed a text value" <> _, context: %{record: "u.w1_member"}}} =
             MatrixTests.render(project, mistyped, @opts)
  end

  describe "oracles" do
    setup %{matrix: matrix} do
      id = "privacy_read.custom.note.w1_member"
      s = scenario(matrix, id)
      model = recording(matrix, id)

      {:ok, bubble} =
        %{model | oracle: :bubble, source: %{app: "fixture-app", branch: "wtfreplay"}}
        |> Map.from_struct()
        |> Recording.new()

      %{id: id, bubble: bubble, s: s}
    end

    test "a Bubble recording is preferred over the model's",
         %{project: project, matrix: matrix} = ctx do
      {:ok, out} = MatrixTests.render(project, matrix, @opts ++ [recordings: [ctx.bubble]])
      assert out.counts["oracles"] == %{"bubble" => 1, "model" => length(matrix.scenarios) - 1}
      assert out.source =~ "@tag oracle: :bubble"

      # the result cites the Bubble recording and its branch
      observed = %{ctx.id => ctx.bubble.observations}

      {:ok, results} =
        MatrixTests.results(matrix, observed,
          app: "fixture-app",
          ran_at: @now,
          recordings: [ctx.bubble]
        )

      result = Enum.find(results, &(&1.id == ctx.id))
      assert result.status == :pass

      assert result.oracle == %{
               kind: :bubble,
               sha256: Recording.sha256(ctx.bubble),
               branch: "wtfreplay"
             }
    end

    test "a stale, incomplete or model recording in :recordings is an error",
         %{project: project, matrix: matrix} = ctx do
      stale = %{ctx.bubble | seed_sha256: String.duplicate("0", 64)}

      assert {:error, %{message: "the recording is stale"}} =
               MatrixTests.render(project, matrix, @opts ++ [recordings: [stale]])

      incomplete = %{ctx.bubble | complete: false}

      assert {:error, %{message: "the recording is incomplete"}} =
               MatrixTests.render(project, matrix, @opts ++ [recordings: [incomplete]])

      assert {:error, %{message: "recordings: expected Bubble recordings"}} =
               MatrixTests.render(
                 project,
                 matrix,
                 @opts ++ [recordings: [recording(matrix, ctx.id)]]
               )
    end
  end

  describe "results" do
    test "observations matching the model recording pass, never Bubble-verified",
         %{matrix: matrix} do
      observed = Map.new(matrix.recordings, &{&1.scenario.id, &1.observations})
      {:ok, results} = MatrixTests.results(matrix, observed, app: "fixture-app", ran_at: @now)

      assert length(results) == length(matrix.scenarios)
      assert Enum.all?(results, &(&1.status == :pass))

      for r <- results do
        assert {:ok, %{passing: true, bubble_verified: false}} =
                 Result.evaluate(r, %Resolved{entries: []},
                   now: @now,
                   app: "fixture-app",
                   recording: MatrixTests.recording_for(matrix, r.id)
                 )
      end
    end

    test "a leaked field fails with a diff; a scenario not run is an error", %{matrix: matrix} do
      id = "privacy_read.custom.note.w1_member"

      leaked =
        Enum.map(recording(matrix, id).observations, fn
          %Observation{kind: :visible_fields, value: [_ | _] = v} = o ->
            %{o | value: Enum.sort(["secret" | v])}

          o ->
            o
        end)

      {:ok, results} =
        MatrixTests.results(matrix, %{id => leaked}, app: "fixture-app", ran_at: @now)

      by_id = Map.new(results, &{&1.id, &1})

      assert %Result{status: :fail, diff: [_ | _] = diff} = by_id[id]
      assert Enum.all?(diff, &(&1.op == "field_visible" and &1.field == "secret"))

      other = Enum.find(results, &(&1.id != id))
      assert other.status == :error
      assert other.reason =~ "not run"
    end

    test "read_observations/1 reads what the generated tests write", %{matrix: matrix} do
      dir = Path.join(System.tmp_dir!(), "matrix_tests_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      rec = recording(matrix, "privacy_read.custom.note.w1_member")
      module_dir = MatrixTests.observations_dir(dir, "Fixtures.TargetPolicies.PrivacyMatrixTest")
      File.mkdir_p!(module_dir)

      # the JSON the emitted write/2 produces
      doc = %{
        "format" => "bubble_ex.verify.observations",
        "schema_version" => 1,
        "scenario" => rec.scenario.id,
        "observations" => Enum.map(rec.observations, &Observation.to_map/1)
      }

      File.write!(Path.join(module_dir, rec.scenario.id <> ".json"), Jason.encode!(doc))

      assert {:ok, %{"privacy_read.custom.note.w1_member" => observations}} =
               MatrixTests.read_observations(module_dir)

      assert Observation.sort(observations) == Observation.sort(rec.observations)

      File.write!(Path.join(module_dir, "bad.json"), Jason.encode!(%{doc | "format" => "x"}))
      assert {:error, _} = MatrixTests.read_observations(module_dir)
    end
  end
end
