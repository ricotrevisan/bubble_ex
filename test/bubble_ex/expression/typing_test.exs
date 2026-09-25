defmodule BubbleEx.Expression.TypingTest do
  # Typing (WTF-368) over the synthetic expression fixture: every context
  # source and accessor kind, the diagnostics for what stays untyped, and
  # that typing keeps the source (round trip) and is deterministic.
  use ExUnit.Case, async: true

  import BubbleEx.Test.ExpressionFixture

  alias BubbleEx.{CanonicalJson, Expression}
  alias BubbleEx.Expression.{Ast, Tree, Typing}
  alias BubbleEx.Expression.Ast.{Field, Property, Scope}

  defp typed(raw, opts) do
    env = env(opts)
    {:ok, %{ast: ast, diagnostics: diagnostics}} = Typing.type(parse!(raw, env), env)
    {ast, diagnostics}
  end

  describe "context sources" do
    test "parent group's thing is the nearest enclosing group's content type" do
      {ast, []} = typed(chain(src("ElementParent"), [msg("title_text")]), host: "bT1")
      assert %Field{field: "title_text", type: "text", subject: %Scope{type: "custom.task"}} = ast
    end

    test "inside a reusable, the parent group can be the reusable itself" do
      {ast, []} = typed(chain(src("ElementParent"), [msg("name_text")]), host: "bT9")
      assert %Field{type: "text", subject: %Scope{type: "custom.workspace"}} = ast
    end

    test "current cell's thing is the enclosing repeating group's item" do
      {ast, []} = typed(chain(src("CurrentDataItem"), [msg("assignee_user")]), host: "bT3")

      assert %Field{type: "user", subject: %Scope{kind: :current_cell_thing, type: "custom.task"}} =
               ast

      {index, []} = typed(src("CurrentCellsIndex"), host: "bT3")
      assert index.type == "number"
    end

    test "in a database trigger, thing now and before change are the triggering record" do
      for source <- ["CurrentDataItem", "OldDataItem"] do
        {ast, []} = typed(chain(src(source), [msg("title_text")]), trigger_type: "custom.task")
        assert %Field{type: "text", subject: %Scope{type: "custom.task"}} = ast
      end
    end

    test "current page's thing is the page's type" do
      {ast, []} = typed(chain(src("CurrentPageItem"), [msg("due_date")]), host: "bT4")
      assert %Field{type: "date"} = ast
    end

    test "a previous step has its step's result type" do
      raw = chain(src("PreviousStep", %{"action_id" => "bA1"}), [msg("estimate_number")])
      {ast, []} = typed(raw, steps: %{"bA1" => "custom.task"})
      assert %Field{type: "number", subject: %Scope{type: "custom.task"}} = ast
    end

    test "page data and URL parameters are typed by name" do
      {date, []} = typed(src("PageData", %{"name" => "Current Date/Time"}), [])
      assert date.type == "date"

      {param, []} = typed(src("GetParamFromUrl", %{"parameter_name" => text(["id"])}), [])
      assert param.type == "text"
    end

    test "an untyped context source is diagnosed" do
      {ast, [diag]} = typed(chain(src("ElementParent"), [msg("title_text")]), host: "bP1")
      assert %Property{type: nil} = ast
      assert diag.code == :expr_untyped_scope
      assert diag.stage == :model
      assert diag.details == %{scope: :parent_group, source: "ElementParent"}
    end
  end

  describe "element states" do
    test "values, visibility, reusable parameters and custom states" do
      cases = [
        {chain(el("bI1"), [msg("get_data")]), "number"},
        {chain(el("bI1"), [msg("is_visible")]), "boolean"},
        {chain(el("bG1"), [msg("get_group_data")]), "custom.task"},
        {chain(el("bR1"), [msg("get_list_data")]), "list.custom.task"},
        {chain(el("bR1"), [msg("page_number")]), "number"},
        {chain(el("bC1"), [msg("param_bPa")]), "text"},
        {chain(el("bC1"), [msg("custom.open_")]), "boolean"},
        {chain(el("bC1"), [msg("get_group_data")]), "custom.workspace"},
        {chain(el("bP1"), [msg("custom.flag_")]), "boolean"}
      ]

      for {raw, type} <- cases do
        assert {%Property{type: ^type}, []} = typed(raw, []), inspect(raw)
      end
    end

    test "This element reads the host's states" do
      assert {%Property{type: "boolean"}, []} =
               typed(chain(src("ThisElement"), [msg("is_hovered")]), host: "bT1")
    end

    test "a plugin element's state is unresolved" do
      {ast, [diag]} = typed(chain(el("bX1"), [msg("get_AAB")]), [])
      assert %Property{type: nil} = ast
      assert diag.code == :expr_unresolved_accessor
      assert diag.path == "/next"
    end
  end

  describe "accessors" do
    test "option attributes and labels" do
      {color, []} = typed(chain(opt("status", "done"), [msg("color")]), [])
      assert %Field{field: "color", type: "text"} = color

      {label, []} = typed(chain(opt("status", "done"), [msg("display")]), [])
      assert %Field{builtin: :display, type: "text"} = label
    end

    test "fields over a list map to a list" do
      {ast, []} =
        typed(chain(cu(), [msg("workspaces_list_custom_workspace"), msg("name_text")]), [])

      assert ast.type == "list.text"
    end

    test "known operators the parser keeps as accessors" do
      {ast, []} = typed(chain(cu(), [msg("name_text"), msg("to_lowercase")]), [])
      assert %Property{type: "text"} = ast
    end

    test "a :filtered list re-binds This Thing to its item type" do
      raw =
        chain(el("bR1"), [
          msg("get_list_data"),
          msg("filtered", nil, %{
            "constraints" => %{
              "0" =>
                con("_advanced_search_constraint", nil, chain(this(), [msg("public_boolean")]))
            }
          })
        ])

      {ast, []} = typed(raw, [])
      [constraint] = ast.constraints
      assert %Field{type: "boolean", subject: %{type: "custom.task"}} = constraint.value
    end
  end

  test "typing keeps the source and is deterministic" do
    raw = chain(src("ElementParent"), [msg("title_text"), msg("to_uppercase")])
    {a, _} = typed(raw, host: "bT1")
    {b, _} = typed(raw, host: "bT1")
    assert a == b
    {:ok, encoded} = Expression.to_bubble(a)
    assert CanonicalJson.encode(encoded) == CanonicalJson.encode(raw)
  end

  test "invalid input is an error, not a crash" do
    assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
             Typing.type(%{"type" => "CurrentUser"}, env())

    assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
             BubbleEx.Expression.Compiler.compile(:nope, env())
  end

  test "the tree records pages, reusables, elements and instances" do
    tree = Tree.build(app())

    assert %Tree.Node{kind: :page, content: "custom.task", states: %{"flag_" => "boolean"}} =
             Tree.node(tree, "bP1")

    assert %Tree.Node{kind: :reusable, params: %{"bPa" => "text"}} = Tree.node(tree, "bU1")
    assert %Tree.Node{instance_of: "bU1"} = Tree.node(tree, "bC1")
    assert Enum.map(Tree.ancestors(tree, "bT3"), & &1.id) == ["bR1", "bP1"]
    assert Ast.node?(parse!(cu(), env()))
  end
end
