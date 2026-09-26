# Runs `mix wtf.task` (WTF-375) against the scratch project of an API
# client fixture (WTF-374): writes the fixture's plan to .wtf/plan.json,
# then claims and completes every api_call task whose call was generated.
# `complete` runs the task's request_shape check, which runs the tests
# tagged `bubble: "api_call:<group>/<call>"` (mix test --only …) in the
# scratch project; it raises unless every criterion passes.
#
#     MIX_ENV=test mix run scripts/phoenix_compile_check/request_shape.exs <dir> <fixture.json>

alias BubbleEx.{Index, Model, Plan}
alias BubbleEx.Target.ApiClients

[dir, fixture] = System.argv()
app = fixture |> File.read!() |> Jason.decode!()
{:ok, model} = Model.build(app)
{:ok, index} = Index.build(app, model: model)
{:ok, plan} = Plan.build(model, index)
:ok = BubbleEx.Tasks.Store.write_plan(dir, plan)

{:ok, spec} = ApiClients.map(model)
generated = for g <- spec.groups, c <- g.calls, into: MapSet.new(), do: c.subject
tasks = for t <- plan.tasks, t.kind == :api_call, MapSet.member?(generated, t.id), do: t.id

if tasks == [], do: raise("no api_call task for a generated call in #{fixture}")

for id <- tasks do
  Mix.Task.rerun("wtf.task", ["claim", id, "--agent", "ci", "--root", dir])
  Mix.Task.rerun("wtf.task", ["complete", id, "--agent", "ci", "--root", dir])
end

IO.puts("wtf.task complete: #{length(tasks)} api_call tasks pass request_shape")
