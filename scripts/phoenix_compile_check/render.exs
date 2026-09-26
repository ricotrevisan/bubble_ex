# Renders one fixture through BubbleEx.Target.Phoenix (privacy: :omit, what
# an owner downloads) into a scratch Phoenix project directory, replacing
# the previous fixture's files. Every fixture renders with the same name
# (module PhxCheck, app :phx_check), so the dependencies, configured the
# same way, compile once for all of them (scripts/phoenix_compile_check.sh).
#
#     MIX_ENV=test mix run scripts/phoenix_compile_check/render.exs list
#     MIX_ENV=test mix run scripts/phoenix_compile_check/render.exs <dir> <fixture>
#
# `list` prints the fixture names: every BubbleEx.Model fixture
# (test/support/model/*.json), every target fixture
# (test/support/target/ash/*.json), the expression fixture and the owner
# decision fixtures (BubbleEx.Test.DecidedFixture), plus `private_app` when
# BUBBLE_EX_PRIVATE_EXPORT is set (never committed).
#
# The committed scripts/phoenix_compile_check/mix.lock replaces the stub
# lock, and with PHOENIX_COMPILE_CHECK_DB (a PostgreSQL URL without a
# database) config/test.exs is pointed at that server. Both render twice
# to check the output is deterministic, and check that the manifest finds
# the written files clean and a hand edit.

alias BubbleEx.Target.Phoenix

fixtures =
  for {pattern, prefix} <- [
        {"test/support/model/*.json", ""},
        {"test/support/target/ash/*.json", "target_"},
        {"test/support/expression/*.json", "expr_"}
      ],
      path <- pattern |> Path.wildcard() |> Enum.sort(),
      into: %{} do
    {prefix <> Path.basename(path, ".json"),
     fn ->
       {:ok, model} = path |> File.read!() |> Jason.decode!() |> BubbleEx.Model.build()
       BubbleEx.Target.Ash.map(model, [], privacy: :omit)
     end}
  end
  |> Map.merge(%{
    "decided_combined" => fn -> BubbleEx.Test.DecidedFixture.project(:combined, privacy: :omit) end,
    "decided_locked" => fn -> BubbleEx.Test.DecidedFixture.locked_project(privacy: :omit) end
  })
  |> Map.merge(
    case System.get_env("BUBBLE_EX_PRIVATE_EXPORT") do
      blank when blank in [nil, ""] ->
        %{}

      path ->
        %{
          "private_app" => fn ->
            {:ok, model} = path |> BubbleEx.Test.SplitExport.load() |> BubbleEx.Model.build()
            BubbleEx.Target.Ash.map(model, [], privacy: :omit)
          end
        }
    end
  )

case System.argv() do
  ["list"] ->
    fixtures |> Map.keys() |> Enum.sort() |> Enum.each(&IO.puts/1)

  [dir, name] ->
    {:ok, project} = Map.fetch!(fixtures, name).()
    opts = [name: "Phx Check #{name}", module: "PhxCheck"]
    {:ok, files} = Phoenix.render(project, opts)
    {:ok, ^files} = Phoenix.render(project, opts)

    # The previous fixture's files (the scratch keeps deps and _build).
    for entry <- ~w(lib test priv config assets .wtf),
        do: File.rm_rf!(Path.join(dir, entry))

    for {path, content} <- files do
      file = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, content)
    end

    File.cp!("scripts/phoenix_compile_check/mix.lock", Path.join(dir, "mix.lock"))

    {:ok, %{clean?: true, modified: [], missing: []}} =
      Phoenix.check_manifest(files[".wtf/generated.json"], dir)

    domain = "lib/phx_check/domain.ex"

    {:ok, %{clean?: false, modified: [^domain]}} =
      Phoenix.check_manifest(
        files[".wtf/generated.json"],
        Map.update!(files, domain, &(&1 <> "# edited\n"))
      )

    case System.get_env("PHOENIX_COMPILE_CHECK_DB") do
      blank when blank in [nil, ""] ->
        :ok

      url ->
        uri = URI.parse(url)
        [user, password] = String.split(uri.userinfo || "postgres:postgres", ":", parts: 2)

        File.write!(Path.join(dir, "config/test.exs"), """

        config :phx_check, PhxCheck.Repo,
          hostname: #{inspect(uri.host)},
          port: #{uri.port || 5432},
          username: #{inspect(user)},
          password: #{inspect(password)}
        """, [:append])
    end

    generated = files[".wtf/generated.json"] |> Jason.decode!() |> Map.fetch!("generated")

    IO.puts(
      "rendered #{name}: #{map_size(files)} files " <>
        "(#{map_size(generated)} generated, #{length(Phoenix.owned_paths(files))} owned)"
    )
end
