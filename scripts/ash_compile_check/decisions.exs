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
#     whose relationship is set and one whose relationship is empty (nil);
#     it sorts (Ash.Query.sort and sort_input, nils last / descending), and
#     sort_input cannot sort through the private `*_for_privacy` twin it
#     reads through, nor through the unsortable public relationship
#
# and the cut-2 transforms (WTF-405):
#
#   * every derived count reads back from PostgreSQL: the length of a
#     stored list (3 for a three-ID list, 0 for an empty or nil one, 0
#     when the reference it reads through is empty) and an aggregate over a
#     derived has_many (the records whose reference points here; a record
#     pointing elsewhere is not counted), loaded, as a filter and sorted
#     (Ash.Query.sort and sort_input)
#   * every derived has_many loads the records whose reference points
#     here, and nothing for a record none points to
#   * a belongs_to a text_to_reference decision made loads the record its
#     ID names, and nil for a dangling ID (there is no foreign key)
#   * every index exists with its method (btree, GIN, GIN trigram
#     `gin_trgm_ops`, GIN over the `to_tsvector` expression), and the
#     extensions the fixture lists are installed

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

        {n, failures} = acc
        found = extensions(repo, fixture["extensions"])
        acc = {n + 1, found ++ failures}

        Enum.reduce(fixture["resources"], acc, fn resource, {n, failures} ->
          module = Module.concat([resource["resource"]])

          found =
            columns(repo, resource) ++
              Enum.flat_map(resource["derived"], &derived/1) ++
              Enum.flat_map(resource["counts"], &count(module, &1)) ++
              Enum.flat_map(resource["has_many"], &has_many(module, &1)) ++
              Enum.flat_map(resource["text_references"], &text_reference(module, &1)) ++
              indexes(repo, resource)

          checks =
            1 + length(resource["derived"]) + length(resource["counts"]) +
              length(resource["has_many"]) + length(resource["text_references"]) +
              length(resource["indexes"])

          {n + checks, found ++ failures}
        end)
      end)

    resources = Enum.flat_map(fixtures, & &1["resources"])
    derived = Enum.flat_map(resources, & &1["derived"])
    if derived == [], do: raise("no derived calculation to check")

    for {key, what} <- [
          {"counts", "derived count"},
          {"has_many", "derived has_many"},
          {"text_references", "text reference"},
          {"indexes", "index"}
        ],
        Enum.flat_map(resources, & &1[key]) == [],
        do: raise("no #{what} to check")

    for kind <- ["length", "count"],
        not Enum.any?(Enum.flat_map(resources, & &1["counts"]), &(&1["kind"] == kind)),
        do: raise("no #{kind} count to check")

    if failures != [] do
      Enum.each(failures, &IO.puts/1)
      raise "decisions check failed: #{length(failures)} failures"
    end

    count = fn key -> resources |> Enum.flat_map(& &1[key]) |> length() end

    IO.puts(
      "decisions check passed: #{length(fixtures)} fixtures, #{checks} checks, " <>
        "#{length(derived)} derived calculations and #{count.("counts")} derived counts " <>
        "read back, #{count.("has_many")} has_many and #{count.("text_references")} text " <>
        "references loaded, #{count.("indexes")} indexes found"
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

    ids = [Map.fetch!(linked, pk), Map.fetch!(empty, pk)]
    ours = Ash.Query.do_filter(resource, [{pk, [in: ids]}])

    sorted =
      ours
      |> Ash.Query.sort([{calc, :asc_nils_last}])
      |> Ash.read!(authorize?: false)
      |> Enum.map(&Map.fetch!(&1, pk))

    sorted_input =
      ours
      |> Ash.Query.sort_input("-" <> d["calculation"])
      |> Ash.read(authorize?: false)

    # sort_input cannot reach through a private twin, nor a public
    # relationship with privacy policies (unsortable)
    through =
      for rel <- Enum.uniq([d["relationship"], d["public_relationship"]]),
          rel != nil,
          d["relationship"] != d["public_relationship"],
          match?(
            {:ok, _},
            ours
            |> Ash.Query.sort_input("#{rel}.#{d["attribute"]}")
            |> Ash.read(authorize?: false)
          ),
          do: rel

    [
      {sorted == ids, "sorts to #{inspect(sorted)}"},
      {match?({:ok, [_, _]}, sorted_input) and
         Enum.map(elem(sorted_input, 1), &Map.fetch!(&1, pk)) == Enum.reverse(ids),
       "sort_input gives #{inspect(sorted_input |> elem(1) |> List.wrap() |> Enum.map(&(is_map(&1) && Map.get(&1, pk))))}"},
      {through == [], "sort_input reaches through #{inspect(through)}"},
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

  # --- cut 2 (WTF-405) -------------------------------------------------------------

  defp extensions(repo, extensions) do
    %{rows: rows} = repo.query!("SELECT extname FROM pg_extension", [])
    installed = List.flatten(rows)
    for e <- extensions, e not in installed, do: "extension #{e} is not installed"
  end

  defp indexes(repo, %{"table" => table, "indexes" => indexes}) do
    %{rows: rows} =
      repo.query!(
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' AND tablename = $1",
        [table]
      )

    defs = Map.new(rows, fn [name, definition] -> {name, definition} end)

    for index <- indexes,
        definition = defs[index["name"]],
        problem = index_problem(definition, index),
        do: "#{table}: index #{index["name"]} #{problem}"
  end

  defp index_problem(nil, _index), do: "does not exist"

  defp index_problem(definition, %{"method" => method, "columns" => columns}) do
    expected =
      case method do
        "btree" -> ["USING btree (" <> Enum.join(columns, ", ") <> ")"]
        "gin" -> ["USING gin (" <> hd(columns) <> ")"]
        "trigram" -> ["USING gin (", "gin_trgm_ops"]
        "full_text" -> ["USING gin (to_tsvector('simple'::regconfig", hd(columns)]
      end

    # PostgreSQL quotes reserved words (`"order"`)
    definition = String.replace(definition, "\"", "")

    if Enum.all?(expected, &String.contains?(definition, &1)),
      do: nil,
      else: "is #{inspect(definition)}, expected #{inspect(expected)}"
  end

  # A count: `path` is empty (the record's own list or has_many) or one
  # belongs_to, then the list (a stored attribute, or a has_many for an
  # aggregate).
  defp count(resource, %{"name" => name, "kind" => kind, "path" => path, "list" => list} = c) do
    calc = String.to_atom(name)
    [pk] = Ash.Resource.Info.primary_key(resource)
    tag = "#{inspect(resource)}.#{name}"

    {via, owner} =
      case {kind, path} do
        {"length", []} -> {nil, resource}
        {"length", [rel]} -> {rel(resource, rel), rel(resource, rel).destination}
        {"count", [_many]} -> {nil, resource}
        {"count", [rel, _many]} -> {rel(resource, rel), rel(resource, rel).destination}
      end

    [owner_pk] = Ash.Resource.Info.primary_key(owner)

    # the owner record holding 3 items, and one holding none
    full = create!(owner, %{owner_pk => "full-" <> tag})
    none = create!(owner, %{owner_pk => "none-" <> tag})

    expected_full =
      case kind do
        "length" ->
          attribute = String.to_atom(list)
          update!(full, %{attribute => ["a", "b", "c"]})
          update!(none, %{attribute => []})
          3

        "count" ->
          many = rel(owner, List.last(path))
          [dest_pk] = Ash.Resource.Info.primary_key(many.destination)

          for i <- 1..2,
              do:
                create!(many.destination, %{
                  dest_pk => "item-#{i}-" <> tag,
                  many.destination_attribute => Map.fetch!(full, owner_pk)
                })

          # a record pointing elsewhere is not counted
          create!(many.destination, %{
            dest_pk => "stray-" <> tag,
            many.destination_attribute => "elsewhere-" <> tag
          })

          2
      end

    records =
      if via do
        linked = create!(resource, %{pk => "linked-" <> tag, via.source_attribute => Map.fetch!(full, owner_pk)})
        other = create!(resource, %{pk => "other-" <> tag, via.source_attribute => Map.fetch!(none, owner_pk)})
        unlinked = create!(resource, %{pk => "unlinked-" <> tag})
        [{linked, full}, {other, none}, {unlinked, nil}]
      else
        [{full, full}, {none, none}]
      end

    # What each record should count, read independently: the list's
    # length, or (a count) the records pointing at its owner, which are
    # of the counting resource itself when it counts its own type.
    expected_of = fn
      nil ->
        0

      owner_record ->
        case kind do
          "length" ->
            if owner_record == full, do: expected_full, else: 0

          "count" ->
            many = rel(owner, List.last(path))

            many.destination
            |> Ash.Query.do_filter([
              {many.destination_attribute, Map.fetch!(owner_record, owner_pk)}
            ])
            |> Ash.count!(authorize?: false)
        end
    end

    records = Enum.map(records, fn {r, owner_record} -> {r, expected_of.(owner_record)} end)
    expected_full = records |> hd() |> elem(1)

    ids = Enum.map(records, fn {r, _} -> Map.fetch!(r, pk) end)
    expected = Enum.map(records, &elem(&1, 1))
    ours = Ash.Query.do_filter(resource, [{pk, [in: ids]}])

    loaded =
      resource
      |> Ash.Query.do_filter([{pk, [in: ids]}])
      |> Ash.Query.load(calc)
      |> Ash.read!(authorize?: false)
      |> Map.new(&{Map.fetch!(&1, pk), Map.fetch!(&1, calc)})

    loaded = Enum.map(ids, &loaded[&1])

    filtered =
      ours
      |> Ash.Query.do_filter([{calc, expected_full}])
      |> Ash.read!(authorize?: false)
      |> Enum.map(&Map.fetch!(&1, pk))

    by_count = fn direction ->
      records
      |> Enum.sort_by(fn {r, n} -> {n, Map.fetch!(r, pk)} end, direction)
      |> Enum.map(&Map.fetch!(elem(&1, 0), pk))
    end

    sorted =
      ours
      |> Ash.Query.sort([{calc, :desc}, {pk, :desc}])
      |> Ash.read!(authorize?: false)
      |> Enum.map(&Map.fetch!(&1, pk))

    sorted_input =
      ours
      |> Ash.Query.sort_input(name <> ",#{pk}")
      |> Ash.read(authorize?: false)

    [
      {loaded == expected, "loads #{inspect(loaded)}, expected #{inspect(expected)}"},
      {Enum.sort(filtered) ==
         Enum.sort(for({r, n} <- records, n == expected_full, do: Map.fetch!(r, pk))),
       "filters to #{inspect(filtered)}"},
      {sorted == by_count.(:desc), "sorts to #{inspect(sorted)}"},
      {match?({:ok, _}, sorted_input) and
         Enum.map(elem(sorted_input, 1), &Map.fetch!(&1, pk)) == by_count.(:asc),
       "sort_input gives #{inspect(sorted_input)}"}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(fn {_, what} -> "#{tag} (#{c["kind"]}): #{what}" end)
  rescue
    error -> ["#{inspect(resource)}.#{c["name"]}: #{Exception.message(error)}"]
  end

  defp has_many(resource, %{"name" => name}) do
    many = rel(resource, name)
    [pk] = Ash.Resource.Info.primary_key(resource)
    [dest_pk] = Ash.Resource.Info.primary_key(many.destination)
    tag = "#{inspect(resource)}.#{name}"
    owner = create!(resource, %{pk => "owner-" <> tag})
    lonely = create!(resource, %{pk => "lonely-" <> tag})

    ids =
      for i <- 1..2 do
        item =
          create!(many.destination, %{
            dest_pk => "child-#{i}-" <> tag,
            many.destination_attribute => Map.fetch!(owner, pk)
          })

        Map.fetch!(item, dest_pk)
      end

    [owner, lonely] = Ash.load!([owner, lonely], [many.name], authorize?: false)
    got = owner |> Map.fetch!(many.name) |> Enum.map(&Map.fetch!(&1, dest_pk)) |> Enum.sort()

    [
      {got == Enum.sort(ids), "loads #{inspect(got)}, expected #{inspect(ids)}"},
      {Map.fetch!(lonely, many.name) == [], "loads #{inspect(Map.fetch!(lonely, many.name))} for a record none points to"}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(fn {_, what} -> "#{tag}: #{what}" end)
  rescue
    error -> ["#{inspect(resource)}.#{name}: #{Exception.message(error)}"]
  end

  defp text_reference(resource, %{"name" => name}) do
    ref = rel(resource, name)
    [pk] = Ash.Resource.Info.primary_key(resource)
    [dest_pk] = Ash.Resource.Info.primary_key(ref.destination)
    tag = "#{inspect(resource)}.#{name}"
    target = create!(ref.destination, %{dest_pk => "target-" <> tag})

    linked =
      create!(resource, %{pk => "ref-" <> tag, ref.source_attribute => Map.fetch!(target, dest_pk)})

    dangling = create!(resource, %{pk => "dangling-" <> tag, ref.source_attribute => "gone-" <> tag})
    [linked, dangling] = Ash.load!([linked, dangling], [ref.name], authorize?: false)
    got = linked |> Map.fetch!(ref.name) |> then(&(&1 && Map.fetch!(&1, dest_pk)))

    [
      {got == Map.fetch!(target, dest_pk), "loads #{inspect(got)}"},
      {Map.fetch!(dangling, ref.name) == nil,
       "loads #{inspect(Map.fetch!(dangling, ref.name))} for a dangling ID"}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(fn {_, what} -> "#{tag}: #{what}" end)
  rescue
    error -> ["#{inspect(resource)}.#{name}: #{Exception.message(error)}"]
  end

  defp rel(resource, name),
    do: Ash.Resource.Info.relationship(resource, String.to_atom(name)) || raise("no relationship #{name}")

  defp create!(resource, attrs),
    do: resource |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!(authorize?: false)

  defp update!(record, attrs),
    do: record |> Ash.Changeset.for_update(:update, attrs) |> Ash.update!(authorize?: false)

  defp sample(Ash.Type.String), do: "Acme Workspace"
  defp sample(Ash.Type.UtcDatetimeUsec), do: ~U[2024-05-06 07:08:09.123456Z]
  defp sample(Ash.Type.Float), do: 2.5
  defp sample(Ash.Type.Integer), do: 42
  defp sample(Ash.Type.Decimal), do: Decimal.new("2.50")
  defp sample(Ash.Type.Boolean), do: true
  defp sample(type), do: raise("no sample for #{inspect(type)}")
end

DecisionsCheck.run()
