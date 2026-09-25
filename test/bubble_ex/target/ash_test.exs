defmodule BubbleEx.Target.AshTest do
  # Conformance for BubbleEx.Target.Ash (WTF-342): a golden Project snapshot
  # for every Model fixture (test/support/model/) and every target fixture
  # (test/support/target/ash/), golden rendered source for a few, and the
  # determinism, naming and name-map checks. All data is invented.
  #
  # Regenerate the snapshots after an intended change with
  #
  #     BUBBLE_EX_UPDATE_GOLDEN=1 mix test test/bubble_ex/target/ash_test.exs
  #
  # and explain the diff in the PR.
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Model}
  alias BubbleEx.Target.Ash
  alias BubbleEx.Target.Ash.{Attribute, Project, Relationship, Source}
  alias BubbleEx.Test.PermutedJson

  @golden "test/support/target/ash/golden"
  @fixtures Enum.map(
              Path.wildcard("test/support/model/*.json"),
              &{Path.basename(&1, ".json"), &1}
            ) ++
              Enum.map(
                Path.wildcard("test/support/target/ash/*.json"),
                &{"target_" <> Path.basename(&1, ".json"), &1}
              )
  @sources ~w(field_types option_sets external_types naming target_names target_defaults)

  defp load(path), do: path |> File.read!() |> Jason.decode!()

  defp fixture(name) do
    {^name, path} = List.keyfind(@fixtures, name, 0)
    load(path)
  end

  defp project!(app, opts \\ []) do
    {:ok, model} = Model.build(app)
    {:ok, project} = Ash.map(model, [], opts)
    project
  end

  defp golden_json(project),
    do: project |> Project.to_map() |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)

  defp check_golden(path, actual) do
    if System.get_env("BUBBLE_EX_UPDATE_GOLDEN"), do: File.write!(path, actual)
    assert File.exists?(path), "missing golden #{path}; set BUBBLE_EX_UPDATE_GOLDEN=1"
    assert actual == File.read!(path)
  end

  defp attribute(project, module, name) do
    resource = Enum.find(project.resources, &(&1.module == module))
    Enum.find(resource.attributes, &(&1.name == name))
  end

  defp field(project, type, field) do
    resource = Enum.find(project.resources, &(&1.source.type == type))
    Enum.find(resource.attributes, &(&1.source[:field] == field))
  end

  defp codes(project, subject) do
    for d <- project.diagnostics, d.stage == {:target, :ash}, d.subject == subject, do: d.code
  end

  describe "golden snapshots" do
    for {name, path} <- @fixtures do
      @name name
      @path path
      test "#{name} matches its golden Project" do
        actual = golden_json(project!(load(@path))) <> "\n"
        check_golden(Path.join(@golden, @name <> ".project.json"), actual)
      end
    end

    for name <- @sources do
      @name name
      test "#{name} renders its golden source" do
        {:ok, source} = @name |> fixture() |> project!() |> Source.render()
        check_golden(Path.join(@golden, @name <> ".ex.txt"), source)
      end
    end

    test "every fixture has a golden and every golden a fixture" do
      goldens =
        [@golden, "*.project.json"]
        |> Path.join()
        |> Path.wildcard()
        |> Enum.map(&Path.basename(&1, ".project.json"))

      assert Enum.sort(goldens) == @fixtures |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    end
  end

  describe "determinism" do
    test "two mappings and renders give identical bytes" do
      for {name, path} <- @fixtures do
        app = load(path)
        a = project!(app)
        b = project!(app)
        assert Project.to_json(a) == Project.to_json(b), name
        assert Source.render(a) == Source.render(b), name
      end
    end

    test "permuted source text gives identical bytes" do
      for {name, path} <- @fixtures do
        app = load(path)
        expected = project!(app)
        {:ok, expected_source} = Source.render(expected)

        for seed <- 1..3 do
          :rand.seed(:exsss, {seed, 11, 17})
          actual = app |> PermutedJson.encode() |> Jason.decode!() |> project!()
          assert Project.to_json(actual) == Project.to_json(expected), "#{name} (#{seed})"
          assert Source.render(actual) == {:ok, expected_source}
        end
      end
    end

    test "mapping again with the returned name map gives the same Project" do
      for {name, path} <- @fixtures do
        app = load(path)
        first = project!(app)
        again = project!(app, names: first.names)
        assert Project.to_json(again) == Project.to_json(first), name

        # The name map survives a JSON round trip (WTF-352 persists it).
        decoded = first.names |> Jason.encode!() |> Jason.decode!()
        assert Project.to_json(project!(app, names: decoded)) == Project.to_json(first)
      end
    end
  end

  describe "source-faithful mapping (WTF-338)" do
    setup do
      %{project: project!(fixture("field_types"))}
    end

    test "the Bubble ID is a writable, untrimmed string primary key", %{project: p} do
      assert %Attribute{
               name: "id",
               type: :string,
               primary_key?: true,
               allow_nil?: false,
               writable?: true,
               constraints: [trim?: false, allow_empty?: true]
             } = attribute(p, "Task", "id")

      for resource <- p.resources do
        assert [%Attribute{primary_key?: true, name: "id"}] =
                 Enum.filter(resource.attributes, & &1.primary_key?)
      end
    end

    test "scalars, files and lists", %{project: p} do
      assert %{type: :string, constraints: [trim?: false, allow_empty?: true]} =
               attribute(p, "Task", "title")

      assert %{type: :float} = attribute(p, "Task", "estimate")
      assert %{type: :boolean} = attribute(p, "Task", "done")
      assert %{type: :utc_datetime_usec} = attribute(p, "Task", "due")

      assert %{type: :string, constraints: [trim?: false, allow_empty?: true]} =
               attribute(p, "Task", "cover")

      assert %{type: {:array, :float}} = attribute(p, "Task", "scores")

      assert %{type: {:array, :string}, constraints: [items: [trim?: false, allow_empty?: true]]} =
               attribute(p, "Task", "notes")
    end

    test "every attribute but the primary key allows nil", %{project: p} do
      for resource <- p.resources, attribute <- resource.attributes do
        assert attribute.allow_nil? == not attribute.primary_key?
      end
    end

    test "defaults are preserved", %{project: p} do
      assert %{default: {:value, false}} = attribute(p, "Task", "done")
      assert %{default: {:value, 1.0}} = attribute(p, "Task", "estimate")
    end

    test "a scalar reference is belongs_to with a string key and no database FK", %{project: p} do
      resource = Enum.find(p.resources, &(&1.module == "Task"))
      project_rel = Enum.find(resource.relationships, &(&1.name == "project"))

      assert %Relationship{
               kind: :belongs_to,
               destination: "Project",
               source_attribute: "project_id",
               destination_attribute: "id",
               attribute_type: :string,
               define_attribute?: false,
               db_reference: :ignore
             } = project_rel

      assert %{type: :string, references: %{target: "project", cardinality: :one}} =
               attribute(p, "Task", "project_id")
    end

    test "a list of things is an ordered array of Bubble IDs", %{project: p} do
      assert %{type: {:array, :string}, references: %{target: "task", cardinality: :many}} =
               attribute(p, "Task", "subtasks")
    end

    test "system fields are writable attributes and Created By is belongs_to :creator",
         %{project: p} do
      for name <- ~w(created_date modified_date) do
        assert %{type: :utc_datetime_usec, writable?: true} = attribute(p, "Task", name)
      end

      assert %{type: :string, writable?: true} = attribute(p, "Task", "slug")
      assert %{source: %{field: "Created By"}} = attribute(p, "Task", "creator_id")
      resource = Enum.find(p.resources, &(&1.module == "Task"))

      assert %Relationship{name: "creator", destination: "User", source_attribute: "creator_id"} =
               Enum.find(resource.relationships, &(&1.name == "creator"))

      assert %{type: :string} = attribute(p, "User", "email")
    end

    test "option sets are enums keyed by db_value with attribute lookup data", %{project: p} do
      assert %{type: {:module, "Enums.Status"}} = attribute(p, "Task", "status")
      assert %{type: {:array, {:module, "Enums.Status"}}} = attribute(p, "Task", "labels")

      assert [%{module: "Enums.Status", values: values, attributes: [%{name: "color"}]}] =
               p.enums

      assert [
               %{value: "open", label: "Open", attributes: %{"color" => "#00aa00"}},
               %{value: "closed", label: "Closed", attributes: %{"color" => "#aa0000"}}
             ] = values
    end

    test "structured values are typed structs from the Model's parts; bounds stay unverified",
         %{project: p} do
      assert %{type: {:module, "Types.GeographicAddress"}} = attribute(p, "Task", "place")
      assert %{type: {:array, {:module, "Types.DateRange"}}} = attribute(p, "Task", "ranges")

      by_module = Map.new(p.typed_structs, &{&1.module, &1})

      assert Enum.map(by_module["Types.GeographicAddress"].fields, &{&1.name, &1.type}) == [
               {"formatted_address", :string},
               {"lat", :float},
               {"lng", :float}
             ]

      assert by_module["Types.DateRange"].metadata == %{
               bounds: %{start: :unverified, end: :unverified}
             }

      assert by_module["Types.GeographicAddress"].metadata == %{}
    end

    test "a date interval has no modeled shape: :map, diagnosed", %{project: p} do
      assert %{type: :map} = attribute(p, "Task", "duration")
      assert :ash_opaque_value in codes(p, %{type: "task", field: "duration_dateinterval"})
    end

    test "missing and deleted targets, deleted fields and types" do
      p = project!(fixture("missing_and_deleted"))
      refute Enum.any?(p.resources, &(&1.source.type == "archive"))
      assert codes(p, %{type: "archive"}) == [:ash_deleted_omitted]

      assert %{type: :string, references: %{target: "ghost"}} =
               field(p, "invoice", "customer_custom_ghost")

      assert %{type: {:array, :string}} = field(p, "invoice", "lines_list_custom_ghost_line")
      assert %{type: :string} = field(p, "invoice", "archive_custom_archive")
      assert %{type: :string} = field(p, "invoice", "state_option_ghost_state")

      for f <-
            ~w(customer_custom_ghost lines_list_custom_ghost_line archive_custom_archive state_option_ghost_state) do
        assert codes(p, %{type: "invoice", field: f}) == [:ash_unresolved_reference]
      end

      [archive] = for d <- p.diagnostics, d.subject[:field] == "archive_custom_archive", do: d
      assert archive.details.reason == "omitted"

      assert field(p, "invoice", "old_total_number") == nil
      assert codes(p, %{type: "invoice", field: "old_total_number"}) == [:ash_deleted_omitted]
      assert p.enums == []
    end

    test "API types: known shapes are typed structs, unknown ones and cycle edges :map" do
      p = project!(fixture("external_types"))
      modules = Enum.map(p.typed_structs, & &1.module)

      # Every struct follows the structs its fields use.
      for {struct, i} <- Enum.with_index(p.typed_structs),
          f <- struct.fields,
          {:module, used} <- [unwrap(f.type)] do
        assert Enum.find_index(modules, &(&1 == used)) < i
      end

      assert %{type: :map} = field(p, "shipment", "missing_api")

      assert :external_type_unresolved_root in codes(p, %{
               type: "shipment",
               field: "missing_api"
             })

      cuts = for d <- p.diagnostics, d.code == :external_type_cycle_edge, do: d
      assert cuts != []
      assert Enum.all?(cuts, &(&1.stage == {:target, :ash} and &1.outcome == :degraded))
    end

    test "a synthesized User is a resource with the built-in fields only" do
      p = project!(fixture("hostile_empty_app"))
      assert [%{module: "User", synthesized: true} = user] = p.resources

      assert Enum.map(user.attributes, & &1.name) ==
               ~w(id created_date modified_date creator_id slug email)
    end

    test "defaults with no Ash equivalent are omitted and diagnosed" do
      p = project!(fixture("target_defaults"))
      mapped = for a <- hd(p.resources).attributes, a.default, into: %{}, do: {a.name, a.default}

      assert mapped == %{
               "active" => {:value, true},
               "color" => {:value, "blue"},
               "count" => {:value, 3.0},
               "empty" => {:value, ""},
               "icon" => {:value, "https://example.invalid/icon.png"},
               "title" => {:value, "Untitled"}
             }

      for f <- ~w(due_date hue_option_color tags_list_text weird_text) do
        assert codes(p, %{type: "card", field: f}) == [:ash_default_unmapped]
      end
    end

    test "duplicate option keys keep the first value" do
      p = project!(fixture("option_sets"))
      priority = Enum.find(p.enums, &(&1.source.option_set == "priority"))
      keys = Enum.map(priority.values, & &1.value)
      assert keys == Enum.uniq(keys)
      assert :ash_duplicate_enum_value in codes(p, %{option_set: "priority"})
    end

    test "the Model's diagnostics are carried with the target's" do
      {:ok, model} = Model.build(fixture("missing_and_deleted"))
      {:ok, project} = Ash.map(model)
      assert model.diagnostics -- project.diagnostics == []
    end
  end

  describe "naming (WTF-339)" do
    setup do
      %{naming: project!(fixture("naming")), names: project!(fixture("target_names"))}
    end

    test "ordinal prefixes and emoji are stripped, meaningful words kept", %{naming: p} do
      assert Enum.map(p.resources, & &1.module) == ~w(ThingJoin Launch Thing Thing2 User)
      assert Enum.map(p.resources, & &1.table) == ~w(thing_join launch thing thing2 user)
      assert %{name: "done"} = field(p, "00__thing___join", "11__done_boolean")

      assert %{name: "sort_thing_title"} =
               field(p, "00__thing___join", "40__sort__thing_title_text")

      assert %{name: "name"} = field(p, "launch", "name_text")
      assert [%{module: "Enums.Levels", values: [%{value: "id"}, %{value: "type"}]}] = p.enums
    end

    test "reserved words get a suffix", %{naming: p, names: n} do
      assert %{name: "id_field"} = field(p, "00__thing___join", "id_text")
      assert %{name: "type_field"} = field(p, "00__thing___join", "type_text")
      assert %{name: "inserted_at_field"} = field(p, "00__thing___join", "inserted_at_date")
      assert %{name: "struct"} = field(p, "00__thing___join", "__struct___text")
      assert %{name: "updated_at_field"} = field(n, "gadget", "updated_date")

      assert %{module: "RepoResource", table: "repo_resource"} =
               Enum.find(n.resources, &(&1.source.type == "repo"))

      assert %{module: "DomainResource"} = Enum.find(n.resources, &(&1.source.type == "domain"))
      tier = hd(n.enums)
      assert Enum.map(tier.attributes, & &1.name) == ~w(nil_field rank rank_2)
    end

    test "collisions are numbered in Bubble ID order", %{naming: p, names: n} do
      assert %{name: "title"} = field(p, "00__thing___join", "title_text")
      assert %{name: "title_2"} = field(p, "00__thing___join", "title_text1")
      assert %{name: "title"} = field(n, "gadget", "a_title_text")
      assert %{name: "title_2"} = field(n, "gadget", "b_title_text")
      assert %{name: "title_3"} = field(n, "gadget", "c_title_text")

      # Built-in fields claim their names first.
      assert %{name: "slug"} = field(n, "gadget", "Slug")
      assert %{name: "slug_2"} = field(n, "gadget", "slug_text")
      assert %{name: "creator_2_id"} = field(n, "gadget", "creator_user")

      gadget = Enum.find(n.resources, &(&1.source.type == "gadget"))
      assert Enum.map(gadget.relationships, & &1.name) == ~w(creator creator_2 widget)
      assert %{name: "widget_id"} = field(n, "gadget", "widget_custom_repo")
      assert %{name: "widget_id_2"} = field(n, "gadget", "widget_id_text")

      names = for r <- n.resources, a <- r.attributes, do: {r.module, a.name}
      assert names == Enum.uniq(names)
    end

    test "fallback, accents, camel case and leading digits", %{naming: p, names: n} do
      assert %{name: "text"} = field(p, "launch", "_text")

      assert %{module: "N3dGadget", table: "n3d_gadget"} =
               Enum.find(n.resources, &(&1.source.type == "gadget"))

      assert %{name: "cafe_strasse"} = field(n, "gadget", "cafe_text")
      assert %{name: "first_name"} = field(n, "gadget", "camel_text")
      assert %{name: "n3_5_inch"} = field(n, "gadget", "inch_number")
      assert %{name: "n2fa_code"} = field(n, "gadget", "twofa_text")
      assert [%{module: "Enums.Tier"}] = n.enums
      assert [%{value: "Gold Tier"}, %{value: "silver"}] = hd(n.enums).values
    end

    test "long and non-Latin names stay within PostgreSQL's identifier limit" do
      p = project!(fixture("hostile_long_unicode_names"))

      for r <- p.resources do
        assert byte_size(r.table) <= 63
        for a <- r.attributes, do: assert(byte_size(a.name) <= 63)
      end

      assert Enum.any?(p.resources, &(&1.module == "Resource"))
    end

    test "a caption edit does not rename code once the name map is supplied" do
      app = fixture("field_types")
      first = project!(app)

      renamed =
        app
        |> put_in(["user_types", "task", "display"], "99. Chore ✅")
        |> put_in(["user_types", "task", "fields", "title_text", "display"], "Headline")
        |> put_in(["option_sets", "status", "display"], "State")

      locked = project!(renamed, names: first.names)
      assert generated_names(locked) == generated_names(first)
      assert locked.names == first.names

      # Without the map the names follow the captions.
      fresh = project!(renamed)

      assert %{module: "Chore", table: "chore"} =
               Enum.find(fresh.resources, &(&1.source.type == "task"))

      assert %{name: "headline"} = field(fresh, "task", "title_text")
      assert [%{module: "Enums.State"}] = fresh.enums
    end

    test "new definitions avoid locked names, including those of removed definitions" do
      app = fixture("field_types")
      first = project!(app)

      # The locked Title is gone; a new field captioned Title must not take it.
      changed =
        app
        |> update_in(["user_types", "task", "fields"], &Map.delete(&1, "title_text"))
        |> put_in(["user_types", "task", "fields", "zz_title_text"], %{
          "display" => "Title",
          "value" => "text"
        })

      p = project!(changed, names: first.names)
      assert %{name: "title_2"} = field(p, "task", "zz_title_text")
      assert get_in(p.names, ["resources", "task", "attributes", "title_text"]) == "title"
    end

    test "invalid or conflicting name maps are errors" do
      {:ok, model} = Model.build(fixture("field_types"))
      {:ok, project} = Ash.map(model)

      for names <- [
            :nope,
            %{"version" => 2},
            %{"resources" => []},
            %{"resources" => %{"task" => %{"module" => "not a module"}}},
            %{"resources" => %{"task" => %{"attributes" => %{"title_text" => "Bad Name"}}}}
          ] do
        assert {:error, %BubbleEx.Error{kind: :invalid_input}} = Ash.map(model, [], names: names)
      end

      conflicting =
        put_in(project.names, ["resources", "task", "attributes", "done_boolean"], "title")

      assert {:error, %BubbleEx.Error{kind: :invalid_input, context: %{name: "title"}}} =
               Ash.map(model, [], names: conflicting)

      clash = put_in(project.names, ["resources", "project", "module"], "Task")
      assert {:error, %BubbleEx.Error{kind: :invalid_input}} = Ash.map(model, [], names: clash)
    end
  end

  describe "interface" do
    test "decisions are not interpreted yet: [] only" do
      {:ok, model} = Model.build(fixture("field_types"))
      assert {:ok, %Project{}} = Ash.map(model)
      assert {:ok, %Project{}} = Ash.map(model, [])

      assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
               Ash.map(model, [%{"kind" => "number_to_integer"}])

      assert {:error, %BubbleEx.Error{kind: :invalid_input}} = Ash.map(%{}, [])
    end

    test "the renderer checks its module options" do
      project = project!(fixture("field_types"))
      assert {:ok, source} = Source.render(project, namespace: "Acme.Data", repo: "Acme.Repo")
      assert source =~ "defmodule Acme.Data.Task do"
      assert source =~ "repo Acme.Repo"
      assert source =~ "defmodule Acme.Data do\n  use Ash.Domain"

      for opts <- [[namespace: "acme"], [repo: "Acme Repo"], [domain: :acme]] do
        assert {:error, %BubbleEx.Error{kind: :invalid_input}} = Source.render(project, opts)
      end

      assert {:error, %BubbleEx.Error{}} = Source.render(%{})
    end

    test "summary counts" do
      summary = Project.summary(project!(fixture("field_types")))
      assert summary["resources"] == 3
      assert summary["enums"] == 1
      assert summary["typed_structs"] == %{"structured" => 3}
      assert summary["attributes_by_type"]["enum"] == 1
      assert summary["relationships"] == %{"belongs_to" => 5}
      assert summary["db_references"] == %{"ignore" => 5}
    end
  end

  defp unwrap({:array, type}), do: unwrap(type)
  defp unwrap(type), do: type

  defp generated_names(project) do
    {for(r <- project.resources, do: {r.module, r.table, Enum.map(r.attributes, & &1.name)}),
     for(e <- project.enums, do: {e.module, Enum.map(e.attributes, & &1.name)}),
     Enum.map(project.typed_structs, & &1.module)}
  end
end
