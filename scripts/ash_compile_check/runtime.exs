# Runtime proof for BubbleEx.Target.Ash (run by scripts/ash_compile_check.sh
# in the scratch project, after the generated migrations): inserts four rows
# into every generated resource through its create action and reads each
# back, requiring every attribute value to survive unchanged:
#
#   * the Bubble ID primary key with surrounding whitespace, and ""
#   * strings: "" kept distinct from nil, whitespace not trimmed
#   * floats, booleans, microsecond dates and lists of them
#   * belongs_to source attributes holding IDs of records that do not exist
#     (there is no foreign key)
#   * lists of IDs in their order
#   * enum values, typed-struct values
#   * Types.JsonValue: an object, a number, a string and a list

for repo <- Application.fetch_env!(:ash_compile_check, :ecto_repos) do
  {:ok, _} = repo.start_link()
end

defmodule RuntimeCheck do
  @instant ~U[2024-05-06 07:08:09.123456Z]
  @json [%{"a" => [1, %{"b" => nil}], "c" => "d"}, 5, "x", [1, "two", nil, 3.5]]

  def run do
    resources =
      for domain <- Application.fetch_env!(:ash_compile_check, :ash_domains),
          resource <- Ash.Domain.Info.resources(domain),
          do: resource

    failures = Enum.flat_map(resources, &check/1)

    if failures != [] do
      Enum.each(failures, &IO.puts/1)
      raise "runtime check failed: #{length(failures)} mismatches"
    end

    IO.puts("runtime check passed: #{length(resources)} resources, #{4 * length(resources)} rows")
  end

  defp check(resource) do
    [pk] = Ash.Resource.Info.primary_key(resource)
    refs = for r <- Ash.Resource.Info.relationships(resource), into: MapSet.new(), do: r.source_attribute
    attributes = Ash.Resource.Info.attributes(resource)

    Enum.flat_map(0..3, fn i ->
      input =
        Map.new(attributes, fn a ->
          value =
            cond do
              a.name == pk -> Enum.at(["  a b  ", "", "row 3", "row-4"], i)
              MapSet.member?(refs, a.name) -> "missing record #{i}"
              true -> sample(a.type, a.constraints, i)
            end

          {a.name, value}
        end)

      record =
        resource
        |> Ash.Changeset.for_create(:create, input)
        |> Ash.create!()

      read = Ash.get!(resource, Map.fetch!(input, pk))

      for a <- attributes,
          {:ok, expected} = Ash.Type.cast_input(a.type, input[a.name], a.constraints),
          actual = Map.fetch!(read, a.name),
          actual != expected or Map.fetch!(record, a.name) != expected do
        "#{inspect(resource)}.#{a.name} row #{i}: wrote #{inspect(input[a.name])}, " <>
          "expected #{inspect(expected)}, read #{inspect(actual)}"
      end
    end)
  end

  defp sample({:array, type}, constraints, i) do
    items = Keyword.get(constraints, :items, [])

    case type do
      Ash.Type.String -> Enum.map(["id-c", "id-a", "id-b"], &"#{&1}-#{i}")
      _ -> for n <- 0..2, v = sample(type, items, i + n + 1), not is_nil(v), do: v
    end
  end

  defp sample(Ash.Type.String, _c, i), do: Enum.at(["", nil, " keep  spaces ", "z"], i)
  defp sample(Ash.Type.Float, _c, i), do: Enum.at([1.5, 0.0, -2.25, 1.0e20], i)
  defp sample(Ash.Type.Integer, _c, i), do: i
  defp sample(Ash.Type.Boolean, _c, i), do: Enum.at([true, false, nil, true], i)
  defp sample(Ash.Type.UtcDatetimeUsec, _c, i), do: DateTime.add(@instant, i * 61, :second)
  defp sample(Ash.Type.Map, _c, i), do: %{"k" => i}

  defp sample(type, _c, i) do
    Code.ensure_loaded!(type)

    cond do
      String.ends_with?(inspect(type), ".JsonValue") ->
        Enum.at(@json, i)

      function_exported?(type, :values, 0) ->
        case type.values() do
          [] -> nil
          values -> Enum.at(values, rem(i, length(values)))
        end

      Spark.Dsl.is?(type, Ash.TypedStruct) ->
        Map.new(Ash.TypedStruct.Info.fields(type), &{&1.name, sample(&1.type, &1.constraints || [], i)})

      true ->
        raise "no sample for #{inspect(type)}"
    end
  end
end

RuntimeCheck.run()

# Every compiled privacy-rule condition (<namespace>.PrivacyFilters, see
# render.exs) runs as a read filter against the rows above: logged out and
# as each stored user, loaded with the filter's `actor_loads`. It must
# execute in PostgreSQL and agree with Ash's in-memory evaluation of the
# same filter over the same rows (loaded as the filter's relationship
# paths need).
# Ash's in-memory evaluator reads `exists(...)` and relationship paths
# from loaded relationships: load them (two levels) before comparing.
defmodule RelationshipLoads do
  def of(_resource, 0), do: []

  def of(resource, depth) do
    for r <- Ash.Resource.Info.relationships(resource), do: {r.name, of(r.destination, depth - 1)}
  end
end

