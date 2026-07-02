defmodule BubbleEx.Db.NamingTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Naming

  describe "snake_case/2" do
    test "sanitizes free-form labels like the encoders always have" do
      assert Naming.snake_case("Created Date") == "created_date"
      assert Naming.snake_case("camelCaseName") == "camel_case_name"
    end

    test "preserves a single leading underscore (Bubble's _id)" do
      assert Naming.snake_case("_id") == "_id"
    end

    test "prefixes digit-leading names so they are legal atom literals" do
      assert Naming.snake_case("1st place") == "n1st_place"
    end

    test "falls back when nothing sanitizable remains" do
      assert Naming.snake_case("🎉🎉") == "field"
      assert Naming.snake_case("🎉", "col") == "col"
    end
  end

  describe "pascal_case/2" do
    test "builds module segments" do
      assert Naming.pascal_case("user profile") == "UserProfile"
    end

    test "prefixes digit-leading names so they are legal module segments" do
      # tokens/1 splits digit->uppercase boundaries ("3D" -> "3", "d"),
      # matching the private helper in BubbleEx.Db.Ecto.
      assert Naming.pascal_case("3D Models") == "N3DModels"
    end

    test "falls back when nothing sanitizable remains" do
      assert Naming.pascal_case("日本語") == "Table"
    end
  end

  describe "claim/3" do
    test "returns the base name when free and marks it used" do
      {name, used} = Naming.claim("owner", MapSet.new())
      assert name == "owner"
      assert MapSet.member?(used, "owner")
    end

    test "suffixes from _2 upward when taken" do
      used = MapSet.new(["owner", "owner_2"])
      assert {"owner_3", _} = Naming.claim("owner", used)
    end
  end

  describe "unique_names/4" do
    test "collisions get numeric suffixes in encounter order" do
      items = [%{id: "a", name: "Owner!"}, %{id: "b", name: "owner?"}]

      assert Naming.unique_names(items, & &1.id, &Naming.snake_case(&1.name)) ==
               %{"a" => "owner", "b" => "owner_2"}
    end

    test "reserved names are taken from the start" do
      items = [%{id: "t1", name: "repo"}]

      assert Naming.unique_names(items, & &1.id, &Naming.pascal_case(&1.name),
               reserved: ["Repo"],
               suffix: fn name, n -> "#{name}#{n}" end
             ) == %{"t1" => "Repo2"}
    end

    test "fallback names dedup too" do
      items = [%{id: "a", name: "🎉"}, %{id: "b", name: "✨"}]

      assert Naming.unique_names(items, & &1.id, &Naming.snake_case(&1.name)) ==
               %{"a" => "field", "b" => "field_2"}
    end
  end
end
