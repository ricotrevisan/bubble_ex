defmodule BubbleEx.Db.ZodTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Zod

  defp col(id, name, type, opts \\ []) do
    %{
      table_id: Keyword.get(opts, :table_id, "t1"),
      table_name: Keyword.get(opts, :table_name, "Thing"),
      table_group: Keyword.get(opts, :table_group, :custom),
      id: id,
      name: name,
      type: type,
      primary_key: Keyword.get(opts, :primary_key, false),
      deleted: Keyword.get(opts, :deleted, false)
    }
  end

  defp thing_db(columns, relationships \\ []) do
    %{
      bubble_id: "app",
      tables: [%{id: "t1", name: "Thing", group: :custom, columns: columns}],
      relationships: relationships
    }
  end

  test "emits the import, schema const, fields, and inferred type alias" do
    db =
      thing_db([
        col("name_field", "name", %{type: :string}),
        col("score_field", "score", %{type: :float}),
        col("_id", "_id", %{type: :string}, primary_key: true)
      ])

    assert {:ok, schema} = Zod.encode(db)
    assert schema =~ "import { z } from 'zod';"
    assert schema =~ "export const ThingSchema = z.object({"
    assert schema =~ "  name: z.string().nullish(),"
    assert schema =~ "  score: z.number().nullish(),"
    assert schema =~ "  _id: z.string(),"
    assert schema =~ "export type Thing = z.infer<typeof ThingSchema>;"
  end

  test "does not mark the primary key as nullish" do
    db = thing_db([col("_id", "_id", %{type: :string}, primary_key: true)])
    assert {:ok, schema} = Zod.encode(db)
    assert schema =~ "  _id: z.string(),"
    refute schema =~ "_id: z.string().nullish()"
  end

  test "maps each Bubble scalar/custom type to its Zod expression" do
    db =
      thing_db([
        col("a", "a", %{type: :boolean}),
        col("b", "b", %{type: :utc_datetime_usec}),
        col("c", "c", %{type: :custom, custom_type: "bubble_image"}),
        col("d", "d", %{type: :custom, custom_type: "bubble_file"}),
        col("e", "e", %{type: :custom, custom_type: "bubble_geo_address"}),
        col("f", "f", %{type: :api, custom_type: "x.y"})
      ])

    assert {:ok, schema} = Zod.encode(db)
    assert schema =~ "  a: z.boolean().nullish(),"
    assert schema =~ "  b: z.string().datetime().nullish(),"
    assert schema =~ "  c: z.string().nullish(),"
    assert schema =~ "  d: z.string().nullish(),"
    assert schema =~ "  e: z.object({}).passthrough().nullish(), // bubble_geo_address"
    assert schema =~ "  f: z.string().nullish(), // api -> x.y"
  end

  test "wraps list fields in z.array(...)" do
    db = thing_db([col("tags", "tags", %{type: :string, is_array: true})])
    assert {:ok, schema} = Zod.encode(db)
    assert schema =~ "  tags: z.array(z.string()).nullish(),"
  end

  test "wraps a list reference in z.array(z.string()) with a reference comment" do
    db =
      thing_db([
        col("refs", "owners", %{type: :reference, custom_type: "user", is_array: true})
      ])

    assert {:ok, schema} = Zod.encode(db)
    assert schema =~ "  owners: z.array(z.string()).nullish(), // reference -> user"
  end

  test "renders a scalar reference as z.string() with a target comment" do
    db = thing_db([col("ref", "owner", %{type: :reference, custom_type: "user"})])
    assert {:ok, schema} = Zod.encode(db)
    assert schema =~ "  owner: z.string().nullish(), // reference -> user"
  end

  test "renders an enum as z.string() with an option-set comment" do
    db = thing_db([col("st", "status", %{type: :enum, custom_type: "status_type"})])
    assert {:ok, schema} = Zod.encode(db)

    assert schema =~
             "  status: z.string().nullish(), // enum -> status_type option set (values not in IR)"
  end

  test "quotes field keys that are not valid JS identifiers" do
    db = thing_db([col("f", "first name", %{type: :string})])
    assert {:ok, schema} = Zod.encode(db)
    assert schema =~ "  'first name': z.string().nullish(),"
  end

  test "escapes single quotes inside quoted field keys" do
    db = thing_db([col("f", "a'b c", %{type: :string})])
    assert {:ok, schema} = Zod.encode(db)
    assert schema =~ "  'a\\'b c': z.string().nullish(),"
  end

  test "respects :id naming for the schema const and field keys" do
    db = thing_db([col("name_field", "name", %{type: :string})])
    assert {:ok, schema} = Zod.encode(db, naming: :id)
    assert schema =~ "export const T1Schema = z.object({"
    assert schema =~ "  name_field: z.string().nullish(),"
    assert schema =~ "export type T1 = z.infer<typeof T1Schema>;"
  end

  test "uses :proper naming by default (display names, PascalCased const)" do
    db = thing_db([col("name_field", "name", %{type: :string})])
    assert {:ok, schema} = Zod.encode(db)
    assert schema =~ "export const ThingSchema = z.object({"
    assert schema =~ "  name: z.string().nullish(),"
  end

  test "skips deleted columns" do
    db =
      thing_db([
        col("keep", "keep", %{type: :string}),
        col("gone", "gone", %{type: :string}, deleted: true)
      ])

    assert {:ok, schema} = Zod.encode(db)
    assert schema =~ "  keep: z.string().nullish(),"
    refute schema =~ "gone"
  end

  test "omits api-group placeholder tables" do
    db = %{
      bubble_id: "app",
      tables: [%{id: "x.y", name: "x.y", group: :api, columns: []}],
      relationships: []
    }

    assert {:ok, schema} = Zod.encode(db)
    refute schema =~ "x.y"
  end

  test "PascalCases multi-word display names" do
    db = %{
      bubble_id: "app",
      tables: [
        %{
          id: "t1",
          name: "Survey Response",
          group: :custom,
          columns: [col("f", "answer", %{type: :string})]
        }
      ],
      relationships: []
    }

    assert {:ok, schema} = Zod.encode(db)
    assert schema =~ "export const SurveyResponseSchema = z.object({"
    assert schema =~ "export type SurveyResponse = z.infer<typeof SurveyResponseSchema>;"
  end

  test "renders reusable loose External API schemas with getter recursion" do
    id = "api.apiconnector2.a.call.Node"

    db =
      thing_db([
        col("payload", "payload", %{type: :external, target: id, cardinality: :one, raw: id})
      ])
      |> Map.put(:external_types, [
        %{
          id: id,
          resolution: :resolved,
          fields: [
            %{
              id: "name",
              caption: "Name",
              type: %{type: :scalar, scalar: :text, cardinality: :one}
            },
            %{
              id: "children",
              caption: "Children",
              type: %{type: :external, target: id, cardinality: :many}
            }
          ]
        }
      ])

    assert {:ok, schema} = Zod.encode(db, external_types: :preserve)
    assert schema =~ "export const NodeSchema = z.looseObject({"
    assert schema =~ "get Children() { return z.array(NodeSchema).nullish(); }"
    assert schema =~ "payload: NodeSchema.nullish()"
  end

  test "uses JSON fallback in opaque mode without undeclared schemas" do
    id = "api.apiconnector2.a.call.Node"

    db =
      thing_db([
        col("payload", "payload", %{type: :external, target: id, cardinality: :one, raw: id})
      ])
      |> Map.put(:external_types, [])

    assert {:ok, schema} = Zod.encode(db, external_types: :opaque)
    assert schema =~ "payload: z.json().nullish()"
    refute schema =~ "NodeSchema"
  end
end
