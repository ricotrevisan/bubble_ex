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
#     here, and nothing for a record none points to; with policies
#     (privacy: :unverified), a decided fixture's has_many whose
#     destination is readable only by its creator (the cut-2 Card's
#     Creator rule) is also loaded through the public relationship with
#     authorization on: a user who created none of its children sees [],
#     one who created one sees only that one (WTF-410)
#   * a belongs_to a text_to_reference decision made loads the record its
#     ID names, and nil for a dangling ID (there is no foreign key)
#   * every index exists with its method (btree, GIN, GIN trigram
#     `gin_trgm_ops`, GIN over the `to_tsvector` expression), and the
#     extensions the fixture lists are installed
#
# and the cut-3 transforms (WTF-406):
#
#   * every join resource's table has exactly its columns (the two IDs,
#     the positions) with the two IDs as its primary key, and the lists it
#     replaces have no column
#   * every many_to_many loads its members from the join rows written for
#     it, and nothing for a record with none; with a position column, the
#     owner's join relationship sorted by position gives the list's order
#   * a list reads only its own rows of a join table (a row written
#     without the list's column is not a member)
#   * with policies, the restrictive joins of the cut-3 fixture read with
#     authorization on. One table holds Workspace's Members and User's
#     Workspaces, asymmetrically: the Members list a member whose
#     Workspaces do not list the workspace back, and a lister's Workspaces
#     list it while the Members do not: the Member rule holds for the
#     member only and the Listed rule ("Current User's Workspaces contains
#     This Workspace") for the lister only (a union would widen both), the
#     lister finds the workspace in searches and an outsider does not, and
#     the members are the member alone. An outsider sees none of the
#     members (the many_to_many, the join rows, the member's rows) nor of
#     a project's tasks (whose rule tests the members, a join read through
#     another). Two mutants (render.exs) must leak: without the join rows'
#     policy (and the join relationships' check) the rows show to the
#     outsider, and without the many_to_many filters the members and tasks
#     too; a mutant that does not leak fails the check (it would pass
#     vacuously)

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

        found =
          extensions(repo, fixture["extensions"]) ++
            Enum.flat_map(fixture["joins"], &join(repo, &1)) ++
            join_privacy(fixture["join_privacy"])

        checks =
          1 + length(fixture["joins"]) + if(fixture["join_privacy"], do: 2, else: 0)

        acc = {n + checks, found ++ failures}

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

    if Enum.any?(fixtures, &(&1["privacy"] == "unverified")) and
         not Enum.any?(Enum.flat_map(resources, & &1["has_many"]), & &1["creator"]),
       do: raise("no has_many with a restrictive destination read policy to check")

    for kind <- ["length", "count"],
        not Enum.any?(Enum.flat_map(resources, & &1["counts"]), &(&1["kind"] == kind)),
        do: raise("no #{kind} count to check")

    joins = Enum.flat_map(fixtures, & &1["joins"])
    if joins == [], do: raise("no join resource to check")

    for kind <- ["position", "flag"],
        not Enum.any?(Enum.flat_map(joins, & &1["sides"]), &(&1["kind"] == kind)),
        do: raise("no join list with a #{kind} to check")

    if Enum.any?(fixtures, &(&1["privacy"] == "unverified")) do
      variants = for f <- fixtures, p = f["join_privacy"], do: p["variant"]

      if Enum.sort(variants) != ["", "open_all", "open_join"],
        do: raise("the join privacy checks need the cut-3 fixture and both mutants: #{inspect(variants)}")
    end

    if failures != [] do
      Enum.each(failures, &IO.puts/1)
      raise "decisions check failed: #{length(failures)} failures"
    end

    count = fn key -> resources |> Enum.flat_map(& &1[key]) |> length() end

    IO.puts(
      "decisions check passed: #{length(fixtures)} fixtures, #{checks} checks, " <>
        "#{length(derived)} derived calculations and #{count.("counts")} derived counts " <>
        "read back, #{count.("has_many")} has_many and #{count.("text_references")} text " <>
        "references loaded, #{count.("indexes")} indexes found, #{length(joins)} join " <>
        "resources with #{joins |> Enum.flat_map(& &1["sides"]) |> length()} lists loaded"
    )
  end

  # --- cut 3 (WTF-406) -------------------------------------------------------------

  defp join(repo, %{"table" => table} = j) do
    %{rows: rows} =
      repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND table_name = $1",
        [table]
      )

    columns = rows |> List.flatten() |> Enum.sort()

    %{rows: keys} =
      repo.query!(
        "SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid " <>
          "AND a.attnum = ANY(i.indkey) WHERE i.indrelid = $1::text::regclass AND i.indisprimary",
        [~s("#{table}")]
      )

    keys = keys |> List.flatten() |> Enum.sort()

    [
      {columns == Enum.sort(j["columns"]), "columns #{inspect(columns)}, expected #{inspect(j["columns"])}"},
      {keys == Enum.sort(j["keys"]), "primary key #{inspect(keys)}, expected #{inspect(j["keys"])}"}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(fn {_, what} -> "join #{table}: #{what}" end)
    |> Enum.concat(Enum.flat_map(Enum.with_index(j["sides"]), &join_side(j, &1)))
  rescue
    error -> ["join #{j["table"]}: #{Exception.message(error)}"]
  end

  # Writes join rows for one list (authorization off) and loads them
  # back: the members, in the list's order through the join relationship.
  defp join_side(j, {side, i}) do
    owner = Module.concat([side["owner"]])
    member = Module.concat([side["member"]])
    join = Module.concat([j["resource"]])
    [pk] = Ash.Resource.Info.primary_key(owner)
    [member_pk] = Ash.Resource.Info.primary_key(member)
    tag = "#{j["table"]}-#{i}"
    o = create!(owner, %{pk => "owner-" <> tag})
    lonely = create!(owner, %{pk => "lonely-" <> tag})
    # members in reverse ID order, so the position order is not the ID order
    ids = for n <- [3, 2, 1], do: Map.fetch!(create!(member, %{member_pk => "member-#{n}-" <> tag}), member_pk)
    owner_column = String.to_atom(side["owner_column"])
    member_column = String.to_atom(side["member_column"])

    marker = String.to_atom(side["marker"])
    position? = side["kind"] == "position"

    for {id, position} <- Enum.with_index(ids) do
      create!(join, %{
        owner_column => Map.fetch!(o, pk),
        member_column => id,
        marker => if(position?, do: position, else: true)
      })
    end

    # a row of the table that is not a member of this list (another
    # list's, or written without the list's column) is not listed
    stray = create!(member, %{member_pk => "stray-" <> tag})
    create!(join, %{owner_column => Map.fetch!(o, pk), member_column => Map.fetch!(stray, member_pk)})

    rel = String.to_atom(side["relationship"])
    [o, lonely] = Ash.load!([o, lonely], [rel], authorize?: false)
    got = o |> Map.fetch!(rel) |> Enum.map(&Map.fetch!(&1, member_pk)) |> Enum.sort()

    ordered =
      if position? do
        rows = Ash.Query.sort(join, [{marker, :asc}])

        o
        |> Ash.load!([{String.to_atom(side["join_relationship"]), rows}], authorize?: false)
        |> Map.fetch!(String.to_atom(side["join_relationship"]))
        |> Enum.map(&Map.fetch!(&1, member_column))
      else
        ids
      end

    [
      {got == Enum.sort(ids),
       "#{side["relationship"]} loads #{inspect(got)}, expected #{inspect(ids)} (not a row outside the list)"},
      {Map.fetch!(lonely, rel) == [], "#{side["relationship"]} loads #{inspect(Map.fetch!(lonely, rel))} for a record with no rows"},
      {ordered == ids, "the join rows sorted by position give #{inspect(ordered)}, expected #{inspect(ids)}"}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(fn {_, what} -> "#{inspect(owner)} (join #{j["table"]}): #{what}" end)
  rescue
    error -> ["join #{j["table"]} side #{i}: #{Exception.message(error)}"]
  end

  defp join_privacy(nil), do: []

  # The restrictive joins with authorization on (see the header). Each
  # read is compared with what the fixture's variant must show.
  defp join_privacy(%{"variant" => variant, "actor" => actor} = p) do
    privacy = Module.concat([actor])
    users = privacy.actor_resource()
    [user_pk] = Ash.Resource.Info.primary_key(users)
    m = p["membership"]
    workspaces = Module.concat([m["owner"]])
    [ws_pk] = Ash.Resource.Info.primary_key(workspaces)
    tag = "privacy-" <> if(variant == "", do: "real", else: variant)
    a = &String.to_atom/1

    member = create!(users, %{user_pk => "member-" <> tag})
    lister = create!(users, %{user_pk => "lister-" <> tag})
    outsider = create!(users, %{user_pk => "outsider-" <> tag})
    workspace = create!(workspaces, %{ws_pk => "workspace-" <> tag})
    w = Map.fetch!(workspace, ws_pk)
    mid = Map.fetch!(member, user_pk)
    lid = Map.fetch!(lister, user_pk)

    # one table, two lists: the workspace's Members list the member, whose
    # Workspaces do not list it back; the lister's Workspaces list it, and
    # its Members do not list the lister
    join = Module.concat([m["join"]])
    create!(join, %{a.(m["workspace_column"]) => w, a.(m["user_column"]) => mid, a.(m["members_marker"]) => 0})
    create!(join, %{a.(m["workspace_column"]) => w, a.(m["user_column"]) => lid, a.(m["workspaces_marker"]) => 0})

    n = p["nested"]
    projects = Module.concat([n["owner"]])
    tasks = Module.concat([n["member"]])
    [project_pk] = Ash.Resource.Info.primary_key(projects)
    [task_pk] = Ash.Resource.Info.primary_key(tasks)
    project = create!(projects, %{project_pk => "project-" <> tag, a.(n["workspace_attribute"]) => w})
    task = create!(tasks, %{task_pk => "task-" <> tag})
    t = Map.fetch!(task, task_pk)

    create!(Module.concat([n["join"]]), %{
      a.(n["owner_column"]) => Map.fetch!(project, project_pk),
      a.(n["member_column"]) => t,
      a.(n["marker"]) => 0
    })

    load = fn user -> privacy.load_actor(Map.fetch!(user, user_pk)) end

    # The IDs `record`'s relationship `rel` shows to `user`, with
    # authorization on (`key`: the ID read from each related record).
    seen = fn user, record, rel, key ->
      record
      |> Ash.load!([a.(rel)], actor: load.(user), authorize?: true)
      |> Map.fetch!(a.(rel))
      |> Enum.map(&Map.fetch!(&1, if(is_binary(key), do: a.(key), else: key)))
      |> Enum.sort()
    end

    # A privacy rule's condition for `user` on the workspace (the rule's
    # calculation, computed in PostgreSQL).
    rule = fn user, calc ->
      workspace
      |> Ash.load!([a.(calc)], actor: load.(user), authorize?: false)
      |> Map.fetch!(a.(calc))
    end

    searched = fn user ->
      workspaces
      |> Ash.Query.for_read(:search, %{}, actor: load.(user))
      |> Ash.Query.filter_input(%{Atom.to_string(ws_pk) => %{"eq" => w}})
      |> Ash.read(actor: load.(user))
      |> case do
        {:ok, records} -> Enum.map(records, &Map.fetch!(&1, ws_pk))
        {:error, %Ash.Error.Forbidden{}} -> []
      end
    end

    # what an outsider sees: nothing, unless the variant removed what
    # hides it
    leak = fn what, ids ->
      open =
        case {variant, what} do
          {"open_join", read} when read in [:rows, :join_rows] -> true
          {"open_all", _} -> true
          _ -> false
        end

      if open, do: ids, else: []
    end

    member_col = m["user_column"]
    ws_col = m["workspace_column"]
    task_col = n["member_column"]
    project_col = n["owner_column"]

    [
      # the asymmetric shared join widens nothing: each rule reads its
      # own list's rows (a union would make both true for both)
      {rule.(member, m["member_rule"]), true, "the Member rule for the member"},
      {rule.(lister, m["member_rule"]), false, "the Member rule for the lister (not in Members)"},
      {rule.(member, m["listed_rule"]), false, "the Listed rule for the member (not in its Workspaces)"},
      {rule.(lister, m["listed_rule"]), true, "the Listed rule for the lister (Current User's Workspaces contains This Workspace)"},
      {rule.(outsider, m["member_rule"]) or rule.(outsider, m["listed_rule"]), false, "a rule for an outsider"},
      {searched.(lister), [w], "the workspace in the lister's searches"},
      {searched.(outsider), [], "the workspace in an outsider's searches"},
      {seen.(member, workspace, m["members"], user_pk), [mid], "the workspace's members, to the member (not the lister)"},
      {seen.(lister, lister, m["workspaces"], ws_pk), [w], "the lister's workspaces, to the lister"},
      {seen.(member, member, m["workspaces"], ws_pk), [], "the member's workspaces (it lists none), to the member"},
      # an outsider
      {seen.(outsider, workspace, m["members"], user_pk), leak.(:many_to_many, [mid]), "the workspace's members, to an outsider"},
      {seen.(outsider, workspace, m["members_join"], member_col), leak.(:join_rows, [mid]), "the workspace's member rows, to an outsider"},
      {seen.(outsider, member, m["member_rows"], ws_col), leak.(:rows, [w]), "the member's rows of Members, to an outsider"},
      {seen.(outsider, project, n["relationship"], task_pk), leak.(:many_to_many, [t]), "the project's tasks, to an outsider"},
      {seen.(outsider, project, n["join_relationship"], task_col), leak.(:join_rows, [t]), "the project's task rows, to an outsider"},
      {seen.(outsider, task, n["rows"], project_col), leak.(:rows, [Map.fetch!(project, project_pk)]), "the task's rows of Tasks, to an outsider"},
      # a member
      {seen.(member, member, m["member_rows"], ws_col), [w], "the member's rows of Members, to the member"},
      {seen.(member, project, n["relationship"], task_pk), [t], "the project's tasks, to a member"}
    ]
    |> Enum.reject(fn {got, expected, _} -> got == expected end)
    |> Enum.map(fn {got, expected, what} ->
      "join privacy (#{tag}): #{what} is #{inspect(got)}, expected #{inspect(expected)}" <>
        if(variant != "" and got in [[], false] and expected not in [[], false],
          do: " (the mutant does not leak: the check would pass vacuously)",
          else: ""
        )
    end)
  rescue
    error -> ["join privacy (#{p["variant"]}): #{Exception.message(error)}"]
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

          case many.type do
            # a list normalized to a join (WTF-406): members through join
            # rows; a member of another owner is not counted
            :many_to_many ->
              for {i, of} <- [{1, full}, {2, full}, {3, none}] do
                item = create!(many.destination, %{dest_pk => "item-#{i}-" <> tag})

                # (every membership column set: the row is a member of
                # the table's lists)
                members =
                  for a <- Ash.Resource.Info.attributes(many.through),
                      not a.primary_key?,
                      into: %{},
                      do: {a.name, if(a.type == Ash.Type.Boolean, do: true, else: 0)}

                create!(
                  many.through,
                  Map.merge(members, %{
                    many.source_attribute_on_join_resource => Map.fetch!(of, owner_pk),
                    many.destination_attribute_on_join_resource => Map.fetch!(item, dest_pk)
                  })
                )
              end

            _ ->
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
          end

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

            case many.type do
              :many_to_many ->
                many.through
                |> Ash.Query.do_filter([
                  {many.source_attribute_on_join_resource, Map.fetch!(owner_record, owner_pk)}
                ])
                |> Ash.count!(authorize?: false)

              _ ->
                many.destination
                |> Ash.Query.do_filter([
                  {many.destination_attribute, Map.fetch!(owner_record, owner_pk)}
                ])
                |> Ash.count!(authorize?: false)
            end
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

  defp has_many(resource, %{"name" => name} = h) do
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
    |> Enum.concat(authorized_has_many(resource, h, owner, tag))
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(fn {_, what} -> "#{tag}: #{what}" end)
  rescue
    error -> ["#{inspect(resource)}.#{name}: #{Exception.message(error)}"]
  end

  # The public has_many with authorization on, when its destination is
  # readable only by the user who created the record: an outsider sees
  # none of the owner's children, a member only the child they created.
  defp authorized_has_many(_resource, %{"creator" => nil}, _owner, _tag), do: []

  defp authorized_has_many(resource, %{"public" => public, "creator" => creator} = h, owner, tag) do
    many = rel(resource, public)
    privacy = Module.concat([h["actor"]])
    users = privacy.actor_resource()
    [user_pk] = Ash.Resource.Info.primary_key(users)
    [dest_pk] = Ash.Resource.Info.primary_key(many.destination)
    [pk] = Ash.Resource.Info.primary_key(resource)

    unless Ash.Policy.Authorizer in Ash.Resource.Info.authorizers(many.destination),
      do: raise("#{inspect(many.destination)} has no policies")

    member = create!(users, %{user_pk => "member-" <> tag})
    outsider = create!(users, %{user_pk => "outsider-" <> tag})

    mine =
      create!(many.destination, %{
        dest_pk => "member-child-" <> tag,
        many.destination_attribute => Map.fetch!(owner, pk),
        String.to_atom(creator) => Map.fetch!(member, user_pk)
      })

    seen = fn user ->
      actor = privacy.load_actor(Map.fetch!(user, user_pk))

      owner
      |> Ash.load!([many.name], actor: actor, authorize?: true)
      |> Map.fetch!(many.name)
      |> Enum.map(&Map.fetch!(&1, dest_pk))
      |> Enum.sort()
    end

    outsider_sees = seen.(outsider)
    member_sees = seen.(member)

    [
      {outsider_sees == [],
       "#{public} with authorization on shows #{inspect(outsider_sees)} to a user who created no child, expected []"},
      {member_sees == [Map.fetch!(mine, dest_pk)],
       "#{public} with authorization on shows #{inspect(member_sees)} to the creator of one child, expected only it"}
    ]
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
