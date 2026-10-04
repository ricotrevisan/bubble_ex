defmodule BubbleEx.Target.Phoenix.IndexSnapshotsTest do
  # WTF-418: upgrading a project whose snapshots record the index hints as
  # not concurrent, without dropping and rebuilding them.
  use ExUnit.Case, async: false

  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Target.Phoenix.{Checks, IndexSnapshots, Manifest, Structural}
  alias BubbleEx.Test.DecidedFixture
  alias Mix.Tasks.Bubble.ConcurrentIndexSnapshots, as: Task

  @moduletag :tmp_dir

  @dir "priv/resource_snapshots/repo"
  # AshPostgres' layout, with a trailing newline (an editor's)
  @tasks "#{@dir}/project_tasks/20260102000000.json"
  @older "#{@dir}/project_tasks/20260101000000.json"
  @dev "#{@dir}/project_tasks/20260103000000_dev.json"
  # compact JSON: differs from the layout by whitespace only
  @workspaces "#{@dir}/user_workspaces/20260101000000.json"
  # keys out of order: not rewritten, skipped, still stale
  @favorites "#{@dir}/favorite_project/20260101000000.json"
  # not the generated resources' snapshots
  @foreign "#{@dir}/oban_jobs/20260101000000.json"
  @tenant "#{@dir}/tenants/project_tasks/20260101000000.json"
  @second_repo "priv/resource_snapshots/audit_repo/project_tasks/20260105000000.json"

  setup %{tmp_dir: root} do
    {:ok, project} = DecidedFixture.project(:cut3)
    {:ok, files} = Phoenix.render(project, name: "Acme Import")

    for {path, content} <- files, do: put(root, path, content)

    # what the generated resources declare (the fixture's join tables)
    tasks = Enum.find_value(files, fn {_, c} -> c =~ ~s(table "project_tasks") && c end)

    assert tasks =~
             ~s(index [:task_id], name: "project_tasks_task_id_index", concurrently: true)

    hint = index("project_tasks_task_id_index", ["task_id"])

    snapshots = %{
      # the hint (to flip), an index of the owner's, a unique index, and
      # an identity
      @tasks =>
        snapshot("project_tasks",
          custom_indexes: [
            hint,
            index("project_tasks_owner_index", ["position"]),
            index("project_tasks_task_id_unique_index", ["task_id"], unique: true)
          ],
          identities: [%{"name" => "unique_pair", "keys" => [], "concurrently" => false}]
        ) <> "\n",
      @older => snapshot("project_tasks", custom_indexes: [hint]),
      @dev => snapshot("project_tasks", custom_indexes: [hint]),
      @workspaces =>
        "user_workspaces"
        |> snapshot(
          custom_indexes: [index("user_workspaces_workspace_id_index", ["workspace_id"])]
        )
        |> Jason.decode!()
        |> Jason.encode!(),
      @favorites =>
        ~s({"table": "favorite_project", "repo": "Elixir.AcmeImport.Repo", "custom_indexes": [) <>
          Jason.encode!(index("favorite_project_user_id_index", ["user_id"])) <> "]}\n",
      @foreign => snapshot("oban_jobs", custom_indexes: [hint]),
      @tenant => snapshot("project_tasks", custom_indexes: [hint]),
      @second_repo =>
        snapshot("project_tasks", custom_indexes: [hint], repo: "Elixir.AcmeImport.AuditRepo")
    }

    for {path, content} <- snapshots, do: put(root, path, content)
    %{root: root, snapshots: snapshots}
  end

  defp put(root, path, content) do
    File.mkdir_p!(Path.dirname(Path.join(root, path)))
    File.write!(Path.join(root, path), content)
  end

  defp index(name, fields, opts \\ []) do
    %{
      "all_tenants?" => false,
      "concurrently" => false,
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
  end

  defp snapshot(table, opts) do
    %{
      "attributes" => [],
      "base_filter" => nil,
      "check_constraints" => [],
      "custom_indexes" => Keyword.get(opts, :custom_indexes, []),
      "custom_statements" => [],
      "has_create_action" => true,
      "hash" => "0",
      "identities" => Keyword.get(opts, :identities, []),
      "multitenancy" => %{"attribute" => nil, "global" => nil, "strategy" => nil},
      "repo" => Keyword.get(opts, :repo, "Elixir.AcmeImport.Repo"),
      "schema" => nil,
      "table" => table
    }
    |> Jason.encode!(pretty: true)
  end

  defp read(root, path), do: File.read!(Path.join(root, path))

  defp concurrently(root, path) do
    root
    |> read(path)
    |> Jason.decode!()
    |> Map.fetch!("custom_indexes")
    |> Map.new(&{&1["name"], &1["concurrently"]})
  end

  defp tmp_files(root) do
    root
    |> Path.join("priv/resource_snapshots/**/.*.tmp")
    |> Path.wildcard(match_dot: true)
  end

  describe "fix/2" do
    test "a dry run reports, writes nothing", %{root: root, snapshots: snapshots} do
      assert {:ok, report} = IndexSnapshots.fix(root, dry_run: true)

      assert report.changes == [
               %{path: @tasks, table: "project_tasks", indexes: ["project_tasks_task_id_index"]},
               %{
                 path: @workspaces,
                 table: "user_workspaces",
                 indexes: ["user_workspaces_workspace_id_index"]
               }
             ]

      assert [%{path: @favorites, table: "favorite_project", reason: reason}] = report.skipped
      assert reason =~ "by more than whitespace"
      assert reason =~ "favorite_project_user_id_index"
      refute report.written?
      for {path, content} <- snapshots, do: assert(read(root, path) == content)
    end

    test "flips only the generated indexes of the latest snapshots; idempotent",
         %{root: root, snapshots: snapshots} do
      assert {:ok, %{written?: true, changes: [_, _]}} = IndexSnapshots.fix(root)

      assert concurrently(root, @tasks) == %{
               "project_tasks_task_id_index" => true,
               "project_tasks_owner_index" => false,
               "project_tasks_task_id_unique_index" => false
             }

      assert Jason.decode!(read(root, @tasks))["identities"] == [
               %{"name" => "unique_pair", "keys" => [], "concurrently" => false}
             ]

      # only that flag changed, in AshPostgres' layout; the trailing
      # newline is kept
      assert read(root, @tasks) ==
               String.replace(
                 snapshots[@tasks],
                 ~s("concurrently": false,\n      "error_fields": [\n        "task_id"),
                 ~s("concurrently": true,\n      "error_fields": [\n        "task_id"),
                 global: false
               )

      # whitespace-only differences: rewritten in AshPostgres' layout
      assert concurrently(root, @workspaces) == %{"user_workspaces_workspace_id_index" => true}

      # older, _dev, tenant, other tables' and other repos' snapshots, and
      # the skipped one, are untouched
      for path <- [@older, @dev, @tenant, @foreign, @second_repo, @favorites],
          do: assert(read(root, path) == snapshots[path], "#{path} changed")

      assert tmp_files(root) == []
      assert {:ok, %{changes: [], written?: false}} = IndexSnapshots.fix(root)
    end

    test "a failed write leaves that snapshot whole and stops", %{
      root: root,
      snapshots: snapshots
    } do
      rename = fn tmp, target ->
        if String.ends_with?(target, @workspaces),
          do: {:error, :eacces},
          else: File.rename(tmp, target)
      end

      assert {:error, %BubbleEx.Error{message: message, context: context}} =
               IndexSnapshots.fix(root, rename: rename)

      assert message =~ "could not write #{@workspaces}: :eacces (left unchanged)"
      assert context.written == [@tasks]
      assert concurrently(root, @tasks)["project_tasks_task_id_index"] == true
      assert read(root, @workspaces) == snapshots[@workspaces]
      assert tmp_files(root) == []
    end

    test "invalid JSON is skipped and stays stale", %{root: root} do
      put(root, @workspaces, "{\"custom_indexes\": [")
      {:ok, %{skipped: skipped}} = IndexSnapshots.fix(root, dry_run: true)
      assert %{reason: "not valid JSON" <> _} = Enum.find(skipped, &(&1.path == @workspaces))

      {:ok, report} = Manifest.check(read(root, Manifest.path()), root)
      assert @workspaces in report.index_snapshots_stale
    end

    test "an index of another shape under a generated name is not touched", %{root: root} do
      put(
        root,
        @tasks,
        snapshot("project_tasks",
          custom_indexes: [index("project_tasks_task_id_index", ["position"])]
        )
      )

      {:ok, %{changes: changes}} = IndexSnapshots.fix(root, dry_run: true)
      refute Enum.any?(changes, &(&1.path == @tasks))
    end

    test "warns about _dev snapshots and a symbolically linked snapshot directory",
         %{root: root} do
      {:ok, %{warnings: warnings}} = IndexSnapshots.fix(root, dry_run: true)
      assert [dev] = warnings
      assert dev =~ "#{@dev} is a `mix ash.codegen --dev` snapshot: not changed"

      real = Path.join(root, "elsewhere")
      File.rename!(Path.join(root, "priv/resource_snapshots"), real)
      File.ln_s!(real, Path.join(root, "priv/resource_snapshots"))

      {:ok, report} = IndexSnapshots.fix(root, dry_run: true)
      assert report.changes == [] and report.skipped == []

      assert report.warnings == [
               "priv/resource_snapshots is a symbolic link: not followed; run against the " <>
                 "directory it points to"
             ]
    end
  end

  describe "the warning" do
    test "check_manifest and the checks warn until every snapshot is fixed", %{root: root} do
      manifest = read(root, Manifest.path())

      # the skipped snapshot counts: codegen would rebuild its index
      assert {:ok, %{index_snapshots_stale: [@favorites, @tasks, @workspaces], clean?: true}} =
               Manifest.check(manifest, root)

      ctx = %{root: root, cmd: fn _args, _env -> {"", 0} end}

      assert {%{status: :pass, detail: detail}, _} =
               Checks.run(%{check: :generated_unchanged, args: %{}}, ctx, %{})

      assert detail =~ "generated files unchanged; warning: 3 resource snapshot(s) record"
      assert detail =~ "mix bubble.concurrent_index_snapshots --root <project>"

      pending = fn
        ["ash.codegen" | _], _ -> {"pending", 1}
        _, _ -> {"", 0}
      end

      {:ok, report} =
        Structural.project(root, app: "acme", now: ~U[2026-01-01 00:00:00Z], cmd: pending)

      [migrations] = for r <- report.results, r.id == "structural.migrations_in_sync", do: r
      [%{detail: hint}] = migrations.diff

      assert hint =~
               "exit status 1; 3 resource snapshot(s) record generated indexes as not concurrent"

      assert hint =~ "mix bubble.concurrent_index_snapshots"

      # fixed by the task, but for the skipped one
      {:ok, _} = IndexSnapshots.fix(root)
      assert {:ok, %{index_snapshots_stale: [@favorites]}} = Manifest.check(manifest, root)

      # ... which the owner fixes by hand
      favorites = read(root, @favorites) |> Jason.decode!()
      [hint_index] = favorites["custom_indexes"]

      put(
        root,
        @favorites,
        Jason.encode!(%{favorites | "custom_indexes" => [%{hint_index | "concurrently" => true}]})
      )

      assert {:ok, %{index_snapshots_stale: []}} = Manifest.check(manifest, root)

      assert {%{status: :pass, detail: detail}, _} =
               Checks.run(%{check: :generated_unchanged, args: %{}}, ctx, %{})

      refute detail =~ "warning"
    end
  end

  describe "mix bubble.concurrent_index_snapshots" do
    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "a skipped snapshot fails the task; then it upgrades", %{
      root: root,
      snapshots: snapshots
    } do
      assert_raise Mix.Error, ~r/1 snapshot\(s\) skipped: fix them/, fn ->
        Task.run(["--root", root, "--dry-run"])
      end

      assert_received {:mix_shell, :info, ["Would record as concurrent in " <> line]}
      assert line == "#{@tasks}: project_tasks_task_id_index"
      assert_received {:mix_shell, :error, ["Warning: " <> _dev]}
      assert_received {:mix_shell, :error, ["Skipped " <> skipped]}
      assert skipped =~ @favorites
      for {path, content} <- snapshots, do: assert(read(root, path) == content)

      # without the skipped snapshot: no "Now run" while one is skipped
      File.rm!(Path.join(root, @favorites))
      Task.run(["--root", root])

      assert_received {:mix_shell, :info,
                       ["2 index(es) in 2 snapshot(s). Now run mix ash.codegen."]}

      Task.run(["--root", root])
      assert_received {:mix_shell, :info, ["No snapshot records a generated index" <> _]}
    end

    test "resources generated before WTF-418: regenerate first", %{root: root} do
      for path <- Path.wildcard(Path.join(root, "lib/**/*.ex")) do
        File.write!(path, String.replace(File.read!(path), ", concurrently: true", ""))
      end

      assert_raise Mix.Error, ~r/without concurrently: true: regenerate the project/, fn ->
        Task.run(["--root", root])
      end
    end

    test "usage and a directory that is not a generated project", %{root: root} do
      assert_raise Mix.Error, ~r/usage/, fn -> Task.run([root]) end

      assert_raise Mix.Error, ~r/not a generated project/, fn ->
        Task.run(["--root", Path.join(root, "priv")])
      end
    end
  end
end
