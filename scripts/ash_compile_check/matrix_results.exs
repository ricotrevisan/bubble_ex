# Scores the generated privacy-matrix tests (BubbleEx.Target.Ash.MatrixTests,
# WTF-383), run by scripts/ash_compile_check.sh after `mix test` in the
# scratch project wrote their observations to <scratch>/observations:
#
#     MIX_ENV=test mix run scripts/ash_compile_check/matrix_results.exs <scratch dir>
#
# For every fixture in <scratch>/matrix_index.json (written by render.exs)
# it decodes the matrix files (<scratch>/matrix/<name>/.wtf/verification),
# turns the observations into one BubbleEx.Verify.Result per scenario
# (MatrixTests.results/3), writes them to <scratch>/matrix/<name>/results/
# and scores each with Result.evaluate/3 against its recording and no
# decisions. It prints scenarios, ops, compared observations, results by
# status, passing and Bubble-verified counts (always 0: the oracle is the
# model) and the ops the interpreter could not decide (left out of the
# matrix), and fails unless every result passes.

alias BubbleEx.Decision.Resolved
alias BubbleEx.Target.Ash.MatrixTests
alias BubbleEx.Verify.Result

[dir] = System.argv()
index = Path.join(dir, "matrix_index.json") |> File.read!() |> Jason.decode!()
now = DateTime.utc_now() |> DateTime.truncate(:second)

failures =
  for %{"name" => name, "app" => app, "module" => module, "skipped" => skipped} <- index do
    root = Path.join([dir, "matrix", name])

    files =
      for path <- Path.wildcard(Path.join(root, ".wtf/verification/**/*.json")),
          do: {Path.relative_to(path, root), File.read!(path)}

    {:ok, plan} = MatrixTests.plan(files)

    observed_dir = MatrixTests.observations_dir(Path.join(dir, "observations"), module)

    {:ok, observed} =
      if File.dir?(observed_dir), do: MatrixTests.read_observations(observed_dir), else: {:ok, %{}}

    {:ok, results} = MatrixTests.results(plan, observed, app: app, ran_at: now)

    results_dir = Path.join(root, "results")
    File.rm_rf!(results_dir)
    File.mkdir_p!(results_dir)

    verdicts =
      for result <- results do
        File.write!(Path.join(results_dir, result.id <> ".json"), Result.to_json(result))

        {:ok, verdict} =
          Result.evaluate(result, %Resolved{entries: []},
            now: now,
            app: app,
            recording: MatrixTests.recording_for(plan, result.id)
          )

        verdict
      end

    statuses = Enum.frequencies_by(results, &Atom.to_string(&1.status))
    passing = Enum.count(verdicts, & &1.passing)
    verified = Enum.count(verdicts, & &1.bubble_verified)
    ops = plan.scenarios |> Enum.map(&length(&1.ops)) |> Enum.sum()
    compared = plan.recordings |> Enum.map(&length(&1.observations)) |> Enum.sum()

    IO.puts(
      "privacy matrix #{name}: #{length(results)} scenarios, #{ops} ops, #{compared} observations compared; " <>
        "results #{inspect(statuses)}; passing #{passing}/#{length(results)}, Bubble-verified #{verified} " <>
        "(oracle model); undecided by the interpreter, left out: #{skipped["gets"]} gets, " <>
        "#{skipped["searches"]} searches"
    )

    for %{result: r, passing: false} <- verdicts do
      "#{name} #{r.id}: #{r.status} #{r.reason || ""}#{inspect(Enum.take(r.diff, 5))}"
    end
  end
  |> List.flatten()

if failures != [] do
  failures |> Enum.take(50) |> Enum.each(&IO.puts/1)
  raise "privacy matrix check failed: #{length(failures)} scenarios not passing"
end

IO.puts("privacy matrix check passed: every generated scenario passes against its expected recording")
