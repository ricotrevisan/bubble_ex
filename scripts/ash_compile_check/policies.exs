# Runtime proof of the generated privacy policies (WTF-356), run by
# scripts/ash_compile_check.sh in the scratch project after runtime.exs
# (which left sample rows in every table):
#
#   * smoke test (no expectations): every resource of every rendered
#     fixture (and the private export, when rendered) is read through its
#     :search action and, by primary key, its :read action, with
#     authorization, logged out and as stored users loaded with
#     <namespace>.Privacy.load_actor/1: each read must run or be forbidden
#     (Ash forbids a read whose policy is false for the actor before running
#     it, e.g. a logged-out actor where every rule reads the actor; Bubble
#     would show nothing). It proves the policies execute, not what they
#     select
#   * the policy fixture (test/support/target/ash/policies.json) is seeded
#     with the rows of its hand-authored expectation table
#     (test/support/target/ash/expectations/policies.json, copied here) and,
#     per type, read action and persona (logged out, no role, positive,
#     empty), exactly the expected records must be read with exactly the
#     expected fields visible (by primary key, through :search, and none
#     through an unkeyed :read); filter_input and sort_input on hidden
#     fields and gated relationships, and relationship loads, must reveal
#     nothing; aggregates (count, exists, max) through the keyed :read
#     must be refused unless keyed; :auto_bind updates and a create must be allowed or forbidden
#     as expected

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
          action <- [:get, :search],
          actor <- [nil | users] do
        case smoke_read(resource, action, actor) do
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
      "policy smoke check (runs, no expectations) passed: #{length(results)} authorized reads " <>
        "(ok: #{shape[:ok] || 0}, forbidden: #{shape[:forbidden] || 0})"
    )
  end

  # :get reads every stored record by primary key.
  defp smoke_read(resource, :search, actor), do: PolicyCheck.read(resource, :search, actor)

  defp smoke_read(resource, :get, actor) do
    pk = PolicyCheck.pk(resource)
    ids = resource |> Ash.read!(authorize?: false) |> Enum.map(&Map.fetch!(&1, pk))

    Enum.reduce_while(ids, {:ok, []}, fn id, acc ->
      case Ash.get(resource, id, actor: actor) do
        {:ok, _} -> {:cont, acc}
        {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} -> {:cont, acc}
        {:error, %Ash.Error.Forbidden{}} -> {:halt, :forbidden}
        {:error, error} -> {:halt, {:error, Exception.message(error)}}
      end
    end)
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

    probe_failures =
      for(
        %{"type" => type, "persona" => persona, "filter" => filter, "expected" => ids} <- doc["filters"],
        failure <- probe(resource.(type), actor.(persona), &Ash.Query.filter_input(&1, filter), ids, true, table[type]),
        do: "#{type} filter_input #{inspect(filter)} as #{persona}: #{failure}"
      ) ++
        for(
          %{"type" => type, "persona" => persona, "sort" => sort, "expected" => ids} <- doc["sorts"],
          failure <- probe(resource.(type), actor.(persona), &Ash.Query.sort_input(&1, sort), ids, false, table[type]),
          do: "#{type} sort_input #{sort} as #{persona}: #{failure}"
        ) ++
        for(
          %{"type" => type, "record" => id, "relationship" => rel, "persona" => persona, "expected" => want} <-
            doc["loads"],
          failure <- load(resource.(type), id, String.to_existing_atom(rel), actor.(persona), want),
          do: "#{type} #{id}.#{rel} as #{persona}: #{failure}"
        )

    write_failures =
      for %{"type" => type, "record" => id, "actor" => persona, "changes" => changes, "allowed" => allowed} <-
            doc["auto_bind"],
          failure <- auto_bind(resource.(type), id, actor.(persona), changes, allowed),
          do: "#{type}.auto_bind #{id} #{inspect(changes)} as #{persona}: #{failure}"

    create_failures =
      for %{"type" => type, "actor" => persona, "input" => input, "allowed" => allowed} <- doc["creates"],
          failure <- create(resource.(type), actor.(persona), input, allowed),
          do: "#{type}.create as #{persona}: #{failure}"

    aggregate_failures =
      for %{"type" => type, "action" => action, "persona" => persona, "kind" => kind, "expected" => want} = a <-
            doc["aggregates"],
          failure <- aggregate(resource.(type), action, actor.(persona), kind, a, want),
          do: "#{type} #{kind} via :#{action} as #{persona}: #{failure}"

    failures = read_failures ++ probe_failures ++ aggregate_failures ++ write_failures ++ create_failures

    if failures != [] do
      Enum.each(failures, &IO.puts/1)
      raise "policy expectation check failed: #{length(failures)} failures"
    end

    IO.puts(
      "policy expectation check passed: #{length(doc["reads"])} type/action cases, #{reads} persona reads, " <>
        "#{length(doc["filters"])} filter_input, #{length(doc["sorts"])} sort_input and " <>
        "#{length(doc["loads"])} relationship-load and #{length(doc["aggregates"])} aggregate probes, " <>
        "#{length(doc["auto_bind"])} auto-binding updates, #{length(doc["creates"])} creates"
    )
  end

  defp read_case(resource, action, actor, expected, ids) do
    got =
      case read_records(resource, action, actor, ids) do
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

  # "get": each record by primary key; "list": the primary :read, unkeyed.
  defp read_records(resource, "get", actor, ids) do
    records =
      for id <- ids,
          {:ok, record} <- [Ash.get(resource, id, actor: actor)],
          do: record

    {:ok, records}
  end

  defp read_records(resource, "list", actor, _ids), do: PolicyCheck.read(resource, :read, actor)
  defp read_records(resource, "search", actor, _ids), do: PolicyCheck.read(resource, :search, actor)

  # A :search with `build` applied: the IDs it returns among `ids`, as a
  # set, or in order when `sorted?` is false (the probe sorts); "rejected"
  # when the input is invalid.
  defp probe(resource, actor, build, want, sorted?, ids) do
    query = resource |> Ash.Query.for_read(:search, %{}, actor: actor) |> build.()

    got =
      case Ash.read(query, actor: actor) do
        {:ok, records} -> for r <- records, r.id in ids, do: r.id
        {:error, %Ash.Error.Forbidden{}} -> []
        {:error, %Ash.Error.Invalid{}} -> "rejected"
        {:error, error} -> raise Exception.message(error)
      end

    got = if sorted? and is_list(got), do: Enum.sort(got), else: got
    want = if sorted? and is_list(want), do: Enum.sort(want), else: want
    if got == want, do: [], else: ["got #{inspect(got)}, expected #{inspect(want)}"]
  end

  defp aggregate(resource, action, actor, kind, spec, want) do
    query = Ash.Query.for_read(resource, String.to_existing_atom(action), %{}, actor: actor)
    query = if spec["filter"], do: Ash.Query.filter_input(query, spec["filter"]), else: query

    result =
      case kind do
        "count" -> Ash.count(query, actor: actor)
        "exists" -> Ash.exists(query, actor: actor)
        "max" -> Ash.max(query, String.to_existing_atom(spec["field"]), actor: actor)
      end

    got =
      case result do
        {:ok, value} -> value
        {:error, %Ash.Error.Forbidden{}} -> "forbidden"
        {:error, error} -> raise Exception.message(error)
      end

    if got == want, do: [], else: ["got #{inspect(got)}, expected #{inspect(want)}"]
  end

  defp load(resource, id, rel, actor, want) do
    record = Ash.get!(resource, id, authorize?: false)

    got =
      case Ash.load(record, rel, actor: actor) do
        {:ok, loaded} ->
          case Map.fetch!(loaded, rel) do
            nil -> nil
            related -> related.id
          end

        {:error, %Ash.Error.Forbidden{}} ->
          nil

        {:error, error} ->
          raise Exception.message(error)
      end

    if got == want, do: [], else: ["loaded #{inspect(got)}, expected #{inspect(want)}"]
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

