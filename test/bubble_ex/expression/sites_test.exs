defmodule BubbleEx.Expression.SitesTest do
  # Expression sites and the compile report over the synthetic expression
  # fixture (WTF-368).
  use ExUnit.Case, async: true

  import BubbleEx.Test.ExpressionFixture

  alias BubbleEx.Diagnostic
  alias BubbleEx.Expression.Sites
  alias BubbleEx.Target.CompileReport

  setup_all do
    model = model()
    {:ok, sites} = Sites.collect(app(), model)
    %{model: model, project: project(model), sites: sites}
  end

  defp site(sites, pointer), do: Enum.find(sites, &(Diagnostic.pointer(&1.path) == pointer))

  test "finds every outermost expression with its host", %{sites: sites} do
    pointers = Enum.map(sites, &Diagnostic.pointer(&1.path))
    assert pointers == Enum.sort(pointers)
    assert length(sites) == 19

    assert %{kind: :element, env: %{host: "bT1"}} =
             site(sites, "/pages/task/elements/bG1/elements/bT1/properties/text")

    assert %{kind: :element, env: %{host: "bT3"}} =
             site(sites, "/pages/task/elements/bR1/elements/bT3/states/0/condition")
  end

  test "workflow sites know their element, steps, trigger and subject", %{sites: sites} do
    %{env: env, kind: :workflow} = site(sites, "/pages/task/workflows/bW1/properties/condition")
    assert env.host == "bB1"
    assert env.steps == %{"bA1" => "custom.task"}
    assert env.subject == %{workflow: "bW1"}

    %{env: trigger} = site(sites, "/api/bW8/properties/condition")
    assert trigger.trigger_type == "custom.task"
  end

  test "the compile report counts by stage", %{model: model, project: project} do
    {:ok, report} = CompileReport.build(app(), model, project)

    assert report["privacy"] == %{
             "rules" => 38,
             "rules_without_condition" => 5,
             "conditions" => 33,
             "ash_compiled" => 30,
             "ash_with_actor_loads" => 3,
             "diagnostics" => %{
               "ash_expr_unmapped_reference" => 1,
               "ash_expr_unsupported" => 1,
               "expr_option_by_id" => 1,
               "expr_uncompiled" => 1
             },
             "unsupported" => %{
               "ash_expr_unmapped_reference:the data type" => 1,
               "ash_expr_unsupported:a field of first" => 1,
               "expr_uncompiled:raw" => 1
             }
           }

    expressions = report["expressions"]
    assert expressions["roots"] == 19
    assert expressions["by_kind"] == %{"element" => 13, "workflow" => 6}
    assert expressions["ir_compiled"] == 16
    assert expressions["elixir_compiled"] == 15
    assert expressions["searches_ash_compiled"] == expressions["searches"]

    assert expressions["unsupported"]["ir"] == %{
             "expr_uncompiled:ignore_empty_constraints" => 1,
             "expr_unresolved_accessor" => 1,
             "expr_untyped_scope:previous_step" => 1
           }

    assert CompileReport.build(app(), model, project) == {:ok, report}

    assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
             CompileReport.build(nil, model, project)

    assert {:error, %BubbleEx.Error{}} = Sites.collect([], model)
  end
end
