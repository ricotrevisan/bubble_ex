defmodule BubbleEx.Target.ElixirTest do
  # The Elixir backend of the expression compiler (WTF-368): compiled
  # sources for the fixture's constructs, evaluated against records with a
  # stand-in runtime so the output is proved to be valid Elixir with Bubble
  # semantics, plus the negative cases.
  use ExUnit.Case, async: true

  import BubbleEx.Test.ExpressionFixture

  alias BubbleEx.Expression.{Compiler, IR}
  alias BubbleEx.Target.Elixir, as: Target

  defmodule Runtime do
    @moduledoc false
    # A minimal stand-in for the generated app's runtime.
    def text(nil), do: ""
    def text(true), do: "yes"
    def text(false), do: "no"
    def text(x) when is_float(x) and x == trunc(x), do: Integer.to_string(trunc(x))
    def text(x), do: to_string(x)
    def empty?(x), do: x in [nil, "", []]
    def add(a, b), do: (a || 0) + (b || 0)
    def mul(a, b), do: (a || 0) * (b || 0)
    def compare(_op, nil, _), do: false
    def compare(_op, _, nil), do: false
    def compare(:gt, a, b), do: a > b
    def uppercase(x), do: x && String.upcase(x)
    def default(x, d), do: if(empty?(x), do: d, else: x)
  end

  @runtime inspect(Runtime)

  setup_all do
    %{project: project()}
  end

  defp compile(raw, project, opts \\ []) do
    env = env(opts)
    {:ok, %{ir: %IR{} = ir}} = Compiler.compile(parse!(raw, env), env)
    {:ok, result} = Target.compile(ir, project, runtime: @runtime)
    result
  end

  defp eval(%{source: source}, binding) do
    {value, _} = Code.eval_string(source, binding)
    value
  end

  test "dynamic text with a parent group's field", %{project: project} do
    result =
      compile(text(["Title: ", chain(src("ElementParent"), [msg("title_text")])]), project,
        host: "bT1"
      )

    expected =
      ~s|"Title: " <> #{@runtime}.text(get_in(element_state_bg1_get_group_data, [Access.key(:title)]))|

    assert result.source == expected |> Code.format_string!() |> IO.iodata_to_binary()

    assert [
             %{
               var: "element_state_bg1_get_group_data",
               input: {:element_state, _},
               type: "custom.task"
             }
           ] = result.bindings

    assert result.runtime == [:text]
    assert eval(result, element_state_bg1_get_group_data: %{title: "Plan"}) == "Title: Plan"
    assert eval(result, element_state_bg1_get_group_data: nil) == "Title: "
  end

  test "arithmetic on an input's value", %{project: project} do
    result =
      compile(text(["Total: ", chain(el("bI1"), [msg("get_data"), msg("plus", 1)])]), project)

    assert eval(result, element_state_bi1_get_data: 2.0) == "Total: 3"
  end

  test "records compare by ID, empty equals empty", %{project: project} do
    raw = chain(src("CurrentDataItem"), [msg("assignee_user"), msg("equals", cu())])
    result = compile(raw, project, host: "bT3")

    assert eval(result, cell_thing_br1: %{assignee_id: "u1"}, current_user: %{id: "u1"})
    refute eval(result, cell_thing_br1: %{assignee_id: "u2"}, current_user: %{id: "u1"})
    assert eval(result, cell_thing_br1: %{assignee_id: nil}, current_user: nil)
  end

  test "field paths through relationships record their loads", %{project: project} do
    raw =
      chain(cu(), [
        msg("current_role_custom_role"),
        msg("workspace_custom_workspace"),
        msg("name_text")
      ])

    result = compile(raw, project)

    assert result.loads == %{"current_user" => [["current_role", "workspace"]]}
    user = %{current_role: %{workspace: %{name: "Acme"}}}
    assert eval(result, current_user: user) == "Acme"
    assert eval(result, current_user: nil) == nil
  end

  test "conditions, options and option labels", %{project: project} do
    done =
      chain(src("CurrentPageItem"), [
        msg("status_option_status"),
        msg("equals", opt("status", "done"))
      ])

    result = compile(chain(cu(), [msg("logged_in"), msg("and_", done)]), project, host: "bT4")
    assert eval(result, current_user: %{id: "u"}, page_thing_bp1: %{status: "done"})
    refute eval(result, current_user: nil, page_thing_bp1: %{status: "done"})

    label =
      compile(
        chain(src("CurrentPageItem"), [msg("status_option_status"), msg("display")]),
        project,
        host: "bT4"
      )

    assert label.source =~ "MyApp.Enums.Status.label("
  end

  test "ordering comparisons and yes/no values go through the runtime", %{project: project} do
    result =
      compile(
        chain(cu(), [
          msg("admin_boolean"),
          msg("and_", chain(el("bI1"), [msg("get_data"), msg("greater_than", 3)]))
        ]),
        project
      )

    assert eval(result, current_user: %{admin: true}, element_state_bi1_get_data: 4)
    refute eval(result, current_user: %{admin: nil}, element_state_bi1_get_data: 4)
    refute eval(result, current_user: %{admin: true}, element_state_bi1_get_data: nil)
  end

  test "a search is not compiled yet", %{project: project} do
    raw = chain(search("custom.task", []), [msg("count")])
    assert %{source: nil, diagnostics: [diag]} = compile(raw, project)
    assert diag.code == :elixir_expr_unsupported
    assert diag.stage == {:target, :elixir}
    assert diag.details == %{constructs: ["search"], at: []}
  end

  test "every compiled source parses and is deterministic", %{project: project} do
    raw =
      text([
        chain(src("CurrentDataItem"), [
          msg("title_text"),
          msg("to_uppercase"),
          msg("defaulting_to", "-")
        ])
      ])

    a = compile(raw, project, host: "bT3")
    assert a == compile(raw, project, host: "bT3")
    assert {:ok, _} = Code.string_to_quoted(a.source)
    assert eval(a, cell_thing_br1: %{title: "x"}) == "X"
    assert eval(a, cell_thing_br1: %{title: nil}) == "-"
  end
end
