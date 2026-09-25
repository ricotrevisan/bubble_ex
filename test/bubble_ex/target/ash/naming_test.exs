defmodule BubbleEx.Target.Ash.NamingTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Target.Ash.Naming

  doctest Naming

  describe "words/1" do
    test "strips ordinal prefixes but keeps numbers that are part of the name" do
      assert Naming.words("00. Thing - Join") == ~w(thing join)
      assert Naming.words("11. Done") == ~w(done)
      assert Naming.words("40. Sort: Thing Title") == ~w(sort thing title)
      assert Naming.words("1.2) Nested") == ~w(nested)
      assert Naming.words("3.5 inch") == ~w(3 5 inch)
      assert Naming.words("2FA code") == ~w(2fa code)
    end

    test "strips emoji, folds accents and splits camel case" do
      assert Naming.words("🚀 Launch ✨") == ~w(launch)
      assert Naming.words("Café Straße Øre") == ~w(cafe strasse ore)
      assert Naming.words("firstName HTTPServer") == ~w(first name http server)
      assert Naming.words("🔥") == []
      assert Naming.words("类型 🏷️") == []
      assert Naming.words(nil) == []
    end
  end

  describe "base/4" do
    test "falls back to the Bubble ID, then to the kind word" do
      assert Naming.base(:snake, "🔥", "_text", "field") == "text"
      assert Naming.base(:pascal, "类型", "类型", "Resource") == "Resource"
    end

    test "prefixes a leading digit" do
      assert Naming.base(:snake, "3D model", "x", "field") == "n3d_model"
      assert Naming.base(:pascal, "3D model", "x", "Resource") == "N3dModel"
    end

    test "keeps whole words within the length limit" do
      name = Naming.base(:snake, String.duplicate("word ", 40), "x", "field")
      assert String.length(name) <= 50
      assert String.ends_with?(name, "word")

      assert Naming.base(:snake, String.duplicate("x", 300), "x", "field") ==
               String.duplicate("x", 50)
    end
  end

  describe "claim/4" do
    test "suffixes reserved words, then numbers collisions from 2" do
      {a, used} = Naming.claim("title", MapSet.new(), :snake, :attribute)
      {b, used} = Naming.claim("title", used, :snake, :attribute)
      {c, used} = Naming.claim("id", used, :snake, :attribute)
      {d, _used} = Naming.claim("id", used, :snake, :none)
      assert [a, b, c, d] == ~w(title title_2 id_field id)

      {m, used} = Naming.claim("Repo", MapSet.new(), :pascal, :module)
      {n, _} = Naming.claim("Thing", MapSet.put(used, "Thing"), :pascal, :module)
      assert [m, n] == ~w(RepoResource Thing2)
    end
  end

  test "underscore/1 turns a generated module segment into a table name" do
    assert Naming.underscore("ThingJoin") == "thing_join"
    assert Naming.underscore("Thing2") == "thing2"
    assert Naming.underscore("V2Api") == "v2_api"
    assert Naming.underscore("N3dModel") == "n3d_model"
  end

  test "valid?/2" do
    assert Naming.valid?(:snake, "title_2")
    refute Naming.valid?(:snake, "Title")
    refute Naming.valid?(:snake, String.duplicate("a", 64))
    assert Naming.valid?(:pascal, "ThingJoin")
    refute Naming.valid?(:pascal, "thing")
    refute Naming.valid?(:pascal, nil)
  end
end
