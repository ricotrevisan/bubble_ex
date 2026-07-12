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

    test "rejects unknown modes and mismatched capabilities" do
      assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
               Encoder.render(:dbml, %{}, external_types: :future)

      assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
               Encoder.render(:dbml, %{}, external_type_capabilities: %{tsql: [:future_json]})
    end

    test "defaults older maps without external_types to legacy mode" do
      assert {:ok, %Encoder.Result{content: content}} =
               Encoder.render(:dbml, %{bubble_id: "old", tables: [], relationships: []})

      assert content =~ ~s(Project "old")
    end
  end
end
