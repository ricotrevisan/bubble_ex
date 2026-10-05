defmodule BubbleEx.Target.Elixir.ShapesTest do
  # WTF-500: compiled page code never raises on a value's shape. Every list
  # read goes through the runtime's `as_list/1` (a field the user may not
  # view, `%Ash.ForbiddenField{}` in the generated app, is empty), the
  # current user's operands are checked with `empty?/1`, and a field of a
  # list of things is each item's. Evaluated with a stand-in runtime whose
  # `Hidden` struct plays the forbidden field.
  use ExUnit.Case, async: true

  import BubbleEx.Test.ExpressionFixture, only: [project: 0]

  alias BubbleEx.Expression.IR
  alias BubbleEx.Target.Elixir, as: Target

  defmodule Hidden do
    @moduledoc false
    defstruct field: nil
  end

  defmodule Runtime do
    @moduledoc false
    alias BubbleEx.Target.Elixir.ShapesTest.Hidden

    def empty?(%Hidden{}), do: true
    def empty?(x), do: x in [nil, "", []]
    def as_list(x) when is_list(x), do: x
    def as_list(x), do: if(empty?(x), do: [], else: [x])
  end

  @runtime inspect(Runtime)

  setup_all do
    %{project: project()}
  end

  defp compile!(ir, project) do
    {:ok, %{source: source} = result} = Target.compile(ir, project, runtime: @runtime)
    assert is_binary(source), inspect(result.diagnostics)
    result
  end

  defp eval(%{source: source}, binding) do
    {value, _} = Code.eval_string(source, binding)
    value
  end

  defp lit(v, type), do: IR.node(:literal, [v], type)
  defp this, do: IR.node(:this, [:page], "custom.task")
  defp user, do: IR.node(:current_user, [], "user")

  test "count, first item and contains of a hidden list are empty, never a raise",
       %{project: project} do
    access = IR.node(:field, [this(), "task", "access_list_user"], "list.user")

    count = compile!(IR.node(:count, [access], "number"), project)
    refute count.source =~ "|| []"
    assert eval(count, this: %{access: %Hidden{}}) == 0
    assert eval(count, this: %{access: nil}) == 0
    assert eval(count, this: %{access: ["u1", "u2"]}) == 2

    first = compile!(IR.node(:first, [access], "user"), project)
    assert eval(first, this: %{access: %Hidden{}}) == nil

    member = compile!(IR.node(:member, [access, lit("u1", "user")], "boolean"), project)
    refute eval(member, this: %{access: %Hidden{}})
    assert eval(member, this: %{access: ["u1"]})
  end

  test "a field of a list of things is each item's: one list, empty values dropped",
       %{project: project} do
    tasks = IR.node(:input, [:step, %{step: "bS1"}], "list.custom.task")
    titles = IR.node(:field, [tasks, "task", "title_text"], "list.text")
    result = compile!(titles, project)
    [%{var: var}] = result.bindings

    # get_in/2 on the list itself raised (BadMapError on []).
    for empty <- [[], nil] do
      assert eval(result, [{String.to_atom(var), empty}]) == []
    end

    tasks_value = [%{title: "Alpha"}, %{title: nil}, %{title: %Hidden{}}, %{title: "Bravo"}]
    assert eval(result, [{String.to_atom(var), tasks_value}]) == ["Alpha", "Bravo"]
  end

  test "the current user's hidden field is empty in a comparison, in either polarity",
       %{project: project} do
    name = IR.node(:field, [user(), "user", "name_text"], "text")

    for op <- [:eq, :neq] do
      ir = IR.node(op, [name, lit("Ada", "text")], "boolean")
      result = compile!(ir, project)
      refute result.source =~ "not in [nil"
      refute eval(result, current_user: %{name: %Hidden{}}), "#{op} on a hidden field"
    end

    is = compile!(IR.node(:eq, [name, lit("Ada", "text")], "boolean"), project)
    assert eval(is, current_user: %{name: "Ada"})
  end
end
