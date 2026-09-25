defmodule BubbleEx.Db.Encoder.NamesTest do
  # Names unique after case conversion (WTF-391), through every converting
  # encoder. The fixture's Post type has `created_date`, `Created-By` and
  # `created_by_id` (the built-ins' names after conversion), `Foo Bar` and
  # `foo-bar` (differing only by punctuation and case), `Owner ID` before the
  # reference `Owner` (whose foreign key is `owner_id`), and `bubble_id`
  # (Convex's primary key). `Blog Post` (a data type) and `Blog-Post` (an
  # option set) differ only by punctuation, and `Repo` is the app's repo.
  use ExUnit.Case, async: true

  alias BubbleEx.Db.{Convex, Ecto, Encoder, Reader, Xano, Zod}
  alias BubbleEx.Test.NameCheck

  @fixture "test/support/db/fixtures/converted_names.json"

  setup_all do
    {:ok, db} = @fixture |> File.read!() |> Jason.decode!() |> Reader.parse()
    %{db: db}
  end

  defp render(db, format, opts \\ []) do
    {:ok, result} = Encoder.render(format, db, opts)
    result
  end

  defp suffixed(result),
    do:
      for(
        d <- result.diagnostics,
        d.code == :db_converted_name_suffixed,
        do: {d.details.name, d.details.rendered}
      )

  test "Ecto: built-ins keep their names, user fields and references are suffixed", %{db: db} do
    result = render(db, :ecto)

    assert result.content =~
             "belongs_to :created_by, MyApp.User, foreign_key: :created_by_id, references: :_id"

    assert result.content =~ "field :created_date, :utc_datetime_usec\n"
    assert result.content =~ "field :created_date_2, :utc_datetime_usec"

    assert result.content =~
             "belongs_to :created_by_2, MyApp.User, foreign_key: :created_by_2_id, references: :_id"

    assert result.content =~ "field :created_by_id_2, :string"
    assert result.content =~ "field :foo_bar, :string"
    assert result.content =~ "field :foo_bar_2, :float"
    assert result.content =~ "field :owner_id, :string"
    assert result.content =~ "belongs_to :owner_2, MyApp.User, foreign_key: :owner_2_id"
    assert result.content =~ "add :owner_2_id, :string"
    assert result.content =~ ~s{create index("post", [:owner_2_id])}

    assert suffixed(result) == [
             {"BlogPost", "BlogPost2"},
             {"created_date", "created_date_2"},
             {"created_by", "created_by_2"},
             {"created_by_id", "created_by_id_2"},
             {"foo_bar", "foo_bar_2"},
             {"owner", "owner_2"},
             {"Repo", "Repo2"}
           ]

    assert NameCheck.duplicates(:ecto, result.content) == []
  end

  test "Ecto: tables repeating a module or table name, or naming the Repo, are suffixed",
       %{db: db} do
    content = render(db, :ecto).content

    assert content =~ ~s{defmodule MyApp.BlogPost do\n}
    assert content =~ ~s{schema "blog_post" do}
    assert content =~ ~s{defmodule MyApp.BlogPost2 do\n}
    assert content =~ ~s{schema "blog_post_2" do}
    assert content =~ "defmodule MyApp.Repo.Migrations.CreateBlogPost2 do"
    assert content =~ ~s{defmodule MyApp.Repo2 do\n}
    refute content =~ "defmodule MyApp.Repo do"
  end

  test "Convex: the primary key and built-ins keep their keys", %{db: db} do
    result = render(db, :convex)

    assert result.content =~ "    bubbleId: v.string(), // primary key"
    assert result.content =~ "    bubbleId2: v.string(),\n"
    assert result.content =~ "    createdDate2: v.float64(),"
    assert result.content =~ "    createdBy2: v.string(),"
    assert result.content =~ "    fooBar2: v.float64(),"
    assert result.content =~ "  blogPost2: defineTable({"

    assert suffixed(result) == [
             {"blogPost", "blogPost2"},
             {"createdDate", "createdDate2"},
             {"createdBy", "createdBy2"},
             {"fooBar", "fooBar2"},
             {"bubbleId", "bubbleId2"}
           ]

    assert NameCheck.duplicates(:convex, result.content) == []
  end

  test "Xano: tables and fields are unique after snake_casing", %{db: db} do
    result = render(db, :xano)
    tables = result.content |> Jason.decode!() |> tl()
    post = Enum.find(tables, &(&1["name"] == "post"))

    assert Enum.map(tables, & &1["name"]) == ~w(blog_post post repo user blog_post_2)

    assert Enum.map(post["fields"], & &1["name"]) ==
             ~w(_id created_date modified_date created_by slug created_date_2 created_by_2
                created_by_id foo_bar foo_bar_2 owner_id owner bubble_id)

    assert NameCheck.duplicates(:xano, result.content) == []
  end

  test "Zod: schema consts and types are unique; field keys stay display names", %{db: db} do
    result = render(db, :zod)

    assert result.content =~ "export const BlogPost2Schema = z.object({"
    assert result.content =~ "export type BlogPost2 = z.infer<typeof BlogPost2Schema>;"
    assert result.content =~ "  created_date: z.string().datetime().nullish(),"
    assert result.content =~ "  'foo-bar': z.number().nullish(),"
    assert suffixed(result) == [{"BlogPostSchema", "BlogPost2Schema"}]
    assert NameCheck.duplicates(:zod, result.content) == []
  end

  test "Zod: a table's const does not take an API Connector type's" do
    db = %{
      tables: [
        %{
          id: "task",
          name: "Task",
          group: :custom,
          columns: [],
          values: []
        }
      ],
      relationships: [],
      external_types: [
        %{
          id: "api.c.call.Task",
          caption: "Task",
          resolution: :resolved,
          fields: [%{id: "f", caption: "f", path: ["f"], type: %{type: :scalar, scalar: :text}}]
        }
      ]
    }

    {:ok, content} = Zod.encode(db, external_types: :preserve)
    assert content =~ "export const TaskSchema = z.looseObject({"
    assert content =~ "export const Task2Schema = z.object({"
    assert NameCheck.duplicates(:zod, content) == []
  end

  test "the suffixes are the same in either naming", %{db: db} do
    for format <- [:ecto, :convex, :xano, :zod] do
      result = render(db, format, naming: :id)
      assert NameCheck.duplicates(format, result.content) == [], "#{format}"
    end
  end

  test "names/2 is the one decision point: encode and render agree", %{db: db} do
    for module <- [Ecto, Convex, Xano, Zod] do
      assert %Encoder.Names{} = module.names(db, [])
    end

    ecto = Ecto.names(db, [])
    post = Enum.find(db.tables, &(&1.id == "post"))
    owner = Enum.find(post.columns, &(&1.id == "g_owner_user"))
    created_by = Enum.find(post.columns, &(&1.system == :created_by))

    assert Encoder.Names.table(ecto, post) == [{:module, "Post"}, {:table, "post"}]
    assert Encoder.Names.column(ecto, owner) == ["owner_2", "owner_2_id"]
    assert Encoder.Names.column(ecto, created_by) == ["created_by", "created_by_id"]
  end

  test "the formats that keep display names report no conversion suffix", %{db: db} do
    for format <- [:dbml, :postgres, :sqlite, :tsql] do
      assert suffixed(render(db, format)) == [], "#{format}"
    end
  end

  test "diagnostics carry the target, subject and path", %{db: db} do
    [diagnostic | _] =
      db
      |> render(:ecto)
      |> Map.fetch!(:diagnostics)
      |> Enum.filter(&(&1.code == :db_converted_name_suffixed and &1.subject[:field]))

    assert diagnostic.stage == {:target, :ecto}
    assert diagnostic.subject == %{type: "post", field: "a_created_date_date"}
    assert diagnostic.path == "/user_types/post/fields/a_created_date_date/value"
    assert diagnostic.details.scope == "column"
  end

  test "Ecto names fit PostgreSQL's 63-character identifiers, suffix kept" do
    long = String.duplicate("very long name ", 10)

    db = %{
      tables: [
        %{
          id: "t",
          name: long,
          group: :custom,
          columns: [
            %{
              table_id: "t",
              table_name: long,
              table_group: :custom,
              id: "a",
              name: long <> "a",
              type: %{type: :string},
              primary_key: false,
              deleted: false
            },
            %{
              table_id: "t",
              table_name: long,
              table_group: :custom,
              id: "b",
              name: long <> "b",
              type: %{type: :string},
              primary_key: false,
              deleted: false
            }
          ],
          values: []
        }
      ],
      relationships: []
    }

    {:ok, content} = Ecto.encode(db)
    [first, second] = Regex.scan(~r/field :(\w+),/, content, capture: :all_but_first)

    assert String.length(hd(first)) == 63
    assert hd(second) == String.slice(hd(first), 0, 61) <> "_2"
    [module] = Regex.run(~r/defmodule MyApp\.(\w+) do/, content, capture: :all_but_first)
    assert String.length(module) == 63
    assert NameCheck.duplicates(:ecto, content) == []
  end
end
