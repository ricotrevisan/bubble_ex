defmodule BubbleEx.Db.DbmlTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Dbml
  alias BubbleEx.Db.Reader

  describe "encode/2 primary keys" do
    test "marks Reader-injected primary keys with [pk]" do
      attrs = %{
        "_id" => "app",
        "user_types" => %{
          "pet" => %{
            "%d" => "Pet",
            "%f3" => %{"f_name" => %{"%d" => "name", "%v" => "text"}}
          }
        },
        "option_sets" => %{
          "status" => %{
            "%d" => "Status",
            "attributes" => %{"f_color" => %{"%d" => "Color", "%v" => "text"}}
          }
        }
      }

      {:ok, db} = Reader.parse(attrs)
      {:ok, dbml} = Dbml.encode(db)

      assert dbml =~ ~s("_id" varchar [pk])
      assert dbml =~ ~s("Display" varchar [pk])
    end
  end

  describe "encode/2 relationships" do
    test "renders single references as many-to-one and list references as many-to-many" do
      attrs = %{
        "_id" => "app",
        "user_types" => %{
          "person" => %{
            "%d" => "Person",
            "%f3" => %{
              "f_pet" => %{"%d" => "pet", "%v" => "custom.pet"},
              "f_pets" => %{"%d" => "pets", "%v" => "list.custom.pet"}
            }
          },
          "pet" => %{
            "%d" => "Pet",
            "%f3" => %{"f_name" => %{"%d" => "name", "%v" => "text"}}
          }
        }
      }

      {:ok, db} = Reader.parse(attrs)
      {:ok, dbml} = Dbml.encode(db)

      assert dbml =~ ~s(Ref: custom."Person"."pet" > custom."Pet"."_id")
      assert dbml =~ ~s(Ref: custom."Person"."pets" <> custom."Pet"."_id")
    end
  end

  describe "encode/2 array types" do
    test "renders list types as the scalar rendering plus []" do
      attrs = %{
        "_id" => "app",
        "user_types" => %{
          "person" => %{
            "%d" => "Person",
            "%f3" => %{
              "f_pets" => %{"%d" => "pets", "%v" => "list.custom.pet"},
              "f_pics" => %{"%d" => "pics", "%v" => "list.image"},
              "f_tags" => %{"%d" => "tags", "%v" => "list.text"},
              "f_dates" => %{"%d" => "dates", "%v" => "list.date"},
              "f_flags" => %{"%d" => "flags", "%v" => "list.boolean"},
              "f_scores" => %{"%d" => "scores", "%v" => "list.number"}
            }
          },
          "pet" => %{
            "%d" => "Pet",
            "%f3" => %{"f_name" => %{"%d" => "name", "%v" => "text"}}
          }
        }
      }

      {:ok, db} = Reader.parse(attrs)
      {:ok, dbml} = Dbml.encode(db)

      assert dbml =~ ~s("pets" pet.id[])
      assert dbml =~ ~s("pics" bubble_image[])
      assert dbml =~ ~s("tags" varchar[])
      assert dbml =~ ~s("dates" datetime[])
      assert dbml =~ ~s("flags" bool[])
      assert dbml =~ ~s("scores" float[])
    end
  end

  describe "quote_identifier/1" do
    test "leaves safe identifiers unquoted" do
      assert Dbml.quote_identifier("test") == "test"
      assert Dbml.quote_identifier("_test") == "_test"
      assert Dbml.quote_identifier("te_st") == "te_st"
    end

    test "quotes identifiers containing special characters" do
      assert Dbml.quote_identifier("%d") == ~s("%d")
      assert Dbml.quote_identifier("d%d") == ~s("d%d")
      assert Dbml.quote_identifier("string has spaces") == ~s("string has spaces")
    end
  end

  test "combines and escapes DBML settings for external fields" do
    column = %{
      table_id: "t",
      table_name: "T",
      table_group: :custom,
      id: "p",
      name: "Payload",
      type: %{
        type: :external,
        target: "api.apiconnector2.a.call.O'Reilly\nShape",
        cardinality: :one,
        raw: "x"
      },
      primary_key: true,
      deleted: false
    }

    db = %{
      bubble_id: "app",
      tables: [%{id: "t", name: "T", group: :custom, columns: [column]}],
      relationships: [],
      external_types: [],
      warnings: []
    }

    assert {:ok, result} = BubbleEx.Db.Encoder.render(:dbml, db)

    assert result.content =~
             "[pk, note: 'External API type api.apiconnector2.a.call.O\\'Reilly Shape (one)']"
  end
end
