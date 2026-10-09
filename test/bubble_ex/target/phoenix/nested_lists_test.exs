defmodule BubbleEx.Target.Phoenix.NestedListsTest do
  # WTF-520: a repeating group in another's cell, rendered per outer cell
  # (two levels), its list and its cells' sources read for every cell of
  # every outer cell together. The behavior of the generated app is
  # test/support/target/phoenix/nested_lists_behavior.exs
  # (scripts/phoenix_compile_check.sh).
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, PageData}
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Workflows.Frontend

  @fixture "test/support/target/phoenix/nested_lists.json"

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

    %{spec: spec, project: project, frontend: frontend, model: model, index: index}
  end

  defp files(app) do
    %{spec: spec, project: project, frontend: frontend, model: model, index: index} = spec(app)

    {:ok, compiled} =
      BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
        runtime: "Shop.Bubble.Runtime",
        namespace: "Shop"
      )

    {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
    {:ok, workflows} = BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "Shop")

    {:ok, files} =
      Phoenix.render(project,
        module: "Shop",
        frontend: frontend,
        expressions: compiled,
        workflows: workflows,
        frontend_workflows: spec
      )

    files
  end

  defp data(spec, element) do
    spec.surfaces
    |> Enum.flat_map(fn {_id, s} -> s.data end)
    |> Enum.find(&(&1.element == element))
  end

  @outer ["pages", "customers", "elements", "bCustomers"]
  @box @outer ++ ["elements", "bCustBox"]
  @inner @box ++ ["elements", "bOrders"]

  defp text(id, entries) do
    %{
      "id" => id,
      "type" => "Text",
      "properties" => %{
        "width" => 300,
        "height" => 40,
        "text" => %{
          "type" => "TextExpression",
          "entries" => entries |> Enum.with_index() |> Map.new(fn {e, i} -> {"#{i}", e} end)
        }
      }
    }
  end

  # A repeating group of items in each order's cell: a third level.
  defp deep(app) do
    deep = %{
      "id" => "bDeep",
      "type" => "RepeatingGroup",
      "properties" => %{
        "group_type" => "custom.item",
        "rows" => 5,
        "width" => 300,
        "height" => 100,
        "data_source" => %{
          "type" => "Search",
          "properties" => %{
            "type_to_find" => "custom.item",
            "sort_field" => "name_text",
            "descending" => false,
            "ignore_empty_constraints" => false,
            "constraints" => %{
              "0" => %{
                "constraint_type" => "equals",
                "key" => "order_custom_order",
                "value" => %{"type" => "ElementParent"}
              }
            }
          }
        }
      },
      "elements" => %{
        "bDeepN" =>
          text("bDeepN", [
            "Deep: ",
            %{
              "type" => "CurrentDataItem",
              "next" => %{"type" => "Message", "name" => "name_text"}
            }
          ])
      }
    }

    put_in(app, @inner ++ ["elements", "bDeep"], deep)
  end

  describe "binding" do
    test "an inner list is a value per outer cell: its search batched on the outer cell" do
      %{spec: spec} = spec(app())

      # Keyed on the outer cell's group (Parent group's customer).
      assert %{
               residue: [],
               cell: "bCustomers",
               outer: nil,
               read: {:query, %{batch: %{keys: [%{attr: "customer_id", kind: :eq}]}} = q}
             } = data(spec, "bOrders")

      # Its own page (10 rows) in each outer cell.
      assert q.take == :all and data(spec, "bOrders").page_size == 10
      assert {:cell_data, "bCustBox"} in data(spec, "bOrders").reads
      # It needs the outer list, whatever it reads.
      assert {:cell, "bCustomers"} in data(spec, "bOrders").reads
      assert Spec.cell_reads?(data(spec, "bOrders"))

      # An inner list fed by the outer cell's list field: a value, no search.
      assert %{residue: [], cell: "bCustomers", read: {:value, v}} = data(spec, "bListed")
      refute Map.has_key?(v, :queries)

      assert %{kind: :list, cell: "bCustomers"} = spec.data_index.elements["bOrders"]
      assert %{kind: :list, cell: "bCustomers"} = spec.data_index.elements["bListed"]
    end

    test "an inner cell's sources are its own: the inner cell's thing, batched across every outer cell" do
      %{spec: spec} = spec(app())

      assert %{
               residue: [],
               cell: "bOrders",
               outer: "bCustomers",
               read: {:query, %{take: :count, batch: %{keys: [%{attr: "order_id"}]}}}
             } = data(spec, "bItems")

      assert {:cell, "bOrders"} in data(spec, "bItems").reads

      # A reusable instance in an inner cell is rendered per inner cell.
      assert %{
               residue: [],
               cell: "bOrders",
               outer: "bCustomers",
               read: {:value, _}
             } = data(spec, "bOrderCard")

      assert %{"bOrderCard" => %{residue: [], cell: "bOrders", outer: "bCustomers"}} = spec.cells
      assert Spec.per_cell?(spec, "bOrderCard")

      # Its workflow reads its own thing: the inner cell's order.
      w = Spec.workflow(spec, "bCardDef", "wPick")
      assert Spec.native?(w) and Spec.wired?(w)
    end

    test "the outer cell reads its inner list; an inner cell reads the outer cell's group" do
      %{spec: spec} = spec(app())

      assert %{residue: [], read: {:value, %{bindings: [%{bind: {:cell_data, "bOrders"}}]}}} =
               data(spec, "bOrderCount")

      index = spec.data_index

      # Read in an inner cell (`cell` bOrders).
      assert {:ok, {:cell, "bOrders"}} =
               Spec.data_read(index, "bCustomersPage", "bOrders", cell_thing("bOrders"))

      assert {:ok, {:cell_index, "bOrders"}} =
               Spec.data_read(
                 index,
                 "bCustomersPage",
                 "bOrders",
                 {:cell_index, %{"element" => "bOrders"}}
               )

      assert {:ok, {:outer_cell, "bCustomers"}} =
               Spec.data_read(index, "bCustomersPage", "bOrders", cell_thing("bCustomers"))

      assert {:ok, {:outer_cell_index, "bCustomers"}} =
               Spec.data_read(
                 index,
                 "bCustomersPage",
                 "bOrders",
                 {:cell_index, %{"element" => "bCustomers"}}
               )

      assert {:ok, {:outer_cell_data, "bCustBox"}} =
               Spec.data_read(index, "bCustomersPage", "bOrders", group("bCustBox"))

      # A sibling inner list of the outer cell, from an inner cell.
      assert {:ok, {:outer_cell_data, "bListed"}} =
               Spec.data_read(index, "bCustomersPage", "bOrders", list("bListed"))

      # Not as a group, nor the wrong kind.
      assert {:error, _} = Spec.data_read(index, "bCustomersPage", "bOrders", group("bListed"))
      assert {:error, _} = Spec.data_read(index, "bCustomersPage", "bOrders", list("bCustBox"))

      # Read in the outer cell: its inner list, never an inner cell's.
      assert {:ok, {:cell_data, "bOrders"}} =
               Spec.data_read(index, "bCustomersPage", "bCustomers", list("bOrders"))

      assert {:error, _} =
               Spec.data_read(index, "bCustomersPage", "bCustomers", cell_thing("bOrders"))

      assert {:error, _} = Spec.data_read(index, "bCustomersPage", "bCustomers", group("bItems"))
      # Outside every cell: neither.
      assert {:error, _} = Spec.data_read(index, "bCustomersPage", nil, cell_thing("bOrders"))
      assert {:error, _} = Spec.data_read(index, "bCustomersPage", nil, list("bOrders"))
    end

    test "with enforced privacy, the same sources load, through :search" do
      %{spec: spec} = spec(app(), :enforced)

      for element <- ~w(bOrders bListed bItems bOrderCard bOrderCount),
          do: assert(%{residue: []} = data(spec, element), element)

      assert %{read: {:query, %{batch: %{keys: [_]}}}} = data(spec, "bOrders")
    end

    test "a third level stays residue, and so does what its cells read" do
      %{spec: spec} = spec(deep(app()))

      assert %{read: nil, residue: [%{reason: :page_data_in_cell, detail: %{kind: "list"}}]} =
               data(spec, "bDeep")

      refute Map.has_key?(spec.data_index.elements, "bDeep")

      assert {:error, "cell_thing"} =
               Spec.data_read(spec.data_index, "bCustomersPage", "bDeep", cell_thing("bDeep"))

      # The two levels above still load.
      assert %{residue: []} = data(spec, "bOrders")
      assert %{residue: []} = data(spec, "bItems")
    end

    test "an inner list whose outer list does not load is not loaded, nor its cells" do
      app =
        put_in(app(), @outer ++ ["properties", "data_source"], %{"type" => "NoSuchExpression"})

      %{spec: spec} = spec(app)

      assert %{residue: [_ | _]} = data(spec, "bCustomers")

      for element <- ~w(bOrders bListed bItems bOrderCard),
          do: assert(%{read: nil, residue: [_ | _]} = data(spec, element), element)

      assert %{"bOrderCard" => %{residue: [_ | _]}} = spec.cells
      refute Spec.per_cell?(spec, "bOrderCard")
    end

    test "a list in the cell of an inner list that does not load is a third level: residue" do
      container = %{
        "id" => "bSides",
        "type" => "RepeatingGroup",
        "properties" => %{
          "group_type" => "custom.customer",
          "width" => 300,
          "height" => 300,
          "data_source" => %{"type" => "NoSuchExpression"}
        },
        "elements" => %{
          "bTucked" =>
            put_in(get_in(app(), @inner), ["id"], "bTucked")
            |> Map.put("elements", %{})
        }
      }

      app = put_in(app(), @outer ++ ["elements", "bSides"], container)
      %{spec: spec} = spec(app)

      # The inner list does not load; the one in its cells is a third
      # level either way.
      assert %{residue: [%{reason: :uncompiled_expression}]} = data(spec, "bSides")

      assert %{residue: [%{reason: :page_data_in_cell, detail: %{kind: "list"}}]} =
               data(spec, "bTucked")
    end

    test "a repeating group in a table of the outer cell is a marked runtime container, not nested" do
      inner = get_in(app(), @inner)

      cell = fn id, axis, elements ->
        %{
          "id" => id,
          "type" => "TableCell",
          "properties" => %{"cell_main_axis_id" => axis, "order" => 1},
          "elements" => elements
        }
      end

      table = %{
        "id" => "bTable",
        "type" => "Table",
        "properties" => %{"order" => 9, "width" => 300, "height" => 200},
        "elements" => %{
          "bTCol" => %{
            "id" => "bTCol",
            "type" => "TableMainAxis",
            "properties" => %{"axis_index" => 0}
          },
          "bTHead" => %{
            "id" => "bTHead",
            "type" => "TableCrossAxis",
            "properties" => %{"axis_index" => 0},
            "elements" => %{
              "bTHeadCell" =>
                cell.("bTHeadCell", "bTCol", %{
                  "bInTable" =>
                    inner
                    |> Map.put("id", "bInTable")
                    |> Map.put("elements", %{
                      "bInTableT" =>
                        text("bInTableT", [
                          "In table: ",
                          %{
                            "type" => "CurrentDataItem",
                            "next" => %{"type" => "Message", "name" => "title_text"}
                          }
                        ])
                    })
                })
            }
          }
        }
      }

      app = put_in(app(), @outer ++ ["elements", "bTable"], table)
      %{spec: spec} = spec(app)

      assert %{read: nil, residue: [%{reason: :page_data_in_cell, detail: %{kind: "list"}}]} =
               data(spec, "bInTable")

      refute Spec.nested_list?(spec, "bInTable")
      assert Spec.nested_list?(spec, "bOrders")

      heex = files(app)["lib/shop_web/live/customers_live.html.heex"]
      refute heex =~ ~s|"bInTable", cell_bcustomers_i|
      assert heex =~ "TODO(bubble:bInTable)"
      # The two levels beside it still render.
      assert heex =~ ~s|Bubble.cells(@bubble_data, "", "bOrders", cell_bcustomers_i)|
    end

    test "an inner list's own \"Current cell's\" is the outer cell" do
      # Search orders where customer = Current cell's customer, in the
      # inner list's own data source: the outer cell (its parent's
      # context), not the inner list itself.
      app =
        put_in(
          app(),
          @inner ++ ["properties", "data_source", "properties", "constraints", "0", "value"],
          %{"type" => "CurrentDataItem"}
        )

      %{spec: spec} = spec(app)

      assert %{residue: [], read: {:query, %{batch: %{keys: [%{attr: "customer_id"}]}}}} =
               data(spec, "bOrders")

      assert {:cell, "bCustomers"} in data(spec, "bOrders").reads
    end

    test "an inner cell's instance whose own source does not load is not rendered there (WTF-522)" do
      broken = %{
        "id" => "bOrderCard2",
        "type" => "CustomElement",
        "properties" => %{
          "custom_id" => "bCardDef",
          "group_type" => "custom.order",
          "width" => 300,
          "height" => 120,
          "data_source" => %{"type" => "NoSuchExpression"}
        }
      }

      app = put_in(app(), @inner ++ ["elements", "bOrderCard2"], broken)
      %{spec: spec} = spec(app)

      # Its sibling gives the card its thing: the card's reads of it load,
      # so the broken instance would read nothing.
      assert Spec.unloaded(spec, "bOrderCard2") == [:uncompiled_expression]
      assert Spec.unloaded(spec, "bOrderCard") == nil
      refute Spec.per_cell?(spec, "bOrderCard2")
      assert Spec.per_cell?(spec, "bOrderCard")

      files = files(app)
      heex = files["lib/shop_web/live/customers_live.html.heex"]
      assert heex =~ "TODO(bubble:bOrderCard2) not rendered"

      module = files["lib/shop_web/live/customers_live/workflows.ex"]

      assert module =~
               ~s({{"bCustomers", "bOrders"}, [{"bOrderCard", ShopWeb.Reusables.OrderCard.Workflows}]})

      refute module =~ ~s({"bOrderCard2",)
    end
  end

  defp cell_thing(rg), do: {:cell_thing, %{"element" => rg}}
  defp group(e), do: {:element_state, %{"element" => e, "state" => "get_group_data"}}
  defp list(e), do: {:element_state, %{"element" => e, "state" => "get_list_data"}}

  describe "printed" do
    test "the inner list loops per outer cell; inner values are kept in the outer cell's scope" do
      files = files(app())
      heex = files["lib/shop_web/live/customers_live.html.heex"]

      assert heex =~ ~s|Bubble.cells(@bubble_data, "", "bOrders", cell_bcustomers_i)|
      assert heex =~ ~s|Bubble.cells(@bubble_data, "", "bListed", cell_bcustomers_i)|

      outer_scope = ~s|Bubble.cell_scope("", "bCustomers", cell_bcustomers, cell_bcustomers_i)|

      # An inner cell's group, by the inner index in the outer cell's scope.
      assert heex =~ ~s|Bubble.data(@bubble_data, #{outer_scope}, "bItems", cell_borders_i)|
      # The outer cell's group, read in an inner cell.
      assert heex =~ ~s|Bubble.data(@bubble_data, "", "bCustBox", cell_bcustomers_i)|
      # The instance's scope: its inner cell's, in its outer cell's.
      assert String.replace(heex, ~r/\s+/, "") =~
               String.replace(
                 ~s|Bubble.nest(Bubble.cell_scope(#{outer_scope}, "bOrders", cell_borders, cell_borders_i), "bOrderCard")|,
                 ~r/\s+/,
                 ""
               )

      refute heex =~ "TODO(bubble:bOrders)"
      refute heex =~ "TODO(bubble:bItemsN)"

      module = files["lib/shop_web/live/customers_live/workflows.ex"]
      assert module =~ ~s(outer: "bCustomers")
      assert module =~ "deps: [cell_data: \"bOrders\"]"
      assert module =~ ~s|BubbleWorkflows.cell_data(ctx, "bCustBox")|

      assert module =~
               ~s({{"bCustomers", "bOrders"}, [{"bOrderCard", ShopWeb.Reusables.OrderCard.Workflows}]})

      refute module =~ "page_data_in_cell"

      runtime = files["lib/shop_web/bubble_data.ex"]
      assert runtime =~ "defp nested_items(data, scope, rg, index)"
      assert runtime =~ "defp cell_scopes(data, scope, {outer, rg})"

      workflows = files["lib/shop_web/bubble_workflows.ex"]
      assert workflows =~ "def outer_cell_data(%{outer: {_item, index}} = ctx, element)"
    end

    test "a third level renders as a runtime container, marked" do
      heex = files(deep(app()))["lib/shop_web/live/customers_live.html.heex"]
      refute heex =~ ~s|"bDeep", cell_borders_i|
      assert heex =~ "TODO(bubble:bDeep)"
    end
  end
end
