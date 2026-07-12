defmodule BubbleEx.Db.EncoderTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Encoder

  describe "module_for/1" do
    test "resolves the dbml format" do
      assert Encoder.module_for(:dbml) == {:ok, BubbleEx.Db.Dbml}
    end

    test "resolves the postgres format" do
      assert Encoder.module_for(:postgres) == {:ok, BubbleEx.Db.Sql.Postgres}
    end

    test "returns a closed-kind error for an unknown format" do
      assert {:error, %BubbleEx.Error{kind: :unknown_format} = error} =
               Encoder.module_for(:mongodb)

      assert error.context == %{format: :mongodb}
    end

    test "resolves :ash" do
      assert BubbleEx.Db.Encoder.module_for(:ash) == {:ok, BubbleEx.Db.Ash}
    end
  end

  describe "render/3" do
    test "returns detailed DBML content and structured warnings without changing encode/2" do
      db = %{
        bubble_id: "app",
        external_types: [],
        warnings: [],
        relationships: [],
        tables: [
          %{
            id: "item",
            name: "Item",
            group: :custom,
            columns: [
              %{
                table_id: "item",
                table_name: "Item",
                table_group: :custom,
                id: "payload",
                name: "Payload",
                type: %{
                  type: :external,
                  target: "api.apiconnector2.alpha.call.Shape",
                  cardinality: :one,
                  raw: "api.apiconnector2.alpha.call.Shape"
                },
                primary_key: false,
                deleted: false
              }
            ]
          }
        ]
      }

      assert {:ok, %Encoder.Result{format: :dbml, content: content, warnings: [warning]}} =
               Encoder.render(:dbml, db)

      assert content =~
               "\"Payload\" json [note: 'External API type api.apiconnector2.alpha.call.Shape (one)']"

      assert warning.kind == :external_type_rendering
      assert {:ok, legacy} = BubbleEx.Db.Dbml.encode(db)
      assert legacy =~ ~s(api."apiconnector2.alpha.call.Shape")
    end

    test "plans collision-safe mutual recursion and nested unresolved fallbacks across targets" do
      a = "api.apiconnector2.one.call.Node"
      b = "api.apiconnector2.two.call.Node"
      missing = "api.apiconnector2.three.call.Missing"

      edge = fn id, target ->
        %{
          id: id,
          caption: id,
          path: [id],
          type: %{type: :external, target: target, cardinality: :one, raw: target}
        }
      end

      nodes = [
        %{
          id: a,
          caption: "Node",
          resolution: :resolved,
          fields: [edge.("next", b), edge.("missing", missing)]
        },
        %{id: b, caption: "Node", resolution: :resolved, fields: [edge.("previous", a)]}
      ]

      column = %{
        table_id: "item",
        table_name: "Item",
        table_group: :custom,
        id: "payload",
        name: "Payload",
        type: %{type: :external, target: a, cardinality: :one, raw: a},
        primary_key: false,
        deleted: false
      }

      db = %{
        bubble_id: "app",
        external_types: nodes,
        warnings: [],
        relationships: [],
        tables: [%{id: "item", name: "Item", group: :custom, columns: [column]}]
      }

      planned_names =
        BubbleEx.Db.Encoder.Plan.build(db).names |> Map.values() |> Enum.map(&String.downcase/1)

      for format <- [:postgres, :ecto, :ash, :convex] do
        assert {:ok, result} = Encoder.render(format, db, external_types: :preserve)
        normalized_content = String.downcase(result.content) |> String.replace(~r/[^a-z0-9]+/, "")
        normalized_names = Enum.map(planned_names, &String.replace(&1, ~r/[^a-z0-9]+/, ""))

        assert Enum.all?(normalized_names, &String.contains?(normalized_content, &1)),
               "missing planned names in #{format}"

        assert Enum.any?(result.warnings, &(&1.reason == :cycle_edge))
        assert Enum.any?(result.warnings, &(&1.reason == :unresolved_nested_target))
      end

      assert {:ok, xano} = Encoder.render(:xano, db, external_types: :preserve)
      assert xano.content =~ ~s("type": "json")
      assert Enum.any?(xano.warnings, &(&1.reason == :cycle_edge))
      assert Enum.any?(xano.warnings, &(&1.reason == :unresolved_nested_target))

      assert {:ok, zod} = Encoder.render(:zod, db, external_types: :preserve)
      assert Enum.all?(planned_names, &String.contains?(String.downcase(zod.content), &1))
      assert zod.content =~ "get next()"
      assert Enum.any?(zod.warnings, &(&1.reason == :unresolved_nested_target))
      refute Enum.any?(zod.warnings, &(&1.reason == :cycle_edge))

      assert {:ok, ecto_recursive} =
               Encoder.render(:ecto, db,
                 external_types: :preserve,
                 external_type_capabilities: %{ecto: [:recursive_embeds]}
               )

      assert ecto_recursive.content =~ "embeds_one"
      refute Enum.any?(ecto_recursive.warnings, &(&1.reason == :cycle_edge))

      assert {:ok, ash_recursive} =
               Encoder.render(:ash, db,
                 external_types: :preserve,
                 external_type_capabilities: %{ash: [:recursive_new_type]}
               )

      refute Enum.any?(ash_recursive.warnings, &(&1.reason == :cycle_edge))

      shuffled = %{
        db
        | external_types:
            nodes |> Enum.reverse() |> Enum.map(&%{&1 | fields: Enum.reverse(&1.fields)})
      }

      for format <- [:postgres, :ecto, :ash, :zod, :xano, :convex] do
        assert Encoder.render(format, shuffled, external_types: :preserve) ==
                 Encoder.render(format, db, external_types: :preserve)
      end
    end

    test "rejects unknown modes and mismatched capabilities" do
      assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
               Encoder.render(:dbml, %{}, external_types: :future)

      assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
               Encoder.render(:dbml, %{}, external_type_capabilities: %{tsql: [:future_json]})

      assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
               Encoder.render(:ecto, %{},
                 external_type_capabilities: %{ash: [:recursive_new_type]}
               )
    end

    test "defaults older maps without external_types to legacy mode" do
      assert {:ok, %Encoder.Result{content: content}} =
               Encoder.render(:dbml, %{bubble_id: "old", tables: [], relationships: []})

      assert content =~ ~s(Project "old")
    end

    test "every registered format deliberately handles opaque External API fields" do
      id = "api.apiconnector2.a.call.Shape"

      column = %{
        table_id: "item",
        table_name: "Item",
        table_group: :custom,
        id: "payload",
        name: "Payload",
        type: %{type: :external, target: id, cardinality: :one, raw: id},
        primary_key: false,
        deleted: false
      }

      db = %{
        bubble_id: "app",
        external_types: [],
        warnings: [],
        relationships: [],
        tables: [%{id: "item", name: "Item", group: :custom, columns: [column]}]
      }

      for format <- [:dbml, :postgres, :sqlite, :tsql, :ecto, :ash, :zod, :xano, :convex],
          mode <- [:preserve, :opaque, :legacy] do
        assert {:ok, %Encoder.Result{format: ^format, content: content, warnings: warnings}} =
                 Encoder.render(format, db, external_types: mode)

        assert is_binary(content) and content != ""

        if mode in [:opaque, :legacy] or format in [:dbml, :sqlite, :tsql] do
          assert Enum.any?(warnings, &(&1.kind == :external_type_rendering))
        end
      end
    end
  end
end
