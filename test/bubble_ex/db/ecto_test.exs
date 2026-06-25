defmodule BubbleEx.Db.EctoTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Ecto

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

  test "emits a schema module, fields, and a changeset" do
    db =
      thing_db([
        col("name_field", "name", %{type: :string}),
        col("score_field", "score", %{type: :float}),
        col("_id", "_id", %{type: :string}, primary_key: true)
      ])

    assert {:ok, code} = Ecto.encode(db)
    assert code =~ "defmodule MyApp.Thing do"
    assert code =~ "use Ecto.Schema"
    assert code =~ "import Ecto.Changeset"
    assert code =~ ~s[schema "thing" do]
    assert code =~ "field :name, :string"
    assert code =~ "field :score, :float"
    assert code =~ "rec |> cast(attrs, [:name, :score])"
  end

  test "emits a string primary key with autogenerate disabled" do
    db =
      thing_db([
        col("name_field", "name", %{type: :string}),
        col("_id", "_id", %{type: :string}, primary_key: true)
      ])

    assert {:ok, code} = Ecto.encode(db)
    assert code =~ "@primary_key {:_id, :string, autogenerate: false}"
    assert code =~ "@foreign_key_type :string"
    assert code =~ "|> validate_required([:_id])"
  end

  test "maps each Bubble type to its Ecto type" do
    db =
      thing_db([
        col("a", "a", %{type: :boolean}),
        col("b", "b", %{type: :utc_datetime_usec}),
        col("c", "c", %{type: :custom, custom_type: "bubble_image"}),
        col("d", "d", %{type: :custom, custom_type: "bubble_geo_address"}),
        col("e", "e", %{type: :api, custom_type: "x.y"})
      ])

    assert {:ok, code} = Ecto.encode(db)
    assert code =~ "field :a, :boolean"
    assert code =~ "field :b, :utc_datetime_usec"
    assert code =~ "field :c, :string"
    assert code =~ "field :d, :map"
    assert code =~ "field :e, :string"
  end

  test "renders list fields as array columns" do
    db = thing_db([col("tags", "tags", %{type: :string, is_array: true})])
    assert {:ok, code} = Ecto.encode(db)
    assert code =~ "field :tags, {:array, :string}"
  end

  test "renders a scalar reference as belongs_to with an index" do
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
    assert {:ok, code} = Ecto.encode(db)

    assert code =~
             "belongs_to :owner, MyApp.User, foreign_key: :owner_id, references: :_id, type: :string"

    assert code =~ "create index(\"thing\", [:owner_id])"
    assert code =~ "rec |> cast(attrs, [:owner_id])"
  end

  test "belongs_to uses a foreign key distinct from the association name and a references" do
    # Ecto raises at compile time if foreign_key equals the association name, and
    # defaults references to :id (absent here), so both must be explicit.
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
    assert {:ok, code} = Ecto.encode(db)

    [belongs_to_line] =
      code
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "belongs_to :owner,"))

    assert belongs_to_line =~ "foreign_key: :owner_id"
    assert belongs_to_line =~ "references: :_id"
    refute belongs_to_line =~ "foreign_key: :owner,"
  end

  test "renders an enum reference as belongs_to to the option-set module" do
    from =
      col("ref", "status", %{type: :enum, custom_type: "status_type"},
        table_id: "t1",
        table_name: "Thing"
      )

    to =
      col("display", "Display", %{type: :string},
        table_id: "status_type",
        table_name: "Status Type",
        table_group: :option,
        primary_key: true
      )

    db = thing_db([from], [{from, to, :one_to_one}])
    assert {:ok, code} = Ecto.encode(db)

    assert code =~
             "belongs_to :status, MyApp.StatusType, foreign_key: :status_id, references: :display, type: :string"
  end

  test "renders a list reference as an array column with no association or index" do
    from = col("refs", "owners", %{type: :reference, custom_type: "user", is_array: true})

    to =
      col("_id", "_id", %{type: :string},
        table_id: "user",
        table_name: "User",
        primary_key: true
      )

    db = thing_db([from], [{from, to, :one_to_many}])
    assert {:ok, code} = Ecto.encode(db)
    refute code =~ "belongs_to"
    refute code =~ "create index"
    assert code =~ "field :owners, {:array, :string}"
  end

  test "skips deleted columns" do
    db =
      thing_db([
        col("keep", "keep", %{type: :string}),
        col("gone", "gone", %{type: :string}, deleted: true)
      ])

    assert {:ok, code} = Ecto.encode(db)
    assert code =~ "field :keep, :string"
    refute code =~ "field :gone"
  end

  test "respects :proper naming (default)" do
    db = thing_db([col("name_field", "name", %{type: :string})])
    assert {:ok, code} = Ecto.encode(db)
    assert code =~ "defmodule MyApp.Thing do"
    assert code =~ ~s[schema "thing" do]
    assert code =~ "field :name, :string"
  end

  test "respects :id naming" do
    db =
      thing_db([
        col("name_field", "name", %{type: :string}),
        col("_id", "_id", %{type: :string}, primary_key: true)
      ])

    assert {:ok, code} = Ecto.encode(db, naming: :id)
    assert code =~ "defmodule MyApp.T1 do"
    assert code =~ ~s[schema "t1" do]
    assert code =~ "field :name_field, :string"
    assert code =~ "@primary_key {:_id, :string, autogenerate: false}"
  end

  test "honors a custom namespace" do
    db = thing_db([col("name_field", "name", %{type: :string})])
    assert {:ok, code} = Ecto.encode(db, namespace: "Acme")
    assert code =~ "defmodule Acme.Thing do"
    assert code =~ "defmodule Acme.Repo.Migrations.CreateThing do"
  end

  test "omits api-group placeholder tables" do
    db = %{
      bubble_id: "app",
      tables: [%{id: "x.y", name: "x.y", group: :api, columns: []}],
      relationships: []
    }

    assert {:ok, code} = Ecto.encode(db)
    refute code =~ "x"
  end

  test "emits a migration without a default primary key" do
    db =
      thing_db([
        col("name_field", "name", %{type: :string}),
        col("_id", "_id", %{type: :string}, primary_key: true)
      ])

    assert {:ok, code} = Ecto.encode(db)
    assert code =~ "defmodule MyApp.Repo.Migrations.CreateThing do"
    assert code =~ "use Ecto.Migration"
    assert code =~ ~s[create table("thing", primary_key: false) do]
    assert code =~ "add :_id, :string, primary_key: true"
    assert code =~ "add :name, :string"
  end
end