# The privacy interpreter (BubbleEx.Verify.Interpreter, WTF-382) against
# the generated policies: render.exs wrote its verdicts on the policy
# table's get and search reads (interpreter_policies.json); here the same
# reads run through the policies in PostgreSQL. Where the interpreter
# decides, the records read and their visible fields must match; where an
# unsupported rule leaves it unknown, the policies must deny (the record
# unread, or exactly the known fields visible). It runs on the table's
# rows after PolicyExpectations (which seeds them); its auto-binding
# updates change titles and secrets, which no condition of the fixture
# reads.
defmodule InterpreterCheck do
  @namespace Fixtures.TargetPolicies

  def run(path, table_path) do
    doc = path |> File.read!() |> Jason.decode!()
    table = table_path |> File.read!() |> Jason.decode!() |> Map.fetch!("records")
    privacy = Module.concat(@namespace, Privacy)
    resource = fn type -> Module.concat(@namespace, Macro.camelize(type)) end
    actor = fn "logged_out" -> nil; id -> privacy.load_actor(id) end

    outcomes =
      for %{"type" => type, "action" => action, "verdicts" => verdicts} <- doc,
          {persona, mine} <- verdicts do
        res = resource.(type)
        ids = Enum.map(table[type], & &1["id"])
        all = res |> PolicyCheck.fields() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
        got = reads(res, action, actor.(persona), ids)

        for id <- Enum.sort(ids) do
          verdict = compare(Map.get(mine, id, :hidden), Map.get(got, id, :hidden), all)
          {verdict, "#{type}.#{action} #{id} as #{persona}: interpreter #{inspect(Map.get(mine, id))}, policies #{inspect(Map.get(got, id))}"}
        end
      end
      |> List.flatten()

    disagreements = for {:disagree, message} <- outcomes, do: message
    counts = outcomes |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()

    if disagreements != [] do
      Enum.each(disagreements, &IO.puts/1)
      raise "privacy interpreter disagrees with the generated policies: #{length(disagreements)} cells"
    end

    IO.puts(
      "privacy interpreter check passed: agrees with the generated policies on #{counts[:agree] || 0} " <>
        "record reads; #{counts[:unknown] || 0} undecided by the interpreter are denied by the policies"
    )
  end

  defp reads(resource, "get", actor, ids) do
    for id <- ids, {:ok, r} <- [Ash.get(resource, id, actor: actor)], into: %{},
        do: {id, Enum.sort(PolicyCheck.visible(r, resource))}
  end

  defp reads(resource, "search", actor, _ids) do
    case PolicyCheck.read(resource, :search, actor) do
      {:ok, records} -> Map.new(records, &{&1.id, Enum.sort(PolicyCheck.visible(&1, resource))})
      :forbidden -> %{}
      {:error, message} -> raise message
    end
  end

  defp compare("unknown", :hidden, _all), do: :unknown
  defp compare(%{"known" => known}, got, _all) when got == known, do: :unknown
  defp compare("all", got, all) when got == all, do: :agree
  defp compare(fields, got, _all) when is_list(fields) and got == fields, do: :agree
  defp compare(:hidden, :hidden, _all), do: :agree
  defp compare(_, _, _), do: :disagree
end

PolicySmoke.run()

if File.exists?("policy_expectations.json") and
     Code.ensure_loaded?(Fixtures.TargetPolicies.Privacy),
   do: PolicyExpectations.run("policy_expectations.json")

# Wherever the policy table is checked, the interpreter's verdicts must be
# too: a missing file (render.exs writes it) fails the harness.
if File.exists?("policy_expectations.json") and
     Code.ensure_loaded?(Fixtures.TargetPolicies.Privacy) do
  File.exists?("interpreter_policies.json") ||
    raise "interpreter_policies.json is missing: render.exs did not write the privacy interpreter's verdicts"

  InterpreterCheck.run("interpreter_policies.json", "policy_expectations.json")
end
