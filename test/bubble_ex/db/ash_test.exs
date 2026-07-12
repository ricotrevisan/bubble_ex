defmodule BubbleEx.Db.AshTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Ash

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

  test "emits a resource with postgres block, string PK, and Ash 3 action defaults" do
    db =
      thing_db([
        col("_id", "_id", %{type: :string}, primary_key: true),
        col("name_field", "name", %{type: :string})
      ])

    assert {:ok, code} = Ash.encode(db, external_types: :preserve)
    assert code =~ "defmodule MyApp.Thing do"
    assert code =~ "use Ash.Resource, domain: MyApp, data_layer: AshPostgres.DataLayer"
    assert code =~ ~s[    table "thing"]
    assert code =~ "    repo MyApp.Repo"
    assert code =~ "attribute :_id, :string, primary_key?: true, allow_nil?: false, public?: true"
    assert code =~ "attribute :name, :string, public?: true"
    assert code =~ "defaults [:read, :destroy, create: :*, update: :*]"
    refute code =~ "defaults [:read, :create"
  end

  test "maps each Bubble type to its Ash type" do
    db =
      thing_db([
        col("a", "a", %{type: :boolean}),
        col("b", "b", %{type: :utc_datetime_usec}),
        col("c", "c", %{type: :custom, custom_type: "bubble_image"}),
        col("d", "d", %{type: :custom, custom_type: "bubble_geo_address"}),
        col("e", "e", %{type: :float}),
        col("f", "tags", %{type: :string, is_array: true})
      ])

    assert {:ok, code} = Ash.encode(db)
    assert code =~ "attribute :a, :boolean, public?: true"
    assert code =~ "attribute :b, :utc_datetime_usec, public?: true"
    assert code =~ "attribute :c, :string, public?: true"
    assert code =~ "attribute :d, :map, public?: true"
    assert code =~ "attribute :e, :float, public?: true"
    assert code =~ "attribute :tags, {:array, :string}, public?: true"
  end

  test "renders a scalar reference as belongs_to and does not duplicate the FK attribute" do
    from = col("ref", "owner", %{type: :reference, custom_type: "user"})

    to =
      col("_id", "_id", %{type: :string},
        table_id: "t2",
        table_name: "User",
        primary_key: true
      )

    db = %{
      bubble_id: "app",
      tables: [
        %{
          id: "t1",
          name: "Thing",
          group: :custom,
          columns: [col("_id", "_id", %{type: :string}, primary_key: true), from]
        },
        %{id: "t2", name: "User", group: :custom, columns: [to]}
      ],
      relationships: [{from, to, :one_to_many}]
    }

    assert {:ok, code} = Ash.encode(db)
    assert code =~ "belongs_to :owner, MyApp.User do"
    assert code =~ "source_attribute :owner_id"
    assert code =~ "destination_attribute :_id"
    assert code =~ "attribute_type :string"
    # The FK is defined by `belongs_to`'s source_attribute, never as a
    # standalone top-level attribute. (A bare `refute code =~ "attribute
    # :owner_id"` would spuriously match the substring inside
    # `source_attribute :owner_id`; key on the full attribute line instead.)
    refute code =~ "attribute :owner_id, :string"
  end

  test "a list of references degrades to a string array with no relationship" do
    db = thing_db([col("r", "members", %{type: :reference, is_array: true, custom_type: "user"})])
    assert {:ok, code} = Ash.encode(db)
    assert code =~ "attribute :members, {:array, :string}, public?: true"
    refute code =~ "belongs_to"
  end

  test "skips :api tables and degrades references pointing at them" do
    from = col("ref", "ext", %{type: :reference, custom_type: "x.y"})
    to = col("_id", "_id", %{type: :string}, table_id: "t3", table_name: "Ext", table_group: :api)

    db = %{
      bubble_id: "app",
      tables: [
        %{id: "t1", name: "Thing", group: :custom, columns: [from]},
        %{id: "t3", name: "Ext", group: :api, columns: [to]}
      ],
      relationships: [{from, to, :one_to_many}]
    }

    assert {:ok, code} = Ash.encode(db)
    refute code =~ "MyApp.Ext"
    refute code =~ "belongs_to"
    assert code =~ "attribute :ext, :string, public?: true"
  end

  test "option sets render as sibling resources and the domain lists every resource" do
    status_pk =
      col("display", "display", %{type: :string},
        table_id: "t2",
        table_name: "Status",
        table_group: :option,
        primary_key: true
      )

    db = %{
      bubble_id: "app",
      tables: [
        %{
          id: "t1",
          name: "Thing",
          group: :custom,
          columns: [col("_id", "_id", %{type: :string}, primary_key: true)]
        },
        %{id: "t2", name: "Status", group: :option, columns: [status_pk]}
      ],
      relationships: []
    }

    assert {:ok, code} = Ash.encode(db)
    assert code =~ "defmodule MyApp.Status do"

    assert code =~
             "attribute :display, :string, primary_key?: true, allow_nil?: false, public?: true"

    assert code =~ "defmodule MyApp do"
    assert code =~ "use Ash.Domain"
    assert code =~ "resource MyApp.Thing"
    assert code =~ "resource MyApp.Status"
  end

  test "hostile names: digit-leading, emoji, collisions, and a table named Repo" do
    db = %{
      bubble_id: "app",
      tables: [
        %{
          id: "t1",
          name: "3D Models",
          group: :custom,
          columns: [
            col("_id", "_id", %{type: :string},
              table_id: "t1",
              table_name: "3D Models",
              primary_key: true
            ),
            col("c1", "1st choice", %{type: :string}, table_id: "t1", table_name: "3D Models"),
            col("c2", "Owner!", %{type: :string}, table_id: "t1", table_name: "3D Models"),
            col("c3", "owner?", %{type: :string}, table_id: "t1", table_name: "3D Models"),
            col("c4", "🎉", %{type: :string}, table_id: "t1", table_name: "3D Models")
          ]
        },
        %{
          id: "t2",
          name: "Repo",
          group: :custom,
          columns: [
            col("_id2", "_id", %{type: :string},
              table_id: "t2",
              table_name: "Repo",
              primary_key: true
            )
          ]
        }
      ],
      relationships: []
    }

    assert {:ok, code} = Ash.encode(db)
    assert code =~ "defmodule MyApp.N3DModels do"
    assert code =~ "attribute :n1st_choice, :string"
    assert code =~ "attribute :owner, :string"
    assert code =~ "attribute :owner_2, :string"
    assert code =~ "attribute :field, :string"
    assert code =~ "defmodule MyApp.Repo2 do"
    refute code =~ "defmodule MyApp.Repo do"
  end

  test "a plain field named owner_id does not collide with a reference's FK" do
    from = col("ref", "owner", %{type: :reference, custom_type: "user"})
    clash = col("c9", "owner id", %{type: :string})

    to =
      col("_id", "_id", %{type: :string}, table_id: "t2", table_name: "User", primary_key: true)

    db = %{
      bubble_id: "app",
      tables: [
        %{id: "t1", name: "Thing", group: :custom, columns: [clash, from]},
        %{id: "t2", name: "User", group: :custom, columns: [to]}
      ],
      relationships: [{from, to, :one_to_many}]
    }

    assert {:ok, code} = Ash.encode(db)
    assert code =~ "attribute :owner_id, :string, public?: true"
    assert code =~ "source_attribute :owner_id_2"
  end

  test "supports :id naming and a custom namespace" do
    db = thing_db([col("_id", "_id", %{type: :string}, primary_key: true)])
    assert {:ok, code} = Ash.encode(db, naming: :id, namespace: "Acme")
    assert code =~ "defmodule Acme.T1 do"
    assert code =~ "use Ash.Resource, domain: Acme"
    assert code =~ "repo Acme.Repo"
  end

  test "header carries the honest-emit caveats" do
    db = thing_db([col("_id", "_id", %{type: :string}, primary_key: true)])
    assert {:ok, code} = Ash.encode(db)
    assert code =~ "re-key after"
    assert code =~ "mix igniter.new"
    assert code =~ "mix ash.codegen --dev"
  end

  test "renders resolved External API types as identity-free embedded resources" do
    id = "api.apiconnector2.a.call.Shape"

    db =
      thing_db([
        col("payload", "payload", %{type: :external, target: id, cardinality: :one, raw: id})
      ])

    db =
      Map.put(db, :external_types, [
        %{
          id: id,
          resolution: :resolved,
          fields: [
            %{
              id: "value",
              caption: "Value",
              type: %{type: :scalar, scalar: :text, cardinality: :one}
            }
          ]
        }
      ])

    assert {:ok, code} = Ash.encode(db, external_types: :preserve)
    assert code =~ "defmodule MyApp.External.Shape do"
    assert code =~ "use Ash.Resource, data_layer: :embedded"
    refute code =~ "primary_key?: true, allow_nil?: false"
    assert code =~ "attribute :payload, MyApp.External.Shape"
  end
end
