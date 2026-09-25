# Runtime proof of owner decisions applied by BubbleEx.Target.Ash (WTF-401),
# run by scripts/ash_compile_check.sh in both scratch projects after the
# migrations and runtime.exs. For every decided fixture in decisions.json
# (written by render.exs):
#
#   * the table has exactly the stored attributes' columns: a field derived
#     by a decision has no column (it is a calculation), and an attribute
#     renamed after the name lock keeps its column (`source:`)
#   * refined numbers are bigint (integer) and numeric (decimal) columns,
#     floats stay double precision
#   * every derived calculation reads the related record's value back from
#     PostgreSQL: loaded, and as a filter (evaluated in SQL), for a record
#     whose relationship is set and one whose relationship is empty (nil)

for repo <- Application.fetch_env!(:ash_compile_check, :ecto_repos),
    not match?({:error, {:already_started, _}}, repo.start_link()),
    do: :ok

defmodule DecisionsCheck do
  def run do
    fixtures = "decisions.json" |> File.read!() |> Jason.decode!()
    if fixtures == [], do: raise("decisions.json lists no decided fixture")

    {checks, failures} =
      Enum.reduce(fixtures, {0, []}, fn fixture, acc ->
        repo = Module.concat([fixture["repo"]])

        Enum.reduce(fixture["resources"], acc, fn resource, {n, failures} ->
          found = columns(repo, resource) ++ Enum.flat_map(resource["derived"], &derived/1)
          {n + 1 + length(resource["derived"]), found ++ failures}
        end)
      end)

    derived = fixtures |> Enum.flat_map(& &1["resources"]) |> Enum.flat_map(& &1["derived"])
    if derived == [], do: raise("no derived calculation to check")

    if failures != [] do
      Enum.each(failures, &IO.puts/1)
      raise "decisions check failed: #{length(failures)} failures"
    end

    IO.puts(
      "decisions check passed: #{length(fixtures)} fixtures, #{checks} checks, " <>
        "#{length(derived)} derived calculations read back"
    )
  end

  defp columns(repo, %{"table" => table} = resource) do
    %{rows: rows} =
      repo.query!(
        "SELECT column_name, udt_name FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND table_name = $1",
        [table]
      )

    actual = Map.new(rows, fn [name, udt] -> {name, udt} end)
    stored = Enum.sort(resource["stored"])

    shape =
      if Enum.sort(Map.keys(actual)) == stored,
        do: [],
        else: [
          "#{table}: columns #{inspect(Enum.sort(Map.keys(actual)))}, expected #{inspect(stored)}"
        ]

    types =
      for {column, udt} <- resource["columns"], actual[column] != udt do
        "#{table}.#{column}: #{inspect(actual[column])}, expected #{udt}"
      end

    shape ++ types
  end

  defp derived(d) do
    resource = Module.concat([d["resource_module"] || raise("missing resource")])
    destination = Module.concat([d["destination"]])
    calc = String.to_atom(d["calculation"])
    attribute = String.to_atom(d["attribute"])
    fk = String.to_atom(d["source_attribute"])
    [dest_pk] = Ash.Resource.Info.primary_key(destination)
    [pk] = Ash.Resource.Info.primary_key(resource)
    value = sample(Ash.Resource.Info.attribute(destination, attribute).type)

    related =
      destination
      |> Ash.Changeset.for_create(:create, %{
        dest_pk => "decided-" <> d["calculation"],
        attribute => value
      })
      |> Ash.create!(authorize?: false)

    linked =
      resource
      |> Ash.Changeset.for_create(:create, %{
        pk => "linked-" <> d["calculation"],
        fk => Map.fetch!(related, dest_pk)
      })
      |> Ash.create!(authorize?: false)

    empty =
      resource
      |> Ash.Changeset.for_create(:create, %{pk => "empty-" <> d["calculation"]})
      |> Ash.create!(authorize?: false)

    loaded = Ash.load!([linked, empty], [calc], authorize?: false)

    filtered =
      resource
      |> Ash.Query.do_filter([{calc, value}])
      |> Ash.read!(authorize?: false)
      |> Enum.map(&Map.fetch!(&1, pk))

    [
      {Enum.map(loaded, &Map.fetch!(&1, calc)) == [value, nil],
       "loads #{inspect(Enum.map(loaded, &Map.fetch!(&1, calc)))}"},
      {filtered == [Map.fetch!(linked, pk)], "filters to #{inspect(filtered)}"}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(fn {_, what} ->
      "#{inspect(resource)}.#{calc}: #{what}, expected #{inspect(value)}"
    end)
  rescue
    error -> ["#{d["resource_module"]}.#{d["calculation"]}: #{Exception.message(error)}"]
  end

  defp sample(Ash.Type.String), do: "Acme Workspace"
  defp sample(Ash.Type.UtcDatetimeUsec), do: ~U[2024-05-06 07:08:09.123456Z]
  defp sample(Ash.Type.Float), do: 2.5
  defp sample(Ash.Type.Integer), do: 42
  defp sample(Ash.Type.Decimal), do: Decimal.new("2.50")
  defp sample(Ash.Type.Boolean), do: true
  defp sample(type), do: raise("no sample for #{inspect(type)}")
end

DecisionsCheck.run()