defmodule FilterRuntimeCheck do
  require Ash.Query

  def run do
    entries =
      for domain <- Application.fetch_env!(:ash_compile_check, :ash_domains),
          module = Module.concat(domain, PrivacyFilters),
          Code.ensure_loaded?(module),
          entry <- module.all(),
          do: entry

    {runs, failures} =
      Enum.reduce(entries, {[], []}, fn entry, {runs, failures} ->
        # The sample rows include a user whose Bubble ID is "" (hostile; real
        # Bubble IDs are never empty). Ash's in-memory evaluator reads that
        # ID as nil when comparing it with an attribute across a relationship
        # (e.g. `parent.assignee_id`) while PostgreSQL keeps "", so that actor
        # is left out of the comparison.
        users = Ash.read!(entry.actor, authorize?: false, load: entry.actor_loads)
        actors = [nil | Enum.reject(users, &(&1.id == ""))]

        Enum.reduce(actors, {runs, failures}, fn actor, {runs, failures} ->
          {outcome, found} = check(entry, actor)
          {[outcome | runs], found ++ failures}
        end)
      end)

    if failures != [] do
      Enum.each(failures, &IO.puts/1)
      raise "privacy filter runtime check failed: #{length(failures)} failures"
    end

    shape = Enum.frequencies(runs)

    IO.puts(
      "privacy filter runtime check passed: #{length(entries)} filters, #{length(runs)} reads " <>
        "(selecting none: #{shape[:none] || 0}, all: #{shape[:all] || 0}, " <>
        "some: #{shape[:some] || 0})"
    )
  end

  defp check(entry, actor) do
    filled = Ash.Expr.fill_template(entry.filter, actor: actor)
    selected = entry.resource |> Ash.Query.filter(^filled) |> Ash.read!(authorize?: false)

    all = Ash.read!(entry.resource, authorize?: false, load: RelationshipLoads.of(entry.resource, 2))
    parsed = Ash.Filter.parse!(entry.resource, filled)
    domain = Ash.Resource.Info.domain(entry.resource)
    {:ok, matched} = Ash.Filter.Runtime.filter_matches(domain, all, parsed)

    outcome =
      cond do
        selected == [] -> :none
        length(selected) == length(all) -> :all
        true -> :some
      end

    if ids(selected) == ids(matched),
      do: {outcome, []},
      else:
        {outcome,
         [
           "#{entry.type}/#{entry.rule} as #{inspect(actor && actor.id)}: SQL selected " <>
             "#{inspect(ids(selected))}, in memory #{inspect(ids(matched))}"
         ]}
  rescue
    error -> {:error, ["#{entry.type}/#{entry.rule}: #{Exception.message(error)}"]}
  end

  defp ids(records), do: records |> Enum.map(& &1.id) |> Enum.sort()
end

FilterRuntimeCheck.run()

# The expression fixture's hand-authored expectations
# (test/support/expression/expectations/privacy.json, copied here by
# ash_compile_check.sh): discriminating rows (positive matches, empty
# fields, empty and nil lists, dangling references) and, per privacy rule
# and actor (logged out, u1, u2, u3), exactly the records it must select,
# in PostgreSQL and in Ash's in-memory evaluation. The Elixir backend is
# held to the same table by BubbleEx.Target.ElixirTest.
defmodule ExpectationCheck do
  require Ash.Query

  def run(path) do
    doc = path |> File.read!() |> Jason.decode!()
    entries = Fixtures.ExprApp.PrivacyFilters.all()
    resources = Map.new(entries, &{&1.type, &1.resource}) |> Map.put("user", hd(entries).actor)

    for {type, rows} <- doc["records"], row <- rows do
      input = Map.new(row, fn {k, v} -> {String.to_existing_atom(k), v} end)
      resources |> Map.fetch!(type) |> Ash.Changeset.for_create(:create, input) |> Ash.create!()
    end

    table = Map.new(doc["records"], fn {type, rows} -> {type, Enum.map(rows, & &1["id"])} end)

    results =
      for %{"type" => type, "rule" => rule, "expected" => expected} <- doc["cases"],
          entry = Enum.find(entries, &(&1.type == type and &1.rule == rule)) || raise("no filter for #{type}/#{rule}"),
          {actor_key, ids} <- expected do
        actor =
          if actor_key != "logged_out",
            do: Ash.get!(entry.actor, actor_key, load: entry.actor_loads, authorize?: false)

        {sql, memory} = select(entry, actor, table[type])
        shape = if(sql == [], do: :none, else: if(length(sql) == length(table[type]), do: :all, else: :some))

        failures =
          for {where, got} <- [sql: sql, memory: memory], got != Enum.sort(ids),
              do: "#{type}/#{rule} as #{actor_key} (#{where}): selected #{inspect(got)}, expected #{inspect(Enum.sort(ids))}"

        {shape, failures}
      end

    failures = Enum.flat_map(results, &elem(&1, 1))

    if failures != [] do
      Enum.each(failures, &IO.puts/1)
      raise "privacy expectation check failed: #{length(failures)} failures"
    end

    shape = results |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()

    IO.puts(
      "privacy expectation check passed: #{length(doc["cases"])} rules, #{length(results)} reads " <>
        "(selecting none: #{shape[:none] || 0}, all: #{shape[:all] || 0}, some: #{shape[:some] || 0})"
    )
  end

  defp select(entry, actor, ids) do
    filled = Ash.Expr.fill_template(entry.filter, actor: actor)
    sql = entry.resource |> Ash.Query.filter(^filled) |> Ash.read!(authorize?: false)

    all = Ash.read!(entry.resource, authorize?: false, load: RelationshipLoads.of(entry.resource, 2))
    parsed = Ash.Filter.parse!(entry.resource, filled)
    domain = Ash.Resource.Info.domain(entry.resource)
    {:ok, memory} = Ash.Filter.Runtime.filter_matches(domain, all, parsed)

    {within(sql, ids), within(memory, ids)}
  end

  defp within(records, ids), do: records |> Enum.map(& &1.id) |> Enum.filter(&(&1 in ids)) |> Enum.sort()
end

if File.exists?("expectations.json") and Code.ensure_loaded?(Fixtures.ExprApp.PrivacyFilters),
  do: ExpectationCheck.run("expectations.json")
