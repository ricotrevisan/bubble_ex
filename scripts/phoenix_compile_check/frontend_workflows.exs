# Runs `mix wtf.task` (WTF-375) against the scratch project of the frontend
# workflows fixture (WTF-372): writes the fixture's plan (with its
# normalized frontend and the lowering's residue) to .wtf/plan.json, checks
# that every generated workflow test is tagged with a workflow task of the
# plan, formats the project (see below), then, in plan order, claims and
# completes every workflow task whose workflow was generated whole (one
# waiting on a task left to agent work, such as a custom event with
# residue, cannot be claimed and is skipped). `complete` runs the task's
# criteria (mix compile --warnings-as-errors, mix format --check-formatted,
# and step_order: one `# bubble:workflow <id>` marker with one
# `# bubble:step N <type>` per action, in order); it raises unless every
# criterion passes. Finally it
# runs the tests tagged with each of those tasks (`mix test --only
# bubble:workflow:<id>`, the task CLI's tagged-test binding).
#
#     MIX_ENV=test mix run scripts/phoenix_compile_check/frontend_workflows.exs <dir> <fixture.json>

alias BubbleEx.{Index, Model, Plan}
alias BubbleEx.Target.Elixir.FrontendWorkflows
alias BubbleEx.Workflows.Frontend

[dir, fixture] = System.argv()
app = fixture |> File.read!() |> Jason.decode!()
{:ok, model} = Model.build(app)
{:ok, index} = Index.build(app, model: model)
{:ok, frontend} = BubbleEx.Frontend.normalize(app)
{:ok, lowered} = Frontend.build(app, model, index)
{:ok, plan} = Plan.build(model, index, frontend, [], residue: Frontend.residue(lowered))
:ok = BubbleEx.Tasks.Store.write_plan(dir, plan)

{:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
{:ok, spec} = FrontendWorkflows.map(lowered, project, namespace: "PhxCheck", frontend: frontend)

workflow_tasks = for t <- plan.tasks, t.kind == :workflow, into: MapSet.new(), do: t.id
native = for w <- FrontendWorkflows.Spec.workflows(spec), FrontendWorkflows.Spec.native?(w), do: w.symbol

# Every generated workflow test carries a literal tag the plan knows.
test_file = Path.join(dir, "test/phx_check_web/bubble_workflows_test.exs")

tags =
  Regex.scan(~r/@tag bubble: "(workflow:[^"]+)"/, File.read!(test_file), capture: :all_but_first)
  |> List.flatten()

if tags == [] or Enum.sort(tags) != Enum.sort(native),
  do: raise("the generated workflow tests are not tagged with the native workflows")

for tag <- tags, not MapSet.member?(workflow_tasks, tag),
    do: raise("#{tag} is not a workflow task of the plan")

order = plan.tasks |> Enum.with_index() |> Map.new(fn {t, i} -> {t.id, i} end)

tasks =
  native
  |> Enum.filter(&MapSet.member?(workflow_tasks, &1))
  |> Enum.sort_by(&order[&1])

if tasks == [], do: raise("no workflow task for a generated workflow in #{fixture}")

# The owner's first `mix format`: the scaffold's HEEx templates, router,
# runtime config and smoke test are not formatter-clean as generated
# (WTF-369/370), so `lint` fails on a fresh project for every task. The
# workflow modules and tests of this ticket are formatted as generated.
{_, 0} = System.cmd("mix", ["format"], cd: dir, env: [{"MIX_ENV", "test"}])

completed =
  Enum.filter(tasks, fn id ->
    try do
      Mix.Task.rerun("wtf.task", ["claim", id, "--agent", "ci", "--root", dir])
      true
    rescue
      e in Mix.Error ->
        if String.contains?(Exception.message(e), "waits on"),
          do: (IO.puts("skipped #{id}: #{Exception.message(e)}"); false),
          else: reraise(e, __STACKTRACE__)
    end
    |> tap(fn claimed? ->
      if claimed?, do: Mix.Task.rerun("wtf.task", ["complete", id, "--agent", "ci", "--root", dir])
    end)
  end)

if completed == [], do: raise("no workflow task completed")

for id <- completed do
  {output, status} =
    System.cmd("mix", ["test", "--only", "bubble:" <> id],
      cd: dir,
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )

  if status != 0, do: raise("mix test --only bubble:#{id} failed:\n#{output}")
end

IO.puts(
  "wtf.task complete: #{length(completed)} workflow tasks pass compiles, lint and step_order; " <>
    "their tagged tests pass"
)
