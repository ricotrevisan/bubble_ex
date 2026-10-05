defmodule BubbleEx.Target.Elixir.ListOpsTest do
  # WTF-495: the list operators of page data sources (sorted, merged,
  # unique, filtered lists, further sort keys), lowered to Ash queries read
  # as the current user and Elixir over what they read. The behavior of the
  # generated app is test/support/target/phoenix/list_ops_behavior.exs
  # (scripts/phoenix_compile_check.sh, both privacy modes).
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, PageData}
  alias BubbleEx.Expression.IR
  alias BubbleEx.Target.Ash.Expressions
  alias BubbleEx.Target.Elixir, as: Target
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Lists
  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Workflows.Frontend

  @fixture "test/support/target/phoenix/list_ops.json"

  defp app, do: @fixture |> File.read!() |> Jason.decode!()

  defp render(app, privacy \\ :omit) do
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: privacy)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    {:ok, lowered} = Frontend.build(app, model, index)
    {:ok, page_data} = PageData.build(app, model)
    {:ok, backend_lowered} = BubbleEx.Workflows.Backend.build(app, model, index)

    {:ok, backend} =
      BubbleEx.Target.Ash.Workflows.map(backend_lowered, project, namespace: "Shop")

    {:ok, spec} =
      FrontendWorkflows.map(lowered, project,
        namespace: "Shop",
        frontend: frontend,
        backend: backend,
        page_data: page_data
      )

    %{project: project, page_data: page_data, spec: spec, frontend: frontend, backend: backend}
  end

  defp data(spec, element) do
    spec.surfaces
    |> Enum.flat_map(fn {_id, s} -> s.data end)
    |> Enum.find(&(&1.element == element))
  end

  setup_all do
    render(app())
  end

  test "every list source of the fixture lowers and loads", %{page_data: pd, spec: spec} do
    assert Enum.all?(pd.sources, &(&1.residue == [])), inspect(pd.sources)

    for s <- pd.sources do
      assert data(spec, s.element).residue == [], s.element
    end
  end

  test "a sorted search sorted again, and further sort keys, are one sorted query", %{spec: spec} do
    assert %{read: {:query, %{sort: [{"rank", :desc}, {"title", :asc}], take: :all}}} =
             data(spec, "bSorted")

    assert %{read: {:query, %{sort: [{"rank", :asc}, {"title", :desc}]}}} = data(spec, "bMulti")
  end

  test "merged searches are queries read first, merged in Elixir", %{spec: spec} do
    assert %{read: {:value, %{queries: [q1, q2], source: source}}} = data(spec, "bMerged")
    assert {q1.n, q2.n} == {1, 2}
    assert q1.take == :all and q1.sort == [{"title", :asc}]
    refute Map.has_key?(q1, :listed)
    assert source =~ "Runtime.merge(query_1, query_2)"

    # item #2 of the same merge: a group's thing.
    assert %{read: {:value, %{queries: [_, _], source: second}}} = data(spec, "bSecond")
    assert second =~ "item_at("
  end

  test "a list field sorted is a query for its records; filtered keeps its order", %{spec: spec} do
    assert %{read: {:query, %{listed: "pin_1", sort: [{"title", :asc}], pins: [pin]}}} =
             data(spec, "bFieldSorted")

    assert %{var: "pin_1", ref: :listed} = pin
    assert data(spec, "bFieldSorted").reads == [{:data, %{path: [], element: "bProject"}}]

    assert %{read: {:value, %{queries: [q], source: source}}} = data(spec, "bFieldFiltered")
    assert q.listed == "q1_pin_1"
    assert [%{var: "q1_pin_1"}] = q.pins
    assert source =~ "Runtime.intersect("
  end

  test "list algebra over a list field and options filtered in Elixir", %{spec: spec} do
    assert %{read: {:value, %{source: unique}}} = data(spec, "bUnique")
    assert unique =~ "Runtime.unique("
    assert %{read: {:value, %{source: limit}}} = data(spec, "bLimit")
    assert limit =~ "Runtime.limit("
    assert %{read: {:value, %{source: options}}} = data(spec, "bOptions")

    assert options =~
             "Enum.filter(Shop.Bubble.Runtime.as_list(Shop.Enums.Color.values()), fn item ->"
  end

  test "a page's :filtered not stating the option matches nothing on an empty value", %{
    spec: spec
  } do
    assert %{read: {:query, %{filter: filter}}} = data(spec, "bFilteredSearch")
    assert BubbleEx.Target.Ash.Source.filter(filter) =~ "is_distinct_from(^pin_2, true)"
  end

  test "a list operator over a search in a repeating group's cell is residue" do
    app = app()
    merged = get_in(app, ["pages", "index", "elements", "bMerged", "properties", "data_source"])

    app =
      put_in(app, ["pages", "index", "elements", "bSorted", "elements", "bInner"], %{
        "id" => "bInner",
        "type" => "RepeatingGroup",
        "properties" => %{
          "group_type" => "custom.task",
          "rows" => 2,
          "columns" => 1,
          "data_source" => merged
        }
      })

    %{spec: spec} = render(app)

    assert [%{reason: :page_data_in_cell, detail: %{kind: kind}}] =
             data(spec, "bInner").residue

    assert kind in ["list", "query"]
  end

  # M1: a search read as a query stops at :max_items; counting it, taking
  # its last item or subtracting it would show more or other than Bubble.
  test "counting, the last item or subtracting a capped query is residue" do
    app = app()
    els = ["pages", "index", "elements"]
    tasks = get_in(app, els ++ ["bUnique", "properties", "data_source"])
    merged = get_in(app, els ++ ["bMerged", "properties", "data_source"])
    search = Map.delete(merged, "next")
    put = fn app, id, next -> put_in(app, els ++ [id, "properties", "data_source"], next) end
    chain = fn source, message -> put_in(source, ["next", "next", "next"], message) end

    app =
      app
      # gProject's tasks :minus list Search for tasks
      |> put.(
        "bUnique",
        chain.(tasks, %{"type" => "Message", "name" => "minus_list", "args" => search})
      )
      # Search for tasks :merged with gProject's tasks :count
      |> put.(
        "bSecond",
        Map.put(search, "next", %{
          "type" => "Message",
          "name" => "merged_with",
          "args" =>
            Map.delete(tasks, "next")
            |> Map.put("next", %{
              "type" => "Message",
              "name" => "get_group_data",
              "next" => %{"type" => "Message", "name" => "tasks_list_custom_task"}
            }),
          "next" => %{"type" => "Message", "name" => "count"}
        })
      )
      |> put.(
        "bLimit",
        put_in(merged, ["next", "next"], %{"type" => "Message", "name" => "last_element"})
      )

    %{spec: spec} = render(app)

    for e <- ["bUnique", "bSecond", "bLimit"] do
      assert [%{reason: :uncompiled_expression, detail: %{constructs: ["elixir:capped_list"]}}] =
               data(spec, e).residue,
             e
    end

    # A count of the list's own records reads them all: not capped.
    filtered = get_in(app(), els ++ ["bFieldFiltered", "properties", "data_source"])

    counted =
      put_in(filtered, ["next", "next", "next"], %{"type" => "Message", "name" => "count"})

    %{spec: spec} = render(put.(app(), "bCount", counted))
    assert data(spec, "bCount").residue == []
  end

  test "printed: queries before the value, listed reads, followed changes", %{
    project: project,
    frontend: frontend,
    backend: backend,
    spec: spec
  } do
    {:ok, files} =
      Phoenix.render(project,
        name: "Shop",
        module: "Shop",
        frontend: frontend,
        workflows: backend,
        frontend_workflows: spec
      )

    {_, w} = Enum.find(files, fn {p, _} -> String.ends_with?(p, "index_live/workflows.ex") end)
    assert {:ok, _} = Code.string_to_quoted(w)
    assert w =~ "query_1 =\n"
    assert w =~ "require Ash.Query"
    assert w =~ "|> BubbleData.read(ctx, :all, nil)"
    assert w =~ "|> BubbleData.listed(pin_1)"
    assert w =~ "pin_1 =\n      BubbleData.listed_ids("
    # A text over a query follows the searched type's changes (M2).
    assert w =~ ~r/element: "bFirstTitle",.*?topic: nil,.*?query_topics: \["Task"\]/s
    # A count of merged searches is one count query.
    assert w =~
             "Ash.Query.filter(done == true or rank < 3)\n    |> BubbleData.read(ctx, :count, nil)"

    assert w =~ "Ash.Query.sort([{:rank, :desc}, {:title, :asc}])"
    # A value over queries is re-read on its type's changes.
    assert w =~ ~r/element: "bMerged",\s+fun: :\w+,\s+read: :query/

    {_, data} = Enum.find(files, fn {p, _} -> String.ends_with?(p, "/bubble_data.ex") end)
    assert data =~ "def listed(query, ids) when is_list(ids) do"
  end

  test "enforced: listed queries read through the view action" do
    %{project: project, frontend: frontend, backend: backend, spec: spec} =
      render(app(), :enforced)

    {:ok, files} =
      Phoenix.render(project,
        name: "Shop",
        module: "Shop",
        frontend: frontend,
        workflows: backend,
        frontend_workflows: spec
      )

    {_, data} = Enum.find(files, fn {p, _} -> String.ends_with?(p, "/bubble_data.ex") end)
    assert data =~ "action: read_action(query)"

    assert data =~
             "defp read_action(%Ash.Query{context: %{bubble_listed: n}}) when is_integer(n),"

    # A listed count too (L3).
    assert data =~ "|> Ash.read(action: read_action(query), actor: ctx.actor, authorize?: true)"
    refute data =~ "action: :search"
  end

  describe "Lists.lower/1" do
    defp search(pred \\ nil), do: IR.node(:search, ["task", pred], "list.custom.task")
    defp item, do: IR.node(:this, [:filter_item], "custom.task")

    defp field_list,
      do:
        IR.node(
          :field,
          [
            IR.node(
              :input,
              [:element_state, %{"element" => "g", "state" => "get_group_data"}],
              "custom.project"
            ),
            "project",
            "tasks_list_custom_task"
          ],
          "list.custom.task"
        )

    defp done,
      do:
        IR.node(
          :eq,
          [
            IR.node(:field, [item(), "task", "done_boolean"], "boolean"),
            IR.node(:literal, [true], "boolean")
          ],
          "boolean"
        )

    test "a filter of a sorted search adds its constraints under the sort" do
      ir =
        IR.node(
          :filter,
          [IR.node(:sort, [search(), "title_text", false], "list.custom.task"), done()],
          "list.custom.task"
        )

      assert %IR{op: :sort, args: [%IR{op: :search, args: ["task", pred]}, "title_text", false]} =
               Lists.lower(ir)

      assert pred == done()
    end

    test "a sort of a list of things is a listed search for its records" do
      ir = IR.node(:sort, [field_list(), "title_text", true], "list.custom.task")
      lowered = Lists.lower(ir)

      assert %IR{
               op: :sort,
               args: [
                 %IR{
                   op: :search,
                   args: [
                     "task",
                     %IR{op: :member, args: [%IR{op: :pinned, args: [list]}, %IR{op: :this}]}
                   ]
                 },
                 "title_text",
                 true
               ]
             } = lowered

      assert list == field_list()
      assert Lists.listed?(lowered)
      refute Lists.listed?(search())
    end

    test "a filter of a list of things intersects it with its records that match" do
      lowered = Lists.lower(IR.node(:filter, [field_list(), done()], "list.custom.task"))

      assert %IR{
               op: :intersect,
               args: [
                 list,
                 %IR{op: :search, args: ["task", %IR{op: :and, args: [_member, pred]}]} = s
               ]
             } =
               lowered

      assert list == field_list() and pred == done() and Lists.listed?(s)
    end

    test "lists of values and predicates are left alone" do
      options =
        IR.node(
          :filter,
          [IR.node(:all_options, ["color"], "list.option.color"), done()],
          "list.option.color"
        )

      assert Lists.lower(options) == options
      assert Lists.lower(search(done())) == search(done())
    end
  end

  test "Ash: nested sorts are one sort by several keys", %{project: project} do
    ir =
      IR.node(
        :sort,
        [
          IR.node(:sort, [search(), "title_text", true], "list.custom.task"),
          "rank_number",
          false
        ],
        "list.custom.task"
      )

    assert {:ok, %{expr: %{sort: [{"rank", :asc}, {"title", :desc}]}}} =
             Expressions.search(ir, project)
  end

  test "Elixir: list algebra calls the runtime; a filter of things does not compile", %{
    project: project
  } do
    list = field_list()

    for {op, args, fun} <- [
          {:merge, [list, list], "merge"},
          {:unique, [list], "unique"},
          {:minus_item, [list, IR.node(:literal, ["x"], "text")], "minus_item"},
          {:limit, [list, IR.node(:literal, [2], "number")], "limit"},
          {:item_at, [list, IR.node(:literal, [2], "number")], "item_at"},
          {:as_list, [IR.node(:literal, ["x"], "text")], "as_list"}
        ] do
      {:ok, %{source: source, runtime: runtime}} =
        Target.compile(IR.node(op, args, "list.custom.task"), project, runtime: "R")

      assert source =~ "R.#{fun}("
      assert String.to_atom(fun) in runtime
    end

    {:ok, %{source: nil, diagnostics: [d]}} =
      Target.compile(IR.node(:filter, [list, done()], "list.custom.task"), project)

    assert d.details.constructs == ["filter on a list of things"]
  end

  test "every list function the backend calls is in the runtime contract" do
    functions = BubbleEx.Target.Elixir.Runtime.functions()

    for f <- ~w(as_list unique merge minus_list intersect plus_item minus_item limit item_at)a,
        do: assert(f in functions)
  end
end
