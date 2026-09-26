defmodule BubbleEx.Target.Phoenix.Checks do
  @moduledoc """
  Binds the abstract criteria of plan tasks (`BubbleEx.Plan.Criteria`) to
  concrete checks in a project rendered by `BubbleEx.Target.Phoenix`
  (WTF-359 §4, WTF-375). `mix wtf.task complete` and `audit` run them
  locally, in the owner's repository (`BubbleEx.Tasks`). Every verdict is
  advisory: the project, its manifest, its tests and the results are the
  implementing agent's to edit ("Threat model" in `BubbleEx.Tasks`;
  WTF-411).

  | criterion | Phoenix binding |
  |-----------|-----------------|
  | `generated_unchanged` | `BubbleEx.Target.Phoenix.check_manifest/3` of `.wtf/generated.json` against the files: no hand-edited or missing generated file (the manifest itself is unsigned) |
  | `compiles` | `mix compile --warnings-as-errors`: undefined and deprecated calls are compiler warnings, so they fail it |
  | `lint` | `mix format --check-formatted`, and `mix credo --strict` when the project has Credo (`deps/credo`) |
  | `traceability` | every listed element is a `data-bubble-id="<id>"` attribute in `lib/` outside comments (Elixir, `<%!-- --%>`, `<%# %>` and HTML comments are removed first), and every listed page or reusable is rendered by its tagged tests (see Tagged tests; the generated LiveView tests assert each `data-bubble-id` with `has_element?`). With no page or reusable listed, only the source is checked (`advisory: true`: weaker) |
  | `render_smoke` | no `TODO(bubble:` placeholder left for the listed elements or in the files tracing the listed surfaces, and the tests tagged with each of them pass |
  | `step_order` | `advisory: true` (weaker: comments, not code): in `lib/`, exactly one `# bubble:workflow <id>` comment, followed (before the next workflow marker) by one `# bubble:step N <Type>` comment per action, in order, read with `Code.string_to_quoted_with_comments/2` |
  | `unit_test` | the tests tagged with each listed workflow pass |
  | `request_shape` | the tests tagged with each listed API call pass |
  | `deterministic` | passing `deterministic` `BubbleEx.Verify.Result`s naming the task (the generator renders twice) |
  | `policy_matrix` | passing `privacy_read` results naming the task (`BubbleEx.Target.Ash.MatrixTests.results/3`) |
  | `visual_parity` | passing `visual_parity` results naming the task |
  | `replay` | results naming the task, each passing **and Bubble-verified** (its recording, `.wtf/verification/recordings/<scenario>.json`, present and matching) |
  | `data_counts` | passing `row_counts` results naming the task |
  | `subtasks_done`, `independent_review`, `decision_recorded`, `attested` | task state, not the code: see `BubbleEx.Tasks` |

  ## Tagged tests

  Tests prove a subject by carrying its ID in a `bubble` tag:

      @tag bubble: "workflow:bTuV"          # or @moduletag / @describetag
      test "the workflow sends the invoice" do …

  Every subject `S` must appear as a `bubble: "<S>"` tag in the parsed
  code of `test/` (a tag in a comment or a string is none). Then
  `mix test --only bubble:<S>` runs once per subject, and only its exit
  status counts: non-zero when a test fails or none ran (the summary line
  is not parsed). A check without subjects uses the task ID.

  ## Results

  Result-backed checks read `BubbleEx.Verify.Result` files (unsigned)
  given as evidence and evaluate every one naming the task with
  `BubbleEx.Verify.Result.evaluate/3` (`app:`, `now:`, `reviewers:` whose
  waivers count, the decision store as `resolved:`; without one, a result
  citing a decision does not count). All of them must pass: a newer pass
  does not mask an older failure. A decoded result never counts by itself;
  `skipped` never passes.
  """

  alias BubbleEx.Decision.Resolved
  alias BubbleEx.Target.Phoenix.Manifest
  alias BubbleEx.Verify.{Recording, Result}

  @result_checks %{
    deterministic: "deterministic",
    policy_matrix: "privacy_read",
    visual_parity: "visual_parity",
    data_counts: "row_counts"
  }

  @typedoc """
  The context of a run:

    * `root` - the project's root directory
    * `task` - the `BubbleEx.Plan.Task` whose criteria run
    * `results` - `[{ref, sha256, %Result{}}]` of the evidence
    * `app`, `now`, `reviewers`, `resolved` - for `Result.evaluate/3`
    * `cmd` - `(args, env) -> {output, exit_status}`: runs `mix` in `root`
  """
  @type ctx :: %{
          root: Path.t(),
          task: BubbleEx.Plan.Task.t(),
          results: [{String.t(), String.t(), Result.t()}],
          app: String.t() | nil,
          now: DateTime.t(),
          reviewers: [String.t()],
          resolved: Resolved.t() | nil,
          cmd: (list(String.t()), list() -> {String.t(), non_neg_integer()})
        }

  @typedoc "One criterion's outcome. `output` is shown, never stored."
  @type outcome :: %{
          status: :pass | :fail,
          binding: String.t(),
          detail: String.t() | nil,
          refs: [%{ref: String.t(), sha256: String.t()}],
          output: String.t() | nil
        }

  @doc "The criteria this module binds to the code (the rest are task state)."
  @spec bound() :: [atom()]
  def bound,
    do: ~w(generated_unchanged compiles lint traceability render_smoke step_order unit_test
         request_shape)a ++ Map.keys(@result_checks) ++ [:replay]

  @doc """
  Runs `criterion` (`%{check, args}`). `cache` memoizes project-wide
  checks (compile, lint, the source scans) across criteria and tasks of
  one run; pass `%{}` to start.
  """
  @spec run(map(), ctx(), map()) :: {outcome(), map()}
  def run(%{check: check, args: args}, ctx, cache), do: check(check, args, ctx, cache)

  # --- structural --------------------------------------------------------------------

  defp check(:generated_unchanged, _args, ctx, cache) do
    memo(cache, :generated_unchanged, fn ->
      binding = "check_manifest(.wtf/generated.json)"

      # The manifest is the agent's to edit too (advisory, WTF-411).
      with {:ok, json} <- manifest(ctx),
           {:ok, report} <- Manifest.check(json, ctx.root) do
        manifest_outcome(binding, report)
      else
        {:error, :enoent} -> fail(binding, "no #{Manifest.path()}")
        {:error, %BubbleEx.Error{message: m}} -> fail(binding, m)
        {:error, reason} -> fail(binding, inspect(reason))
      end
    end)
  end

  defp check(:compiles, _args, ctx, cache) do
    memo(cache, :compiles, fn -> mix(ctx, ~w(compile --warnings-as-errors)) end)
  end

  defp check(:lint, _args, ctx, cache) do
    memo(cache, :lint, fn ->
      format = mix(ctx, ~w(format --check-formatted))

      cond do
        format.status == :fail -> format
        File.dir?(Path.join(ctx.root, "deps/credo")) -> mix(ctx, ~w(credo --strict))
        true -> %{format | detail: "credo is not a dependency: format only"}
      end
    end)
  end

  # --- traceability ------------------------------------------------------------------

  defp check(:traceability, args, ctx, cache) do
    {sources, cache} = sources(ctx, cache)
    ids = list(args, "elements")
    {surfaces, elements} = Enum.split_with(ids, &surface?/1)
    binding = "data-bubble-id attributes in lib/ (comments ignored)"
    missing = Enum.reject(elements, &traced?(sources, &1))

    cond do
      missing != [] ->
        {fail(binding, "not traced: " <> summary(missing)), cache}

      surfaces == [] ->
        # Nothing renders the elements here: the source is all there is.
        {%{pass(binding, "#{length(elements)} Bubble IDs in the source") | advisory: true}, cache}

      true ->
        # The surfaces' render tests (the generated LiveView tests assert
        # every data-bubble-id with has_element?) are what render them.
        {outcome, cache} = tagged(surfaces, ctx, cache)

        detail =
          "#{length(elements)} Bubble IDs in the source, rendered by the tests of " <>
            summary(surfaces)

        {if(outcome.status == :pass, do: %{outcome | detail: detail}, else: outcome), cache}
    end
  end

  defp check(:render_smoke, args, ctx, cache) do
    {sources, cache} = sources(ctx, cache)
    {raw, cache} = raw_sources(ctx, cache)
    uncommented = Map.new(sources)
    subjects = list(args, "surfaces") ++ list(args, "elements")

    placeholders =
      for {path, text} <- raw,
          String.contains?(text, "TODO(bubble:"),
          Enum.any?(subjects, &placeholder_in?({text, uncommented[path]}, &1)),
          uniq: true,
          do: path

    if placeholders == [] do
      tagged(subjects, ctx, cache)
    else
      {fail("TODO(bubble: placeholders", "left in " <> summary(Enum.sort(placeholders))), cache}
    end
  end

  defp check(:step_order, args, ctx, cache) do
    {markers, cache} = markers(ctx, cache)
    workflow = args["workflow"]
    steps = list(args, "steps")
    binding = "# bubble:workflow / # bubble:step comments in lib/ (advisory: comments, not code)"

    outcome =
      case Map.get(markers, bubble_id(workflow), []) do
        [] ->
          fail(binding, "no # bubble:workflow #{bubble_id(workflow)} marker")

        [{_path, found}] ->
          expected = steps |> Enum.with_index(1) |> Enum.map(fn {type, n} -> {n, type} end)

          if found == expected,
            do: %{pass(binding, "#{length(steps)} steps in order") | advisory: true},
            else:
              fail(
                binding,
                "expected steps #{steps_text(expected)}, found #{steps_text(found)}"
              )

        many ->
          fail(binding, "the workflow is marked in #{length(many)} places")
      end

    {outcome, cache}
  end

  defp check(:unit_test, args, ctx, cache), do: tagged(list(args, "workflows"), ctx, cache)
  defp check(:request_shape, args, ctx, cache), do: tagged(list(args, "calls"), ctx, cache)

  # --- results -----------------------------------------------------------------------

  defp check(:replay, _args, ctx, cache) do
    results = for {_, _, r} = entry <- ctx.results, ctx.task.id in r.tasks, do: entry
    {evaluate(results, "replay results", ctx, true), cache}
  end

  defp check(check, _args, ctx, cache) when is_map_key(@result_checks, check) do
    name = @result_checks[check]

    results =
      for {_, _, r} = entry <- ctx.results, r.check == name, ctx.task.id in r.tasks, do: entry

    {evaluate(results, "#{name} results", ctx, false), cache}
  end

  defp check(check, _args, _ctx, cache),
    do: {fail("unbound", "#{check} has no Phoenix binding"), cache}

  defp evaluate([], binding, ctx, _bubble?),
    do: fail(binding, "no result names #{ctx.task.id}: pass the results with --evidence")

  defp evaluate(_results, binding, %{app: nil}, _bubble?),
    do: fail(binding, "evaluating results needs the Bubble app ID (--app)")

  defp evaluate(results, binding, ctx, bubble?) do
    refs = Enum.map(results, fn {ref, sha, _} -> %{ref: ref, sha256: sha} end)
    resolved = ctx.resolved || %Resolved{}

    failures =
      for {ref, _sha, r} <- results,
          reason = verdict(r, resolved, ctx, bubble?),
          reason != nil,
          do: "#{ref}: #{reason}"

    if failures == [],
      do: %{pass(binding, "#{length(results)} results count") | refs: refs},
      else: %{fail(binding, summary(failures)) | refs: refs}
  end

  defp verdict(r, resolved, ctx, bubble?) do
    opts = [
      app: ctx.app,
      now: ctx.now,
      reviewers: ctx.reviewers,
      recording: recording(ctx.root, r)
    ]

    case Result.evaluate(r, resolved, opts) do
      {:ok, %{passing: false, result: linked}} -> "status #{linked.status} does not count"
      {:ok, %{bubble_verified: false}} when bubble? -> "not Bubble-verified"
      {:ok, _} -> nil
      {:error, %BubbleEx.Error{message: m}} -> m
    end
  end

  defp recording(root, %Result{oracle: %{kind: kind}, scenario: %{id: id}})
       when kind in [:bubble, :model] and is_binary(id) do
    with {:ok, text} <-
           File.read(Path.join([root, ".wtf/verification/recordings", id <> ".json"])),
         {:ok, rec} <- Recording.from_json(text) do
      rec
    else
      _ -> nil
    end
  end

  defp recording(_root, _r), do: nil

  # --- tagged tests ------------------------------------------------------------------

  defp tagged([], ctx, cache), do: tagged([ctx.task.id], ctx, cache)

  # Every subject needs its own passing tests (one run per subject: AND,
  # not the OR of several --only filters). Only mix's exit status counts:
  # it is non-zero when a test fails and when no test ran; the summary
  # line is output the tests control, and its format changes between
  # Elixir versions.
  defp tagged(subjects, ctx, cache) do
    {tags, cache} = test_tags(ctx, cache)
    binding = "mix test --only bubble:<subject>, per subject"

    case Enum.reject(subjects, &MapSet.member?(tags, &1)) do
      [] ->
        {outcomes, cache} = Enum.map_reduce(subjects, cache, &subject_tests(&1, ctx, &2))

        case Enum.find(outcomes, &(&1.status == :fail)) do
          nil -> {pass(binding, "tests pass for " <> summary(subjects)), cache}
          failed -> {%{failed | binding: binding}, cache}
        end

      untagged ->
        {fail(binding, "no test tagged bubble: " <> summary(untagged)), cache}
    end
  end

  defp subject_tests(subject, ctx, cache) do
    memo(cache, {:tests, subject}, fn ->
      outcome = mix(ctx, ["test", "--only", "bubble:" <> subject], [{"MIX_ENV", "test"}])

      if outcome.status == :fail,
        do: %{outcome | detail: "#{subject}: #{outcome.detail} (a test failed or none ran)"},
        else: outcome
    end)
  end

  # The `bubble:` tags of test/, read from the parsed code: @tag,
  # @moduletag and @describetag with a `bubble: "<subject>"` entry.
  defp test_tags(ctx, cache) do
    memo(cache, :test_tags, fn ->
      for path <- files(ctx.root, "test/**/*.{exs,ex}"),
          {:ok, ast} <- [Code.string_to_quoted(File.read!(path))],
          subject <- tags(ast),
          into: MapSet.new(),
          do: subject
    end)
  end

  defp tags(ast) do
    ast
    |> Macro.prewalk([], fn
      {:@, _, [{attr, _, [value]}]} = node, acc when attr in [:tag, :moduletag, :describetag] ->
        {node, bubble_tags(value) ++ acc}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp bubble_tags(value) when is_list(value) do
    for {:bubble, subject} <- value, is_binary(subject), do: subject
  end

  defp bubble_tags(_), do: []

  # --- source scans ------------------------------------------------------------------

  # [{relative path, text}] of lib/, comments removed (HEEx, HTML and
  # Elixir): a marker in a comment traces nothing.
  defp sources(ctx, cache) do
    memo(cache, :sources, fn ->
      for path <- files(ctx.root, "lib/**/*.{ex,exs,heex,eex}"),
          do: {Path.relative_to(path, ctx.root), path |> File.read!() |> uncommented(path)}
    end)
  end

  # The raw text of lib/ (placeholders live in comments).
  defp raw_sources(ctx, cache) do
    memo(cache, :raw_sources, fn ->
      for path <- files(ctx.root, "lib/**/*.{ex,exs,heex,eex}"),
          do: {Path.relative_to(path, ctx.root), File.read!(path)}
    end)
  end

  defp uncommented(text, path) do
    text = if Path.extname(path) in [".ex", ".exs"], do: without_elixir_comments(text), else: text
    Regex.replace(~r/<%!--.*?--%>|<%#.*?%>|<!--.*?-->/s, text, "")
  end

  defp without_elixir_comments(text) do
    case Code.string_to_quoted_with_comments(text) do
      {:ok, _ast, comments} ->
        # A comment runs from its column to the end of its line.
        column = Map.new(comments, &{&1.line, &1.column})

        text
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {line, n} -> before_column(line, column[n]) end)

      _ ->
        text
    end
  end

  defp before_column(line, nil), do: line

  defp before_column(line, col),
    do: line |> String.to_charlist() |> Enum.take(col - 1) |> List.to_string()

  defp traced?(sources, id) do
    bubble = Regex.escape(bubble_id(id))

    Enum.any?(sources, fn {_, text} ->
      Regex.match?(~r/data-bubble-id=["']#{bubble}["']/, text)
    end)
  end

  defp surface?(id), do: String.starts_with?(id, ["page:", "reusable:"])

  # A placeholder for the element itself, or, for a page or reusable,
  # anywhere in a file tracing it.
  defp placeholder_in?({text, uncommented}, id) do
    String.contains?(text, "TODO(bubble:#{bubble_id(id)})") or
      (surface?(id) and traced?([{nil, uncommented}], id))
  end

  # workflow Bubble ID => [{path, [{n, type}]}], from the comments of lib/**/*.ex.
  defp markers(ctx, cache) do
    memo(cache, :markers, fn ->
      for path <- files(ctx.root, "lib/**/*.{ex,exs}"),
          {id, steps} <- file_markers(File.read!(path)),
          reduce: %{} do
        acc -> Map.update(acc, id, [{path, steps}], &(&1 ++ [{path, steps}]))
      end
    end)
  end

  defp file_markers(source) do
    case Code.string_to_quoted_with_comments(source) do
      {:ok, _ast, comments} ->
        comments
        |> Enum.map(&String.trim(String.trim_leading(&1.text, "#")))
        |> Enum.reduce([], &marker/2)
        |> Enum.reverse()

      _ ->
        []
    end
  end

  # Workflow markers open a block; step markers join the open one.
  defp marker(text, acc) do
    case {Regex.run(~r/\Abubble:workflow\s+(\S+)/, text),
          Regex.run(~r/\Abubble:step\s+(\d+)\s+(\S+)/, text), acc} do
      {[_, id], _, acc} ->
        [{id, []} | acc]

      {_, [_, n, type], [{id, steps} | rest]} ->
        [{id, steps ++ [{String.to_integer(n), type}]} | rest]

      _ ->
        acc
    end
  end

  defp steps_text([]), do: "none"
  defp steps_text(steps), do: Enum.map_join(steps, ", ", fn {n, type} -> "#{n} #{type}" end)

  defp manifest_outcome(binding, %{clean?: true} = report),
    do: pass(binding, "#{length(report.unchanged)} generated files unchanged")

  defp manifest_outcome(binding, report) do
    changes =
      Enum.map(report.modified, &"modified #{&1}") ++ Enum.map(report.missing, &"missing #{&1}")

    fail(binding, summary(changes))
  end

  # --- helpers -----------------------------------------------------------------------

  defp mix(ctx, args, env \\ []) do
    binding = Enum.join(["mix" | args], " ")
    {output, status} = ctx.cmd.(args, env)

    if status == 0,
      do: pass(binding, nil),
      else: %{fail(binding, "exit status #{status}") | output: tail(output)}
  end

  defp tail(output),
    do: output |> String.split("\n") |> Enum.take(-40) |> Enum.join("\n")

  defp files(root, pattern), do: root |> Path.join(pattern) |> Path.wildcard() |> Enum.sort()

  defp memo(cache, key, fun) do
    case cache do
      %{^key => value} ->
        {value, cache}

      _ ->
        value = fun.()
        {value, Map.put(cache, key, value)}
    end
  end

  defp list(args, key) do
    case args[key] do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  # "element:bTx" -> "bTx"; a bare ID stays as it is.
  defp bubble_id(nil), do: ""

  defp bubble_id(id) do
    case String.split(id, ":", parts: 2) do
      [_kind, bubble] -> bubble
      [bubble] -> bubble
    end
  end

  defp summary(items) do
    {shown, rest} = Enum.split(items, 10)
    Enum.join(shown, ", ") <> if(rest == [], do: "", else: " and #{length(rest)} more")
  end

  defp pass(binding, detail),
    do: %{
      status: :pass,
      binding: binding,
      detail: detail,
      refs: [],
      output: nil,
      advisory: false
    }

  defp fail(binding, detail),
    do: %{
      status: :fail,
      binding: binding,
      detail: detail,
      refs: [],
      output: nil,
      advisory: false
    }

  defp manifest(ctx) do
    case File.read(Path.join(ctx.root, Manifest.path())) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, %BubbleEx.Error{message: "no #{Manifest.path()}"}}
      {:error, reason} -> {:error, %BubbleEx.Error{message: inspect(reason)}}
    end
  end
end
