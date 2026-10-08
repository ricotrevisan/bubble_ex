defmodule BubbleEx.Target.ElixirTest do
  # The Elixir backend of the expression compiler (WTF-368): compiled
  # sources for the fixture's constructs, evaluated against records with a
  # stand-in runtime so the output is proved to be valid Elixir with Bubble
  # semantics, plus the negative cases.
  use ExUnit.Case, async: true

  import BubbleEx.Test.ExpressionFixture

  alias BubbleEx.Expression.{Compiler, IR}
  alias BubbleEx.Target.Elixir, as: Target

  defmodule Hidden do
    @moduledoc false
    # Plays `%Ash.ForbiddenField{}`: a field the user may not view.
    defstruct field: nil
  end

  defmodule Runtime do
    @moduledoc false
    # A minimal stand-in for the generated app's runtime.
    def text(nil), do: ""
    def text(true), do: "yes"
    def text(false), do: "no"
    def text(x) when is_float(x) and x == trunc(x), do: Integer.to_string(trunc(x))
    def text(x), do: to_string(x)
    def empty?(x), do: x in [nil, "", []]
    def add(a, b), do: a && b && a + b
    def mul(a, b), do: a && b && a * b
    def compare(_op, nil, _), do: false
    def compare(_op, _, nil), do: false
    def compare(:gt, a, b), do: a > b
    def compare(:lt, a, b), do: a < b
    def uppercase(x), do: x && String.upcase(x)
    def default(x, d), do: if(empty?(x), do: d, else: x)
    def as_list(x) when is_list(x), do: x
    def as_list(x), do: if(empty?(x), do: [], else: [x])
    def unhidden(""), do: nil
    def unhidden(x), do: x
    def id(%BubbleEx.Target.ElixirTest.Hidden{}), do: nil
    def id(""), do: nil
    def id(%{id: id}), do: id
    def id(id) when is_binary(id), do: id
    def id(_x), do: nil
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

  test "normalized list reads load the join relationship and preserve Bubble IDs" do
    %{model: model} = BubbleEx.Test.DecidedFixture.build(:join)
    {:ok, project} = BubbleEx.Test.DecidedFixture.project(:join)
    env = BubbleEx.Expression.Env.new(model, this_type: "custom.project", this_binder: :page)
    raw = chain(this(), [msg("tasks_list_custom_task")])
    {:ok, %{ir: list}} = Compiler.compile(parse!(raw, env), env)
    assert list.type == "list.custom.task"

    {:ok, result} = Target.compile(list, project, runtime: @runtime)

    assert result.diagnostics == []
    assert result.loads == %{"this" => [["tasks"]]}
    assert eval(result, this: %{tasks: [%{id: "t1"}, %{id: "t2"}]}) == ["t1", "t2"]
    assert eval(result, this: %{tasks: nil}) == []

    {:ok, count} = Target.compile(IR.node(:count, [list], "number"), project, runtime: @runtime)
    assert count.loads == %{"this" => [["tasks"]]}
    assert eval(count, this: %{tasks: [%{id: "t1"}]}) == 1

    {:ok, member} =
      Target.compile(
        IR.node(:member, [list, IR.node(:literal, ["t2"], "custom.task")], "boolean"),
        project,
        runtime: @runtime
      )

    assert eval(member, this: %{tasks: [%{id: "t1"}, %{id: "t2"}]})
  end

  test "frontend binding consumes a normalized list without losing its load" do
    app = BubbleEx.Test.DecidedFixture.app(:join)
    %{model: model} = BubbleEx.Test.DecidedFixture.build(:join)
    {:ok, project} = BubbleEx.Test.DecidedFixture.project(:join)

    node = %BubbleEx.Frontend.Normalized.Node{
      exporter_id: "page",
      kind: :page,
      map_key: "page",
      source: %BubbleEx.Frontend.Normalized.Source{},
      bindings: %{
        "text" => %{
          kind: :value,
          id: "favorites",
          payload: chain(cu(), [msg("favorites_list_custom_project")])
        }
      }
    }

    frontend = %BubbleEx.Frontend.Normalized{pages: [node], reusables: []}

    {:ok, %{"favorites" => compiled}} =
      BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend, runtime: @runtime)

    assert compiled.loads == %{"current_user" => [["favorites"]]}
    assert eval(compiled, current_user: %{favorites: [%{id: "p1"}]}) == ["p1"]
  end

  test "arithmetic on an input's value", %{project: project} do
    result =
      compile(text(["Total: ", chain(el("bI1"), [msg("get_data"), msg("plus", 1)])]), project)

    assert eval(result, element_state_bi1_get_data: 2.0) == "Total: 3"
  end

  # A runtime whose ordering answers nil on an empty side (the contract
  # asks for false; stubs and hand edits may not comply).
  defmodule LaxRuntime do
    @moduledoc false
    def compare(_op, nil, _), do: nil
    def compare(_op, _, nil), do: nil
    def compare(:gt, a, b), do: a > b
    def default(x, d), do: if(x in [nil, "", []], do: d, else: x)
  end

  # WTF-471: a condition used as a value is strictly true or false, never
  # nil: `(estimate > 3) defaulting to yes` on an empty estimate is no,
  # even when the runtime's comparison answers nil.
  test "a condition used as a value is never nil", %{project: project} do
    this = IR.node(:this, [:rule_record], "custom.task")
    estimate = IR.node(:field, [this, "task", "estimate_number"], "number")
    over = IR.node(:gt, [estimate, IR.node(:literal, [3.0], "number")], "boolean")
    yes = IR.node(:literal, [true], "boolean")
    ir = IR.node(:eq, [IR.node(:fallback, [over, yes], "boolean"), yes], "boolean")

    for runtime <- [@runtime, inspect(LaxRuntime)] do
      {:ok, result} = Target.compile(ir, project, runtime: runtime)

      refute eval(result, this: %{estimate: nil}), runtime
      assert eval(result, this: %{estimate: 5.0})
      refute eval(result, this: %{estimate: 1.0})
    end
  end

  test "a record held by an element compares by ID with a reference field", %{project: project} do
    this = IR.node(:this, [:rule_record], "custom.task")
    assignee = IR.node(:field, [this, "task", "assignee_user"], "user")
    held = IR.node(:input, [:element_state, %{"element" => "bG1", "state" => "param_p1"}], "user")

    for op <- [:eq, :neq] do
      {:ok, result} =
        Target.compile(IR.node(op, [held, assignee], "boolean"), project, runtime: @runtime)

      var = "element_state_bg1_param_p1"
      same = [{String.to_atom(var), %{id: "u1", name: "One"}}, {:this, %{assignee_id: "u1"}}]
      other = [{String.to_atom(var), %{id: "u2"}}, {:this, %{assignee_id: "u1"}}]

      assert eval(result, same) == (op == :eq)
      assert eval(result, other) == (op == :neq)
    end

    # In a list of IDs too.
    ids = IR.node(:field, [this, "task", "access_list_user"], "list.user")

    {:ok, member} =
      Target.compile(IR.node(:member, [ids, held], "boolean"), project, runtime: @runtime)

    assert eval(member, element_state_bg1_param_p1: %{id: "u2"}, this: %{access: ["u1", "u2"]})

    # Empty or hidden (a field the user may not view reads as empty): no ID,
    # never a member, and equal to an empty reference only.
    for empty <- [nil, %Hidden{}] do
      refute eval(member, element_state_bg1_param_p1: empty, this: %{access: ["u1"]})

      {:ok, eq} =
        Target.compile(IR.node(:eq, [held, assignee], "boolean"), project, runtime: @runtime)

      assert eval(eq, element_state_bg1_param_p1: empty, this: %{assignee_id: nil})
      refute eval(eq, element_state_bg1_param_p1: empty, this: %{assignee_id: "u1"})
    end
  end

  # WTF-514: Bubble has no empty text apart from empty, so `is` and `is
  # not` read `""` as empty (inferred, not replayed). The generated
  # policies keep the stricter rule (Target.Ash.ExpressionsTest).
  test "an empty text is empty in is / is not; numbers and the actor guard unchanged", %{
    project: project
  } do
    this = IR.node(:this, [:rule_record], "custom.task")
    title = IR.node(:field, [this, "task", "title_text"], "text")
    parent = IR.node(:field, [this, "task", "parent_custom_task"], "custom.task")
    parent_title = IR.node(:field, [parent, "task", "title_text"], "text")
    segment = IR.node(:input, [:url, %{"type" => "path_segment", "index" => 2}], "text")
    empty_text = IR.node(:literal, [""], "text")

    compile_ir = fn ir ->
      {:ok, result} = Target.compile(ir, project, runtime: @runtime)
      assert result.source, inspect(result.diagnostics)
      result
    end

    is = compile_ir.(IR.node(:eq, [title, parent_title], "boolean"))
    is_not = compile_ir.(IR.node(:neq, [title, parent_title], "boolean"))

    for a <- [nil, ""], b <- [nil, ""] do
      this = %{title: a, parent: %{title: b}}
      assert eval(is, this: this), "#{inspect(a)} is #{inspect(b)}"
      refute eval(is_not, this: this), "#{inspect(a)} is not #{inspect(b)}"
    end

    refute eval(is, this: %{title: "", parent: %{title: "Plan"}})
    assert eval(is_not, this: %{title: "", parent: %{title: "Plan"}})

    # Against an empty text literal: nil is it too.
    for op <- [:eq, :neq], value <- [nil, "", "Plan"] do
      result = compile_ir.(IR.node(op, [title, empty_text], "boolean"))
      assert eval(result, this: %{title: value}) == (op == :eq == (value != "Plan"))
    end

    # The demo's tab: a value set to an empty text against a URL path
    # segment that is not there (nil).
    tab = compile_ir.(IR.node(:eq, [segment, title], "boolean"))
    [%{var: var}] = Enum.reject(tab.bindings, &(&1.var == "this"))
    assert eval(tab, [{String.to_atom(var), nil}, this: %{title: ""}])
    refute eval(tab, [{String.to_atom(var), "x"}, this: %{title: ""}])

    # Numbers keep their semantics: 0 is not empty.
    estimate = IR.node(:field, [this, "task", "estimate_number"], "number")
    parent_estimate = IR.node(:field, [parent, "task", "estimate_number"], "number")
    numbers = compile_ir.(IR.node(:eq, [estimate, parent_estimate], "boolean"))
    refute eval(numbers, this: %{estimate: 0, parent: %{estimate: nil}})
    assert eval(numbers, this: %{estimate: nil, parent: %{estimate: nil}})

    # The current user's empty text still matches nothing (fail-safe).
    name = IR.node(:field, [IR.node(:current_user, [], "user"), "user", "name_text"], "text")

    for op <- [:eq, :neq] do
      guarded = compile_ir.(IR.node(op, [title, name], "boolean"))
      refute eval(guarded, this: %{title: nil}, current_user: %{name: ""}), "#{op}"
      refute eval(guarded, this: %{title: ""}, current_user: %{name: nil}), "#{op}"
    end
  end

  test "the stand-in runtime's id/1: a record's ID, an ID, else nil" do
    assert Runtime.id(%{id: "u1"}) == "u1"
    assert Runtime.id("u1") == "u1"
    assert Runtime.id(nil) == nil
    assert Runtime.id(%Hidden{}) == nil
    assert Runtime.id(42) == nil
  end

  test "records compare by ID; the current user side must not be empty", %{project: project} do
    raw = chain(src("CurrentDataItem"), [msg("assignee_user"), msg("equals", cu())])
    result = compile(raw, project, host: "bT3")

    assert eval(result, cell_thing_br1: %{assignee_id: "u1"}, current_user: %{id: "u1"})
    refute eval(result, cell_thing_br1: %{assignee_id: "u2"}, current_user: %{id: "u1"})
    # Fail-safe: an empty value read from the current user never matches.
    refute eval(result, cell_thing_br1: %{assignee_id: nil}, current_user: nil)
  end

  test "field paths through relationships record their loads", %{project: project} do
    raw =
      chain(cu(), [
        msg("active_membership_custom_membership"),
        msg("team_custom_team"),
        msg("name_text")
      ])

    result = compile(raw, project)

    assert result.loads == %{"current_user" => [["active_membership", "team"]]}
    user = %{active_membership: %{team: %{name: "Acme"}}}
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

  describe "the privacy expectation table (shared with the Ash backend's runtime check)" do
    @expectations "test/support/expression/expectations/privacy.json"
                  |> File.read!()
                  |> Jason.decode!()

    test "every case selects exactly the expected records", %{project: project} do
      model = model()
      db = records(@expectations["records"], project)

      # page and workflow conditions follow Bubble's reading where the
      # policies are stricter by design (`expected_elixir`)
      for %{"type" => type, "rule" => rule} = c <- @expectations["cases"] do
        expected = c["expected_elixir"] || c["expected"]

        condition =
          Enum.find(BubbleEx.Model.data_type(model, type).rules, &(&1.id == rule)).condition

        env = rule_env(type)
        {:ok, %{ir: %IR{} = ir}} = Compiler.compile(condition, env)
        {:ok, %{source: source}} = Target.compile(ir, project, runtime: @runtime)
        assert source, "#{type}/#{rule} did not compile to Elixir"

        for {actor, ids} <- expected do
          user = if actor != "logged_out", do: resolve(db, "user", actor)

          selected =
            for %{id: id} <- db[type],
                {true, _} <- [
                  Code.eval_string(source, this: resolve(db, type, id), current_user: user)
                ],
                do: id

          assert Enum.sort(selected) == Enum.sort(ids), "#{type}/#{rule} as #{actor}"
        end
      end
    end

    # Records by type, with atom keys, plus how each relationship resolves.
    defp records(json, project) do
      types = Map.new(project.resources, &{&1.module, &1.source.type})

      relationships =
        Map.new(project.resources, fn r ->
          {r.source.type,
           for(
             rel <- r.relationships,
             do: {rel.name, rel.source_attribute, types[rel.destination]}
           )}
        end)

      json
      |> Map.new(fn {type, rows} ->
        {type,
         Enum.map(rows, fn row -> Map.new(row, fn {k, v} -> {String.to_atom(k), v} end) end)}
      end)
      |> Map.put(:relationships, relationships)
    end

    # A record with its relationships loaded (a dangling or empty reference
    # loads as nil), three levels deep.
    defp resolve(db, type, id, depth \\ 3) do
      case Enum.find(db[type] || [], &(&1.id == id)) do
        nil ->
          nil

        record when depth == 0 ->
          record

        record ->
          Enum.reduce(db.relationships[type], record, fn {name, attribute, target}, acc ->
            related = Map.get(record, String.to_atom(attribute))
            Map.put(acc, String.to_atom(name), related && resolve(db, target, related, depth - 1))
          end)
      end
    end
  end

  test "every runtime function the backend calls is in the published contract", %{
    project: project
  } do
    functions = BubbleEx.Target.Elixir.Runtime.functions()
    assert BubbleEx.Target.Elixir.Runtime.stubs() -- functions == []

    {:ok, sites} = BubbleEx.Expression.Sites.collect(app(), model())

    used =
      for site <- sites,
          {:ok, %{ir: %IR{} = ir}} <- [Compiler.compile(parse!(site.raw, site.env), site.env)],
          {:ok, %{runtime: runtime}} <- [Target.compile(ir, project)],
          fun <- runtime,
          uniq: true,
          do: fun

    assert used != []
    assert used -- functions == []
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
