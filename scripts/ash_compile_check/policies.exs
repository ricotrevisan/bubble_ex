# Runtime proof of the generated privacy policies (WTF-356), run by
# scripts/ash_compile_check.sh in the scratch project after runtime.exs
# (which left sample rows in every table):
#
#   * every resource of every rendered fixture (and the private export, when
#     rendered) is read through its :read and :search actions with
#     authorization, logged out and as stored users loaded with
#     <namespace>.Privacy.load_actor/1: each read must succeed or be
#     forbidden (Ash forbids a read whose policy is false for the actor
#     before running it, e.g. a logged-out actor where every rule reads the
#     actor; Bubble would show nothing)
#   * the policy fixture (test/support/target/ash/policies.json) is seeded
#     with the rows of its hand-authored expectation table
#     (test/support/target/ash/expectations/policies.json, copied here) and,
#     per type, read action and persona (logged out, no role, positive,
#     empty), exactly the expected records must be read with exactly the
#     expected fields visible; :auto_bind updates and a create must be
#     allowed or forbidden as expected

for repo <- Application.fetch_env!(:ash_compile_check, :ecto_repos),
    not match?({:error, {:already_started, _}}, repo.start_link()),
    do: :ok

defmodule PolicyCheck do
  def domains, do: Application.fetch_env!(:ash_compile_check, :ash_domains)

  def privacy(domain), do: Module.concat(domain, Privacy)

  # {:ok, records} | :forbidden
  def read(resource, action, actor) do
    case resource |> Ash.Query.for_read(action, %{}, actor: actor) |> Ash.read(actor: actor) do
      {:ok, records} -> {:ok, records}
      {:error, %Ash.Error.Forbidden{}} -> :forbidden
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  def pk(resource), do: resource |> Ash.Resource.Info.primary_key() |> hd()

  def fields(resource) do
    pk = pk(resource)
    for a <- Ash.Resource.Info.public_attributes(resource), a.name != pk, do: a.name
  end

  def visible(record, resource) do
    for f <- fields(resource), not match?(%Ash.ForbiddenField{}, Map.fetch!(record, f)),
        do: Atom.to_string(f)
  end
end

defmodule PolicySmoke do
  # Every resource, both read actions, logged out and as up to three users.
  def run do
    results =
      for domain <- PolicyCheck.domains(),
          privacy = PolicyCheck.privacy(domain),
          Code.ensure_loaded?(privacy),
          users = users(privacy),
          resource <- Ash.Domain.Info.resources(domain),
          action <- [:read, :search],
          actor <- [nil | users] do
        case PolicyCheck.read(resource, action, actor) do
          {:ok, _} -> :ok
          :forbidden -> :forbidden
          {:error, message} -> {:error, "#{inspect(resource)}.#{action} as #{inspect(actor && actor.id)}: #{message}"}
        end
      end

    failures = for {:error, message} <- results, do: message

    if failures != [] do
      Enum.each(failures, &IO.puts/1)
      raise "policy smoke check failed: #{length(failures)} failures"
    end

    shape = Enum.frequencies(results)

    IO.puts(
      "policy smoke check passed: #{length(results)} authorized reads " <>
        "(ok: #{shape[:ok] || 0}, forbidden: #{shape[:forbidden] || 0})"
    )
  end

  defp users(privacy) do
    if function_exported?(privacy, :actor_resource, 0) do
      privacy.actor_resource()
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)
      |> Enum.sort()
      |> Enum.take(3)
      |> Enum.map(&privacy.load_actor/1)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end
end

