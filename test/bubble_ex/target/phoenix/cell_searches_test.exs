defmodule BubbleEx.Target.Phoenix.CellSearchesTest do
  # WTF-520: searches in a repeating group's cells, read for every cell
  # together (one query per round of cells, never one per cell). The
  # behavior of the generated app is
  # test/support/target/phoenix/cell_searches_behavior.exs
  # (scripts/phoenix_compile_check.sh).
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, PageData}
  alias BubbleEx.Target.Ash.Expr
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Elixir.FrontendWorkflows.{Data, Spec}
  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Workflows.Frontend

  @fixture "test/support/target/phoenix/cell_searches.json"

  defp app, do: @fixture |> File.read!() |> Jason.decode!()

  defp spec(app, privacy \\ :omit) do
    {:ok, model} = Model.build(app)
    {:ok, page_data} = PageData.build(app, model)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: privacy)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    {:ok, lowered} = Frontend.build(app, model, index)

    {:ok, spec} =
      FrontendWorkflows.map(lowered, project,
        namespace: "Shop",
        frontend: frontend,
        page_data: page_data
      )

    %{spec: spec, project: project, frontend: frontend, model: model, page_data: page_data}
  end

  defp data(spec, element) do
    spec.surfaces
    |> Enum.flat_map(fn {_id, s} -> s.data end)
    |> Enum.find(&(&1.element == element))
  end

  defp cell_path(element),
    do: ["pages", "customers", "elements", "bCustomers", "elements", element]

  defp source_path(element), do: cell_path(element) ++ ["properties", "data_source"]

  defp constraint(app, element, constraint),
    do:
      update_in(app, source_path(element) ++ ["properties", "constraints"], fn cs ->
        Map.put(cs, Integer.to_string(map_size(cs)), constraint)
      end)

  defp files(app) do
    %{spec: spec, project: project, frontend: frontend, model: model} = spec(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
    {:ok, workflows} = BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "Shop")

    {:ok, files} =
      Phoenix.render(project,
        module: "Shop",
        frontend: frontend,
        workflows: workflows,
        frontend_workflows: spec
      )

    files
  end

  describe "binding" do
    test "a search reading the cell's thing is batched on the key it compares, not residue" do
      %{spec: spec} = spec(app())

      for element <- ~w(bCount bFirst bLast bOpen) do
        assert %{residue: [], read: {:query, %{batch: batch} = q}} = data(spec, element)
        assert [%{var: "pin_1", attr: "customer_id", kind: :eq, unless: nil}] = batch.keys
        # The cell's query compares with its own value, the batch with every cell's.
        assert BubbleEx.Target.Ash.Source.filter(q.filter) =~
                 "is_not_distinct_from(customer_id, ^pin_1)"

        assert BubbleEx.Target.Ash.Source.filter(batch.filter) =~ "customer_id in ^pin_1"
        assert Spec.cell_reads?(data(spec, element))
      end

      # The count of open orders keeps its other constraint in both.
      assert %{read: {:query, %{batch: batch}}} = data(spec, "bOpen")
      assert BubbleEx.Target.Ash.Source.filter(batch.filter) =~ "open == true"
    end

    test "a value over a search in a cell batches the search it reads first" do
      %{spec: spec} = spec(app())

      # The first two orders' count: a per-cell limit.
      assert %{residue: [], read: {:value, %{queries: [q]}}} = data(spec, "bTwo")
      assert %{take: {:limit, 2}, batch: %{keys: [%{kind: :eq, attr: "customer_id"}]}} = q

      # A cell's list filtered: the records it holds, keyed by their IDs.
      assert %{residue: [], read: {:value, %{queries: [q]}}} = data(spec, "bListed")
      assert %{listed: var, batch: %{keys: [%{var: var, kind: :in, attr: "id"}]}} = q

      # Those records sorted: a query reading the first one's records, batched too
      # (the loader reads it in the next round).
      assert %{residue: [], read: {:query, %{take: :first, listed: v} = q}} =
               data(spec, "bNewest")

      assert %{batch: %{keys: [%{var: ^v, kind: :in}]}, queries: [%{batch: _}]} = q
    end

    test "a reusable element rendered per cell batches its search on its thing" do
      %{spec: spec} = spec(app())

      assert %{residue: [], read: {:query, %{batch: %{keys: [%{attr: "customer_id"}]}}}} =
               data(spec, "bCardCount")

      # Its instances in the cells are rendered per cell.
      assert %{"bCard1" => %{residue: []}} = spec.cells
    end

    test "an empty constraint dropped: the key holds only where the value is not empty" do
      app =
        put_in(app(), source_path("bCount") ++ ["properties", "ignore_empty_constraints"], true)

      %{spec: spec} = spec(app)

      assert %{residue: [], read: {:query, %{batch: %{keys: [key]}}}} = data(spec, "bCount")
      assert %{var: "pin_1", kind: :eq, unless: "pin_2"} = key
    end

    test "a constraint the batch cannot key stays residue, as before" do
      contains = %{
        "constraint_type" => "text contains string",
        "key" => "title_text",
        "value" => %{
          "type" => "CurrentDataItem",
          "next" => %{"type" => "Message", "name" => "name_text"}
        }
      }

      %{spec: spec} = spec(constraint(app(), "bCount", contains))

      assert %{read: nil, residue: [%{reason: :page_data_in_cell, detail: %{kind: "query"}}]} =
               data(spec, "bCount")

      # The others still load.
      assert %{residue: []} = data(spec, "bFirst")
    end

    test "Bubble's random sort in a cell stays residue" do
      app =
        put_in(app(), source_path("bFirst") ++ ["properties", "sort_field"], "_random_sorting")

      %{spec: spec} = spec(app)
      assert %{residue: [%{reason: :page_data_in_cell}]} = data(spec, "bFirst")
    end

    test "a field hidden from searches stays refused in a cell (WTF-457)" do
      rules = %{
        "everyone" => %{
          "permissions" => %{
            "search_for" => true,
            "view_all" => true,
            "non_filterable_fields" => %{"0" => "customer_custom_customer"}
          }
        }
      }

      app = put_in(app(), ["user_types", "order", "privacy_role"], rules)
      %{spec: spec} = spec(app)

      assert %{read: nil, residue: [%{reason: :search_field_restricted}]} = data(spec, "bCount")
    end

    test "with enforced privacy, the batch is the same search, read through :search" do
      %{spec: spec} = spec(app(), :enforced)
      assert %{residue: [], read: {:query, %{batch: %{keys: [_]}}}} = data(spec, "bCount")
    end
  end

  describe "cell_batch/2" do
    defp query(expr, pins, opts \\ []) do
      %{
        resource: "Order",
        filter: %Expr{resource: "Order", expr: expr},
        sort: Keyword.get(opts, :sort, []),
        take: :all,
        pins: pins
      }
    end

    defp pin(var, ref, type \\ nil), do: %{var: var, ref: ref, type: type, value: %{bindings: []}}

    test "an equality on a thing's ID is a key; constraints alike in every cell are kept" do
      expr =
        {:and,
         [
           {:call, "is_distinct_from", [{:pin, "e"}, {:value, true}]},
           {:op, "==", {:ref, [], "customer_id"}, {:pin, "k"}},
           {:op, "==", {:ref, [], "status"}, {:pin, "s"}}
         ]}

      q = query(expr, [pin("e", nil, "boolean"), pin("k", :one), pin("s", nil, "text")])

      assert {:ok, %{keys: [%{var: "k", attr: "customer_id", kind: :eq}], filter: f}} =
               Data.cell_batch(q, %{"e" => true, "k" => true, "s" => false})

      assert {:and, [_, {:op, "in", {:ref, [], "customer_id"}, {:pin, "k"}}, _]} = f.expr
    end

    test "a value differing per cell anywhere but a key or a yes/no is not batched" do
      expr =
        {:and,
         [
           {:op, "==", {:ref, [], "customer_id"}, {:pin, "k"}},
           {:op, ">", {:ref, [], "total"}, {:pin, "t"}}
         ]}

      q = query(expr, [pin("k", :one), pin("t", nil, "number")])
      assert :error = Data.cell_batch(q, %{"k" => true, "t" => true})
      # The same, alike in every cell: batched.
      assert {:ok, _} = Data.cell_batch(q, %{"k" => true, "t" => false})
    end

    test "a key under `or` or `not`, or used twice, is not batched" do
      key = {:op, "==", {:ref, [], "customer_id"}, {:pin, "k"}}
      other = {:op, "==", {:ref, [], "status"}, {:value, "x"}}
      pins = [pin("k", :one)]

      assert :error = Data.cell_batch(query({:or, [key, other]}, pins), %{"k" => true})
      assert :error = Data.cell_batch(query({:not, key}, pins), %{"k" => true})

      twice = {:and, [key, {:op, "==", {:ref, [], "owner_id"}, {:pin, "k"}}]}
      assert :error = Data.cell_batch(query(twice, pins), %{"k" => true})
    end

    test "a key on a related record's field is not batched" do
      expr = {:op, "==", {:ref, ["customer"], "region_id"}, {:pin, "k"}}
      assert :error = Data.cell_batch(query(expr, [pin("k", :one)]), %{"k" => true})
    end

    test "a key guarded by its empty value (`^empty == true or key`) holds unless empty" do
      expr =
        {:or,
         [
           {:op, "==", {:pin, "e"}, {:value, true}},
           {:call, "is_not_distinct_from", [{:ref, [], "customer_id"}, {:pin, "k"}]}
         ]}

      q = query(expr, [pin("e", nil, "boolean"), pin("k", :one)])

      assert {:ok, %{keys: [%{var: "k", unless: "e"}], filter: f}} =
               Data.cell_batch(q, %{"e" => true, "k" => true})

      assert {:or, [_, {:op, "in", {:ref, [], "customer_id"}, {:pin, "k"}}]} = f.expr
    end

    test "the records a list holds are keyed by their IDs; random order is not batched" do
      expr = {:op, "in", {:ref, [], "id"}, {:pin, "ids"}}
      q = query(expr, [pin("ids", :listed)]) |> Map.put(:listed, "ids")

      assert {:ok, %{keys: [%{kind: :in, attr: "id"}]}} = Data.cell_batch(q, %{"ids" => true})
      assert :error = Data.cell_batch(%{q | sort: [:random]}, %{"ids" => true})
    end
  end

  describe "printed" do
    test "a batched search reads through BubbleData.cell_read/4 and its source says so" do
      files = files(app())
      module = files["lib/shop_web/live/customers_live/workflows.ex"]

      assert module =~ "cell_reads: true"
      assert module =~ "BubbleData.cell_read("
      assert module =~ "keys: [{:pin_1, :customer_id, :eq, nil}]"
      assert module =~ "customer_id in ^pin_1"
      assert module =~ "is_not_distinct_from(customer_id, ^pin_1)"
      refute module =~ "page_data_in_cell"

      runtime = files["lib/shop_web/bubble_data.ex"]
      assert runtime =~ "def cell_read(ctx, spec, query, batch)"
      assert runtime =~ "Ash.Query.distinct("
    end
  end
end
