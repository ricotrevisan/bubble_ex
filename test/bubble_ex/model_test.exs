defmodule BubbleEx.ModelTest do
  # Conformance for BubbleEx.Model (WTF-342): one committed synthetic fixture
  # per concept plus hostile fixtures under test/support/model/ (all data
  # invented), each with a golden Model snapshot in test/support/model/golden/.
  #
  # Regenerate the snapshots after an intended Model change with
  #
  #     BUBBLE_EX_UPDATE_GOLDEN=1 mix test test/bubble_ex/model_test.exs
  #
  # and explain the diff in the PR.
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Diagnostic, Model}
  alias BubbleEx.Diagnostic.Codes
  alias BubbleEx.Expression.Schema
  alias BubbleEx.Model.{DataType, Field, OptionSet, Type}
  alias BubbleEx.Test.PermutedJson

  @dir "test/support/model"
  @fixtures @dir
            |> Path.join("*.json")
            |> Path.wildcard()
            |> Enum.map(&Path.basename(&1, ".json"))

  defp load(name), do: @dir |> Path.join(name <> ".json") |> File.read!() |> Jason.decode!()

  defp build!(name) do
    {:ok, model} = name |> load() |> Model.build()
    model
  end

  defp golden(model),
    do: model |> Model.to_map() |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)

  describe "golden snapshots" do
    for name <- @fixtures do
      @name name
      test "#{name} matches its golden Model" do
        path = Path.join([@dir, "golden", @name <> ".model.json"])
        actual = golden(build!(@name)) <> "\n"

        if System.get_env("BUBBLE_EX_UPDATE_GOLDEN") do
          File.write!(path, actual)
        end

        assert File.exists?(path), "missing golden #{path}; set BUBBLE_EX_UPDATE_GOLDEN=1"
        assert actual == File.read!(path)
      end
    end

    test "every fixture has a golden and every golden a fixture" do
      goldens =
        [@dir, "golden", "*.model.json"]
        |> Path.join()
        |> Path.wildcard()
        |> Enum.map(&Path.basename(&1, ".model.json"))

      assert Enum.sort(goldens) == Enum.sort(@fixtures)
    end
  end

  describe "determinism" do
    test "two builds give identical bytes" do
      for name <- @fixtures do
        app = load(name)
        {:ok, a} = Model.build(app)
        {:ok, b} = Model.build(app)
        assert Model.to_json(a) == Model.to_json(b), name
        assert Model.sha256(a) == Model.sha256(b)
      end
    end

    # Re-emit each fixture's text with every object's members shuffled
    # (embedded API Connector registries too, so they are different strings;
    # see BubbleEx.Test.PermutedJson), decode it and rebuild: the Model's
    # bytes must not change. The inputs are checked to really differ.
    test "permuted source text gives identical bytes" do
      for name <- @fixtures do
        app = load(name)
        {:ok, expected} = Model.build(app)

        texts =
          for seed <- 1..5 do
            :rand.seed(:exsss, {seed, 7, 13})
            text = PermutedJson.encode(app)
            {:ok, actual} = Model.build(Jason.decode!(text))
            assert Model.to_json(actual) == Model.to_json(expected), "#{name} (seed #{seed})"
            text
          end

        if map_size(app) > 1 do
          assert Enum.any?(texts, &(&1 != Jason.encode!(app))), "#{name}: text never permuted"
        end
      end
    end

    test "embedded registries are really permuted" do
      :rand.seed(:exsss, {1, 2, 3})
      app = load("external_types")
      permuted = app |> PermutedJson.encode() |> Jason.decode!()
      types = &get_in(&1, ~w(settings client_safe apiconnector2 geo lookup types))
      assert types.(permuted) != types.(app)
      assert Jason.decode!(types.(permuted)) == Jason.decode!(types.(app))
    end
  end

  describe "data types and fields" do
    test "every Bubble field type has a stack-neutral content type" do
      task = Model.data_type(build!("field_types"), "task")
      type = fn id -> Enum.find(task.fields, &(&1.id == id)).type end

      assert %Type{kind: :scalar, base: :text, cardinality: :one} = type.("title_text")
      assert %Type{kind: :scalar, base: :number} = type.("estimate_number")
      assert %Type{kind: :scalar, base: :boolean} = type.("done_boolean")
      assert %Type{kind: :scalar, base: :date} = type.("due_date")
      assert %Type{kind: :file_ref, base: :file} = type.("attachment_file")
      assert %Type{kind: :file_ref, base: :image} = type.("cover_image")

      assert %Type{kind: :structured, base: :geographic_address} =
               type.("place_geographic_address")

      assert %Type{kind: :structured, base: :date_range} = type.("window_date_range")
      assert %Type{kind: :structured, base: :number_range} = type.("budget_number_range")
      assert %Type{kind: :structured, base: :date_interval} = type.("duration_dateinterval")

      assert %Type{kind: :ref, target: "user", resolved: true, cardinality: :one} =
               type.("owner_user")

      assert %Type{kind: :ref, target: "project", resolved: true} =
               type.("project_custom_project")

      assert %Type{kind: :option, target: "status", resolved: true} =
               type.("status_option_status")

      assert %Type{kind: :ref, target: "task", cardinality: :many, source: "list.custom.task"} =
               type.("subtasks_list_custom_task")

      assert %Type{kind: :option, cardinality: :many} = type.("labels_list_option_status")
      assert %Type{kind: :structured, cardinality: :many} = type.("ranges_list_date_range")
    end

    test "fields keep defaults, display names and Bubble IDs" do
      task = Model.data_type(build!("field_types"), "task")
      title = Enum.find(task.fields, &(&1.id == "title_text"))
      assert %Field{name: "Title", default: "Untitled", deleted: false} = title
      assert title.path == "/user_types/task/fields/title_text"
      assert Enum.find(task.fields, &(&1.id == "done_boolean")).default == false
      assert Enum.map(task.fields, & &1.id) == Enum.sort(Enum.map(task.fields, & &1.id))
    end

    test "every data type has Bubble's system fields, and User an email" do
      model = build!("field_types")

      for type <- model.data_types do
        roles = Enum.map(type.system_fields, & &1.system)
        expected = [:unique_id, :created_date, :modified_date, :created_by, :slug]
        expected = if type.id == "user", do: expected ++ [:email], else: expected
        assert roles == expected
      end

      assert {:ok, %Field{system: :created_by, type: %Type{kind: :ref, target: "user"}}} =
               Model.field(model, "task", "Created By")

      assert {:ok, %Field{system: :unique_id, type: %Type{base: :text}}} =
               Model.field(model, "task", "_id")

      assert {:ok, %Field{system: :created_date, type: %Type{base: :date}}} =
               Model.field(model, "project", "Created Date")

      assert :error = Model.field(model, "task", "nope")
      assert :error = Model.field(model, "nope", "_id")
    end

    test "self references and cycles between data types are references by ID" do
      [node] = build!("hostile_self_reference").data_types

      assert Enum.all?(
               node.fields,
               &match?(%Type{kind: :ref, target: "node", resolved: true}, &1.type)
             )

      cycle = build!("hostile_type_cycle")
      assert Enum.map(cycle.data_types, &hd(&1.fields).type.target) == ["b", "c", "a"]
      assert cycle.diagnostics == []
    end

    test "the live payload key form reads like an export" do
      model = build!("live_payload")
      order = Model.data_type(model, "order")
      assert order.name == "Order"

      assert %Type{kind: :ref, target: "item", cardinality: :many} =
               field_type(order, "items_list_custom_item")

      assert Enum.find(order.fields, &(&1.id == "gone_text")).deleted
      assert Model.data_type(model, "item").deleted
      assert order.fields |> hd() |> Map.fetch!(:path) =~ "/user_types/order/%f3/"
      assert [%{key: "wholesale"}, %{key: "retail"}] = Model.option_set(model, "kind").values
    end
  end

  describe "option sets" do
    setup do
      %{model: build!("option_sets")}
    end

    test "values follow sort_factor, keep stable keys and attribute values", %{model: model} do
      set = Model.option_set(model, "priority")

      assert Enum.map(set.values, & &1.id) ==
               ~w(bAd bAb bAc bAa bAe bAf bAg bAh)

      high = Enum.find(set.values, &(&1.id == "bAb"))
      assert high.key == "high"
      assert high.name == "High"
      assert high.attributes["channels"] == ["email", "sms"]
      assert high.attributes["escalates_to"] == "critical"

      assert Enum.find(set.values, &(&1.id == "bAe")).deleted

      assert Enum.find(set.values, &(&1.id == "bAh")).extra == %{
               "tooltip" => "attribute no longer declared"
             }
    end

    test "ties in sort_factor fall back to Bubble ID", %{model: model} do
      assert Enum.map(Model.option_set(model, "channel").values, & &1.id) == ~w(email sms)
    end

    test "attributes are typed fields, deleted ones kept", %{model: model} do
      set = Model.option_set(model, "priority")
      type = fn id -> Enum.find(set.attributes, &(&1.id == id)) end
      assert %Type{kind: :scalar, base: :number} = type.("weight").type
      assert %Type{kind: :file_ref, base: :image} = type.("icon").type
      assert %Type{kind: :option, target: "priority", resolved: true} = type.("escalates_to").type
      assert %Type{kind: :option, target: "channel", cardinality: :many} = type.("channels").type
      assert type.("retired").deleted
      assert type.("color").creation_source == "editor"
    end

    test "missing and duplicate stable keys are diagnosed", %{model: model} do
      unkeyed = model.option_sets |> Enum.flat_map(& &1.values) |> Enum.find(&(&1.id == "bAf"))
      assert unkeyed.key == "bAf"

      assert [%Diagnostic{details: %{value: "bAf"}, outcome: :degraded}] =
               diagnostics(model, :model_option_key_missing)

      assert [%Diagnostic{details: %{key: "high", value: "bAg", first: "bAb"}}] =
               diagnostics(model, :model_duplicate_option_key)

      assert [%Diagnostic{subject: %{option_set: "orphan", field: "parent"}}] =
               diagnostics(model, :model_unresolved_target)
    end

    test "deleted option sets are kept", %{model: model} do
      assert %OptionSet{deleted: true, values: []} = Model.option_set(model, "legacy")
    end
  end

  describe "privacy rules" do
    test "reuse BubbleEx.Privacy rules and type-level flags" do
      model = build!("privacy_rules")
      note = Model.data_type(model, "note")
      assert note.exposed_api == true
      assert note.privacy == :present
      assert Enum.map(note.rules, & &1.id) == ~w(admins_ owner_ everyone)
      owner = Enum.find(note.rules, &(&1.id == "owner_"))
      assert %BubbleEx.Privacy.Rule{} = owner
      assert owner.permissions.binding_fields == ~w(body_text secret_text)
      assert owner.permissions.modify_via_api == true
      assert owner.condition

      assert Model.data_type(model, "public_page").privacy == :none

      assert [%Diagnostic{stage: :parse, subject: %{type: "draft"}}] =
               diagnostics(model, :missing_default_rule)

      [rule] =
        model |> Model.to_map() |> get_in(["data_types", Access.at(1), "rules"]) |> Enum.take(1)

      assert rule["condition"]["node"]
      refute Map.has_key?(rule, "diagnostics")
    end
  end

  describe "external types" do
    setup do
      %{model: build!("external_types")}
    end

    test "known, empty, unknown and invalid API types", %{model: model} do
      assert %{resolution: :resolved, name: "Address", connector: "geo", call: "lookup"} =
               Model.external_type(model, "api.apiconnector2.geo.lookup.Address")

      assert %{resolution: :resolved_empty} =
               Model.external_type(model, "api.apiconnector2.misc.blank.Empty")

      assert %{resolution: :opaque} =
               Model.external_type(model, "api.apiconnector2.geo.lookup.Missing")

      shipment = Model.data_type(model, "shipment")

      assert %Type{kind: :external, resolved: true, cardinality: :one} =
               field_type(shipment, "address_api")

      assert %Type{kind: :external, resolved: false} = field_type(shipment, "missing_api")
      assert %Type{kind: :external, resolved: false} = field_type(shipment, "nowhere_api")

      assert %Type{kind: :opaque, cardinality: :unknown, source: "api.not_a_connector"} =
               field_type(shipment, "invalid_api")

      assert %Type{kind: :external, cardinality: :many} = field_type(shipment, "pings_list_api")
      assert Enum.find(shipment.fields, &(&1.id == "old_api")).deleted

      address = Model.external_type(model, "api.apiconnector2.geo.lookup.Address")

      assert Enum.map(address.fields, &{&1.id, &1.type.kind, &1.type.base}) == [
               {"lat", :scalar, :number},
               {"lines", :scalar, :text},
               {"seen", :scalar, :date_unix},
               {"street", :scalar, :text},
               {"verified", :scalar, :boolean}
             ]
    end

    test "recursive and mutually recursive types are cut at one edge", %{model: model} do
      cuts =
        for t <- model.external_types, f <- t.fields, f.cycle, do: {t.id, f.id}

      assert cuts == [
               {"api.apiconnector2.graph.pong.B", "a"},
               {"api.apiconnector2.tree.walk.Node", "children"}
             ]

      b = Model.external_type(model, "api.apiconnector2.graph.pong.B")
      blob = Enum.find(b.fields, &(&1.id == "blob"))
      assert %Type{kind: :opaque, source: "mystery"} = blob.type
    end

    test "Reader diagnostics are kept at stage :read", %{model: model} do
      codes = model.diagnostics |> Enum.map(&{&1.stage, &1.code}) |> Enum.sort()

      assert codes == [
               read: :connector_missing,
               read: :empty_definition,
               read: :exact_type_definition_missing,
               read: :field_type_unsupported,
               read: :incomplete_field_metadata,
               read: :invalid_descriptor
             ]
    end
  end

  describe "missing targets and deleted definitions" do
    test "references to absent types are unresolved, deleted definitions kept" do
      model = build!("missing_and_deleted")
      invoice = Model.data_type(model, "invoice")

      assert %Type{kind: :ref, target: "ghost", resolved: false} =
               field_type(invoice, "customer_custom_ghost")

      assert %Type{kind: :option, target: "ghost_state", resolved: false} =
               field_type(invoice, "state_option_ghost_state")

      # A deleted type still exists: references to it resolve.
      assert %Type{resolved: true} = field_type(invoice, "archive_custom_archive")
      assert Model.data_type(model, "archive").deleted
      assert Enum.find(invoice.fields, &(&1.id == "old_total_number")).deleted

      unresolved = diagnostics(model, :model_unresolved_target)
      assert length(unresolved) == 4
      assert Enum.all?(unresolved, &(&1.outcome == :unresolved and &1.stage == :model))

      assert Enum.map(unresolved, & &1.details.target) |> Enum.sort() ==
               ~w(ghost ghost ghost_line ghost_state)

      assert [%{deleted: true, values: [%{deleted: true}]}] = model.option_sets
    end
  end

  describe "naming (WTF-339)" do
    test "display names are verbatim and the Model has no target-language names" do
      model = build!("naming")
      join = Model.data_type(model, "00__thing___join")
      assert join.name == "00. Thing - Join"
      assert Enum.count(join.fields, &(&1.name == "Title")) == 2

      assert Enum.sort(Enum.map(join.fields, & &1.name)) ==
               Enum.sort([
                 "11. Done",
                 "40. Sort: Thing Title",
                 "Title",
                 "Title",
                 "__struct__",
                 "id",
                 "inserted_at",
                 "type"
               ])

      assert Model.data_type(model, "launch").name == "🚀 Launch"
      assert Enum.map(model.data_types, & &1.id) == ~w(00__thing___join launch thing thing0)

      keys = model |> Model.to_map() |> all_keys() |> MapSet.new()

      for forbidden <- ~w(module table table_name attribute_name resource enum ash_type column) do
        refute MapSet.member?(keys, forbidden), "target-language key #{forbidden}"
      end
    end

    test "long and Unicode IDs and names survive, with escaped pointers" do
      model = build!("hostile_long_unicode_names")
      type = Model.data_type(model, "tâche_ü")
      assert String.length(type.name) > 500
      slash = Enum.find(type.fields, &(&1.id == "a/b~c_text"))
      assert slash.path == "/user_types/tâche_ü/fields/a~1b~0c_text"

      assert %Type{kind: :ref, target: "类型", resolved: true} =
               field_type(type, "emoji_🧪_custom_类型")

      assert model.diagnostics == []
    end
  end

  describe "hostile input" do
    test "an empty app is an empty Model" do
      assert {:ok, %Model{data_types: [], option_sets: [], external_types: [], diagnostics: []}} =
               Model.build(%{})
    end

    test "non-objects are an error, not a crash" do
      for input <- [nil, [], "app", 42] do
        assert {:error, %BubbleEx.Error{kind: :invalid_input}} = Model.build(input)
      end
    end

    # Carried over from PR #99: Db.Reader.parse/1 crashes on a data type that
    # is not a JSON object. The Model keeps it raw and diagnosed.
    test "a data type that is not an object is kept raw with a malformed_node diagnostic" do
      model = build!("hostile_malformed")

      assert %DataType{raw: "not a type", fields: [], system_fields: []} =
               Model.data_type(model, "broken")

      assert %DataType{raw: 42} = Model.data_type(model, "counted")

      assert [
               %Diagnostic{
                 subject: %{type: "broken"},
                 path: "/user_types/broken",
                 outcome: :preserved
               },
               %Diagnostic{subject: %{type: "counted"}}
             ] = diagnostics(model, :malformed_node)
    end

    test "malformed fields, descriptors and option sets are kept and diagnosed" do
      model = build!("hostile_malformed")
      task = Model.data_type(model, "task")

      assert %Field{raw: "not a field", type: %Type{kind: :unknown}} =
               Enum.find(task.fields, &(&1.id == "bad"))

      assert %Type{kind: :unknown, source: nil} = field_type(task, "untyped")
      assert %Type{kind: :unknown, source: 7} = field_type(task, "numeric_type")
      assert %Type{kind: :unknown, source: "quantum_state"} = field_type(task, "quantum")
      assert %Type{kind: :unknown, source: "list.list.text"} = field_type(task, "nested_list")
      assert %Type{kind: :unknown, source: "custom."} = field_type(task, "empty_custom")

      assert Enum.find(task.fields, &(&1.id == "extra_member")).extra == %{
               "secret_sauce" => %{"k" => [1, 2]}
             }

      assert task.extra == %{"surprise" => %{"x" => 1}}
      assert Model.data_type(model, "listy").extra == %{"fields" => ["not", "a", "map"]}
      assert Model.option_set(model, "bad_set").raw == "nope"

      assert Model.option_set(model, "bad_values").extra == %{
               "values" => "oops",
               "attributes" => ["x"]
             }

      bad_value = Model.option_set(model, "bad_value")
      assert Enum.map(bad_value.values, & &1.id) == ~w(v1 v2)
      assert %{raw: 5, key: "v1"} = hd(bad_value.values)
      assert bad_value.extra == %{"flavor" => "mint"}

      odd = Model.external_type(model, "api.apiconnector2.bad.defs.T")
      assert Enum.map(odd.fields, &{&1.id, &1.type.kind}) == [{"fine", :scalar}, {"odd", :opaque}]
    end

    test "top-level collections that are not objects are kept in extra" do
      model = build!("hostile_malformed_collections")
      assert model.extra == %{"user_types" => [], "option_sets" => "nope"}
      assert length(diagnostics(model, :model_malformed_node)) == 2
    end
  end

  describe "diagnostics" do
    test "carry registered codes, model-stage subjects and truthful outcomes" do
      for name <- @fixtures do
        app = load(name)
        model = build!(name)
        map = Model.to_map(model)
        assert model.diagnostics == Diagnostic.normalize(model.diagnostics)

        for %Diagnostic{stage: :model} = d <- model.diagnostics do
          assert {:ok, %{stage: :model}} = Codes.fetch(d.code)
          assert Atom.to_string(d.code) =~ ~r/^model_/

          # A :preserved diagnostic's source value is retained in the Model.
          case {d.outcome, lookup(app, d.path)} do
            {:preserved, {:ok, value}}
            when is_map(value) and d.code == :model_malformed_field_type ->
              refute Map.has_key?(value, "value") or Map.has_key?(value, "%v")

            {:preserved, {:ok, value}} ->
              assert contains?(map, value), "#{name}: #{d.code} at #{d.path} not kept"

            {:preserved, :error} ->
              flunk("#{name}: #{d.code} path #{d.path} not in the source")

            _ ->
              :ok
          end
        end
      end
    end
  end

  describe "schema for expression typing" do
    test "matches Expression.Schema built from the same app" do
      for name <- @fixtures do
        app = load(name)
        assert Model.schema(build!(name)) == Schema.from_app(app), name
      end
    end

    test "types field chains through the Model" do
      schema = Model.schema(build!("field_types"))

      assert {:ok, %{value: "custom.project"}} =
               Schema.field(schema, "custom.task", "project_custom_project")

      assert {:ok, %{value: "list.text"}} = Schema.field(schema, "list.custom.task", "title_text")
    end
  end

  describe "summary" do
    test "counts data types, fields, relationships and diagnostics" do
      summary = Model.summary(build!("field_types"))
      assert summary["data_types"] == 3
      assert summary["fields"] == 26
      assert summary["system_fields"] == 16
      assert summary["relationships"] == %{"one" => 2, "many" => 2}
      assert summary["option_values"] == 2
      assert summary["diagnostics"] == %{}
    end
  end

  defp field_type(%DataType{fields: fields}, id), do: Enum.find(fields, &(&1.id == id)).type

  defp diagnostics(model, code), do: Enum.filter(model.diagnostics, &(&1.code == code))

  defp all_keys(map) when is_map(map),
    do: Enum.flat_map(map, fn {k, v} -> [k | all_keys(v)] end)

  defp all_keys(list) when is_list(list), do: Enum.flat_map(list, &all_keys/1)
  defp all_keys(_), do: []

  defp contains?(term, value) when term == value, do: true

  defp contains?(map, value) when is_map(map),
    do: Enum.any?(map, fn {_, v} -> contains?(v, value) end)

  defp contains?(list, value) when is_list(list), do: Enum.any?(list, &contains?(&1, value))
  defp contains?(_, _), do: false

  defp lookup(doc, "" <> pointer) do
    pointer
    |> String.split("/", trim: false)
    |> tl()
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
    |> Enum.reduce_while({:ok, doc}, fn segment, {:ok, node} ->
      case node do
        %{^segment => child} -> {:cont, {:ok, child}}
        _ -> {:halt, :error}
      end
    end)
  end
end