defmodule PolicyExpectations do
  @namespace Fixtures.TargetPolicies

  def run(path) do
    doc = path |> File.read!() |> Jason.decode!()
    privacy = Module.concat(@namespace, Privacy)
    resource = fn type -> Module.concat(@namespace, Macro.camelize(type)) end

    for {type, rows} <- doc["records"], row <- rows do
      input = Map.new(row, fn {k, v} -> {String.to_existing_atom(k), v} end)
      type |> resource.() |> Ash.Changeset.for_create(:create, input) |> Ash.create!(authorize?: false)
    end

    table = Map.new(doc["records"], fn {type, rows} -> {type, Enum.map(rows, & &1["id"])} end)
    actor = fn "logged_out" -> nil; id -> privacy.load_actor(id) || raise("no user #{id}") end

    read_failures =
      for %{"type" => type, "action" => action, "expected" => expected} <- doc["reads"],
          {persona, records} <- expected,
          failure <- read_case(resource.(type), action, actor.(persona), records, table[type]),
          do: "#{type}.#{action} as #{persona}: #{failure}"

    reads = doc["reads"] |> Enum.map(&map_size(&1["expected"])) |> Enum.sum()

    write_failures =
      for %{"type" => type, "record" => id, "actor" => persona, "changes" => changes, "allowed" => allowed} <-
            doc["auto_bind"],
          failure <- auto_bind(resource.(type), id, actor.(persona), changes, allowed),
          do: "#{type}.auto_bind #{id} #{inspect(changes)} as #{persona}: #{failure}"

    create_failures =
      for %{"type" => type, "actor" => persona, "input" => input, "allowed" => allowed} <- doc["creates"],
          failure <- create(resource.(type), actor.(persona), input, allowed),
          do: "#{type}.create as #{persona}: #{failure}"

    failures = read_failures ++ write_failures ++ create_failures

    if failures != [] do
      Enum.each(failures, &IO.puts/1)
      raise "policy expectation check failed: #{length(failures)} failures"
    end

    IO.puts(
      "policy expectation check passed: #{length(doc["reads"])} type/action cases, #{reads} persona reads, " <>
        "#{length(doc["auto_bind"])} auto-binding updates, #{length(doc["creates"])} creates"
    )
  end

  defp read_case(resource, action, actor, expected, ids) do
    got =
      case PolicyCheck.read(resource, String.to_existing_atom(action), actor) do
        {:ok, records} ->
          for r <- records, r.id in ids, into: %{}, do: {r.id, Enum.sort(PolicyCheck.visible(r, resource))}

        :forbidden ->
          %{}

        {:error, message} ->
          raise message
      end

    all = resource |> PolicyCheck.fields() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

    want =
      Map.new(expected, fn
        {id, "all"} -> {id, all}
        {id, fields} -> {id, Enum.sort(fields)}
      end)

    if got == want, do: [], else: ["read #{inspect(got)}, expected #{inspect(want)}"]
  end

  defp auto_bind(resource, id, actor, changes, allowed) do
    record = Ash.get!(resource, id, authorize?: false)
    input = Map.new(changes, fn {k, v} -> {String.to_existing_atom(k), v} end)

    result =
      record
      |> Ash.Changeset.for_update(:auto_bind, input, actor: actor)
      |> Ash.update(actor: actor)

    outcome(result, allowed)
  end

  defp create(resource, actor, input, allowed) do
    input = Map.new(input, fn {k, v} -> {String.to_existing_atom(k), v} end)

    resource
    |> Ash.Changeset.for_create(:create, input, actor: actor)
    |> Ash.create(actor: actor)
    |> outcome(allowed)
  end

  defp outcome({:ok, _}, true), do: []
  defp outcome({:error, %Ash.Error.Forbidden{}}, false), do: []
  defp outcome({:ok, _}, false), do: ["allowed, expected forbidden"]
  defp outcome({:error, %Ash.Error.Forbidden{}}, true), do: ["forbidden, expected allowed"]
  defp outcome({:error, error}, _), do: ["failed: #{Exception.message(error)}"]
end

PolicySmoke.run()

if File.exists?("policy_expectations.json") and
     Code.ensure_loaded?(Fixtures.TargetPolicies.Privacy),
   do: PolicyExpectations.run("policy_expectations.json")
