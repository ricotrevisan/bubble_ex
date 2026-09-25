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
    def add(a, b), do: a && b && a + b
    def mul(a, b), do: a && b && a * b
    def compare(_op, nil, _), do: false
    def compare(_op, _, nil), do: false
    def compare(:gt, a, b), do: a > b
    def compare(:lt, a, b), do: a < b
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

      for %{"type" => type, "rule" => rule, "expected" => expected} <- @expectations["cases"] do
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
