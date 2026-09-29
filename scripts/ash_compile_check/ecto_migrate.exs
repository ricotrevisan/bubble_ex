# Runs the BubbleEx.Db.Ecto migrations that scripts/ash_compile_check/render.exs
# wrote to lib/ecto_generated (WTF-391): one fresh database per fixture and
# naming, every `<namespace>.Repo.Migrations.Create*` module up, then the
# database is dropped. A repeated table, column or index name (PostgreSQL
# keeps tables and indexes in one namespace and cuts identifiers to 63
# bytes) fails the migration.
#
#     ASH_COMPILE_CHECK_DB=ecto://postgres:postgres@127.0.0.1:55432 mix run ecto_migrate.exs
#
# The URL is checked by check_db.exs (copied next to this project): an
# explicit port, never 5432 unless ASH_COMPILE_CHECK_ALLOW_5432=1; only
# ecto_check_ databases are created and dropped.

Code.require_file(Path.expand("check_db.exs", __DIR__))
base = CheckDb.url!()
{:ok, modules} = :application.get_key(:ash_compile_check, :modules)

groups =
  modules
  |> Enum.map(&inspect/1)
  |> Enum.filter(&String.contains?(&1, ".Repo.Migrations.Create"))
  |> Enum.sort()
  |> Enum.group_by(&hd(String.split(&1, ".Repo.Migrations.")))

for {namespace, migrations} <- Enum.sort(groups) do
  database =
    CheckDb.database!(
      "ecto_check_" <> (namespace |> String.downcase() |> String.replace(".", "_"))
    )
  config =
    Ecto.Repo.Supervisor.parse_url(base <> "/" <> database) ++ [pool_size: 2, log: false]

  adapter = Ecto.Adapters.Postgres

  adapter.storage_down(config)
  :ok = adapter.storage_up(config)

  try do
    {:ok, pid} = EctoCheck.Repo.start_link(config)

    versions =
      migrations
      |> Enum.with_index(1)
      |> Enum.map(fn {module, version} -> {version, Module.concat([module])} end)

    ran = Ecto.Migrator.run(EctoCheck.Repo, versions, :up, all: true, log: false)

    if length(ran) != length(versions) do
      raise "#{namespace}: ran #{length(ran)} of #{length(versions)} migrations"
    end

    Supervisor.stop(pid)
    IO.puts("#{namespace}: #{length(versions)} Ecto migrations ran")
  after
    adapter.storage_down(config)
  end
end
