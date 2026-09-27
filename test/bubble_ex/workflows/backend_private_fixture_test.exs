defmodule BubbleEx.Workflows.BackendPrivateFixtureTest do
  # Backend workflow lowering coverage on a real app (WTF-373). Excluded by
  # default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
  #
  # Counts only (no names or IDs) are compared with a committed snapshot,
  # by default the mm-137 test version's: the IR-level coverage of
  # `BubbleEx.Workflows.Backend.coverage/1` and the generated-code coverage
  # of `BubbleEx.Target.Ash.Workflows.Spec.coverage/1` (see their docs for
  # the metric). A changed count means updating the snapshot, with the
  # reason in the PR:
  #
  #     BUBBLE_EX_UPDATE_COUNTS=1 BUBBLE_EX_PRIVATE_EXPORT=… mix test --only private_fixture
  #
  # BUBBLE_EX_WORKFLOW_COUNTS names another snapshot file. That the
  # generated app compiles and its workflow tests pass is checked by
  # scripts/phoenix_compile_check.sh with the same BUBBLE_EX_PRIVATE_EXPORT.
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Index, Model, Plan}
  alias BubbleEx.Target.{Ash, Phoenix}
  alias BubbleEx.Target.Ash.Workflows
  alias BubbleEx.Target.Ash.Workflows.Spec
  alias BubbleEx.Test.SplitExport
  alias BubbleEx.Workflows.Backend

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  @default_snapshot "test/support/target/workflows/counts/mm-137.json"

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    app = SplitExport.load(path)
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, backend} = Backend.build(app, model, index)
    {:ok, project} = Ash.map(model, [], privacy: :omit)
    {:ok, spec} = Workflows.map(backend, project, namespace: "Acme")
    %{app: app, model: model, index: index, backend: backend, project: project, spec: spec}
  end

  test "matches the recorded count snapshot", %{backend: backend, spec: spec} do
    snapshot = System.get_env("BUBBLE_EX_WORKFLOW_COUNTS") || @default_snapshot
    counts = %{"lowering" => Backend.coverage(backend), "generated" => Spec.coverage(spec)}

    IO.puts("""

    backend workflow coverage:
    #{counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)}
    """)

    if System.get_env("BUBBLE_EX_UPDATE_COUNTS") do
      File.mkdir_p!(Path.dirname(snapshot))

      File.write!(
        snapshot,
        (counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"
      )
    end

    assert counts == snapshot |> File.read!() |> Jason.decode!(),
           "counts changed; update #{snapshot} with a reason"
  end

  test "every workflow gets an entry point; residue is itemized, never dropped",
       %{backend: backend, spec: spec} do
    assert length(Spec.actions(spec)) == length(backend.workflows)

    for w <- backend.workflows, step <- w.steps do
      assert step.op != nil or step.residue != [], "#{step.id} has neither a lowering nor residue"
    end

    for action <- Spec.actions(spec), step <- action.steps do
      assert step.residue != [] or step.args != %{} or step.op == :terminate
    end
  end

  test "only workflows that ignore privacy rules bypass authorization", %{
    backend: backend,
    spec: spec
  } do
    own = for w <- backend.workflows, w.ignores_privacy?, do: w.bubble_id
    assert spec.privacy_bypasses == Enum.sort(own)

    for action <- Spec.actions(spec), action.authorize == false do
      assert action.workflow in own
    end
  end

  test "sample requests of detect-data workflows never reach any output",
       %{app: app, model: model, index: index, backend: backend, project: project, spec: spec} do
    samples =
      for {_, w} <- app["api"] || %{},
          is_map(w),
          sample = get_in(w, ["properties", "raw_data"]),
          is_binary(sample) and byte_size(sample) > 8,
          do: sample

    # The credential-like values inside them (authorization headers,
    # tokens, keys, signatures), as well as each whole sample.
    secrets =
      samples
      |> Enum.flat_map(fn sample ->
        case Jason.decode(sample) do
          {:ok, decoded} -> [sample | credentials(decoded)]
          _ -> [sample]
        end
      end)
      |> Enum.uniq()

    {:ok, files} = Phoenix.render(project, name: "Acme", module: "Acme", workflows: spec)
    {:ok, plan} = Plan.build(model, index, nil, [], residue: Backend.residue(backend))

    outputs = [
      files |> Map.values() |> Enum.join("\n"),
      inspect(spec, limit: :infinity, printable_limit: :infinity),
      inspect(backend, limit: :infinity, printable_limit: :infinity),
      inspect(spec.diagnostics ++ backend.diagnostics,
        limit: :infinity,
        printable_limit: :infinity
      ),
      Plan.to_json(plan)
    ]

    for secret <- secrets, output <- outputs do
      refute String.contains?(output, secret), "a sample request's credential reached the output"
    end
  end

  @credential ~r/auth|token|secret|key|signature|password|cookie/i

  defp credentials(map) when is_map(map) do
    Enum.flat_map(map, fn
      {k, v} when is_binary(v) and byte_size(v) >= 8 ->
        if Regex.match?(@credential, k), do: [v | bearer(v)], else: []

      {_k, v} ->
        credentials(v)
    end)
  end

  defp credentials(list) when is_list(list), do: Enum.flat_map(list, &credentials/1)
  defp credentials(_), do: []

  defp bearer("Bearer " <> token) when byte_size(token) >= 8, do: [token]
  defp bearer(_), do: []

  test "deterministic", %{backend: backend, project: project, spec: spec} do
    assert Workflows.map(backend, project, namespace: "Acme") == {:ok, spec}
  end
end
