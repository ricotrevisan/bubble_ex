# Runs `mix wtf.task` (WTF-375) against the scratch project of the frontend
# workflows fixture (WTF-372): writes the fixture's plan (with its
# normalized frontend and the lowering's residue) to .wtf/plan.json, checks
# that every generated workflow smoke test is tagged (`bubble_smoke:`, as
# the backend's) with a workflow task of the plan, then, in plan order,
# claims and
# completes every workflow task whose workflow was generated whole (one
# waiting on a task left to agent work, such as a custom event with
# residue, cannot be claimed and is skipped). `complete` runs the task's
# criteria (mix compile --warnings-as-errors, mix format --check-formatted,
# and step_order: one `# bubble:workflow <id>` marker with one
# `# bubble:step N <type>` per action, in order); it raises unless every
# criterion passes; none of them runs mix test, so no test database is
# named (WTF-448). Finally it
# runs the smoke tests tagged with each of those tasks (`mix test --only
# bubble_smoke:workflow:<id>`; exit status only, as the task CLI's
# tagged-test binding).
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
{:ok, backend_lowered} = BubbleEx.Workflows.Backend.build(app, model, index)

{:ok, backend} =
  BubbleEx.Target.Ash.Workflows.map(backend_lowered, project, namespace: "PhxCheck")

{:ok, spec} =
  FrontendWorkflows.map(lowered, project,
    namespace: "PhxCheck",
    frontend: frontend,
    backend: backend
  )

workflow_tasks = for t <- plan.tasks, t.kind == :workflow, into: MapSet.new(), do: t.id

native =
  for w <- FrontendWorkflows.Spec.workflows(spec), FrontendWorkflows.Spec.native?(w), do: w.symbol

# Every generated workflow test carries a literal tag the plan knows.
test_file = Path.join(dir, "test/phx_check_web/bubble_frontend_workflows_test.exs")

tags =
  Regex.scan(~r/@tag bubble_smoke: "(workflow:[^"]+)"/, File.read!(test_file),
    capture: :all_but_first
  )
  |> List.flatten()

if tags == [] or Enum.sort(tags) != Enum.sort(native),
  do: raise("the generated workflow smoke tests are not tagged with the native workflows")

for tag <- tags,
    not MapSet.member?(workflow_tasks, tag),
    do: raise("#{tag} is not a workflow task of the plan")

order = plan.tasks |> Enum.with_index() |> Map.new(fn {t, i} -> {t.id, i} end)

tasks =
  native
  |> Enum.filter(&MapSet.member?(workflow_tasks, &1))
  |> Enum.sort_by(&order[&1])

if tasks == [], do: raise("no workflow task for a generated workflow in #{fixture}")

completed =
  Enum.filter(tasks, fn id ->
    try do
      Mix.Task.rerun("wtf.task", ["claim", id, "--agent", "ci", "--root", dir])
      true
    rescue
      e in Mix.Error ->
        if String.contains?(Exception.message(e), "waits on"),
          do:
            (
              IO.puts("skipped #{id}: #{Exception.message(e)}")
              false
            ),
          else: reraise(e, __STACKTRACE__)
    end
    |> tap(fn claimed? ->
      if claimed?,
        do: Mix.Task.rerun("wtf.task", ["complete", id, "--agent", "ci", "--root", dir])
    end)
  end)

if completed == [], do: raise("no workflow task completed")

for id <- completed do
  {output, status} =
    System.cmd("mix", ["test", "--only", "bubble_smoke:" <> id],
      cd: dir,
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )

  if status != 0, do: raise("mix test --only bubble_smoke:#{id} failed:\n#{output}")
end

IO.puts(
  "wtf.task complete: #{length(completed)} workflow tasks pass compiles, lint and step_order; " <>
    "their smoke tests pass"
)
