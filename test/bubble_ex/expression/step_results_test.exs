defmodule BubbleEx.Expression.StepResultsTest do
  # WTF-520: "Result of step N" is typed from the step's own definition,
  # per kind of step, in Bubble order; a step whose result is not known
  # stays untyped (never guessed).
  use ExUnit.Case, async: true

  import BubbleEx.Test.ExpressionFixture

  alias BubbleEx.Diagnostic
  alias BubbleEx.Expression.{Compiler, IR, Sites, Typing}
  alias BubbleEx.Expression.Ast.{Field, Property, Scope}
  alias BubbleEx.Workflows.Lowering
  alias BubbleEx.Workflows.Lowering.Return

  defp prev(action), do: src("PreviousStep", %{"action_id" => action})

  defp action(id, type, props \\ %{}), do: %{"id" => id, "type" => type, "properties" => props}

  # A custom event declaring a text, a thing, a list of things and a
  # return without a type.
  @event %{
    "id" => "wE",
    "type" => "CustomEvent",
    "properties" => %{
      "return_types" => %{
        "0" => %{"return_id" => "rT", "display" => "Text", "btype_id" => "text"},
        "1" => %{"return_id" => "rTask", "display" => "Task", "btype_id" => "custom.task"},
        "2" => %{
          "return_id" => "rTasks",
          "display" => "Tasks",
          "btype_id" => "custom.task",
          "is_list" => true
        },
        "3" => %{"return_id" => "rNone", "display" => "None"}
      }
    }
  }

  @quiet %{"id" => "wQ", "type" => "CustomEvent", "properties" => %{}}

  defp workflow do
    actions = [
      action("a1", "NewThing", %{"thing_type" => "custom.task"}),
      action("a2", "ChangeThing", %{"to_change" => prev("a1")}),
      action("a3", "ChangeThing", %{"to_change" => prev("a2")}),
      action("a4", "ChangeListOfThings", %{"type_to_change" => "custom.task"}),
      action("a5", "TriggerCustomEvent", %{"custom_event" => "wE"}),
      action("a6", "ScheduleAPIEvent", %{"api_event" => "wApi"}),
      action("a7", "apiconnector2-gA.cB"),
      action("a8", "1600000000000x100-act"),
      action("a9", "SignUp"),
      action("a10", "TriggerCustomEventFromReusable", %{"custom_event" => "wE"}),
      action("a11", "ChangeThing", %{"to_change" => chain(prev("a5"), [msg("rTask")])}),
      action("a12", "TriggerCustomEvent", %{"custom_event" => "wQ"}),
      action("a13", "TriggerCustomEvent", %{"custom_event" => "wMissing"}),
      action("a14", "ChangeThing", %{"to_change" => prev("a7")})
    ]

    %{
      "id" => "bWf",
      "type" => "ButtonClicked",
      "actions" =>
        actions |> Enum.with_index() |> Map.new(fn {a, i} -> {Integer.to_string(i), a} end)
    }
  end

  defp step_env do
    events = Sites.custom_events(%{"api" => %{"wE" => @event, "wQ" => @quiet}})
    Sites.workflow_env(workflow(), ["api", "bWf"], nil, env(custom_events: events))
  end

  defp typed(raw) do
    env = step_env()
    {:ok, %{ast: ast, diagnostics: diags}} = Typing.type(parse!(raw, env), env)
    {ast, Enum.map(diags, & &1.code)}
  end

  defp compiled(raw) do
    env = step_env()
    {:ok, %{ir: ir, diagnostics: diags}} = Compiler.compile(parse!(raw, env), env)
    {ir, diags}
  end

  test "each kind of step has its own result type, in Bubble order" do
    steps = step_env().steps

    assert steps["a1"] == "custom.task"
    # Make changes to an earlier step's result, and to that one's.
    assert steps["a2"] == "custom.task"
    assert steps["a3"] == "custom.task"
    assert steps["a4"] == "list.custom.task"
    assert steps["a9"] == "user"
    # Steps 10 and up come after step 2 (numeric order, not text order).
    assert steps["a11"] == "custom.task"

    assert {:returns, [%Return{id: "rT", type: "text"} | _] = returns} = steps["a5"]
    assert Enum.map(returns, & &1.type) == ["text", "custom.task", "list.custom.task", nil]
    assert {:returns, ^returns} = steps["a10"]

    # No result, or none known: Schedule API workflow, an API Connector
    # call, a plugin action, a custom event without returns or not found,
    # a change of an unknown result.
    for id <- ~w(a6 a7 a8 a12 a13 a14), do: refute(Map.has_key?(steps, id), id)
  end

  test "a changed thing's fields read through the chain" do
    {ast, []} = typed(chain(prev("a3"), [msg("title_text")]))
    assert %Field{type: "text", subject: %Scope{kind: :previous_step, type: "custom.task"}} = ast
  end

  test "a custom event's return value has its declared type" do
    {ast, []} = typed(chain(prev("a5"), [msg("rT")]))
    assert %Property{name: "rT", type: "text", subject: %Scope{type: nil}} = ast

    {ast, []} = typed(chain(prev("a5"), [msg("rTask"), msg("estimate_number")]))
    assert %Field{type: "number", subject: %Property{type: "custom.task"}} = ast

    {ast, []} = typed(chain(prev("a10"), [msg("rTasks")]))
    assert ast.type == "list.custom.task"
  end

  test "a return without a type, or not declared, is unresolved" do
    assert {_ast, [:expr_unresolved_accessor]} = typed(chain(prev("a5"), [msg("rNone")]))
    assert {_ast, [:expr_unresolved_accessor]} = typed(chain(prev("a5"), [msg("rOther")]))
  end

  test "a step whose result is unknown stays untyped" do
    for id <- ~w(a6 a7 a8 a12 a14) do
      assert {_ast, [:expr_untyped_scope]} = typed(chain(prev(id), [msg("title_text")])), id
    end
  end

  test "a return value compiles to the step's input, by return ID and type" do
    {ir, []} = compiled(chain(prev("a5"), [msg("rT")]))

    assert %IR{
             op: :input,
             type: "text",
             args: [:step_result, %{"action" => "a5", "return" => "rT", "type" => "text"}]
           } = ir

    {ir, []} = compiled(chain(prev("a5"), [msg("rTask"), msg("title_text")]))
    assert %IR{op: :field, args: [%IR{op: :input, args: [:step_result, ref]} | _]} = ir
    assert ref == %{"action" => "a5", "return" => "rTask", "type" => "custom.task"}

    {ir, []} = compiled(chain(prev("a3"), [msg("title_text")]))

    assert %IR{op: :field, args: [%IR{args: [:step_result, %{"action" => "a3"} = plain]} | _]} =
             ir

    refute Map.has_key?(plain, "return")
  end

  test "the return values as a whole are not a value" do
    {ir, diags} = compiled(prev("a5"))
    assert ir == nil
    assert [%Diagnostic{code: :expr_uncompiled, details: %{construct: :step_returns}}] = diags
  end

  test "steps are in numeric order; a length member is not a step" do
    entries = %{"0" => :a, "10" => :c, "2" => :b, "length" => 3}
    assert Lowering.ordered(entries) == [{"0", :a}, {"2", :b}, {"10", :c}]
  end

  test "custom events are found on pages, in reusable elements and in the backend" do
    page_event = Map.put(@event, "id", "wPage")
    reusable_event = Map.put(@quiet, "id", "wReusable")

    app = %{
      "pages" => %{
        "p" => %{
          "id" => "p",
          "workflows" => %{"wPage" => page_event, "wClick" => %{"type" => "ButtonClicked"}}
        }
      },
      "element_definitions" => %{
        "r" => %{"id" => "r", "workflows" => %{"wReusable" => reusable_event}}
      },
      "api" => %{"wE" => @event}
    }

    events = Sites.custom_events(app)
    assert events |> Map.keys() |> Enum.sort() == ~w(wE wPage wReusable)
    assert length(events["wPage"]) == 4
    assert events["wReusable"] == []
    assert Sites.custom_events(nil) == %{}
  end
end
