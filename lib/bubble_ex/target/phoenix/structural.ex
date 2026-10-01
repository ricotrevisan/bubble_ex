defmodule BubbleEx.Target.Phoenix.Structural do
  @moduledoc """
  The structural verification pack for the Phoenix target (WTF-386, V6 of
  the WTF-358 verification proposal, §2): offline, deterministic checks
  that the generated project matches the Bubble model. Every outcome is a
  `BubbleEx.Verify.Result` of a structural (L0) check
  (`BubbleEx.Verify.Check`), so the cutover gates (WTF-390) read them like
  any other result. Structural results accept no difference: they pass or
  fail, or are `skipped` with a reason, which never counts as passing.

  **Structural, not behavioural.** These checks prove that every Bubble
  definition is generated or accounted for, that generated files are
  intact and deterministic, and where authorization is bypassed. They do
  not prove the app behaves like the Bubble app: that is the privacy
  matrix and replay (L2/L3), data verification (L4) and the cutover gates
  (L5). `statement/0` says so in every summary.

  It composes what exists instead of re-deriving it: the symbol accounting
  (`Structural.Coverage`) reads the `BubbleEx.Target.Ash.Project`, the
  rendered source, the workflow and API client Specs, the rendered
  surfaces and the `BubbleEx.Plan`; the manifest check is
  `BubbleEx.Target.Phoenix.Manifest.check/3`; compile and lint are
  `BubbleEx.Target.Phoenix.Checks`; bypasses are read from the AST
  (`Structural.Bypasses`). Element- and action-level residue stays the
  plan's `coverage`; privacy behaviour stays the policy matrix
  (`BubbleEx.Target.Ash.MatrixTests`).

  ## Where each check runs

  | check | `run/2` (at generation, with the Bubble model) | `project/2` (the owner's repository, `mix wtf.verify structural`) |
  |-------|-----------------------------------------------|-------------------------------------------------------------------|
  | `symbol_coverage` | one result per category (`symbol_coverage.<category>`, see `Structural.Coverage`): a symbol its generator did not emit is uncovered unless an open task carries its residue | no: needs the model |
  | `policy_coverage` | every privacy rule of a mapped type compiled, denied (a diagnostic) or the `everyone` rule; `skipped` for a `privacy: :omit` project: blocked on WTF-356 | no: needs the model |
  | `bypass_inventory` | the lowering bypasses exactly the backend workflows that ignore privacy rules in Bubble; every bypass site in the rendered `lib/` is a listed workflow body or a scaffold site the generator is expected to write, and `.wtf/bypasses.json` lists exactly those; `skipped` when workflows are expected to bypass and no Spec was given | every bypass site in owned `lib/` code is marked (`Structural.Bypasses`) |
  | `generated_unchanged` | the manifest matches the rendered files | the manifest matches the files on disk |
  | `deterministic` | a second rendering (`rerender`) is byte-identical | no: needs the generator |
  | `compiles`, `lint` | no | `Target.Phoenix.Checks` (a fresh project is lint-clean, WTF-416) |
  | `migrations_in_sync` | no | `mix ash.codegen --check` |
  | `boundary`, `secrets_absent` | not bound yet | not bound yet |
  | `traceability.source`, `traceability.rendered` | per task: `mix wtf.task` (`Target.Phoenix.Checks`) | the same |

  What a run does not check is listed in its summary (`not_run`), with
  why. In the owner's repository every verdict is advisory: the files are
  the implementer's to edit (`BubbleEx.Tasks`, WTF-411).
  """

  alias BubbleEx.{CanonicalJson, Error, Index, Model, Plan}
  alias BubbleEx.Decision.Resolved
  alias BubbleEx.Target.Ash.Project
  alias BubbleEx.Target.Ash.Workflows.Spec, as: WorkflowSpec
  alias BubbleEx.Target.Phoenix.{Checks, Manifest}
  alias BubbleEx.Target.Phoenix.Structural.{Bypasses, Coverage}
  alias BubbleEx.Verify.Result

  @statement "Structural verification (L0) only, not behavioural. It shows that every " <>
               "Bubble data type, field, option set, page, reusable element, workflow and " <>
               "API Connector call is generated or accounted for (residue in an open task, " <>
               "an owner decision, a diagnostic or an exclusion), that generated files are " <>
               "intact and deterministic, and where authorization is bypassed in lib/ " <>
               "(authorize? not literally true, Runtime.start bypasses, bypass policies, " <>
               "authorize modes, always-authorizing policies, missing or empty authorizers, " <>
               "Repo, Ecto.Adapters.SQL, Ash.Seed, Ash.DataLayer and Code.eval calls). It " <>
               "does not see every bypass (not_run lists the forms it misses), and it " <>
               "does not show that the " <>
               "app behaves like the Bubble app: privacy, workflows, pages and data are " <>
               "verified by replay (L2/L3), data verification (L4) and the cutover gates " <>
               "(L5). Residue is work still to do."

  @category_tasks %{
    data_types: ["generate:schema"],
    fields: ["generate:schema"],
    option_sets: ["generate:option_sets"],
    option_values: ["generate:option_sets"],
    pages: ["generate:routes", "generate:surfaces"],
    reusables: ["generate:surfaces"],
    workflows: ["generate:workflow_entry_points"],
    api_calls: ["generate:api_clients"]
  }

  # Structural checks neither run/2 nor project/2 binds yet.
  @unbound [
    {"boundary", "no generated boundary configuration yet"},
    {"secrets_absent", "not bound yet"},
    {"traceability.source", "per task: mix wtf.task complete / audit"},
    {"traceability.rendered", "per task: mix wtf.task complete / audit"}
  ]

  @unseen {"bypass_inventory (not seen)",
           "options merged from a variable or built by another function (Keyword.merge/2, " <>
             "Enum.into/2 of a runtime value), a local call after import, apply/2,3 whose " <>
             "module and function both cannot be read, policies that authorize everything " <>
             "under other conditions or checks, authorizers added by a Spark fragment, a " <>
             "__using__ wrapper's callers, Repo calls in ~H and .heex templates, queries " <>
             "through other libraries, code outside lib/, aliases a dependency's macro injects, a wrapper of a " <>
             "Repo wrapper"}

  @typedoc """
  A run: its results, its counts (aggregates only), the checks it did not
  run and why, the failures known to have an open issue, and (`run/2`)
  the privacy rules where the generated policies are stricter than Bubble
  by design (`intended_differences`, `BubbleEx.Verify.Difference`; counted
  in `counts["privacy_rules"]["stricter_than_bubble"]`): known and
  intended, never a failure. `project/2`
  adds `outputs`: the tail of a failing command's output by result ID, to
  show, never to store.
  """
  @type report :: %{
          required(:results) => [Result.t()],
          required(:counts) => map(),
          required(:not_run) => [%{check: String.t(), reason: String.t()}],
          optional(:known) => [%{check: String.t(), issue: String.t(), reason: String.t()}],
          optional(:intended_differences) => [
            %{type: String.t(), rule: String.t(), flags: [atom()], decision: String.t()}
          ],
          optional(:outputs) => %{String.t() => String.t()}
        }

  @doc "What a structural verdict does and does not show."
  @spec statement() :: String.t()
  def statement, do: @statement

  @doc """
  Runs the checks that need the Bubble model, at generation time.

  `inputs`:

    * `:model`, `:index`, `:plan` - the `BubbleEx.Model`, its
      `BubbleEx.Index` and the `BubbleEx.Plan` built from them (with the
      workflow Spec's residue, `BubbleEx.Target.Ash.Workflows.Spec.residue/1`,
      and `BubbleEx.Target.Elixir.FrontendWorkflows.Spec.residue/1`, so the
      plan knows what the lowerings and their bindings left)
    * `:project` - the `BubbleEx.Target.Ash.Project` that was rendered
      (`privacy: :omit`), or an `:unverified` one to check policy coverage
    * `:files` - the rendered file map (`BubbleEx.Target.Phoenix.render/2`);
      without it nothing rendered is checked, so pages and reusables are
      uncovered and the file checks are not run
    * `:rerender` - a second rendering from the same inputs, for
      `deterministic`
    * `:workflows` - the `BubbleEx.Target.Ash.Workflows.Spec` rendered,
      `:frontend_workflows` - the `BubbleEx.Target.Elixir.FrontendWorkflows.Spec`
      rendered (page and reusable workflows), and `:api_clients` - the
      `BubbleEx.Target.ApiClients.Spec` rendered

  Options: `:app` (the Bubble app ID, required), `:now` (required),
  `:actor` (default `"bubble_ex"`), `:subject_build` (`%{git_sha,
  generated_manifest_sha256}`, optional).
  """
  @spec run(map(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def run(inputs, opts) when is_map(inputs) and is_list(opts) do
    with :ok <- check_inputs(inputs),
         {:ok, base} <- base(inputs.plan, opts, "bubble_ex") do
      accounted = Coverage.account(inputs)
      {policy, policy_counts} = policy_coverage(inputs)
      {bypass, bypass_counts, bypass_not_run} = bypass_inventory(inputs)
      files = Map.get(inputs, :files)

      specs =
        Enum.map(Coverage.categories(), &symbol_result(&1, accounted[&1])) ++
          [policy, bypass] ++
          file_results(files, Map.get(inputs, :rerender))

      not_run =
        [
          {"compiles", "run in the owner's repository: mix wtf.verify structural"},
          {"lint", "run in the owner's repository: mix wtf.verify structural"},
          {"migrations_in_sync", "run in the owner's repository: mix wtf.verify structural"}
        ] ++
          if(files, do: [], else: [{"generated_unchanged", "no rendered files given"}]) ++
          if(files && inputs[:rerender],
            do: [],
            else: [{"deterministic", "no second rendering given"}]
          ) ++
          if(files,
            do: [],
            else: [
              {"symbol_coverage (rendered source)",
               "no rendered files: data types, fields and option sets are checked in the Project only"}
            ]
          ) ++ bypass_not_run ++ @unbound ++ [@unseen]

      with {:ok, results} <- results(specs, base) do
        {:ok,
         %{
           results: results,
           counts: %{
             "symbols" => Coverage.counts(accounted),
             "privacy_rules" => policy_counts,
             "bypasses" => bypass_counts
           },
           not_run: not_run(not_run),
           known: [],
           intended_differences: intended_differences(inputs.project)
         }}
      end
    end
  end

  def run(_inputs, _opts),
    do: {:error, Error.new(:invalid_input, "expected an inputs map and options")}

  @doc """
  Runs the checks of the owner's repository at `root` (what
  `mix wtf.verify structural` runs): `generated_unchanged`, `compiles`,
  `lint`, `migrations_in_sync` and the owned-code `bypass_inventory`.
  Options: `:app` and `:now` (required), `:actor` (default
  `"mix wtf.verify"`), `:cmd` (`(args, env) -> {output, status}` running
  `mix` in `root`), `:git_sha`, `:resolved` (a
  `BubbleEx.Decision.Resolved` of the app's decisions) and `:owners` (the
  trusted owners' author IDs; anchoring this list is WTF-411). A
  `decision:<key>` marker cites a privacy exception: an active, accepted
  `parity_exception` whose `checks` include a privacy check
  (`BubbleEx.Verify.Check`), authored by an owner in `:owners`, whose
  `scope` names the module (`"Acme.Owned"`) or function
  (`"Acme.Owned.run/2"`) it allows. Without both options, or for any
  other decision (a finding, a rename, an owner's drop of a symbol), a
  marker counts as unlisted. Advisory, like everything run in the owner's
  repository.
  """
  @spec project(Path.t(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def project(root, opts) do
    plan =
      case BubbleEx.Tasks.Store.read_plan(root) do
        {:ok, plan} -> plan
        _ -> nil
      end

    with {:ok, manifest_json} <- read(root, Manifest.path()),
         {:ok, manifest} <- Manifest.decode(manifest_json),
         {:ok, base} <- base(plan, opts, "mix wtf.verify") do
      ctx = %{
        root: root,
        cmd:
          Keyword.get(opts, :cmd, fn args, env ->
            System.cmd("mix", args, cd: root, stderr_to_stdout: true, env: env)
          end)
      }

      base = put_build(base, opts[:git_sha], manifest_json)

      {bypass, bypass_counts} =
        owned_bypasses(root, manifest, privacy_exceptions(opts[:resolved], opts[:owners]))

      specs = [
        manifest_result(Manifest.check(manifest_json, root)),
        checks_result("compiles", :compiles, "compile_error", ctx),
        lint_result(ctx),
        migrations_result(ctx),
        bypass
      ]

      decisions =
        cond do
          is_nil(opts[:resolved]) ->
            [
              {"bypass_inventory (decision markers)",
               "no decision store here: decision:<key> markers count as unlisted"}
            ]

          opts[:owners] in [nil, []] ->
            [
              {"bypass_inventory (decision markers)",
               "no trusted owners list (WTF-411): decision:<key> markers count as unlisted"}
            ]

          true ->
            []
        end

      with {:ok, results} <- results(specs, base) do
        {:ok,
         %{
           results: results,
           outputs:
             for(%{output: out} = spec <- specs, is_binary(out), into: %{}, do: {spec.id, out}),
           counts: %{"bypasses" => bypass_counts},
           not_run:
             not_run(
               [
                 {"symbol_coverage", "needs the Bubble model: run at generation (run/2)"},
                 {"policy_coverage", "needs the Bubble model: run at generation (run/2)"},
                 {"deterministic", "needs the generator: run at generation (run/2)"},
                 {"bypass_inventory (generated files)",
                  "hash-checked by generated_unchanged; their bypasses are checked at generation"}
               ] ++ decisions ++ @unbound ++ [@unseen]
             ),
           known: []
         }}
      end
    end
  end

  @doc """
  The summary of a report as JSON-ready data: the statement, each
  result's status, the counts, what was not run and the known failures.
  Aggregates and check names only (no Bubble IDs or names), so a snapshot
  of it can be committed.
  """
  @spec summary(report()) :: map()
  def summary(%{results: results, counts: counts, not_run: not_run} = report) do
    %{
      "statement" => @statement,
      "results" => Map.new(results, &{&1.id, Atom.to_string(&1.status)}),
      "passing" => Enum.all?(results, &(&1.status == :pass)),
      "counts" => counts,
      "not_run" => Enum.map(not_run, &%{"check" => &1.check, "reason" => &1.reason}),
      "known_failures" =>
        report
        |> Map.get(:known, [])
        |> Enum.map(&%{"check" => &1.check, "issue" => &1.issue, "reason" => &1.reason})
    }
  end

  @doc "`summary/1` as canonical, pretty-printed JSON text."
  @spec summary_json(report()) :: String.t()
  def summary_json(report),
    do: (report |> summary() |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"

  # --- inputs --------------------------------------------------------------------------

  defp check_inputs(inputs) do
    cond do
      not match?(%Model{}, inputs[:model]) -> invalid("inputs need the model")
      not match?(%Index{}, inputs[:index]) -> invalid("inputs need the index")
      not match?(%Plan{}, inputs[:plan]) -> invalid("inputs need the plan")
      not match?(%Project{}, inputs[:project]) -> invalid("inputs need the Ash project")
      not (is_nil(inputs[:files]) or is_map(inputs[:files])) -> invalid("files must be a map")
      true -> :ok
    end
  end

  defp base(plan, opts, actor) do
    case {opts[:app], opts[:now]} do
      {app, %DateTime{} = now} when is_binary(app) ->
        {:ok,
         %{
           app: app,
           ran_at: DateTime.truncate(now, :second),
           actor: Keyword.get(opts, :actor, actor),
           subject_build: opts[:subject_build],
           generators: generators(plan)
         }}

      _ ->
        invalid("options need app: (the Bubble app ID) and now: %DateTime{}")
    end
  end

  defp generators(%Plan{tasks: tasks}), do: for(%{kind: :generate, id: id} <- tasks, do: id)
  defp generators(_), do: []

  defp put_build(base, sha, manifest_json) when is_binary(sha),
    do: %{
      base
      | subject_build: %{git_sha: sha, generated_manifest_sha256: Manifest.sha256(manifest_json)}
    }

  defp put_build(base, _sha, _manifest_json), do: base

  # --- symbol coverage -------------------------------------------------------------------

  defp symbol_result(category, entries) do
    diff =
      for %{bucket: :uncovered} = e <- entries,
          do:
            e.subjects
            |> Map.take([:type, :field, :option_set, :page, :element, :workflow])
            |> Map.merge(%{op: "symbol_uncovered", detail: "#{e.id} (#{e.why})"})

    %{
      id: "structural.symbol_coverage.#{category}",
      check: "symbol_coverage",
      tasks: Map.fetch!(@category_tasks, category),
      diff: diff
    }
  end

  # --- policy coverage -------------------------------------------------------------------

  defp policy_coverage(%{model: model, project: project}) do
    types = for t <- model.data_types, not t.deleted, is_nil(t.raw), do: t
    rules = types |> Enum.map(&length(&1.rules)) |> Enum.sum()
    by_privacy = Enum.frequencies_by(types, &Atom.to_string(&1.privacy))

    counts = %{
      "rules" => rules,
      "types" => by_privacy,
      "privacy" => Atom.to_string(project.privacy)
    }

    spec = %{
      id: "structural.policy_coverage",
      check: "policy_coverage",
      tasks: ["generate:policies"]
    }

    case project.privacy do
      :omit ->
        reason =
          "blocked on WTF-356: privacy: :omit - no policy is generated, so none of the " <>
            "#{rules} privacy rules (#{length(types)} data types) is enforced"

        {Map.merge(spec, %{status: :skipped, reason: reason}), counts}

      _ ->
        resources = Map.new(project.resources, &{&1.source[:type], &1})
        diff = Enum.flat_map(types, &rule_gaps(&1, resources[&1.id]))
        privacy = for r <- project.resources, r.privacy, do: r.privacy

        counts =
          Map.merge(counts, %{
            "everyone" => types |> Enum.flat_map(& &1.rules) |> Enum.count(& &1.default?),
            "compiled" => privacy |> Enum.map(&length(&1.compiled_rules)) |> Enum.sum(),
            "denied" => privacy |> Enum.map(&length(&1.denied_rules)) |> Enum.sum(),
            "stricter_than_bubble" => %{
              "rules" => privacy |> Enum.map(&length(&1.stricter_rules)) |> Enum.sum(),
              "types" => Enum.count(privacy, &(&1.stricter_rules != []))
            },
            "uncovered" => length(diff)
          })

        {Map.put(spec, :diff, diff), counts}
    end
  end

  # Where the generated policies are stricter than Bubble by design
  # (BubbleEx.Verify.Difference): known and intended, not a failure.
  defp intended_differences(%Project{privacy: :omit}), do: []

  defp intended_differences(%Project{} = project) do
    flags = BubbleEx.Verify.Difference.flags(:rule_conditions)
    policy = Map.take(BubbleEx.Verify.Difference.policy(), flags)

    for r <- Enum.sort_by(project.resources, & &1.source[:type]),
        %{stricter_rules: rules} <- [r.privacy],
        rule <- rules do
      %{
        type: r.source[:type],
        rule: rule,
        flags: flags,
        decision:
          policy |> Map.values() |> Enum.map(& &1.decision) |> Enum.uniq() |> Enum.join("; ")
      }
    end
  end

  # A type without a resource is symbol coverage's to report.
  defp rule_gaps(_type, nil), do: []

  defp rule_gaps(%{privacy: :unavailable} = type, _resource),
    do: [%{op: "rule_uncovered", type: type.id, detail: "privacy rules unavailable"}]

  defp rule_gaps(%{privacy: :none} = type, resource) do
    if match?(%{source: :public_default}, resource.privacy) and resource.policies != [],
      do: [],
      else: [%{op: "rule_uncovered", type: type.id, detail: "no public-default policy"}]
  end

  # A conditional rule is compiled (a privacy calculation its checks test)
  # or denied (diagnosed: it grants nothing). The `everyone` rule has no
  # calculation: its grants are the default checks of every policy of a
  # type mapped from its rules.
  defp rule_gaps(type, resource) do
    {known, rules?} =
      case resource.privacy do
        %{source: source, compiled_rules: compiled, denied_rules: denied} ->
          {MapSet.new(compiled ++ denied), source == :rules}

        _ ->
          {MapSet.new(), false}
      end

    for rule <- type.rules,
        not if(rule.default?, do: rules?, else: MapSet.member?(known, rule.id)),
        do: %{op: "rule_uncovered", type: type.id, rule: rule.id}
  end

  # --- bypass inventory ------------------------------------------------------------------

  defp bypass_inventory(inputs) do
    removed =
      for %{status: :closed, subjects: subjects} <- inputs.plan.tasks,
          id <- subjects,
          into: MapSet.new(),
          do: id

    expected =
      for %{kind: :workflow, attrs: %{backend: true, ignore_privacy_rules: true}} = s <-
            inputs.index.symbols,
          not MapSet.member?(removed, s.id),
          into: MapSet.new(),
          do: s.bubble_id

    spec = inputs[:workflows]
    files = Map.get(inputs, :files)

    base = %{
      id: "structural.bypass_inventory",
      check: "bypass_inventory",
      tasks: ["generate:workflow_entry_points"]
    }

    if MapSet.size(expected) > 0 and not match?(%WorkflowSpec{}, spec) do
      reason =
        "#{MapSet.size(expected)} workflows ignore privacy rules in Bubble and no workflow " <>
          "Spec was given: nothing was checked"

      {Map.merge(base, %{status: :skipped, reason: reason}),
       %{"expected" => MapSet.size(expected), "lowered" => nil}, [{"bypass_inventory", reason}]}
    else
      {lowered, bypassed} = lowered(spec)
      lib = lib_files(files)

      inventory =
        Bypasses.inventory(lib,
          workflows: bypassed,
          bodies: spec_bodies(spec, files),
          app_repo: app_repo(manifest(files)),
          scaffold: expected_scaffold(lib, inputs.project),
          generated: generated_paths(files)
        )

      diff =
        spec_diff(expected, lowered, bypassed) ++
          started_diff(bypassed, inventory, files) ++
          site_diff(inventory) ++ allowlist_diff(files, lib)

      not_run =
        if files,
          do: [],
          else: [
            {"bypass_inventory (rendered code)",
             "no rendered files: Runtime.start bypasses and scaffold sites are not checked"}
          ]

      {Map.put(base, :diff, diff),
       %{
         "expected" => MapSet.size(expected),
         "lowered" => length(bypassed),
         "sites" => site_counts(inventory)
       }, not_run}
    end
  end

  defp spec_bodies(%WorkflowSpec{} = spec, files),
    do: Bypasses.bodies(spec.names, spec.namespace, manifest(files)["app"])

  defp spec_bodies(_spec, _files), do: %{}

  # The rendered files the manifest hashes (generated, not owned).
  defp generated_paths(files), do: files |> manifest() |> Map.get("generated", %{}) |> Map.keys()

  # The generated app's Repo module, the one `use Ecto.Repo` not a site.
  defp app_repo(%{"module" => module}) when is_binary(module), do: module <> ".Repo"
  defp app_repo(_manifest), do: nil

  # The rendered manifest, or an empty one.
  defp manifest(nil), do: %{}

  defp manifest(files) do
    with json when is_binary(json) <- files[Manifest.path()],
         {:ok, manifest} <- Manifest.decode(json) do
      manifest
    else
      _ -> %{}
    end
  end

  defp lowered(%WorkflowSpec{} = spec),
    do: {MapSet.new(WorkflowSpec.actions(spec), & &1.workflow), spec.privacy_bypasses}

  defp lowered(_), do: {MapSet.new(), []}

  defp spec_diff(expected, lowered, bypassed) do
    bypassed_set = MapSet.new(bypassed)

    for(
      w <- Enum.sort(bypassed),
      not MapSet.member?(expected, w),
      do: %{op: "bypass_unlisted", workflow: w, expected: false, actual: true}
    ) ++
      for w <- Enum.sort(expected),
          MapSet.member?(lowered, w),
          not MapSet.member?(bypassed_set, w),
          do: %{op: "bypass_unlisted", workflow: w, expected: true, actual: false}
  end

  # Every listed workflow's body starts with its bypass.
  defp started_diff(_bypassed, _inventory, nil), do: []

  defp started_diff(bypassed, inventory, _files) do
    started =
      for %{kind: :runtime_start, class: :listed, workflow: w} <- inventory.sites,
          into: MapSet.new(),
          do: w

    for w <- Enum.sort(bypassed),
        not MapSet.member?(started, w),
        do: %{
          op: "bypass_unlisted",
          workflow: w,
          detail: "no Runtime.start(..., false) in the workflow's rendered body"
        }
  end

  # The scaffold sites the generator is expected to write (M2): the
  # purposes' fixed sites in the files present, and one `derived_count`
  # per unauthorized count aggregate of the Project, in its resource's file.
  defp expected_scaffold(lib, project) do
    fixed =
      for {path, _} <- lib,
          {purpose, {suffix, _kind, functions}} <- Bypasses.expected_sites(),
          String.ends_with?(path, suffix),
          {fun, n} <- functions,
          into: %{},
          do: {{path, purpose, fun}, n}

    counts =
      for r <- project.resources,
          %{authorize?: false} <- r.aggregates,
          reduce: %{} do
        acc -> Map.update(acc, r.module, 1, &(&1 + 1))
      end

    derived =
      for {path, source} <- lib,
          counts != %{},
          module <- defined_modules(source),
          n = counts[relative(module, project)],
          n != nil,
          into: %{},
          do: {{path, "derived_count", nil}, n}

    Map.merge(fixed, derived) |> Map.merge(auth_bypasses(lib, project))
  end

  # With enforced policies the User resource bypasses them for
  # AshAuthentication's own interactions: a policy and a field policy
  # bypass (field policies only when the User has some).
  # So does the private file lookup of the generated Uploads (one read).
  defp auth_bypasses(lib, %{privacy: :enforced} = project) do
    user =
      case Enum.find(project.resources, &(&1.source[:type] == "user")) do
        nil ->
          %{}

        user ->
          n = if user.field_policies == [], do: 1, else: 2

          for {path, source} <- lib,
              module <- defined_modules(source),
              relative(module, project) == user.module,
              into: %{},
              do: {{path, "ash_authentication", nil}, n}
      end

    uploads =
      for {path, _} <- lib,
          String.ends_with?(path, "_web/uploads.ex"),
          into: %{},
          do: {{path, "private_file_holders", "holders/4"}, 1}

    Map.merge(user, uploads)
  end

  defp auth_bypasses(_lib, _project), do: %{}

  defp defined_modules(source) do
    case Code.string_to_quoted(source, emit_warnings: false) do
      {:ok, {:defmodule, _, [{:__aliases__, _, parts} | _]}} -> [Enum.join(parts, ".")]
      _ -> []
    end
  end

  # "Acme.Task" -> "Task" (the Project's relative module names).
  defp relative(module, _project) do
    case String.split(module, ".", parts: 2) do
      [_ns, rest] -> rest
      _ -> module
    end
  end

  # `.wtf/bypasses.json` lists exactly the scaffold sites of the rendered
  # code, so the owner's repository can hold the owned files to it.
  defp allowlist_diff(nil, _lib), do: []

  defp allowlist_diff(files, lib) do
    if files[Bypasses.path()] == Bypasses.allowlist_json(lib),
      do: [],
      else: [
        %{
          op: "bypass_unlisted",
          path: Bypasses.path(),
          detail: "does not list the rendered code's scaffold sites"
        }
      ]
  end

  defp lib_files(nil), do: %{}

  defp lib_files(files),
    do: Map.filter(files, fn {path, _} -> String.starts_with?(path, "lib/") end)

  defp site_diff(inventory) do
    for(
      %{class: :unlisted} = site <- inventory.sites,
      do:
        %{
          op: "bypass_unlisted",
          path: "#{site.path}:#{site.line}",
          detail: Enum.join(Enum.reject([site.kind, site.detail], &is_nil/1), ": ")
        }
        |> put_workflow(site[:workflow])
    ) ++
      for path <- inventory.unparsable,
          do: %{op: "bypass_unlisted", path: path, detail: "does not parse"}
  end

  defp put_workflow(entry, nil), do: entry
  defp put_workflow(entry, w), do: Map.put(entry, :workflow, w)

  defp site_counts(inventory),
    do: Enum.frequencies_by(inventory.sites, &"#{&1.kind}:#{&1.class}")

  # Owned code in the owner's repository (generated files are skipped:
  # their hashes are checked), held to the generated allowlist.
  defp owned_bypasses(root, manifest, decisions) do
    generated = Map.get(manifest, "generated", %{})

    files =
      for path <- Path.wildcard(Path.join(root, "lib/**/*.{ex,exs}")),
          rel = Path.relative_to(path, root),
          not Map.has_key?(generated, rel),
          {:ok, content} <- [File.read(path)],
          into: %{},
          do: {rel, content}

    allowlist = File.read(Path.join(root, Bypasses.path()))

    {scaffold, allowlist_diff} =
      case Bypasses.decode_allowlist(ok_or_nil(allowlist)) do
        {:ok, map} ->
          {map, []}

        :error ->
          {%{}, [%{op: "bypass_unlisted", path: Bypasses.path(), detail: "not readable"}]}
      end

    {workflows, names} = generated_workflows(root)

    inventory =
      Bypasses.inventory(files,
        workflows: workflows,
        bodies: Bypasses.bodies(names, manifest["module"], manifest["app"]),
        app_repo: app_repo(manifest),
        scaffold: scaffold,
        decisions: decisions
      )

    {%{
       id: "structural.bypass_inventory",
       check: "bypass_inventory",
       tasks: ["generate:workflow_entry_points"],
       diff: allowlist_diff ++ site_diff(inventory)
     }, %{"allowed_workflows" => length(workflows), "sites" => site_counts(inventory)}}
  end

  defp ok_or_nil({:ok, value}), do: value
  defp ok_or_nil(_), do: nil

  # The decisions a `decision:<key>` marker may cite, key => scope: active,
  # accepted parity exceptions excusing a privacy check, authored by a
  # trusted owner, scoped to a module or function. A finding (including
  # an owner's drop of a symbol, WTF-422) or a rename authorizes no bypass.
  defp privacy_exceptions(%Resolved{entries: entries}, [_ | _] = owners) do
    for %{state: :active, decision: d} <- entries,
        d.kind == :parity_exception and d.choice == :accept,
        match?(%{kind: :owner, id: id} when is_binary(id), d.author),
        d.author.id in owners,
        Enum.any?(Map.get(d.params, :checks, []), &privacy_check?/1),
        scope = Map.get(d.params, :scope),
        Bypasses.decision_scope(scope) != :error,
        into: %{},
        do: {d.key, scope}
  end

  defp privacy_exceptions(_resolved, _owners), do: %{}

  defp privacy_check?(check), do: match?({:ok, {_, :privacy}}, BubbleEx.Verify.Check.fetch(check))

  # The workflows the generator bypasses and its name map
  # (`.wtf/workflows.json`, generated and hash-checked), or none.
  defp generated_workflows(root) do
    with {:ok, json} <- File.read(Path.join(root, ".wtf/workflows.json")),
         {:ok, %{"privacy_bypasses" => list} = map} when is_list(list) <- Jason.decode(json) do
      {Enum.filter(list, &is_binary/1), map["names"]}
    else
      _ -> {[], nil}
    end
  end

  # --- files -----------------------------------------------------------------------------

  defp file_results(nil, _rerender), do: []

  defp file_results(files, rerender) do
    manifest =
      case files[Manifest.path()] do
        nil -> {:error, Error.new(:invalid_input, "no #{Manifest.path()} in the files")}
        json -> Manifest.check(json, files)
      end

    [manifest_result(manifest)] ++
      if rerender, do: [deterministic_result(files, rerender)], else: []
  end

  defp manifest_result({:ok, report}) do
    diff =
      Enum.map(report.modified, &%{op: "file_changed", path: &1, detail: "modified"}) ++
        Enum.map(report.missing, &%{op: "file_changed", path: &1, detail: "missing"})

    %{
      id: "structural.generated_unchanged",
      check: "generated_unchanged",
      tasks: :generators,
      diff: diff
    }
  end

  defp manifest_result({:error, %Error{message: message}}) do
    %{
      id: "structural.generated_unchanged",
      check: "generated_unchanged",
      tasks: :generators,
      diff: [%{op: "file_changed", path: Manifest.path(), detail: message}]
    }
  end

  defp deterministic_result(files, rerender) do
    paths = (Map.keys(files) ++ Map.keys(rerender)) |> Enum.uniq() |> Enum.sort()

    diff =
      for path <- paths,
          files[path] != rerender[path],
          do: %{
            op: "not_deterministic",
            path: path,
            detail: difference(files[path], rerender[path])
          }

    %{id: "structural.deterministic", check: "deterministic", tasks: :generators, diff: diff}
  end

  defp difference(nil, _), do: "only in the second rendering"
  defp difference(_, nil), do: "only in the first rendering"
  defp difference(_, _), do: "content differs"

  # --- owner-repository commands ----------------------------------------------------------

  defp checks_result(check, criterion, op, ctx) do
    {outcome, _cache} = Checks.run(%{check: criterion, args: %{}}, ctx, %{})

    diff =
      if outcome.status == :pass,
        do: [],
        else: [
          %{
            op: op,
            detail: Enum.join(Enum.reject([outcome.binding, outcome.detail], &is_nil/1), ": ")
          }
        ]

    %{
      id: "structural.#{check}",
      check: check,
      tasks: :generators,
      diff: diff,
      output: outcome.output
    }
  end

  defp lint_result(ctx), do: checks_result("lint", :lint, "lint", ctx)

  defp migrations_result(ctx) do
    args = ~w(ash.codegen --check)
    {output, status} = ctx.cmd.(args, [])

    diff =
      if status == 0,
        do: [],
        else: [%{op: "migration", detail: "mix ash.codegen --check: exit status #{status}"}]

    %{
      id: "structural.migrations_in_sync",
      check: "migrations_in_sync",
      tasks: ["generate:schema"],
      diff: diff,
      output: if(status == 0, do: nil, else: output)
    }
  end

  # --- results -----------------------------------------------------------------------------

  defp results(specs, base) do
    specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      case Result.new(result_attrs(spec, base)) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp result_attrs(spec, base) do
    status = Map.get(spec, :status) || if(Map.get(spec, :diff, []) == [], do: :pass, else: :fail)

    tasks =
      case spec.tasks do
        :generators -> base.generators
        list -> Enum.filter(list, &(&1 in base.generators))
      end

    %{
      id: spec.id,
      app: base.app,
      check: spec.check,
      status: status,
      tasks: tasks,
      diff: if(status == :skipped, do: [], else: Map.get(spec, :diff, [])),
      reason: Map.get(spec, :reason),
      subject_build: base.subject_build,
      actor: base.actor,
      ran_at: base.ran_at
    }
  end

  defp not_run(list),
    do: Enum.map(list, fn {check, reason} -> %{check: check, reason: reason} end)

  defp read(root, path) do
    case File.read(Path.join(root, path)) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> invalid("no #{path} in #{root}: not a project generated by bubble_ex")
    end
  end

  defp invalid(message), do: {:error, Error.new(:invalid_input, message)}
end
