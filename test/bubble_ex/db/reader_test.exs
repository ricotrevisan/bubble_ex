defmodule BubbleEx.Db.ReaderTest do
  use ExUnit.Case

  alias BubbleEx.Db.Reader

  @attrs %{
    "_id" => "synthapp",
    "user_types" => %{
      "onboarding_answer" => %{
        "%d" => "Onboarding Answer",
        "%f3" => %{
          "archived__boolean" => %{"%d" => "Archived?", "%v" => "boolean"},
          "label_text" => %{"%d" => "label", "%v" => "text"}
        }
      }
    }
  }

  describe "parse/1" do
    setup do
      attrs = @attrs
      {:ok, db_map} = Reader.parse(attrs)
      {:ok, attrs: attrs, db_map: db_map}
    end

    test "bubble_id", %{attrs: attrs} do
      assert attrs["_id"] == "synthapp"
    end

    test "db_map has bubble_id", %{db_map: db_map} do
      assert db_map.bubble_id == "synthapp"
    end

    test "db_map has tables", %{db_map: db_map} do
      tables = Map.get(db_map, :tables)
      onboarding_answer_table = Enum.find(tables, &(&1.id == "onboarding_answer"))

      assert Map.has_key?(db_map, :tables) == true
      assert is_list(tables) == true
      assert onboarding_answer_table
      assert onboarding_answer_table.id == "onboarding_answer"
      assert onboarding_answer_table.name == "Onboarding Answer"
      assert onboarding_answer_table.group == :custom
    end

    test "columns", %{db_map: db_map} do
      tables = Map.get(db_map, :tables)
      onboarding_answer_table = Enum.find(tables, &(&1.id == "onboarding_answer"))

      column =
        Enum.find(onboarding_answer_table.columns, fn column ->
          column.id == "archived__boolean"
        end)

      assert column
      assert column.id == "archived__boolean"
      assert column.name == "Archived?"
    end

    test "marks the injected custom primary-key column", %{db_map: db_map} do
      table = Enum.find(db_map.tables, &(&1.id == "onboarding_answer"))
      pk = Enum.find(table.columns, & &1.primary_key)
      assert pk.id == "_id"
      # every other column is explicitly non-PK
      assert Enum.count(table.columns, & &1.primary_key) == 1
    end

    test "marks the injected option-set primary-key column" do
      attrs = %{
        "_id" => "synthapp",
        "option_sets" => %{
          "status_type" => %{"%d" => "Status Type", "attributes" => %{}}
        }
      }

      {:ok, db_map} = Reader.parse(attrs)
      table = Enum.find(db_map.tables, &(&1.id == "status_type"))
      pk = Enum.find(table.columns, & &1.primary_key)
      assert pk.id == "display"
    end
  end

  describe "parse/1 relationship targets" do
    test "a custom-type reference targets the referenced table's _id, not an arbitrary column" do
      # The target table's only declared field, "_archived", sorts *before* the
      # Reader-injected "_id" in Elixir term order. A naive "first column whose
      # table_id matches" lookup therefore points the reference at "_archived"
      # instead of the "_id" primary key — the bug behind broken DBML Ref links.
      attrs = %{
        "_id" => "synthapp",
        "user_types" => %{
          "source" => %{
            "%d" => "Source",
            "%f3" => %{
              "field_ref" => %{"%d" => "ref", "%v" => "custom.target"}
            }
          },
          "target" => %{
            "%d" => "Target",
            "%f3" => %{
              "_archived" => %{"%d" => "Archived?", "%v" => "boolean"}
            }
          }
        }
      }

      {:ok, db} = Reader.parse(attrs)

      rel =
        Enum.find(db.relationships, fn {from, _to, _dir} ->
          from.table_id == "source" and from.id == "field_ref"
        end)

      assert rel, "expected a relationship from source.field_ref to target"
      {_from, to, _dir} = rel
      assert to.table_id == "target"
      assert to.id == "_id"
    end

    test "an option-set reference targets the option set's display PK, not an arbitrary attribute" do
      # The option set's "color" attribute sorts before the injected "display"
      # PK, so the naive lookup would point the enum reference at "color".
      attrs = %{
        "_id" => "synthapp",
        "user_types" => %{
          "source" => %{
            "%d" => "Source",
            "%f3" => %{
              "field_status" => %{"%d" => "status", "%v" => "option.status_type"}
            }
          }
        },
        "option_sets" => %{
          "status_type" => %{
            "%d" => "Status Type",
            "attributes" => %{
              "color" => %{"%d" => "Color", "%v" => "text"}
            }
          }
        }
      }

      {:ok, db} = Reader.parse(attrs)

      rel =
        Enum.find(db.relationships, fn {from, _to, _dir} ->
          from.table_id == "source" and from.id == "field_status"
        end)

      assert rel, "expected a relationship from source.field_status to status_type"
      {_from, to, _dir} = rel
      assert to.table_id == "status_type"
      assert to.id == "display"
    end

    test "a list (array) custom reference also targets the referenced table's _id" do
      # `list.custom.X` flows through which_type/1's `list.` Map.merge path,
      # producing is_array: true alongside the reference type. It must still
      # resolve to the target's _id PK.
      attrs = %{
        "_id" => "synthapp",
        "user_types" => %{
          "source" => %{
            "%d" => "Source",
            "%f3" => %{
              "field_refs" => %{"%d" => "refs", "%v" => "list.custom.target"}
            }
          },
          "target" => %{
            "%d" => "Target",
            "%f3" => %{
              "_archived" => %{"%d" => "Archived?", "%v" => "boolean"}
            }
          }
        }
      }

      {:ok, db} = Reader.parse(attrs)

      rel =
        Enum.find(db.relationships, fn {from, _to, _dir} ->
          from.table_id == "source" and from.id == "field_refs"
        end)

      assert rel, "expected a relationship from source.field_refs to target"
      {_from, to, dir} = rel
      assert to.table_id == "target"
      assert to.id == "_id"
      assert dir == :one_to_many
    end

    test "a reference to a missing table resolves to a nil target and is dropped from the DBML" do
      attrs = %{
        "_id" => "synthapp",
        "user_types" => %{
          "source" => %{
            "%d" => "Source",
            "%f3" => %{
              "field_ghost" => %{"%d" => "ghost", "%v" => "custom.nonexistent"}
            }
          }
        }
      }

      {:ok, db} = Reader.parse(attrs)

      rel =
        Enum.find(db.relationships, fn {from, _to, _dir} ->
          from.table_id == "source" and from.id == "field_ghost"
        end)

      assert rel, "expected the orphaned reference to still be parsed"
      assert {_from, nil, _dir} = rel

      # A nil target must not crash encoding and must emit no relationship line.
      # (The field's column *type* still renders as `nonexistent.id`; only the
      # Ref: relationship is dropped.)
      assert {:ok, dbml} = BubbleEx.Db.Dbml.encode(db)
      ref_lines = dbml |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "Ref:"))
      assert ref_lines == []
    end
  end
end
