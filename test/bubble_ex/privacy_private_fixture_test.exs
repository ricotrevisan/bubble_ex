defmodule BubbleEx.PrivacyPrivateFixtureTest do
  # Acceptance against a real app's privacy rules and workflow expressions.
  # Real-app captures stay private (see docs/workflows.md), so this reads a
  # local export named by BUBBLE_EX_PRIVATE_EXPORT and is excluded by default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
  #
  # The path is either a decoded `.bubble` app JSON file or a split export
  # directory (`data_types/<id>/type.json`, plus `pages/`, `api/`,
  # `element-definitions/` JSON for expression samples).
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Expression, Privacy}
  alias BubbleEx.Expression.Ast

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    {app, expression_docs} = load(path)
    {:ok, privacy} = Privacy.parse(app)
    %{app: app, privacy: privacy, expressions: Enum.reduce(expression_docs, [], &roots/2)}
  end

  test "every privacy rule is structured or has itemized diagnostics", %{privacy: privacy} do
    rules = for type <- privacy.data_types, rule <- type.rules, do: rule
    # A live payload never carries privacy rules; its types are unavailable.
    assert rules != [] or Enum.all?(privacy.data_types, &(&1.availability == :unavailable))

    for rule <- rules, rule.condition do
      errors = Enum.count(rule.diagnostics, &(&1.severity == :error))
      assert unmodeled_nodes(rule.condition) <= errors, rule.path
    end

    IO.puts(
      "\nprivacy: #{length(privacy.data_types)} types, #{length(rules)} rules, " <>
        "#{length(privacy.diagnostics)} diagnostics, nodes #{inspect(counts(Enum.map(rules, & &1.condition)))}"
    )
  end

  test "every privacy condition round-trips", %{app: app, privacy: privacy} do
    for type <- privacy.data_types, rule <- type.rules, rule.condition do
      source = app["user_types"][type.id]["privacy_role"][rule.id]["condition"]
      assert_round_trip(source, rule.condition, rule.path)
    end
  end

  test "workflow and page expressions round-trip deterministically", %{
    app: app,
    expressions: roots
  } do
    {:ok, model} = BubbleEx.Model.build(app)
    schema = BubbleEx.Model.schema(model)
    assert roots != []

    asts =
      for raw <- roots do
        {:ok, a} = Expression.parse(raw, schema: schema)
        {:ok, b} = Expression.parse(raw, schema: schema)
        assert Expression.sha256(a.ast) == Expression.sha256(b.ast)
        assert_round_trip(raw, a.ast, "expression")
        assert unmodeled_nodes(a.ast) <= Enum.count(a.diagnostics, &(&1.severity == :error))
        a.ast
      end

    IO.puts("\nexpressions: #{length(roots)} roots, nodes #{inspect(counts(asts))}")
  end

  defp assert_round_trip(source, ast, label) do
    {:ok, encoded} = Expression.to_bubble(ast)
    assert CanonicalJson.sha256(encoded) == CanonicalJson.sha256(source), label
  end

  defp unmodeled_nodes(ast) do
    {:ok, counts} = Expression.node_counts(ast)
    Map.get(counts, "raw", 0)
  end

  defp counts(asts) do
    asts
    |> Enum.filter(&Ast.node?/1)
    |> Enum.map(&elem(Expression.node_counts(&1), 1))
    |> Enum.reduce(%{}, &Map.merge(&1, &2, fn _, a, b -> a + b end))
  end

  defp load(path) do
    if File.dir?(path) do
      types =
        Map.new(Path.wildcard(Path.join(path, "data_types/*/type.json")), fn file ->
          {file |> Path.dirname() |> Path.basename(), decode(file)}
        end)

      docs = path |> Path.join("{pages,api,element-definitions}/**/*.json") |> Path.wildcard()
      {%{"user_types" => types}, Stream.map(docs, &decode/1)}
    else
      app = decode(path)
      {app, [Map.take(app, ~w(pages element_definitions api %p3 %ed))]}
    end
  end

  defp decode(file), do: file |> File.read!() |> Jason.decode!()

  # Outermost expression objects: text expressions and operator chains.
  defp roots(value, acc) when is_map(value) do
    if expression_root?(value),
      do: [value | acc],
      else: Enum.reduce(value, acc, fn {_, child}, a -> roots(child, a) end)
  end

  defp roots(value, acc) when is_list(value), do: Enum.reduce(value, acc, &roots/2)
  defp roots(_, acc), do: acc

  defp expression_root?(value) do
    type = value["type"] || value["%x"]
    next = value["next"] || value["%n"]

    type == "TextExpression" or
      (is_binary(type) and is_map(next) and (next["type"] || next["%x"]) == "Message")
  end
end
