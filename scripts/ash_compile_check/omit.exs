# Runtime smoke check of BubbleEx.Target.Ash with privacy: :omit (run by
# scripts/ash_compile_check.sh in the omit scratch project, after
# runtime.exs has inserted its sample rows): every generated resource has
# no authorizer, policies, field policies, calculations or private
# relationships, only the default actions, and reads every row back with
# authorization left on (Ash's default) and no actor. The project's
# dependencies are BubbleEx.Target.Ash.versions(privacy: :omit): no SAT
# solver.

for repo <- Application.fetch_env!(:ash_compile_check, :ecto_repos) do
  {:ok, _} = repo.start_link()
end

if Code.ensure_loaded?(Picosat),
  do: raise("privacy: :omit project has PicoSAT; versions(privacy: :omit) should not pin it")

resources =
  for domain <- Application.fetch_env!(:ash_compile_check, :ash_domains),
      resource <- Ash.Domain.Info.resources(domain),
      do: resource

failures =
  Enum.flat_map(resources, fn resource ->
    actions =
      resource |> Ash.Resource.Info.actions() |> Enum.map(&{&1.type, &1.name}) |> Enum.sort()

    problems = [
      {Ash.Resource.Info.authorizers(resource) != [], "has authorizers"},
      {Ash.Resource.Info.calculations(resource) != [], "has calculations"},
      {Enum.any?(
         Ash.Resource.Info.relationships(resource),
         &(not &1.public? or not &1.sortable? or &1.filter)
       ), "has a private, unsortable or filtered relationship"},
      {actions != [create: :create, destroy: :destroy, read: :read, update: :update],
       "actions #{inspect(actions)}"},
      {length(Ash.read!(resource)) != 4, "reads #{length(Ash.read!(resource))} rows, not 4"}
    ]

    for {true, problem} <- problems, do: "#{inspect(resource)}: #{problem}"
  end)

if failures != [] do
  Enum.each(failures, &IO.puts/1)
  raise "privacy: :omit check failed: #{length(failures)} failures"
end

IO.puts("privacy: :omit check passed: #{length(resources)} resources, no authorization")
