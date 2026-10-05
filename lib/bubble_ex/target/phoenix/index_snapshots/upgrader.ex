defmodule BubbleEx.Target.Phoenix.IndexSnapshots.Upgrader do
  @moduledoc """
  Records a generated project's concurrent index hints as concurrent in
  its AshPostgres resource snapshots (WTF-418), so `mix ash.codegen` does
  not drop and rebuild those indexes.

  This file is self-contained: it uses only Elixir and Jason. bubble_ex
  runs it as `mix bubble.concurrent_index_snapshots`
  (`BubbleEx.Target.Phoenix.IndexSnapshots`), and every generated project
  ships its source as `priv/bubble/concurrent_index_snapshots.exs` (WTF-499),
  for owners without bubble_ex:

      mix run --no-start priv/bubble/concurrent_index_snapshots.exs --dry-run
      mix run --no-start priv/bubble/concurrent_index_snapshots.exs

  The generated resources declare their custom indexes (the search index
  hints) `concurrently: true`. A project whose migrations were generated
  before that has snapshots recording them `"concurrently": false`, and
  AshPostgres compares the flag: its next `mix ash.codegen` would drop
  every such index and build it again. `fix/2` records them as concurrent
  instead, in each table's latest snapshot.

  A snapshot index is changed only when it is one of the generated
  resources' (listed in `.wtf/generated.json`): same table (and repo),
  same name, same fields and access method, declared `concurrently: true`
  in the resource, not unique, recorded `"concurrently": false`. Identities
  (unique indexes) are never touched, nor indexes the owner declared, nor
  older or `_dev` snapshots, nor tenant snapshots (`<repo>/tenants/`). A
  snapshot is rewritten in AshPostgres' layout, keeping its trailing
  whitespace; one whose JSON differs from that layout by more than
  whitespace (key order, duplicate keys), or is not valid JSON, is
  `skipped` with a reason. Each file is written atomically (a temporary
  file in its directory, then renamed). Run again, it changes nothing.
  """

  @snapshots "priv/resource_snapshots"
  @manifest ".wtf/generated.json"

  @type change :: %{path: String.t(), table: String.t(), indexes: [String.t()]}
  @type skipped :: %{path: String.t(), table: String.t(), reason: String.t()}
  @type report :: %{
          changes: [change()],
          skipped: [skipped()],
          warnings: [String.t()],
          not_concurrent: non_neg_integer(),
          written?: boolean()
        }
  @type failure :: %{message: String.t(), context: map()}

  # --- command line ------------------------------------------------------------------

  @doc """
  The command line: parses `argv` (`--root DIR`, `--dry-run`), runs
  `fix/2`, reports through `:info` and `:error` (one line each; default
  standard output and standard error). `:ok`, or `{:error, message}` when
  the caller must exit non-zero: a usage error, a snapshot skipped,
  resources not regenerated yet, or a failure.

  Options: `:usage` (the usage line), `:root` (the default root; without
  it `--root` is required).
  """
  @spec cli([String.t()], keyword()) :: :ok | {:error, String.t()}
  def cli(argv, opts \\ []) do
    usage = Keyword.get(opts, :usage, "usage: --root DIR [--dry-run]")
    out = %{info: Keyword.get(opts, :info, &IO.puts/1), error: Keyword.get(opts, :error, &warn/1)}
    {parsed, rest, invalid} = OptionParser.parse(argv, strict: [root: :string, dry_run: :boolean])

    case {Keyword.get(parsed, :root, opts[:root]), rest, invalid} do
      {root, [], []} when is_binary(root) ->
        dry_run? = Keyword.get(parsed, :dry_run, false)

        case fix(root, dry_run: dry_run?) do
          {:ok, report} -> print(report, dry_run?, out)
          {:error, %{message: message}} -> {:error, message}
        end

      _ ->
        {:error, usage}
    end
  end

  defp warn(line), do: IO.puts(:stderr, line)

  defp print(report, dry_run?, out) do
    verb = if dry_run?, do: "Would record", else: "Recorded"

    for %{path: path, indexes: indexes} <- report.changes,
        do: out.info.("#{verb} as concurrent in #{path}: #{Enum.join(indexes, ", ")}")

    for warning <- report.warnings, do: out.error.("Warning: " <> warning)

    for %{path: path, reason: reason} <- report.skipped,
        do: out.error.("Skipped #{path}: #{reason}")

    conclude(report, dry_run?, out)
  end

  defp conclude(%{skipped: [_ | _] = skipped} = report, dry_run?, _out) do
    {:error,
     "#{length(skipped)} snapshot(s) skipped: fix them as said above before mix " <>
       "ash.codegen, or it drops and rebuilds their indexes (#{done(report)} " <>
       if(dry_run?, do: "to record)", else: "recorded)")}
  end

  defp conclude(%{changes: [], not_concurrent: n}, _dry_run?, _out) when n > 0 do
    {:error,
     "The generated resources declare #{n} index(es) without concurrently: true: " <>
       "regenerate the project first, then run this again (before mix ash.codegen)."}
  end

  defp conclude(%{changes: []}, _dry_run?, out),
    do: out.info.("No snapshot records a generated index as not concurrent.")

  defp conclude(report, true, out),
    do: out.info.(done(report) <> "; nothing written (--dry-run).")

  defp conclude(report, false, out),
    do: out.info.(done(report) <> ". Now run mix ash.codegen.")

  defp done(%{changes: changes}) do
    count = changes |> Enum.map(&length(&1.indexes)) |> Enum.sum()
    "#{count} index(es) in #{length(changes)} snapshot(s)"
  end

  # --- fix ---------------------------------------------------------------------------

  @doc """
  Records the generated resources' concurrent indexes as concurrent in the
  latest snapshots of the project at `root`. With `dry_run: true`, only
  reports what it would change.

  The report's `skipped` snapshots need a hand fix (they keep their
  non-concurrent indexes); `warnings` name what it does not look at (a
  symbolically linked snapshot directory, `_dev` snapshots);
  `not_concurrent` counts the custom indexes the generated resources
  still declare without `concurrently: true` (resources generated before
  WTF-418: regenerate first). A failed write stops at that file, leaving
  it unchanged: `{:error, failure}` with `failure.context.written`.
  """
  @spec fix(Path.t(), keyword()) :: {:ok, report()} | {:error, failure()}
  def fix(root, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    rename = Keyword.get(opts, :rename, &File.rename/2)

    with :ok <- dir(root),
         {:ok, manifest} <- read_manifest(root),
         {changes, skipped} = plan(manifest, reader(root), lister(root)),
         :ok <- if(dry_run?, do: :ok, else: write(root, changes, rename)) do
      {:ok,
       %{
         changes: Enum.map(changes, &Map.delete(&1, :content)),
         skipped: skipped,
         warnings: warnings(root, manifest),
         not_concurrent: not_concurrent(manifest, reader(root)),
         written?: not dry_run? and changes != []
       }}
    end
  end

  defp write(root, changes, rename) do
    Enum.reduce_while(changes, {:ok, []}, fn %{path: path, content: content}, {:ok, written} ->
      case atomic_write(Path.join(root, path), content, rename) do
        :ok ->
          {:cont, {:ok, [path | written]}}

        {:error, reason} ->
          {:halt,
           failure("could not write #{path}: #{inspect(reason)} (left unchanged)", %{
             path: path,
             written: Enum.reverse(written)
           })}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # A temporary file in the same directory, renamed over the snapshot: a
  # reader sees the old file or the new one, never a part.
  defp atomic_write(file, content, rename) do
    tmp =
      Path.join(
        Path.dirname(file),
        ".#{Path.basename(file)}.#{System.unique_integer([:positive])}.tmp"
      )

    with :ok <- File.write(tmp, content, [:exclusive]),
         :ok <- rename.(tmp, file) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  @doc """
  The latest snapshots whose generated indexes the next `mix
  ash.codegen` would rebuild: those to fix and those skipped. `manifest`
  is the decoded `.wtf/generated.json`; `read` and `list` read project
  paths.
  """
  @spec stale(map(), (String.t() -> binary() | nil), (String.t() -> [String.t()])) ::
          [String.t()]
  def stale(manifest, read, list) do
    {changes, skipped} = plan(manifest, read, list)
    (changes ++ skipped) |> Enum.map(& &1.path) |> Enum.sort()
  end

  # {changes with the new content, skipped}
  defp plan(manifest, read, list) do
    indexes = generated_indexes(manifest, read)

    snapshots = if indexes == %{}, do: [], else: latest(list.(@snapshots))

    outcomes =
      for {table, path} <- snapshots,
          wanted = Map.get(indexes, table),
          wanted != nil,
          outcome = snapshot_change(path, read.(path), wanted),
          outcome != nil,
          do: {table, path, outcome}

    changes = for {table, _path, %{} = change} <- outcomes, do: Map.put(change, :table, table)

    skipped =
      for {table, path, {:skip, reason}} <- outcomes,
          do: %{path: path, table: table, reason: reason}

    {changes, skipped}
  end

  # The latest `<14 digits>.json` per `<repo>/<table>` directory (what
  # AshPostgres compares against), as {table, path}. Tenant snapshots
  # (`<repo>/tenants/<table>`) are not the generated resources'.
  defp latest(paths) do
    paths
    |> Enum.flat_map(&snapshot_file/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.map(fn {{_repo, table}, paths} -> {table, Enum.max(paths)} end)
  end

  defp snapshot_file(path) do
    with ["priv", "resource_snapshots", repo, table, file] when repo != "tenants" <-
           Path.split(path),
         true <- file =~ ~r/\A\d{14}\.json\z/ do
      [{{repo, table}, path}]
    else
      _ -> []
    end
  end

  defp snapshot_change(_path, nil, _wanted), do: nil

  defp snapshot_change(path, content, wanted) do
    case Jason.decode(content) do
      {:ok, %{"custom_indexes" => indexes} = snapshot} when is_list(indexes) ->
        repo = snapshot["repo"]

        flipped =
          for %{"name" => name} = index <- indexes,
              index["concurrently"] == false,
              index["unique"] in [false, nil],
              Enum.any?(wanted, &same_index?(&1, index, repo)),
              do: name

        cond do
          flipped == [] ->
            nil

          not layout?(content, snapshot) ->
            {:skip,
             "its JSON differs from AshPostgres' layout by more than whitespace (key order or " <>
               "duplicate keys); set \"concurrently\": true by hand on " <>
               Enum.join(flipped, ", ")}

          true ->
            indexes = Enum.map(indexes, &flip(&1, flipped))
            new = encode(%{snapshot | "custom_indexes" => indexes}) <> trailing(content)
            %{path: path, indexes: flipped, content: new}
        end

      {:ok, _} ->
        nil

      {:error, _} ->
        {:skip, "not valid JSON: AshPostgres cannot read it either"}
    end
  end

  # The content is AshPostgres' encoding up to whitespace: the same keys
  # in the same (sorted) order, no duplicates, the same values.
  defp layout?(content, snapshot) do
    case Jason.decode(content, objects: :ordered_objects) do
      {:ok, ordered} -> Jason.encode!(ordered) == Jason.encode!(snapshot)
      {:error, _} -> false
    end
  end

  defp trailing(content), do: hd(Regex.run(~r/\s*\z/, content))

  defp flip(%{"name" => name, "concurrently" => false} = index, flipped),
    do: if(name in flipped, do: %{index | "concurrently" => true}, else: index)

  defp flip(index, _flipped), do: index

  # AshPostgres writes `Jason.encode!(snapshot, pretty: true)`; maps of
  # fewer than 33 keys encode in sorted order.
  defp encode(snapshot), do: Jason.encode!(snapshot, pretty: true)

  defp same_index?(wanted, index, repo) do
    index["name"] == wanted.name and
      Enum.map(index["fields"] || [], &field/1) == wanted.fields and
      index["using"] == wanted.using and
      (wanted.repo == nil or repo in [nil, "Elixir." <> wanted.repo])
  end

  defp field(%{"value" => value}) when is_binary(value), do: value
  defp field(value) when is_binary(value), do: value
  defp field(other), do: inspect(other)

  # --- what fix/2 does not look at ---------------------------------------------------

  defp warnings(root, manifest) do
    tables = manifest |> generated_indexes(reader(root)) |> Map.keys()
    symlinked(root) ++ dev_snapshots(root, tables)
  end

  defp symlinked(root) do
    dirs =
      [@snapshots] ++
        for repo <- ls(root, [@snapshots]),
            dir = Path.join(@snapshots, repo),
            table <- [nil | ls(root, [dir])],
            do: if(table, do: Path.join(dir, table), else: dir)

    for dir <- dirs,
        match?({:ok, %File.Stat{type: :symlink}}, File.lstat(Path.join(root, dir))),
        do: "#{dir} is a symbolic link: not followed; run against the directory it points to"
  end

  defp dev_snapshots(root, tables) do
    for repo <- ls(root, [@snapshots]),
        table <- ls(root, [@snapshots, repo]),
        table in tables,
        file <- ls(root, [@snapshots, repo, table]),
        String.ends_with?(file, "_dev.json"),
        do:
          "#{Path.join([@snapshots, repo, table, file])} is a `mix ash.codegen --dev` " <>
            "snapshot: not changed; generate named migrations (without --dev) before upgrading"
  end

  # The custom indexes the generated resources declare without
  # `concurrently: true` (not unique): resources from before WTF-418.
  defp not_concurrent(manifest, read) do
    for path <- resource_paths(manifest),
        content = read.(path),
        is_binary(content),
        {:ok, ast} <- [Code.string_to_quoted(content, emit_warnings: false)],
        {_table, _repo, _indexes, old} <- postgres_blocks(ast),
        reduce: 0 do
      n -> n + old
    end
  end

  # --- the generated resources' indexes --------------------------------------------

  # table => [%{name, fields, using, repo}]: the custom indexes the
  # generated resources declare `concurrently: true` and not unique.
  defp generated_indexes(manifest, read) do
    for path <- resource_paths(manifest),
        content = read.(path),
        is_binary(content),
        {:ok, ast} <- [Code.string_to_quoted(content, emit_warnings: false)],
        {table, repo, indexes, _old} <- postgres_blocks(ast),
        index <- indexes,
        reduce: %{} do
      acc ->
        index = Map.put(index, :repo, repo)
        Map.update(acc, table, [index], &[index | &1])
    end
  end

  # The generated `lib/**/*.ex` files the manifest lists, relative and
  # inside the project.
  defp resource_paths(%{"generated" => generated}) when is_map(generated) do
    for {path, _hash} <- generated,
        is_binary(path),
        String.starts_with?(path, "lib/") and String.ends_with?(path, ".ex"),
        ".." not in Path.split(path),
        do: path
  end

  defp resource_paths(_manifest), do: []

  defp postgres_blocks(ast) do
    {_, blocks} =
      Macro.prewalk(ast, [], fn
        {:postgres, _, [[do: block]]} = node, acc -> {node, [postgres(block) | acc]}
        node, acc -> {node, acc}
      end)

    for {table, _repo, _indexes, _old} = block <- blocks, is_binary(table), do: block
  end

  defp postgres(block) do
    entries = block(block)

    table =
      Enum.find_value(entries, fn
        {:table, _, [t]} -> t
        _ -> nil
      end)

    repo =
      Enum.find_value(entries, fn
        {:repo, _, [{:__aliases__, _, parts}]} -> Enum.map_join(parts, ".", &Atom.to_string/1)
        _ -> nil
      end)

    declared =
      for {:custom_indexes, _, [[do: inner]]} <- entries,
          {:index, _, [fields, opts]} <- block(inner),
          is_list(fields) and Keyword.keyword?(opts),
          opts[:unique] != true,
          is_binary(opts[:name]),
          do: {opts[:concurrently] == true, fields, opts}

    indexes =
      for {true, fields, opts} <- declared,
          do: %{name: opts[:name], fields: Enum.map(fields, &to_string/1), using: opts[:using]}

    {table, repo, indexes, Enum.count(declared, &(not elem(&1, 0)))}
  end

  defp block({:__block__, _, entries}), do: entries
  defp block(entry), do: [entry]

  # --- files -------------------------------------------------------------------------

  defp dir(root) do
    if File.dir?(root),
      do: :ok,
      else: failure("#{inspect(root)} is not a directory")
  end

  defp read_manifest(root) do
    with {:ok, json} <- File.read(Path.join(root, @manifest)),
         {:ok, %{"generated" => generated} = manifest} when is_map(generated) <-
           Jason.decode(json) do
      {:ok, manifest}
    else
      {:error, %Jason.DecodeError{}} -> failure("#{@manifest} in #{root} is not JSON")
      {:ok, _} -> failure("#{@manifest} in #{root} is not a generated-file manifest")
      {:error, _} -> failure("no #{@manifest} in #{root}: not a generated project")
    end
  end

  defp failure(message, context \\ %{}), do: {:error, %{message: message, context: context}}

  defp reader(root) do
    fn path ->
      case File.read(Path.join(root, path)) do
        {:ok, content} -> content
        {:error, _} -> nil
      end
    end
  end

  # The snapshot files `<dir>/<repo>/<table>/<file>`, as project paths. Not
  # Path.wildcard: the root may hold glob characters. Symbolic links are
  # not followed.
  defp lister(root) do
    fn dir ->
      for repo <- ls(root, [dir]),
          table <- ls(root, [dir, repo]),
          file <- ls(root, [dir, repo, table]),
          path = Path.join([dir, repo, table, file]),
          match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(root, path))),
          do: path
    end
  end

  defp ls(root, parts) do
    full = Path.join([root | parts])

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(full),
         {:ok, names} <- File.ls(full) do
      Enum.sort(names)
    else
      _ -> []
    end
  end
end
