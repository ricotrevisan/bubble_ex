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
      # The stable key (the Model's `OptionValue.key`, Bubble's db_value) is
      # the primary key; the display text is an ordinary column.
      assert [%{id: "db_value", primary_key: true}, %{id: "display", primary_key: false}] =
               table.columns
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

      # The `list.` prefix is Bubble's own, so an invalid descriptor's
      # cardinality is still known (the Model's reading).
      assert Enum.find(order.columns, &(&1.id == "broken")).type == %{
               type: :opaque_external,
               target: nil,
               cardinality: :one,
               raw: "api."
             }

      refute Enum.find(order.columns, &(&1.id == "deleted"))

      assert Enum.map(db.external_types, & &1.id) == Enum.sort([address, event, geo, missing])
      assert Enum.find(db.external_types, &(&1.id == event)).resolution == :resolved
      assert Enum.find(db.external_types, &(&1.id == missing)).resolution == :opaque

      event_type = Enum.find(db.external_types, &(&1.id == event))
      assert Enum.find(event_type.fields, &(&1.id == "children")).type.target == event

      # One diagnostic per referencing field, each pointing at its descriptor.
      missing_diagnostics =
        Enum.filter(db.diagnostics, &(&1.code == :exact_type_definition_missing))

      assert Enum.map(missing_diagnostics, &{&1.subject, &1.path}) == [
               {%{type: "order", field: "missing_a"}, "/user_types/order/%f3/missing_a/%v"},
               {%{type: "order", field: "missing_b"}, "/user_types/order/%f3/missing_b/%v"}
             ]

      assert Enum.all?(missing_diagnostics, &(&1.details == %{external_type: missing}))
      assert Enum.any?(db.diagnostics, &(&1.code == :invalid_descriptor))

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

      assert db.diagnostics
             |> Enum.filter(&(&1.stage == :read))
             |> Enum.map(&{&1.code, &1.subject, &1.path}) == [
               {:conflicting_duplicate_definition, %{type: "item", field: "conflict"},
                "/user_types/item/%f3/conflict/%v"},
               {:connector_missing, %{type: "item", field: "ghost"},
                "/user_types/item/%f3/ghost/%v"}
             ]
    end

    test "a registry field definition that is not an object is opaque, not a crash" do
      shape = "api.apiconnector2.alpha.call.Shape"

      attrs = %{
        "user_types" => %{"item" => %{"%d" => "Item", "%f3" => %{"s" => %{"%v" => shape}}}},
        "settings" => %{
          "client_safe" => %{
            "apiconnector2" => %{
              "alpha" => %{
                "call" => %{
                  "ret_value" => shape,
                  "types" => Jason.encode!(%{shape => %{"fields" => %{"odd" => "not a field"}}})
                }
              }
            }
          }
        }
      }

      assert {:ok, db} = Reader.parse(attrs)
      [node] = db.external_types
      assert [%{id: "odd", type: %{type: :opaque_external}}] = node.fields

      assert db.diagnostics
             |> Enum.filter(&(&1.stage == :read))
             |> Enum.map(& &1.code)
             |> Enum.sort() == [:field_type_malformed, :incomplete_field_metadata]
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

    test "an option-set reference targets the option set's db_value PK, not an arbitrary attribute" do
      # The option set's "color" attribute sorts before the injected "db_value"
      # PK, so a naive lookup would point the enum reference at "color".
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
      assert to.id == "db_value"
    end

    test "a list (array) custom reference also targets the referenced table's _id" do
      # `list.custom.X` is a reference with is_array: true. It must still
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
      refute Enum.any?(ref_lines, &String.contains?(&1, "ghost"))
      # Only the built-in Created By -> User relationships remain.
      assert Enum.all?(ref_lines, &String.contains?(&1, ~s("Created By" > custom."User"."_id")))
    end
  end

  describe "parse/1 with export-shaped input (.bubble.json)" do
    test "reads user_types with display/fields keys" do
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
      assert [{from, to, :many_to_one}] =
               Enum.reject(db_map.relationships, fn {from, _, _} -> from.id == "Created By" end)

      assert from.source_path == "/user_types/task/fields/project_ref/value"
      assert from.table_id == "task"
      assert to.table_id == "project"
    end

    test "option-set columns are the declared attributes, not keys of the values" do
      attrs = %{
        "_id" => "synthexport",
        "option_sets" => %{
          "status" => %{
            "display" => "Status",
            "attributes" => %{"color" => %{"display" => "Color", "value" => "text"}},
            "values" => %{
              "v2" => %{"display" => "Closed", "db_value" => "closed", "sort_factor" => 2},
              "v1" => %{
                "display" => "Open",
                "db_value" => "open",
                "sort_factor" => 1,
                "color" => "green"
              },
              "v3" => %{"display" => "Gone", "db_value" => "gone", "deleted" => true}
            }
          }
        }
      }

      {:ok, db_map} = BubbleEx.Db.Reader.parse(attrs)

      status = Enum.find(db_map.tables, &(&1.id == "status"))
      assert status.name == "Status"
      assert status.group == :option

      assert Enum.map(status.columns, &{&1.id, &1.name}) ==
               [{"db_value", "db_value"}, {"display", "Display"}, {"color", "Color"}]

      # Values in Bubble's order (sort_factor), keyed by db_value; deleted ones left out.
      assert status.values == [
               %{id: "v1", name: "Open", db_value: "open"},
               %{id: "v2", name: "Closed", db_value: "closed"}
             ]
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
      assert [pk | built_in] = table.columns
      assert pk.primary_key

      assert Enum.map(built_in, & &1.id) == [
               "Created Date",
               "Modified Date",
               "Created By",
               "Slug"
             ]
    end

    test "user_type with a non-map fields value does not crash" do
      attrs = %{"_id" => "x", "user_types" => %{"odd" => %{"display" => "Odd", "fields" => nil}}}
      {:ok, db_map} = BubbleEx.Db.Reader.parse(attrs)
      assert Enum.find(db_map.tables, &(&1.id == "odd"))
    end
  end

  describe "projection of BubbleEx.Model" do
    @export %{
      "_id" => "proj",
      "user_types" => %{
        "task" => %{
          "display" => "Task",
          "fields" => %{
            "z_title_text" => %{
              "display" => "Title",
              "value" => "text",
              "default_val" => "untitled"
            },
            "a_old_text" => %{"display" => "Old", "value" => "text", "deleted" => true},
            "grid_list" => %{"display" => "Grid", "value" => "list.list.text"},
            "empty_ref" => %{"display" => "Empty", "value" => "custom."},
            "owner_user" => %{"display" => "Owner", "value" => "user"},
            "unnamed_text" => %{"value" => "text"}
          }
        },
        "archive" => %{"display" => "Archive", "deleted" => true, "fields" => %{}}
      },
      "option_sets" => %{
        "retired" => %{"display" => "Retired", "deleted" => true, "values" => %{}}
      }
    }

    test "parse/1 is project/2 of the Model" do
      {:ok, model} = BubbleEx.Model.build(@export)
      assert Reader.parse(@export) == {:ok, Reader.project(model, @export)}
    end

    test "drops deleted types, option sets and fields in the export key form" do
      {:ok, db} = Reader.parse(@export)
      assert Enum.map(db.tables, &{&1.group, &1.id}) == [custom: "task", custom: "user"]
      task = Enum.find(db.tables, &(&1.id == "task"))
      refute Enum.find(task.columns, &(&1.id == "a_old_text"))
    end

    test "keeps export-form defaults" do
      {:ok, db} = Reader.parse(@export)
      task = Enum.find(db.tables, &(&1.id == "task"))
      assert Enum.find(task.columns, &(&1.id == "z_title_text")).default == "untitled"
    end

    test "orders tables and columns by Bubble ID, injected and built-in columns first" do
      {:ok, db} = Reader.parse(@export)
      task = Enum.find(db.tables, &(&1.id == "task"))

      assert Enum.map(task.columns, & &1.id) ==
               ["_id", "Created Date", "Modified Date", "Created By", "Slug"] ++
                 ~w(empty_ref grid_list owner_user unnamed_text z_title_text)
    end

    test "types outside Bubble's vocabulary are unsupported, not guessed" do
      {:ok, db} = Reader.parse(@export)
      task = Enum.find(db.tables, &(&1.id == "task"))

      assert Enum.find(task.columns, &(&1.id == "grid_list")).type ==
               %{type: :unsupported, raw: "list.list.text"}

      assert Enum.find(task.columns, &(&1.id == "empty_ref")).type ==
               %{type: :unsupported, raw: "custom."}

      codes = Enum.map(db.diagnostics, & &1.code)
      assert :model_unsupported_field_type in codes
    end

    test "User is always a table, so user references resolve" do
      {:ok, db} = Reader.parse(@export)

      assert %{columns: [%{id: "_id", primary_key: true} | built_in]} =
               Enum.find(db.tables, &(&1.id == "user"))

      assert Enum.map(built_in, & &1.id) ==
               ["Created Date", "Modified Date", "Created By", "Slug", "email"]

      assert {%{id: "owner_user"}, %{table_id: "user", id: "_id"}, :many_to_one} =
               Enum.find(db.relationships, fn {from, _, _} -> from.id == "owner_user" end)

      assert Enum.any?(db.diagnostics, &(&1.code == :model_synthesized_user_type))
    end

    test "every table gets the Model's built-in fields; Created By references User" do
      {:ok, model} = BubbleEx.Model.build(@export)
      {:ok, db} = Reader.parse(@export)

      for table <- db.tables, table.group == :custom do
        system = BubbleEx.Model.data_type(model, table.id).system_fields
        expected = for f <- system, f.system != :unique_id, do: {f.id, f.name, f.type}
        built_in = Enum.slice(table.columns, 1, length(expected))

        assert Enum.map(built_in, &{&1.id, &1.name, &1.type}) ==
                 Enum.map(expected, fn {id, name, type} ->
                   {id, name, Reader.column_type(type)}
                 end)

        assert {_, %{table_id: "user", id: "_id"}, :many_to_one} =
                 Enum.find(db.relationships, fn {from, _, _} ->
                   from.table_id == table.id and from.id == "Created By"
                 end)
      end

      task = Enum.find(db.tables, &(&1.id == "task"))

      assert Enum.map(Enum.slice(task.columns, 1, 4), &{&1.name, &1.type}) == [
               {"Created Date", %{type: :utc_datetime_usec}},
               {"Modified Date", %{type: :utc_datetime_usec}},
               {"Created By", %{type: :reference, custom_type: "user"}},
               {"Slug", %{type: :string}}
             ]
    end

    test "only a live field replaces the built-in field with its Bubble ID" do
      app = %{
        "user_types" => %{
          "task" => %{
            "display" => "Task",
            "fields" => %{
              "Slug" => %{"display" => "Old slug", "value" => "text", "deleted" => true},
              "Created Date" => "not an object",
              "Modified Date" => %{"display" => "Touched", "value" => "text"}
            }
          }
        }
      }

      {:ok, model} = BubbleEx.Model.build(app)
      system = BubbleEx.Model.data_type(model, "task").system_fields
      assert Enum.map(system, & &1.id) == ["_id", "Created Date", "Created By", "Slug"]
      assert {:ok, %{system: :slug}} = BubbleEx.Model.field(model, "task", "Slug")

      {:ok, db} = Reader.parse(app)
      task = Enum.find(db.tables, &(&1.id == "task"))

      assert Enum.map(task.columns, &{&1.id, &1.name, &1.system}) == [
               {"_id", "_id", :unique_id},
               {"Created Date", "Created Date", :created_date},
               {"Created By", "Created By", :created_by},
               {"Slug", "Slug", :slug},
               {"Modified Date", "Touched", nil}
             ]
    end

    test "a missing display name falls back to the Bubble ID" do
      {:ok, db} = Reader.parse(@export)
      task = Enum.find(db.tables, &(&1.id == "task"))
      assert Enum.find(task.columns, &(&1.id == "unnamed_text")).name == "unnamed_text"
    end

    test "a live-form deleted type is dropped too" do
      app = %{"user_types" => %{"gone" => %{"%d" => "Gone", "%del" => true, "%f3" => %{}}}}
      {:ok, db} = Reader.parse(app)
      refute Enum.find(db.tables, &(&1.id == "gone"))
    end

    test "input that is not a JSON object is an error, not a crash" do
      assert {:error, %BubbleEx.Error{kind: :invalid_input}} = Reader.parse(nil)
      assert {:error, %BubbleEx.Error{kind: :invalid_input}} = Reader.parse([])
    end

    for fixture <- Path.wildcard("test/support/model/hostile_*.json") do
      @fixture fixture
      test "does not crash on #{Path.basename(fixture)} and every encoder renders it" do
        app = @fixture |> File.read!() |> Jason.decode!()
        {:ok, model} = BubbleEx.Model.build(app)
        assert {:ok, db} = Reader.parse(app)
        assert Enum.all?(db.diagnostics, &(&1 in model.diagnostics))

        for format <- ~w(dbml postgres sqlite tsql ecto zod xano convex)a do
          assert {:ok, %{content: content}} = BubbleEx.Db.Encoder.render(format, db)
          assert is_binary(content)
        end
      end
    end
  end

  describe "projection keeps the table view loadable" do
    @collisions "test/support/db/fixtures/collisions.json" |> File.read!() |> Jason.decode!()

    setup do
      {:ok, db} = Reader.parse(@collisions)
      %{db: db}
    end

    defp names(db, id), do: Enum.find(db.tables, &(&1.id == id)).columns |> Enum.map(& &1.name)

    test "column names are unique per table, case-insensitively, key columns first", %{db: db} do
      # Bubble's built-in fields keep their names; a defined field repeating
      # one is suffixed.
      assert names(db, "task") ==
               ["_id", "Created Date", "Modified Date", "Created By", "Slug"] ++
                 ["Title", "title_2", "_ID_2", "Tags", "Gone", "Retired", "Status"] ++
                 ["Created Date_2", "created by_2", "SLUG_2"]

      assert names(db, "user") ==
               ["_id", "Created Date", "Modified Date", "Created By", "Slug", "email", "Email_2"]

      # Suffixes follow Bubble ID order and skip names already taken.
      assert names(db, "status") ==
               ["db_value", "Display", "DB_VALUE_2", "Display_2", "Rank_2", "Rank", "Rank_3"]

      for table <- db.tables do
        folded = Enum.map(table.columns, &String.downcase(&1.name))
        assert folded == Enum.uniq(folded)
      end
    end

    test "table names are unique across groups, data types first", %{db: db} do
      assert Enum.map(db.tables, &{&1.id, &1.name}) == [
               {"task", "Task"},
               {"task_copy", "task_2"},
               {"user", "User"},
               {"status", "Status"},
               {"task_os", "TASK_3"}
             ]
    end

    test "a repeated option key keeps only its first value", %{db: db} do
      status = Enum.find(db.tables, &(&1.id == "status"))
      assert Enum.map(status.values, &{&1.id, &1.db_value}) == [{"v1", "open"}, {"v3", "closed"}]

      assert {:db_duplicate_option_value_dropped, "/option_sets/status/values/v2", _,
              subject: %{option_set: "status"}, details: %{value: "v2", key: "open"}} =
               Enum.find(
                 db.projection_diagnostics,
                 &(elem(&1, 0) == :db_duplicate_option_value_dropped)
               )
    end

    test "references to deleted definitions keep their column and are diagnosed", %{db: db} do
      for field <- ~w(e_gone_custom_gone f_retired_option_retired) do
        assert {_, nil, :many_to_one} =
                 Enum.find(db.relationships, fn {from, _, _} -> from.id == field end)
      end

      notes = for {:db_reference_to_omitted, _, _, opts} <- db.projection_diagnostics, do: opts
      assert Enum.map(notes, & &1[:details].target) == ["gone", "retired"]
    end

    test "SQL has no foreign key by default, only reference comments", %{db: db} do
      for format <- [:postgres, :sqlite, :tsql] do
        {:ok, %{content: sql}} = BubbleEx.Db.Encoder.render(format, db)
        refute sql =~ "FOREIGN KEY", "#{format}"
        comments = sql |> String.split("\n") |> Enum.filter(&(&1 =~ " -> "))
        assert Enum.any?(comments, &(&1 =~ ~r/Created By[\]"] ->/)), "#{format}"
        assert Enum.any?(comments, &(&1 =~ "created by_2")), "#{format}"
      end
    end

    test "enforced SQL has no foreign key on the built-in Created By, only on defined references",
         %{db: db} do
      for format <- [:postgres, :sqlite, :tsql] do
        {:ok, %{content: sql}} = BubbleEx.Db.Encoder.render(format, db, foreign_keys: :enforced)
        fks = sql |> String.split("\n") |> Enum.filter(&(&1 =~ "FOREIGN KEY"))
        refute Enum.any?(fks, &(&1 =~ ~r/Created By[\]"]\)/)), "#{format}: #{inspect(fks)}"
        assert Enum.any?(fks, &(&1 =~ "created by_2")), "#{format}: #{inspect(fks)}"
      end
    end

    test "Encoder.render rejects an unknown foreign_keys mode", %{db: db} do
      assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
               BubbleEx.Db.Encoder.render(:postgres, db, foreign_keys: :deferred)
    end

    test "Encoder.render emits the projection's diagnostics for its target", %{db: db} do
      {:ok, result} = BubbleEx.Db.Encoder.render(:sqlite, db)
      suffixed = Enum.filter(result.diagnostics, &(&1.code == :db_name_suffixed))
      assert length(suffixed) == 11
      assert Enum.all?(suffixed, &(&1.stage == {:target, :sqlite}))
    end

    test "only diagnostics about the tables are kept, not privacy or expression ones", %{db: db} do
      {:ok, model} = BubbleEx.Model.build(@collisions)
      assert Enum.any?(model.diagnostics, &(&1.stage == :parse))
      refute Enum.any?(db.diagnostics, &(&1.stage == :parse))
      assert Enum.all?(db.diagnostics, &(&1 in model.diagnostics))
    end
  end
end
