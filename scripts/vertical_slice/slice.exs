# Vertical slice commands (WTF-378), run from the bubble_ex root with
# MIX_ENV=test (scripts/vertical_slice/run.sh drives them):
#
#     mix run scripts/vertical_slice/slice.exs pages  EXPORT [DECISIONS]
#     mix run scripts/vertical_slice/slice.exs render EXPORT DECISIONS OUT [PAGE]
#     mix run scripts/vertical_slice/slice.exs seed   EXPORT DECISIONS OUT [N]
#
# SLICE_PRIVACY is `omit` (the default) or `enforced` (WTF-423): the Ash
# target's privacy mode for every command. SLICE_PERSONA (default 1) is
# the synthetic user `seed` records as the sign-in user.
#
# EXPORT is a Buildprint v5 workspace or a `.bubble` JSON file, DECISIONS a
# JSON list of decision envelopes (`-` for none), OUT the private slice
# directory (created 0700; the project goes to OUT/project), PAGE a page's
# Bubble ID or `median` (default: scripts/vertical_slice/pages.exs).
#
# `render` writes the generated project with the pinned lock of the Phoenix
# compile check, its migration plan (.wtf/plan.json), and OUT/slice.json:
# the chosen page, its statistics and route, the decision states and the
# app-wide coverage counts. `seed` writes N (default 3) synthetic worlds,
# a record and its twin with negated booleans each, so 2N records per data
# type, as a loader export and loads them into SLICE_DB's
# `slice_dev` database through the data loader (scripts/vertical_slice/
# seed.exs), then OUT/seed.json: the sign-in email, the record IDs by type
# and the loader's counts. Nothing leaves OUT; nothing calls Bubble.
Code.require_file("pipeline.exs", __DIR__)
Code.require_file("pages.exs", __DIR__)
Code.require_file("seed.exs", __DIR__)
Code.require_file("../check_db.exs", __DIR__)

alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
alias VerticalSlice.{Pages, Pipeline}

defmodule VerticalSlice.Cli do
  @moduledoc false

  def private_dir!(dir) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  # The slice's configuration, appended to the owned config/dev.exs and
  # config/test.exs (the generated project's `mix test`, which `mix
  # wtf.task complete` runs with `--test-db` naming the same slice_test
  # (WTF-448), must never reach a developer's PostgreSQL on
  # localhost:5432): the throwaway database (SLICE_DB, validated by
  # scripts/check_db.exs: explicit port, never 5432, a `slice_` database;
  # unset, a host that cannot resolve) and, in dev, the data-access opt-in
  # and every generated API client pointed at a closed local port so
  # nothing reaches a third party (a call without its secrets already fails
  # with `:missing_env`).
  #
  # The clients come from the API client Spec that was rendered, and fail
  # closed: every group must have its module in the rendered files and
  # every file under lib/slice/api_clients/ must be one of them, else the
  # slice stops (a client left unconfigured would call its real host).
  def slice_config(files, clients_spec, env) do
    database = if env == :test, do: "slice_test", else: "slice_dev"

    db =
      case System.get_env("SLICE_DB") do
        blank when blank in [nil, ""] ->
          ~s(hostname: "slice-db-unset.invalid", port: 1, database: "#{database}")

        _ ->
          {host, port, user, password} = db_credentials()

          "hostname: #{inspect(host)}, port: #{port}, username: #{inspect(user)}, " <>
            "password: #{inspect(password)}, database: #{inspect(CheckDb.database!(database))}"
      end

    # In test, the generated API client tests stub every request themselves
    # (Req.Test): their URLs stay the calls' own.
    clients =
      if env == :dev,
        do:
          for(
            mod <- client_modules(files, clients_spec),
            do: "config :slice, #{mod}, base_url: \"http://127.0.0.1:1\", retry: false\n"
          ),
        else: []

    data_access =
      if env == :dev, do: "config :slice, SliceWeb.BubbleWorkflows, data_access: true\n", else: ""

    config =
      """
      config :slice, Slice.Repo, #{db}
      #{data_access}#{Enum.join(clients)}\
      """

    "\n# --- vertical slice (scripts/vertical_slice) ---\n" <>
      IO.iodata_to_binary(Code.format_string!(config)) <> "\n"
  end

  # Host, port, user and password of SLICE_DB (validated), URI-decoded.
  def db_credentials do
    uri = URI.parse(CheckDb.url!("SLICE_DB", "SLICE_ALLOW_5432"))
    [user, password] = String.split(uri.userinfo || "postgres:postgres", ":", parts: 2)
    {uri.host, uri.port, URI.decode(user), URI.decode(password)}
  end

  defp client_modules(files, %{groups: groups}) do
    expected = groups |> Enum.map(&("Slice.ApiClients." <> &1.module)) |> Enum.sort()

    defined =
      for {path, content} <- files,
          String.starts_with?(path, "lib/slice/api_clients/"),
          into: %{} do
        mods =
          Regex.scan(~r/^defmodule (Slice\.ApiClients\.[\w.]+) do/m, content,
            capture: :all_but_first
          )

        {path, List.flatten(mods)}
      end

    unknown =
      for {path, mods} <- defined, mods == [] or Enum.any?(mods, &(&1 not in expected)), do: path

    missing = expected -- Enum.flat_map(defined, &elem(&1, 1))

    if unknown != [] or missing != [],
      do:
        raise(
          "API clients not all accounted for: files #{inspect(Enum.sort(unknown))}, " <>
            "groups without a module #{inspect(missing)}"
        )

    expected
  end

  defp client_modules(_files, nil), do: []

  def decisions("-"), do: nil
  def decisions(path), do: path

  def page_table(rows) do
    header =
      ~w(score id elements own reusables workflows steps wired native data data_wired data_wf schedules)

    lines =
      for r <- rows do
        [
          Map.get(r, :score, "-"),
          r.id,
          r.elements,
          r.own_elements,
          length(r.reusables),
          r.workflows,
          r.steps,
          r.wired,
          r.native,
          r.data_sources,
          r.data_wired,
          r.data_workflows,
          r.backend_schedules
        ]
        |> Enum.map_join("\t", &to_string/1)
      end

    Enum.join([Enum.join(header, "\t") | lines], "\n")
  end
