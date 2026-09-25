# Renders every BubbleEx.Model fixture (test/support/model/*.json) and
# every target fixture (test/support/target/ash/*.json) through
# BubbleEx.Target.Ash and BubbleEx.Target.Ash.Source into a scratch Mix
# project: one namespace, domain and repo per fixture. With
# BUBBLE_EX_PRIVATE_EXPORT set, a private app export is rendered too (as
# `Private.App`); the scratch project is never committed.
#
#     MIX_ENV=test mix run scripts/ash_compile_check/render.exs <scratch dir>

[dir] = System.argv()

fixtures =
  for {pattern, prefix} <- [
        {"test/support/model/*.json", ""},
        {"test/support/target/ash/*.json", "target_"}
      ],
      path <- pattern |> Path.wildcard() |> Enum.sort() do
    name = prefix <> Path.basename(path, ".json")
    {"Fixtures." <> Macro.camelize(name), name, path |> File.read!() |> Jason.decode!()}
  end

private =
  case System.get_env("BUBBLE_EX_PRIVATE_EXPORT") do
    nil -> []
    "" -> []
    path -> [{"Private.App", "private_app", BubbleEx.Test.SplitExport.load(path)}]
  end

lib = Path.join(dir, "lib/generated")
File.rm_rf!(lib)
File.mkdir_p!(lib)
File.mkdir_p!(Path.join(dir, "config"))

namespaces =
  for {namespace, name, app} <- fixtures ++ private do
    {:ok, model} = BubbleEx.Model.build(app)
    {:ok, project} = BubbleEx.Target.Ash.map(model)
    {:ok, source} = BubbleEx.Target.Ash.Source.render(project, namespace: namespace)

    repo = """
    defmodule #{namespace}.Repo do
      use AshPostgres.Repo, otp_app: :ash_compile_check

      def installed_extensions, do: ["ash-functions"]
      def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
    end
    """

    File.write!(Path.join(lib, name <> ".ex"), source <> "\n" <> repo)
    IO.puts("rendered #{name} as #{namespace} (#{length(project.resources)} resources)")
    namespace
  end

repos = Enum.map_join(namespaces, ", ", &(&1 <> ".Repo"))
domains = Enum.join(namespaces, ", ")

repo_config =
  Enum.map_join(namespaces, "\n", fn namespace ->
    "config :ash_compile_check, #{namespace}.Repo, url: \"ecto://postgres:postgres@localhost/ash_compile_check\""
  end)

File.write!(Path.join(dir, "config/config.exs"), """
import Config

config :ash_compile_check, ecto_repos: [#{repos}], ash_domains: [#{domains}]
#{repo_config}
""")
