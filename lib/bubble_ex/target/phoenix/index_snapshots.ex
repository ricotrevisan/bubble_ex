defmodule BubbleEx.Target.Phoenix.IndexSnapshots do
  @moduledoc """
  Upgrades a generated project's AshPostgres resource snapshots to the
  concurrent index hints (WTF-418).

  The generated resources declare their custom indexes (the search index
  hints) `concurrently: true`, so `mix ash.codegen` builds the indexes it
  adds without locking writes. A project whose migrations were generated
  before that has snapshots recording those indexes as not concurrent, and
  AshPostgres compares the flag: its next `mix ash.codegen` would drop
  every such index and build it again. `fix/2` records them as concurrent
  instead, in each table's latest snapshot, so codegen sees no change for
  them (the database keeps its indexes) and builds later ones
  concurrently.

  A snapshot index is changed only when it is one of the generated
  resources' (listed in `.wtf/generated.json`): same table (and repo),
  same name, same fields and access method, declared `concurrently: true`
  in the resource, not unique, recorded `"concurrently": false`. Identities
  (unique indexes) are never touched, nor indexes the owner declared, nor
  older or `_dev` snapshots. A snapshot whose JSON would not be written
  back byte for byte (apart from the flag) is skipped with a reason. Run
  again, it changes nothing.

  `mix bubble.concurrent_index_snapshots` runs it; `check_manifest/3`
  lists the snapshots that need it (`index_snapshots_stale`).
  """

  alias BubbleEx.Error
  alias BubbleEx.Target.Phoenix.Manifest

  @snapshots "priv/resource_snapshots"

  @type change :: %{path: String.t(), table: String.t(), indexes: [String.t()]}
  @type skipped :: %{path: String.t(), reason: String.t()}
  @type report :: %{changes: [change()], skipped: [skipped()], written?: boolean()}

  @doc """
  Records the generated resources' concurrent indexes as concurrent in the
  latest snapshots of the project at `root`. With `dry_run: true`, only
  reports what it would change.
  """
  @spec fix(Path.t(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def fix(root, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    with :ok <- dir(root),
         {:ok, json} <- read_manifest(root),
         {:ok, manifest} <- Manifest.decode(json) do
      {changes, skipped} = plan(manifest, reader(root), lister(root))

      unless dry_run?, do: write(root, changes)

      {:ok,
       %{
         changes: Enum.map(changes, &Map.delete(&1, :content)),
         skipped: skipped,
         written?: not dry_run? and changes != []
       }}
    end
  end

  defp write(root, changes) do
    for %{path: path, content: content} <- changes,
        do: File.write!(Path.join(root, path), content)
  end

  @doc false
  # The latest snapshots that record a generated concurrent index as not
  # concurrent (Manifest.check/3); `read` and `list` read project paths.
  @spec stale(map(), (String.t() -> binary() | nil), (String.t() -> [String.t()])) ::
          [String.t()]
  def stale(manifest, read, list) do
    {changes, _skipped} = plan(manifest, read, list)
    Enum.map(changes, & &1.path)
  end

  # {changes with the new content, skipped}
  defp plan(manifest, read, list) do
    indexes = generated_indexes(manifest, read)

    outcomes =
      if indexes == %{},
        do: [],
        else:
          for(
            {table, path} <- latest(list.(@snapshots)),
            wanted = Map.get(indexes, table),
            wanted != nil,
            outcome = snapshot_change(path, read.(path), wanted),
            outcome != nil,
            do: {table, path, outcome}
          )

    changes = for {table, _path, %{} = change} <- outcomes, do: Map.put(change, :table, table)
    skipped = for {_table, path, {:skip, reason}} <- outcomes, do: %{path: path, reason: reason}
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
    with {:ok, %{"custom_indexes" => indexes} = snapshot} when is_list(indexes) <-
           Jason.decode(content),
         true <- encode(snapshot) == content || {:skip, "not in AshPostgres' JSON layout"} do
      repo = snapshot["repo"]

      flipped =
        for %{"name" => name} = index <- indexes,
            index["concurrently"] == false,
            index["unique"] in [false, nil],
            Enum.any?(wanted, &same_index?(&1, index, repo)),
            do: name

      if flipped == [] do
        nil
      else
        indexes = Enum.map(indexes, &flip(&1, flipped))

        %{
          path: path,
          indexes: flipped,
          content: encode(%{snapshot | "custom_indexes" => indexes})
        }
      end
    else
      {:skip, reason} -> {:skip, reason}
      {:error, _} -> {:skip, "not valid JSON"}
      _ -> nil
    end
  end

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

  # --- the generated resources' indexes --------------------------------------------

  # table => [%{name, fields, using, repo}]: the custom indexes the
  # generated resources declare `concurrently: true` and not unique.
  defp generated_indexes(%{"generated" => generated}, read) do
    for {path, _hash} <- generated,
        String.starts_with?(path, "lib/") and String.ends_with?(path, ".ex"),
        content = read.(path),
        is_binary(content),
        {:ok, ast} <- [Code.string_to_quoted(content, emit_warnings: false)],
        {table, repo, indexes} <- postgres_blocks(ast),
        index <- indexes,
        reduce: %{} do
      acc ->
        index = Map.put(index, :repo, repo)
        Map.update(acc, table, [index], &[index | &1])
    end
  end

  defp generated_indexes(_manifest, _read), do: %{}

  defp postgres_blocks(ast) do
    {_, blocks} =
      Macro.prewalk(ast, [], fn
        {:postgres, _, [[do: block]]} = node, acc -> {node, [postgres(block) | acc]}
        node, acc -> {node, acc}
      end)

    for {table, repo, indexes} <- blocks, is_binary(table), do: {table, repo, indexes}
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

    indexes =
      for {:custom_indexes, _, [[do: inner]]} <- entries,
          {:index, _, [fields, opts]} <- block(inner),
          is_list(fields) and Keyword.keyword?(opts),
          opts[:concurrently] == true and opts[:unique] != true,
          is_binary(opts[:name]),
          do: %{
            name: opts[:name],
            fields: Enum.map(fields, &to_string/1),
            using: opts[:using]
          }

    {table, repo, indexes}
  end

  defp block({:__block__, _, entries}), do: entries
  defp block(entry), do: [entry]

  # --- files -------------------------------------------------------------------------

  defp dir(root) do
    if File.dir?(root),
      do: :ok,
      else: {:error, Error.new(:invalid_input, "#{inspect(root)} is not a directory")}
  end

  defp read_manifest(root) do
    case File.read(Path.join(root, Manifest.path())) do
      {:ok, json} ->
        {:ok, json}

      {:error, _} ->
        {:error,
         Error.new(:invalid_input, "no #{Manifest.path()} in #{root}: not a generated project")}
    end
  end

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