end

alias VerticalSlice.Cli

privacy = Pipeline.privacy_mode(System.get_env("SLICE_PRIVACY"))

case System.argv() do
  ["pages", export | rest] ->
    app = Pipeline.load_app(export)
    decisions = rest |> List.first("-") |> Cli.decisions() |> Pipeline.load_decisions()
    built = Pipeline.build(app, decisions, module: "Slice", privacy: privacy)
    {chosen, ranked} = built |> Pages.stats() |> Pages.choose()
    IO.puts("privacy: #{privacy}")
    IO.puts(Pages.criteria())
    IO.puts(Cli.page_table(ranked))
    IO.puts("\nmedian page: #{chosen && chosen.id}")

  ["render", export, decisions_path, out | rest] ->
    out = Cli.private_dir!(Path.expand(out))
    project_dir = Path.join(out, "project")
    app = Pipeline.load_app(export)
    decisions = decisions_path |> Cli.decisions() |> Pipeline.load_decisions()
    built = Pipeline.build(app, decisions, module: "Slice", privacy: privacy)
    rows = Pages.stats(built)
    {median, ranked} = Pages.choose(rows)

    page =
      case List.first(rest, "median") do
        "median" -> median
        id -> Enum.find(rows, &(&1.id == id)) || raise("no page #{inspect(id)}")
      end

    {:ok, files} = Pipeline.render(built, name: "Slice", module: "Slice")
    # The generator is deterministic: a second render is byte-identical.
    {:ok, rerender} = Pipeline.render(built, name: "Slice", module: "Slice")
    if rerender != files, do: raise("the second rendering differs")
    structural = Pipeline.structural(built, files, rerender)

    # Replace the generated tree, keep deps/_build between runs.
    for entry <- ~w(lib test priv config assets .wtf),
        do: File.rm_rf!(Path.join(project_dir, entry))

    for {path, content} <- files do
      file = Path.join(project_dir, path)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, content)
    end

    for env <- [:dev, :test],
        do:
          File.write!(
            Path.join(project_dir, "config/#{env}.exs"),
            Cli.slice_config(files, built.clients, env),
            [:append]
          )

    File.cp!("scripts/phoenix_compile_check/mix.lock", Path.join(project_dir, "mix.lock"))
    :ok = BubbleEx.Tasks.Store.write_plan(project_dir, built.plan)

    # The determinism result the generator tasks' `deterministic` criterion
    # reads (app "slice", as `mix wtf.task complete --app slice`).
    {:ok, result} =
      BubbleEx.Verify.Result.new(%{
        id: "deterministic.generate",
        app: "slice",
        check: "deterministic",
        status: :pass,
        actor: "vertical-slice",
        ran_at: DateTime.utc_now() |> DateTime.truncate(:second),
        tasks: for(t <- built.plan.tasks, t.kind == :generate, do: t.id)
      })

    results = Path.join(project_dir, ".wtf/verification/results")
    File.mkdir_p!(results)
    File.write!(Path.join(results, "deterministic.json"), BubbleEx.Verify.Result.to_json(result))

    surfaces = files |> Map.fetch!(".wtf/surfaces.json") |> Jason.decode!()

    blocking = BubbleEx.Decision.Resolved.blocking(built.resolved)

    # The data type of the page's thing, when the page loads one from its
    # URL (`/<page>/<unique id>`).
    thing_type =
      Enum.find_value(Spec.data(built.spec, page.id), fn
        %{kind: :page_thing, residue: [], type: type} ->
          BubbleEx.Workflows.Lowering.data_type_key(type)

        _ ->
          nil
      end)

    slice = %{
      "page" => page,
      "privacy" => privacy,
      "path" => get_in(surfaces, ["pages", page.id, "path"]),
      "thing_type" => thing_type,
      "criteria" => Pages.criteria(),
      "candidates" => Enum.take(ranked, 5),
      "pages" => length(rows),
      "surfaces" => surfaces,
      "decisions" => %{
        "records" => length(decisions),
        "states" => Enum.frequencies_by(built.resolved.entries, &to_string(&1.state)),
        "blocking" => length(blocking),
        "applied" => length(built.applied)
      },
      "coverage" => %{
        "frontend_workflows" => BubbleEx.Target.Elixir.FrontendWorkflows.coverage(built.spec),
        "page_data" => Spec.data_coverage(built.spec)
      },
      "plan" => %{"tasks" => length(built.plan.tasks), "plan_sha256" => built.plan.plan_sha256},
      "structural_at_generation" => structural,
      "files" => map_size(files)
    }

    File.write!(Path.join(out, "slice.json"), Jason.encode!(slice, pretty: true))
    File.chmod!(Path.join(out, "slice.json"), 0o600)

    IO.puts(
      "rendered #{map_size(files)} files into #{project_dir}; page #{page.id} " <>
        "(#{page.elements} elements, #{page.workflows} workflows, #{page.data_sources} data sources)"
    )

  ["seed", export, decisions_path, out | rest] ->
    out = Cli.private_dir!(Path.expand(out))
    n = rest |> List.first("3") |> String.to_integer()
    persona = VerticalSlice.Synthetic.persona(System.get_env("SLICE_PERSONA"), n)
    app = Pipeline.load_app(export)
    decisions = decisions_path |> Cli.decisions() |> Pipeline.load_decisions()
    built = Pipeline.build(app, decisions, module: "Slice", privacy: privacy)

    {host, port, user, password} = Cli.db_credentials()

    {:ok, pool} =
      Postgrex.start_link(
        hostname: host,
        port: port,
        username: user,
        password: password,
        database: CheckDb.database!("slice_dev"),
        pool_size: 2
      )

    data_dir = Cli.private_dir!(Path.join(out, "data"))

    report =
      case VerticalSlice.Seed.run(built, pool, data_dir, n) do
        {:ok, report} -> report
        {:blocked, report} -> raise "the synthetic load is blocked: #{inspect(report.blocked)}"
        {:error, error} -> raise "the synthetic load failed: #{inspect(error)}"
      end

    counts = fn key ->
      report.types |> Map.values() |> Enum.map(&Map.get(&1, key, 0)) |> Enum.sum()
    end

    seed = %{
      "sign_in_email" => VerticalSlice.Synthetic.email(persona),
      "persona" => persona,
      "privacy" => privacy,
      "worlds" => n,
      "per_type" => VerticalSlice.Synthetic.records(n),
      "ids" => VerticalSlice.Synthetic.ids(built.model, n),
      "load" => %{
        "types" => map_size(report.types),
        "inserted" => counts.(:inserted),
        "updated" => counts.(:updated),
        "diagnostics" => Enum.frequencies_by(report.diagnostics, &to_string(&1.code))
      }
    }

    File.write!(Path.join(out, "seed.json"), Jason.encode!(seed, pretty: true))
    File.chmod!(Path.join(out, "seed.json"), 0o600)

    IO.puts(
      "loaded #{seed["load"]["inserted"]} synthetic records into #{map_size(report.types)} types"
    )

    IO.inspect(seed["load"]["diagnostics"], label: "loader diagnostics")

  # What the browser drive visits: `<path> <thing id or -> <email> <page ID>`.
  ["target", out] ->
    slice = out |> Path.join("slice.json") |> File.read!() |> Jason.decode!()
    seed = out |> Path.join("seed.json") |> File.read!() |> Jason.decode!()
    thing = slice["thing_type"] && seed["ids"][slice["thing_type"]] |> List.wrap() |> List.first()
    IO.puts("#{slice["path"]} #{thing || "-"} #{seed["sign_in_email"]} #{slice["page"]["id"]}")

  _ ->
    IO.puts(
      :stderr,
      "usage: slice.exs pages EXPORT [DECISIONS] | render EXPORT DECISIONS OUT [PAGE] | seed EXPORT DECISIONS OUT [N]"
    )

    System.halt(2)
end
