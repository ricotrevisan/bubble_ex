defmodule BubbleEx.Target.Phoenix.IndexSnapshotsTest do
  # WTF-418: upgrading a project whose snapshots record the index hints as
  # not concurrent, without dropping and rebuilding them.
  use ExUnit.Case, async: false

  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Target.Phoenix.{Checks, IndexSnapshots, Manifest, Structural}
  alias BubbleEx.Test.DecidedFixture

  @moduletag :tmp_dir

  @dir "priv/resource_snapshots/repo"
  @latest "#{@dir}/project_tasks/20260102000000.json"
  @older "#{@dir}/project_tasks/20260101000000.json"
  @dev "#{@dir}/project_tasks/20260103000000_dev.json"
  @mismatched "#{@dir}/favorite_project/20260101000000.json"
  @foreign "#{@dir}/oban_jobs/20260101000000.json"
  @compact "#{@dir}/user_workspaces/20260101000000.json"

  setup %{tmp_dir: root} do
    {:ok, project} = DecidedFixture.project(:cut3)
    {:ok, files} = Phoenix.render(project, name: "Acme Import")

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), content)
    end

    # what the generated resources declare (the fixture's join tables)
    tasks = Enum.find_value(files, fn {_, c} -> c =~ ~s(table "project_tasks") && c end)

    assert tasks =~
             ~s(index [:task_id], name: "project_tasks_task_id_index", concurrently: true)

    old = [index("project_tasks_task_id_index", ["task_id"])]

    snapshots = %{
      # the latest: the hint (to flip), an index of the owner's, a unique
      # index under the hint's name pattern, and an identity
      @latest =>
        snapshot("project_tasks",
          custom_indexes:
            old ++
              [
                index("project_tasks_owner_index", ["position"]),
                index("project_tasks_task_id_unique_index", ["task_id"], unique: true)
              ],
          identities: [%{"name" => "unique_pair", "keys" => [], "concurrently" => false}]
        ),
      # older and _dev snapshots are not what codegen compares against
      @older => snapshot("project_tasks", custom_indexes: old),
      @dev => snapshot("project_tasks", custom_indexes: old),
      # the generated name over other fields: not the generated index
      @mismatched =>
        snapshot("favorite_project",
          custom_indexes: [index("favorite_project_user_id_index", ["project_id"])]
        ),
      # a table no generated resource has
      @foreign =>
        snapshot("oban_jobs", custom_indexes: [index("project_tasks_task_id_index", ["task_id"])]),
      # not in AshPostgres' layout: skipped, not rewritten
      @compact =>
        Jason.encode!(%{
          "table" => "user_workspaces",
          "repo" => "Elixir.AcmeImport.Repo",
          "custom_indexes" => [
            Jason.decode!(index("user_workspaces_workspace_id_index", ["workspace_id"]))
          ]
        })
    }

    for {path, content} <- snapshots do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), content)
    end

    %{root: root, snapshots: snapshots}
  end

  defp index(name, fields, opts \\ []) do
    %{
      "all_tenants?" => false,
      "concurrently" => Keyword.get(opts, :concurrently, false),
      "error_fields" => fields,
      "fields" => Enum.map(fields, &%{"type" => "atom", "value" => &1}),
      "include" => nil,
      "include_base_filter?" => true,
      "message" => nil,
      "name" => name,
      "nulls_distinct" => true,
      "prefix" => nil,
      "table" => nil,
      "unique" => Keyword.get(opts, :unique, false),
      "using" => nil,
      "where" => nil
    }
    |> Jason.encode!()
  end

  defp snapshot(table, opts) do
    %{
      "attributes" => [],
      "base_filter" => nil,
      "check_constraints" => [],
      "custom_indexes" => Enum.map(Keyword.get(opts, :custom_indexes, []), &Jason.decode!/1),
      "custom_statements" => [],
      "has_create_action" => true,
      "hash" => "0",
      "identities" => Keyword.get(opts, :identities, []),
      "multitenancy" => %{"attribute" => nil, "global" => nil, "strategy" => nil},
      "repo" => "Elixir.AcmeImport.Repo",
      "schema" => nil,
      "table" => table
    }
    |> Jason.encode!(pretty: true)
  end

  defp read(root, path), do: File.read!(Path.join(root, path))

  test "a dry run reports, writes nothing", %{root: root, snapshots: snapshots} do
    assert {:ok, %{changes: [change], skipped: [skipped], written?: false}} =
             IndexSnapshots.fix(root, dry_run: true)

    assert change == %{
             path: @latest,
             table: "project_tasks",
             indexes: ["project_tasks_task_id_index"]
           }

    assert skipped == %{path: @compact, reason: "not in AshPostgres' JSON layout"}
    for {path, content} <- snapshots, do: assert(read(root, path) == content)
  end

  test "flips only the generated index in the latest snapshot; idempotent",
       %{root: root, snapshots: snapshots} do
    assert {:ok, %{changes: [%{path: @latest}], written?: true}} = IndexSnapshots.fix(root)

    flipped = Jason.decode!(read(root, @latest))

    assert Map.new(flipped["custom_indexes"], &{&1["name"], &1["concurrently"]}) == %{
             "project_tasks_task_id_index" => true,
             "project_tasks_owner_index" => false,
             "project_tasks_task_id_unique_index" => false
           }

    assert flipped["identities"] == [
             %{"name" => "unique_pair", "keys" => [], "concurrently" => false}
           ]

    # only that flag changed, in AshPostgres' layout
    assert read(root, @latest) ==
             String.replace(
               snapshots[@latest],
               ~s("concurrently": false,\n      "error_fields": [\n        "task_id"),
               ~s("concurrently": true,\n      "error_fields": [\n        "task_id"),
               global: false
             )

    for {path, content} <- Map.delete(snapshots, @latest),
        do: assert(read(root, path) == content, "#{path} changed")

    assert {:ok, %{changes: [], written?: false}} = IndexSnapshots.fix(root)
  end

  test "check_manifest warns until the snapshots are fixed", %{root: root} do
    manifest = read(root, Manifest.path())

    assert {:ok, %{index_snapshots_stale: [@latest], clean?: true}} =
             Manifest.check(manifest, root)

    ctx = %{root: root, cmd: fn _args, _env -> {"", 0} end}

    assert {%{status: :pass, detail: detail}, _} =
             Checks.run(%{check: :generated_unchanged, args: %{}}, ctx, %{})

    assert detail =~ "generated files unchanged; warning: 1 resource snapshot(s) record"
    assert detail =~ "mix bubble.concurrent_index_snapshots --root <project>"
    assert detail =~ @latest

    # wtf.verify: the pending migrations say why and what to run
    pending = fn
      ["ash.codegen" | _], _ -> {"pending", 1}
      _, _ -> {"", 0}
    end

    {:ok, report} =
      Structural.project(root, app: "acme", now: ~U[2026-01-01 00:00:00Z], cmd: pending)

    [migrations] = for r <- report.results, r.id == "structural.migrations_in_sync", do: r
    [%{detail: hint}] = migrations.diff

    assert hint =~
             "exit status 1; 1 resource snapshot(s) record generated indexes as not concurrent"

    assert hint =~ "mix bubble.concurrent_index_snapshots"

    {:ok, _} = IndexSnapshots.fix(root)
    assert {:ok, %{index_snapshots_stale: []}} = Manifest.check(manifest, root)

    assert {%{status: :pass, detail: detail}, _} =
             Checks.run(%{check: :generated_unchanged, args: %{}}, ctx, %{})

    refute detail =~ "warning"
  end

  test "mix bubble.concurrent_index_snapshots", %{root: root, snapshots: snapshots} do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.Bubble.ConcurrentIndexSnapshots.run(["--root", root, "--dry-run"])
    assert_received {:mix_shell, :info, ["Would record as concurrent in " <> line]}
    assert line == "#{@latest}: project_tasks_task_id_index"
    assert_received {:mix_shell, :error, ["Skipped " <> _]}
    assert_received {:mix_shell, :info, ["1 index(es) in 1 snapshot(s); nothing written" <> _]}
    assert read(root, @latest) == snapshots[@latest]

    Mix.Tasks.Bubble.ConcurrentIndexSnapshots.run(["--root", root])
    assert_received {:mix_shell, :info, ["Recorded as concurrent in " <> _]}

    assert_received {:mix_shell, :info,
                     ["1 index(es) in 1 snapshot(s). Now run mix ash.codegen."]}

    Mix.Tasks.Bubble.ConcurrentIndexSnapshots.run(["--root", root])
    assert_received {:mix_shell, :info, ["No snapshot records a generated index" <> _]}

    assert_raise Mix.Error, ~r/usage/, fn ->
      Mix.Tasks.Bubble.ConcurrentIndexSnapshots.run([root])
    end

    assert_raise Mix.Error, ~r/not a generated project/, fn ->
      Mix.Tasks.Bubble.ConcurrentIndexSnapshots.run(["--root", Path.join(root, "priv")])
    end
  end
end
