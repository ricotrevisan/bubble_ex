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
# (test/support/target/ash/*.json), the expression fixture, every frozen
# fidelity case's payload (`fidelity_<case>`, with its pages) and the owner
# decision fixtures (BubbleEx.Test.DecidedFixture), two frontends with
# hostile Bubble IDs (`hostile_ids`, `hostile_overlays`), plus `private_app` when
# BUBBLE_EX_PRIVATE_EXPORT is set (never committed). An app with a frontend
# renders its pages (WTF-370), with the bindings the expression compiler
# lowers.
#
# The committed scripts/phoenix_compile_check/mix.lock replaces the stub
# lock, and with PHOENIX_COMPILE_CHECK_DB (a PostgreSQL URL without a
# database) config/test.exs is pointed at that server. Both render twice
# to check the output is deterministic, and check that the manifest finds
# the written files clean and a hand edit.

alias BubbleEx.Target.Phoenix

# The app's frontend (pages, reusable elements, styles) and its compiled
# bindings, when the app JSON has one (WTF-370).
frontend = fn app, model, project ->
  case BubbleEx.Frontend.normalize(app) do
    {:ok, frontend} ->
      {:ok, expressions} =
        BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
          runtime: "PhxCheck.Bubble.Runtime",
          namespace: "PhxCheck"
        )

      [frontend: frontend, expressions: expressions]

    {:error, _} ->
      []
  end
end

# A frozen fidelity case's images and icons, from its committed files (the
# URL -> file map of its case.json; never downloaded): served by the app
# from priv/static/images/bubble.
with_case_assets = fn {:ok, project, opts}, case_dir ->
  files =
    for asset <- Jason.decode!(File.read!(Path.join(case_dir, "case.json")))["public_assets"] || [],
        into: %{},
        do: {asset["url"], Path.join(case_dir, asset["path"])}

  nodes =
    case opts[:frontend] do
      nil -> []
      frontend -> frontend.pages ++ frontend.reusables
    end

  {assets, _findings} = BubbleEx.Frontend.Export.Assets.collect(nodes, asset_files: files)
  {:ok, project, Keyword.put(opts, :assets, assets)}
end

# {project, render options} of an app JSON.
app_fixture = fn app ->
  {:ok, model} = BubbleEx.Model.build(app)
  {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
  {:ok, project, frontend.(app, model, project)}
end

fixtures =
  for {pattern, prefix} <- [
        {"test/support/model/*.json", ""},
        {"test/support/target/ash/*.json", "target_"},
        {"test/support/expression/*.json", "expr_"},
        {"test/support/fidelity/cases/*/source/payload.json", "fidelity_"}
      ],
      path <- pattern |> Path.wildcard() |> Enum.sort(),
      into: %{} do
    name =
      if prefix == "fidelity_",
        do: prefix <> (path |> Path.dirname() |> Path.dirname() |> Path.basename()),
        else: prefix <> Path.basename(path, ".json")

    fixture = fn -> path |> File.read!() |> Jason.decode!() |> app_fixture.() end

    if prefix == "fidelity_",
      do: {name, fn -> with_case_assets.(fixture.(), Path.dirname(Path.dirname(path))) end},
      else: {name, fixture}
  end
  |> Map.merge(%{
    # Hostile Bubble IDs (quotes, `#{`, a newline, `*/`, `--%>`, an EEx tag,
    # braces) on a page, a reusable, an instance inside a reusable, a Text,
    # a modal Popup and a Group Focus: the generated code must compile and
    # its test find them (WTF-370).
    "hostile_ids" => fn ->
      "test/support/fidelity/cases/bpgwgmpz/source/payload.json"
      |> File.read!()
      |> Jason.decode!()
      |> BubbleEx.Test.HostileIds.rename(~w(bpgwgmpz bpmvuzce bpcjyrzt bpcjyrzr))
      |> app_fixture.()
    end,
    "hostile_overlays" => fn ->
      "test/support/fidelity/cases/bptvorpv/source/payload.json"
      |> File.read!()
      |> Jason.decode!()
      |> BubbleEx.Test.HostileIds.rename(~w(bptvorpv bptvorpw bptvorqc))
      |> app_fixture.()
    end,
    "decided_combined" => fn ->
      {:ok, project} = BubbleEx.Test.DecidedFixture.project(:combined, privacy: :omit)
      {:ok, project, []}
    end,
    "decided_locked" => fn ->
      {:ok, project} = BubbleEx.Test.DecidedFixture.locked_project(privacy: :omit)
      {:ok, project, []}
    end
  })
  |> Map.merge(
    case System.get_env("BUBBLE_EX_PRIVATE_EXPORT") do
      blank when blank in [nil, ""] ->
        %{}

      path ->
        %{
          "private_app" => fn -> path |> BubbleEx.Test.SplitExport.load() |> app_fixture.() end
        }
    end
  )

case System.argv() do
  ["list"] ->
    fixtures |> Map.keys() |> Enum.sort() |> Enum.each(&IO.puts/1)

  [dir, name] ->
    {:ok, project, frontend_opts} = Map.fetch!(fixtures, name).()
    opts = [name: "Phx Check #{name}", module: "PhxCheck"] ++ frontend_opts
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
