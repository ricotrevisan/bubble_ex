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

    test "retains normalization inputs without guessing unsupported types" do
      attrs = %{
        "_id" => "x",
        "user_types" => %{
          "thing" => %{
            "%d" => "Thing",
            "%f3" => %{
              "gone" => %{"%d" => "Gone", "%v" => "text", "%del" => true},
              "odd" => %{"%d" => "Odd", "%v" => "mystery", "default_val" => "x"}
            }
          }
        },
        "option_sets" => %{
          "status" => %{
            "%d" => "Status",
            "values" => %{
              "open" => %{"%d" => "Open", "db_value" => "open"},
              "gone" => %{"%d" => "Gone", "%del" => true}
            }
          }
        }
      }

      assert {:ok, db} = Reader.parse(attrs)
      thing = Enum.find(db.tables, &(&1.id == "thing"))
      refute Enum.any?(thing.columns, &(&1.id == "gone"))
      odd = Enum.find(thing.columns, &(&1.id == "odd"))
      assert odd.type == %{type: :unsupported, raw: "mystery"}
      assert odd.default == "x"
      status = Enum.find(db.tables, &(&1.id == "status"))
      assert status.values == [%{id: "open", name: "Open", db_value: "open"}]
    end
  end

  describe "parse/1 External API types" do
    test "resolves the deterministic database-reachable API Connector v2 graph fail-soft" do
      event = "api.apiconnector2.alpha.events.Event"
      address = "api.apiconnector2.alpha.addresses.Address"
      geo = "api.apiconnector2.beta.geo.Geo"
      missing = "api.apiconnector2.alpha.addresses.Missing"

      attrs = %{
        "_id" => "synthetic-external-types",
        "user_types" => %{
          "order" => %{
            "%d" => "Order",
            "%f3" => %{
              "shipping" => %{"%d" => "Shipping", "%v" => address},
              "events" => %{"%d" => "Events", "%v" => "list." <> event},
              "missing_a" => %{"%d" => "Missing A", "%v" => missing},
              "missing_b" => %{"%d" => "Missing B", "%v" => missing},
              "broken" => %{"%d" => "Broken", "%v" => "api."},
              "deleted" => %{"%d" => "Deleted", "%v" => event, "%del" => true}
            }
          }
        },
        "settings" => %{
          "client_safe" => %{
            "apiconnector2" => %{
              "alpha" => %{
                "addresses" => %{
                  "ret_value" => address,
                  "types" =>
                    Jason.encode!(%{
                      address => %{
                        "caption" => "Address",
                        "fields" => %{
                          "street" => %{
                            "caption" => "Street",
                            "path" => ["street"],
                            "ret_btype" => "text"
                          },
                          "tags" => %{
                            "caption" => "Tags",
                            "path" => ["tags"],
                            "ret_value" => "list.text"
                          },
                          "geo" => %{"path" => ["geo"], "ret_btype" => geo},
                          "events" => %{
                            "caption" => "Events",
                            "path" => ["events"],
                            "ret_btype" => "list." <> event
                          }
                        }
                      }
                    })
                },
                "events" => %{
                  "ret_value" => event,
                  "types" =>
                    Jason.encode!(%{
                      event => %{
                        "caption" => "Event",
                        "fields" => %{
                          "at" => %{
                            "caption" => "At",
                            "path" => ["at"],
                            "ret_btype" => "date_unix"
                          },
                          "children" => %{
                            "caption" => "Children",
                            "path" => ["children"],
                            "ret_btype" => "list." <> event
                          }
                        }
                      }
                    })
                }
              },
              "beta" => %{
                "geo" => %{
                  "ret_value" => geo,
                  "types" =>
                    Jason.encode!(%{
                      geo => %{
                        "caption" => "Geo",
                        "fields" => %{"lat" => %{"path" => ["lat"], "ret_btype" => "number"}}
                      }
                    })
                }
              }
            }
          }
        }
      }

      assert {:ok, db} = Reader.parse(attrs)
      order = Enum.find(db.tables, &(&1.id == "order"))

      assert Enum.find(order.columns, &(&1.id == "shipping")).type == %{
               type: :external,
               target: address,
               cardinality: :one,
               raw: address
             }

      assert Enum.find(order.columns, &(&1.id == "events")).type == %{
               type: :external,
               target: event,
               cardinality: :many,
               raw: "list." <> event
             }

      assert Enum.find(order.columns, &(&1.id == "broken")).type == %{
               type: :opaque_external,
               target: nil,
               cardinality: :unknown,
               raw: "api."
             }

      assert Enum.map(db.external_types, & &1.id) == Enum.sort([address, event, geo, missing])
      assert Enum.find(db.external_types, &(&1.id == event)).resolution == :resolved
      assert Enum.find(db.external_types, &(&1.id == missing)).resolution == :opaque

      event_type = Enum.find(db.external_types, &(&1.id == event))
      assert Enum.find(event_type.fields, &(&1.id == "children")).type.target == event

      missing_warning = Enum.find(db.warnings, &(&1.category == :exact_type_definition_missing))

      assert Enum.map(missing_warning.occurrences, & &1.root.field_id) == [
               "missing_a",
               "missing_b"
             ]

      assert Enum.any?(db.warnings, &(&1.category == :invalid_descriptor))

      reordered =
        put_in(
          attrs,
          ["user_types", "order", "%f3"],
          attrs["user_types"]["order"]["%f3"] |> Enum.reverse() |> Map.new()
        )

      assert Reader.parse(reordered) == {:ok, db}
    end

    test "keeps missing and contradictory registry metadata addressable" do
      missing_connector = "api.apiconnector2.ghost.call.Shape"
      conflict = "api.apiconnector2.alpha.call.Shape"
      definition = fn scalar -> %{"fields" => %{"value" => %{"ret_btype" => scalar}}} end

      attrs = %{
        "_id" => "synthetic-failures",
        "user_types" => %{
          "item" => %{
            "%d" => "Item",
            "%f3" => %{
              "ghost" => %{"%d" => "Ghost", "%v" => missing_connector},
              "conflict" => %{"%d" => "Conflict", "%v" => conflict}
            }
          }
        },
        "settings" => %{
          "client_safe" => %{
            "apiconnector2" => %{
              "alpha" => %{
                "call" => %{
                  "ret_value" => conflict,
                  "types" => Jason.encode!(%{conflict => definition.("text")})
                }
              },
              "copy" => %{
                "other" => %{"types" => Jason.encode!(%{conflict => definition.("number")})}
              }
            }
          }
        }
      }

      assert {:ok, db} = Reader.parse(attrs)
      assert Enum.find(db.external_types, &(&1.id == conflict)).resolution == :conflicted
      assert Enum.find(db.external_types, &(&1.id == missing_connector)).resolution == :opaque
      assert Enum.any?(db.warnings, &(&1.category == :conflicting_duplicate_definition))
      assert Enum.any?(db.warnings, &(&1.category == :connector_missing))
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
      {_from, to, dir} = rel
      assert to.table_id == "target"
      assert to.id == "_id"
      # Many source rows can point at the same target row.
      assert dir == :many_to_one
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
      # Each row holds many targets and each target can appear in many rows.
      assert dir == :many_to_many
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

  describe "parse/1 with export-shaped input (.bubble.json)" do
    test "normalizes user_types with display/fields keys" do
      attrs = %{
        "_id" => "synthexport",
        "user_types" => %{
          "task" => %{
            "display" => "Task",
            "fields" => %{
              "title_text" => %{"display" => "Title", "value" => "text"},
              "project_ref" => %{"display" => "Project", "value" => "custom.project"}
            }
          },
          "project" => %{
            "display" => "Project",
            "fields" => %{"name_text" => %{"display" => "Name", "value" => "text"}}
          }
        }
      }

      {:ok, db_map} = BubbleEx.Db.Reader.parse(attrs)

      task = Enum.find(db_map.tables, &(&1.id == "task"))
      assert task.name == "Task"
      title = Enum.find(task.columns, &(&1.id == "title_text"))
      assert title.name == "Title"
      assert title.type.type == :string

      # the custom.project reference resolves to a relationship (a single
      # reference column is many-to-one: many tasks point at one project)
      assert [{from, to, :many_to_one}] = db_map.relationships
      assert from.table_id == "task"
      assert to.table_id == "project"
    end

    test "normalizes option_sets with display/values keys and derives attributes" do
      attrs = %{
        "_id" => "synthexport",
        "option_sets" => %{
          "status" => %{
            "display" => "Status",
            "values" => %{
              "v1" => %{"display" => "Open", "db_value" => "open", "sort_factor" => 1},
              "v2" => %{"display" => "Closed", "db_value" => "closed", "sort_factor" => 2}
            }
          }
        }
      }

      {:ok, db_map} = BubbleEx.Db.Reader.parse(attrs)

      status = Enum.find(db_map.tables, &(&1.id == "status"))
      assert status.name == "Status"
      assert status.group == :option

      db_value = Enum.find(status.columns, &(&1.id == "db_value"))
      assert db_value.type.type == :string

      sort_factor = Enum.find(status.columns, &(&1.id == "sort_factor"))
      assert sort_factor.type.type == :float

      # injected PK still present
      assert Enum.find(status.columns, & &1.primary_key).id == "display"
    end

    test "scraped shape still parses identically" do
      attrs = %{
        "_id" => "synthapp",
        "user_types" => %{
          "onboarding_answer" => %{
            "%d" => "Onboarding Answer",
            "%f3" => %{"label_text" => %{"%d" => "label", "%v" => "text"}}
          }
        }
      }

      {:ok, db_map} = BubbleEx.Db.Reader.parse(attrs)
      table = Enum.find(db_map.tables, &(&1.id == "onboarding_answer"))
      assert table.name == "Onboarding Answer"
    end

    test "user_type without a fields key parses to a table with only the injected PK" do
      attrs = %{"_id" => "x", "user_types" => %{"ghost" => %{"display" => "Ghost"}}}
      {:ok, db_map} = BubbleEx.Db.Reader.parse(attrs)
      table = Enum.find(db_map.tables, &(&1.id == "ghost"))
      assert table.name == "Ghost"
      assert [pk] = table.columns
      assert pk.primary_key
    end

    test "user_type with a non-map fields value does not crash" do
      attrs = %{"_id" => "x", "user_types" => %{"odd" => %{"display" => "Odd", "fields" => nil}}}
      {:ok, db_map} = BubbleEx.Db.Reader.parse(attrs)
      assert Enum.find(db_map.tables, &(&1.id == "odd"))
    end
  end
end
