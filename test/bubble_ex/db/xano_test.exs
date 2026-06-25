defmodule BubbleEx.Db.XanoTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Xano

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

  defp encode(db, opts \\ []) do
    assert {:ok, json} = Xano.encode(db, opts)
    Jason.decode!(json)
  end

  defp table(decoded, name), do: Enum.find(decoded, &(&1["name"] == name))
  defp field(table, name), do: Enum.find(table["fields"], &(&1["name"] == name))

  # The output array leads with a `_note` caveat object; tables follow it.
  defp tables(decoded), do: Enum.reject(decoded, &Map.has_key?(&1, "_note"))

  test "leads the output with a format-caveat note" do
    [thing] = encode(thing_db([col("name_field", "name", %{type: :string})])) |> tables()
    assert thing["name"] == "thing"

    decoded = encode(thing_db([col("name_field", "name", %{type: :string})]))
    note = Enum.find(decoded, &Map.has_key?(&1, "_note"))
    assert note["_note"] =~ "Metadata API"
  end

  test "emits a table object with snake_cased name and fields" do
    db =
      thing_db([
        col("name_field", "name", %{type: :string}),
        col("score_field", "score", %{type: :float}),
        col("_id", "_id", %{type: :string}, primary_key: true)
      ])

    [thing] = encode(db) |> tables()
    assert thing["name"] == "thing"
    assert field(thing, "name") == %{"name" => "name", "type" => "text", "style" => "single"}
    assert field(thing, "score") == %{"name" => "score", "type" => "decimal", "style" => "single"}

    assert field(thing, "_id") == %{
             "name" => "_id",
             "type" => "text",
             "style" => "single",
             "description" => "Bubble primary key (link manually in Xano)"
           }
  end

  test "maps each Bubble type to its Xano type" do
    db =
      thing_db([
        col("a", "a", %{type: :boolean}),
        col("b", "b", %{type: :utc_datetime_usec}),
        col("c", "c", %{type: :custom, custom_type: "bubble_image"}),
        col("d", "d", %{type: :custom, custom_type: "bubble_file"}),
        col("e", "e", %{type: :custom, custom_type: "bubble_geo_address"}),
        col("f", "f", %{type: :api, custom_type: "x.y"})
      ])

    [thing] = encode(db) |> tables()
    assert field(thing, "a")["type"] == "bool"
    assert field(thing, "b")["type"] == "timestamp"
    assert field(thing, "c")["type"] == "text"
    assert field(thing, "d")["type"] == "text"
    assert field(thing, "e")["type"] == "json"
    assert field(thing, "f")["type"] == "text"
  end

  test "renders list fields as the base type with style: list" do
    db =
      thing_db([
        col("tags", "tags", %{type: :string, is_array: true}),
        col("nums", "nums", %{type: :float, is_array: true})
      ])

    [thing] = encode(db) |> tables()

    assert field(thing, "tags") == %{
             "name" => "tags",
             "type" => "text",
             "style" => "list"
           }

    assert field(thing, "nums") == %{
             "name" => "nums",
             "type" => "decimal",
             "style" => "list"
           }
  end

  test "degrades a scalar reference to text with a ref comment" do
    from =
      col("ref", "owner", %{type: :reference, custom_type: "user"},
        table_id: "t1",
        table_name: "Thing"
      )

    to =
      col("_id", "_id", %{type: :string},
        table_id: "user",
        table_name: "User",
        primary_key: true
      )

    db = thing_db([from], [{from, to, :one_to_one}])
    [thing] = encode(db) |> tables()

    assert field(thing, "owner") == %{
             "name" => "owner",
             "type" => "text",
             "style" => "single",
             "description" => "ref:user._id (link manually in Xano)"
           }
  end

  test "renders a list reference as text with style: list and a ref description" do
    from =
      col("refs", "owners", %{type: :reference, custom_type: "user", is_array: true})

    to =
      col("_id", "_id", %{type: :string},
        table_id: "user",
        table_name: "User",
        primary_key: true
      )

    db = thing_db([from], [{from, to, :one_to_many}])
    [thing] = encode(db) |> tables()

    assert field(thing, "owners") == %{
             "name" => "owners",
             "type" => "text",
             "style" => "list",
             "description" => "ref:user._id (link manually in Xano)"
           }
  end

  test "degrades an enum to the native enum type with an enum description" do
    from = col("status_ref", "status", %{type: :enum, custom_type: "status_type"})

    to =
      col("display", "Display", %{type: :string},
        table_id: "status_type",
        table_name: "Status Type",
        table_group: :option,
        primary_key: true
      )

    db = thing_db([from], [{from, to, :one_to_one}])
    [thing] = encode(db) |> tables()

    assert field(thing, "status") == %{
             "name" => "status",
             "type" => "enum",
             "style" => "single",
             "values" => [],
             "description" => "enum:status_type (option values not in IR)"
           }
  end

  test "falls back to the type custom_type when no relationship is present" do
    db = thing_db([col("ref", "owner", %{type: :reference, custom_type: "user"})])
    [thing] = encode(db) |> tables()
    assert field(thing, "owner")["description"] == "ref:user (link manually in Xano)"
  end

  test "respects :id naming for table, field, and comment names" do
    from =
      col("field_owner", "owner", %{type: :reference, custom_type: "user"})

    to =
      col("_id", "Unique id", %{type: :string},
        table_id: "user_type",
        table_name: "User",
        primary_key: true
      )

    db = thing_db([from], [{from, to, :one_to_one}])
    [thing] = encode(db, naming: :id) |> tables()
    assert thing["name"] == "t1"
    owner = field(thing, "field_owner")
    assert owner["name"] == "field_owner"
    assert owner["description"] == "ref:user_type._id (link manually in Xano)"
  end

  test "skips deleted columns" do
    db =
      thing_db([
        col("keep", "keep", %{type: :string}),
        col("gone", "gone", %{type: :string}, deleted: true)
      ])

    [thing] = encode(db) |> tables()
    assert field(thing, "keep")
    refute field(thing, "gone")
  end

  test "omits api-group placeholder tables" do
    db = %{
      bubble_id: "app",
      tables: [
        %{id: "t1", name: "Thing", group: :custom, columns: []},
        %{id: "x.y", name: "x.y", group: :api, columns: []}
      ],
      relationships: []
    }

    decoded = encode(db)
    assert table(decoded, "thing")
    refute table(decoded, "x.y")
  end
end
