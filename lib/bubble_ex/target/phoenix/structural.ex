defmodule BubbleEx.Target.Phoenix.Structural do
  @moduledoc """
  The structural verification pack for the Phoenix target (WTF-386, V6 of
  the WTF-358 verification proposal, §2): offline, deterministic checks
  that the generated project matches the Bubble model. Every outcome is a
  `BubbleEx.Verify.Result` of a structural (L0) check
  (`BubbleEx.Verify.Check`), so the cutover gates (WTF-390) read them like
  any other result. Structural results accept no difference: they pass or
  fail (or are `skipped`, which never counts as passing).

  **Structural, not behavioural.** These checks prove that every Bubble
  definition is generated or accounted for, that generated files are
  intact and deterministic, and where privacy is bypassed. They do not
  prove the app behaves like the Bubble app: that is the privacy matrix
  and replay (L2/L3), data verification (L4) and the cutover gates (L5).
  `statement/0` says so in every summary.

  It composes what exists instead of re-deriving it: the symbol accounting
  (`Structural.Coverage`) reads the `BubbleEx.Target.Ash.Project`, the
  workflow and API client Specs, the rendered surfaces and the
  `BubbleEx.Plan` (its tasks and `BubbleEx.Plan.Residue`); the manifest
  check is `BubbleEx.Target.Phoenix.Manifest.check/3`; compile and lint
  are `BubbleEx.Target.Phoenix.Checks`. Element- and action-level residue
  stays the plan's `coverage`; privacy behaviour stays the policy matrix
  (`BubbleEx.Target.Ash.MatrixTests`).

  ## Where each check runs

  | check | `run/2` (at generation, with the Bubble model) | `project/2` (the owner's repository, `mix wtf.verify structural`) |
  |-------|-----------------------------------------------|-------------------------------------------------------------------|
  | `symbol_coverage` | one result per category (`symbol_coverage.<category>`, see `Structural.Coverage`) | no: needs the model |
  | `policy_coverage` | every privacy rule of a mapped type compiled or denied (a diagnostic); `skipped` for a `privacy: :omit` project (no policy is generated, so none is enforced) | no: needs the model |
  | `bypass_inventory` | the lowering bypasses exactly the backend workflows that ignore privacy rules in Bubble, and the rendered bodies agree | every `authorize?: false` in owned code is marked (`Structural.Bypasses`) |
  | `generated_unchanged` | the manifest matches the rendered files | the manifest matches the files on disk |
  | `deterministic` | a second rendering (`rerender`) is byte-identical | no: needs the generator |
  | `compiles`, `lint` | no | `Target.Phoenix.Checks` |
  | `migrations_in_sync` | no | `mix ash.codegen --check` |
  | `boundary`, `secrets_absent` | not bound yet | not bound yet |
  | `traceability.source`, `traceability.rendered` | per task: `mix wtf.task` (`Target.Phoenix.Checks`) | the same |

  What a run does not check is listed in its summary (`not_run`), with
  why. In the owner's repository every verdict is advisory: the files are
  the implementer's to edit (`BubbleEx.Tasks`, WTF-411).
  """

  alias BubbleEx.{CanonicalJson, Error, Index, Model, Plan}
  alias BubbleEx.Target.Ash.Project
  alias BubbleEx.Target.Ash.Workflows.Spec, as: WorkflowSpec
  alias BubbleEx.Target.Phoenix.{Checks, Manifest}
  alias BubbleEx.Target.Phoenix.Structural.{Bypasses, Coverage}
  alias BubbleEx.Verify.Result

  @statement "Structural verification (L0) only, not behavioural. It shows that every " <>
               "Bubble data type, field, option set, page, reusable element, workflow and " <>
               "API Connector call is generated or accounted for (a plan task, residue, an " <>
               "owner decision, a diagnostic or an exclusion), that generated files are " <>
               "intact and deterministic, and where privacy is bypassed. It does not show " <>
               "that the app behaves like the Bubble app: privacy, workflows, pages and data " <>
               "are verified by replay (L2/L3), data verification (L4) and the cutover gates " <>
               "(L5). Symbols counted as task or residue are work still to do."

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

  @typedoc """
  A run: its results, its counts (aggregates only), the checks it did not
  run and why. `project/2` adds `outputs`: the tail of a failing
  command's output by result ID, to show, never to store.
  """
  @type report :: %{
          required(:results) => [Result.t()],
          required(:counts) => map(),
          required(:not_run) => [%{check: String.t(), reason: String.t()}],
          optional(:outputs) => %{String.t() => String.t()}
        }

  @doc "What a structural verdict does and does not show."
  @spec statement() :: String.t()
  def statement, do: @statement

  @doc """
  Runs the checks that need the Bubble model, at generation time.

  `inputs`:

    * `:model`, `:index`, `:plan` - the `BubbleEx.Model`, its
      `BubbleEx.Index` and the `BubbleEx.Plan` built from them
    * `:project` - the `BubbleEx.Target.Ash.Project` that was rendered
      (`privacy: :omit`), or an `:unverified` one to check policy coverage
    * `:files` - the rendered file map (`BubbleEx.Target.Phoenix.render/2`);
      without it the file checks are not run
    * `:rerender` - a second rendering from the same inputs, for
      `deterministic`
    * `:workflows` - the `BubbleEx.Target.Ash.Workflows.Spec` rendered,
      and `:api_clients` - the `BubbleEx.Target.ApiClients.Spec` rendered

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
      {bypass, bypass_counts} = bypass_inventory(inputs)
      files = Map.get(inputs, :files)

      specs =
        Enum.map(Coverage.categories(), &symbol_result(&1, accounted[&1])) ++
          [policy, bypass] ++
          file_results(files, Map.get(inputs, :rerender))

      not_run =
        not_run(
          [
            {"compiles", "run in the owner's repository: mix wtf.verify structural"},
            {"lint", "run in the owner's repository: mix wtf.verify structural"},
            {"migrations_in_sync", "run in the owner's repository: mix wtf.verify structural"}
          ] ++
            if(files, do: [], else: [{"generated_unchanged", "no rendered files given"}]) ++
            if(files && inputs[:rerender],
              do: [],
              else: [{"deterministic", "no second rendering given"}]
            )
        )

      with {:ok, results} <- results(specs, base) do
        {:ok,
         %{
           results: results,
           counts: %{
             "symbols" => Coverage.counts(accounted),
             "privacy_rules" => policy_counts,
             "bypasses" => bypass_counts
           },
           not_run: not_run
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
  `mix` in `root`), `:git_sha`. Advisory, like everything run in the
  owner's repository.
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
      {bypass, bypass_counts} = owned_bypasses(root, manifest)

      specs = [
        manifest_result(Manifest.check(manifest_json, root)),
        checks_result("compiles", :compiles, "compile_error", ctx),
        checks_result("lint", :lint, "lint", ctx),
        migrations_result(ctx),
        bypass
      ]

      with {:ok, results} <- results(specs, base) do
        {:ok,
         %{
           results: results,
           outputs:
             for(%{output: out} = spec <- specs, is_binary(out), into: %{}, do: {spec.id, out}),
           counts: %{"bypasses" => bypass_counts},
           not_run:
             not_run([
               {"symbol_coverage", "needs the Bubble model: run at generation (run/2)"},
               {"policy_coverage", "needs the Bubble model: run at generation (run/2)"},
               {"deterministic", "needs the generator: run at generation (run/2)"},
               {"boundary", "no generated boundary configuration yet"},
               {"secrets_absent", "not bound yet"},
               {"traceability.source", "per task: mix wtf.task complete / audit"},
               {"traceability.rendered", "per task: mix wtf.task complete / audit"}
             ])
         }}
      end
    end
  end

  @doc """
  The summary of a report as JSON-ready data: the statement, each
  result's status, the counts and what was not run. Aggregates and check
  names only (no Bubble IDs or names), so a snapshot of it can be
  committed.
  """
  @spec summary(report()) :: map()
  def summary(%{results: results, counts: counts, not_run: not_run}) do
    %{
      "statement" => @statement,
      "results" => Map.new(results, &{&1.id, Atom.to_string(&1.status)}),
      "passing" => Enum.all?(results, &(&1.status == :pass)),
      "counts" => counts,
      "not_run" => Enum.map(not_run, &%{"check" => &1.check, "reason" => &1.reason})
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
            |> Map.take([:type, :field, :element, :workflow])
            |> Map.merge(%{op: "symbol_uncovered", detail: e.id})

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
          "privacy: :omit - no policy is generated, so none of the #{rules} privacy rules " <>
            "(#{length(types)} data types) is enforced; generated policies are gated (WTF-356)"

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
            "uncovered" => length(diff)
          })

        {Map.put(spec, :diff, diff), counts}
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
    {lowered, bypassed} = lowered(spec)
    files = Map.get(inputs, :files) || %{}
    inventory = Bypasses.inventory(files, allowed: bypassed, scaffold: Map.keys(files))

    started =
      for %{kind: :runtime_start, workflow: w} <- inventory.sites, into: MapSet.new(), do: w

    diff =
      for(
        w <- Enum.sort(bypassed),
        not MapSet.member?(expected, w),
        do: %{op: "bypass_unlisted", workflow: w, expected: false, actual: true}
      ) ++
        for(
          w <- Enum.sort(expected),
          MapSet.member?(lowered, w),
          not MapSet.member?(MapSet.new(bypassed), w),
          do: %{op: "bypass_unlisted", workflow: w, expected: true, actual: false}
        ) ++
        for(
          w <- Enum.sort(bypassed),
          files != %{},
          not MapSet.member?(started, w),
          do: %{
            op: "bypass_unlisted",
            workflow: w,
            detail: "no Runtime.start(..., false) in the rendered workflow bodies"
          }
        ) ++ site_diff(inventory)

    counts = %{
      "expected" => MapSet.size(expected),
      "lowered" => length(bypassed),
      "sites" => site_counts(inventory)
    }

    {%{
       id: "structural.bypass_inventory",
       check: "bypass_inventory",
       tasks: ["generate:workflow_entry_points"],
       diff: diff
     }, counts}
  end

  defp lowered(%WorkflowSpec{} = spec),
    do: {MapSet.new(WorkflowSpec.actions(spec), & &1.workflow), spec.privacy_bypasses}

  defp lowered(_), do: {MapSet.new(), []}

  defp site_diff(inventory) do
    for(
      %{class: :unlisted} = site <- inventory.sites,
      do:
        %{
          op: "bypass_unlisted",
          path: "#{site.path}:#{site.line}",
          detail: Atom.to_string(site.kind)
        }
        |> put_workflow(site.workflow)
    ) ++
      for path <- inventory.unparsable,
          do: %{op: "bypass_unlisted", path: path, detail: "does not parse"}
  end

  defp put_workflow(entry, nil), do: entry
  defp put_workflow(entry, w), do: Map.put(entry, :workflow, w)

  defp site_counts(inventory),
    do: Enum.frequencies_by(inventory.sites, &"#{&1.kind}:#{&1.class}")

  # Owned code in the owner's repository: generated files are skipped
  # (their hashes are checked), owned files still as scaffolded are
  # bubble_ex's own.
  defp owned_bypasses(root, manifest) do
    generated = Map.get(manifest, "generated", %{})
    owned = Map.get(manifest, "owned", %{})

    files =
      for path <- Path.wildcard(Path.join(root, "lib/**/*.{ex,exs}")),
          rel = Path.relative_to(path, root),
          not Map.has_key?(generated, rel),
          {:ok, content} <- [File.read(path)],
          into: %{},
          do: {rel, content}

    scaffold = for {rel, content} <- files, owned[rel] == Manifest.sha256(content), do: rel
    allowed = allowed_bypasses(root)
    inventory = Bypasses.inventory(files, allowed: allowed, scaffold: scaffold)

    {%{
       id: "structural.bypass_inventory",
       check: "bypass_inventory",
       tasks: ["generate:workflow_entry_points"],
       diff: site_diff(inventory)
     }, %{"allowed" => length(allowed), "sites" => site_counts(inventory)}}
  end

  # The workflows the generator bypasses (`.wtf/workflows.json`, generated
  # and hash-checked), or none.
  defp allowed_bypasses(root) do
    with {:ok, json} <- File.read(Path.join(root, ".wtf/workflows.json")),
         {:ok, %{"privacy_bypasses" => list}} when is_list(list) <- Jason.decode(json) do
      Enum.filter(list, &is_binary/1)
    else
      _ -> []
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
