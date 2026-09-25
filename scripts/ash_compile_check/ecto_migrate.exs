# Runs the BubbleEx.Db.Ecto migrations that scripts/ash_compile_check/render.exs
# wrote to lib/ecto_generated (WTF-391): one fresh database per fixture and
# naming, every `<namespace>.Repo.Migrations.Create*` module up, then the
# database is dropped. A repeated table, column or index name (PostgreSQL
# keeps tables and indexes in one namespace and cuts identifiers to 63
# bytes) fails the migration.
#
#     ASH_COMPILE_CHECK_DB=ecto://postgres:postgres@localhost:5432 mix run ecto_migrate.exs

base = System.fetch_env!("ASH_COMPILE_CHECK_DB")
{:ok, modules} = :application.get_key(:ash_compile_check, :modules)

groups =
  modules
  |> Enum.map(&inspect/1)
  |> Enum.filter(&String.contains?(&1, ".Repo.Migrations.Create"))
  |> Enum.sort()
  |> Enum.group_by(&hd(String.split(&1, ".Repo.Migrations.")))

for {namespace, migrations} <- Enum.sort(groups) do
  database = "ecto_check_" <> (namespace |> String.downcase() |> String.replace(".", "_"))
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
