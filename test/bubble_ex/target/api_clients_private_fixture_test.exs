defmodule BubbleEx.Target.ApiClientsPrivateFixtureTest do
  # WTF-374 against a real app, like BubbleEx.Target.AshPrivateFixtureTest.
  # Excluded by default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
  #
  # The Spec's counts (`BubbleEx.Target.ApiClients.Spec.summary/1`: calls
  # generated and in residue, residue reasons, environment variables by
  # kind) are compared with a committed count snapshot, by default
  # mm-137's. The snapshot holds counts only. Update it with a reason:
  #
  #     BUBBLE_EX_UPDATE_COUNTS=1 BUBBLE_EX_PRIVATE_EXPORT=… mix test --only private_fixture
  #
  # BUBBLE_EX_API_CLIENT_COUNTS names another snapshot file. It also checks
  # that no parameter value of the export reaches the generated files.
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Model}
  alias BubbleEx.Model.ConnectorRequest.Reader
  alias BubbleEx.Target.{ApiClients, Phoenix}
  alias BubbleEx.Target.ApiClients.Spec
  alias BubbleEx.Test.SplitExport

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  @default_snapshot "test/support/target/api_clients/counts/mm-137.json"

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    app = SplitExport.load(path)
    {:ok, model} = Model.build(app)
    {:ok, spec} = ApiClients.map(model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, files} = Phoenix.render(project, name: "Private", api_clients: spec)
    generated = Map.filter(files, fn {path, _} -> String.contains?(path, "api_clients") end)
    %{app: app, spec: spec, generated: generated}
  end

  test "matches the recorded count snapshot", %{spec: spec} do
    snapshot = System.get_env("BUBBLE_EX_API_CLIENT_COUNTS") || @default_snapshot
    counts = Spec.summary(spec)

    IO.puts(
      "\napi clients: " <> (counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true))
    )

    if System.get_env("BUBBLE_EX_UPDATE_COUNTS") do
      File.mkdir_p!(Path.dirname(snapshot))

      File.write!(
        snapshot,
        (%{"counts" => counts} |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"
      )
    end

    recorded = snapshot |> File.read!() |> Jason.decode!()
    assert counts == recorded["counts"], "counts changed; update #{snapshot} with a reason"
  end

  test "no parameter value reaches the generated files", %{app: app, generated: generated} do
    values = parameter_values(app)
    text = generated |> Map.values() |> Enum.join("\n")

    leaked = Enum.filter(values, &String.contains?(text, &1))
    assert leaked == [], "#{length(leaked)} parameter values reach the generated files"

    for {path, source} <- generated,
        do: assert(BubbleEx.Secrets.Native.Detectors.scan_value(source) == [], path)
  end

  # Every private header and parameter value, and every other one that
  # could be a credential (that the request template would redact), long
  # enough to be distinctive. Never printed: the assertion reports a count.
  defp parameter_values(app) do
    groups = get_in(app, ["settings", "client_safe", "apiconnector2"]) || %{}

    for {_, group} <- groups,
        is_map(group),
        owner <- [group | Map.values(Map.get(group, "calls") || %{})],
        is_map(owner),
        {_, params} <- owner,
        is_map(params),
        {_, param} <- params,
        is_map(param),
        value <- [param["value"], param["%v"]],
        is_binary(value) and String.length(value) >= 6,
        param["private"] == true or not Reader.safe_text?(value),
        uniq: true,
        do: value
  end
end
