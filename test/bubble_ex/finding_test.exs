defmodule BubbleEx.FindingTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Finding
  alias BubbleEx.Finding.Kinds
  alias BubbleEx.Index.Reference

  doctest BubbleEx.Finding

  defp finding(kind, subject, opts \\ []) do
    Finding.new(
      kind,
      subject,
      Keyword.merge(
        [
          proposal: %{transform: :refine_number_type, field: "field:task/points_number"},
          confidence: :high,
          message: "m"
        ],
        opts
      )
    )
  end

  describe "kind registry" do
    test "every kind emitted under lib/ is registered, and every registered kind is emitted" do
      emitted =
        for file <- Path.wildcard("lib/**/*.ex"),
            [_, kind] <- Regex.scan(~r/Finding\.new\(\s*:(\w+)/, File.read!(file)),
            into: MapSet.new(),
            do: String.to_atom(kind)

      assert emitted == MapSet.new(Kinds.all())

      for kind <- Kinds.all() do
        assert {:ok, %{transforms: [_ | _], doc: doc}} = Kinds.fetch(kind)
        assert doc != ""
      end
    end

    test "rejects unregistered kinds, disallowed transforms, bad subjects and confidences" do
      assert_raise ArgumentError, ~r/unregistered finding kind/, fn ->
        finding(:nope, %{type: "task"})
      end

      assert_raise ArgumentError, ~r/cannot propose/, fn ->
        finding(:number_type, %{type: "task"}, proposal: %{transform: :add_index})
      end

      assert_raise ArgumentError, ~r/invalid finding subject/, fn ->
        finding(:number_type, %{type: "task", page: "p1"})
      end

      assert_raise ArgumentError, ~r/needs a subject/, fn -> finding(:number_type, %{}) end

      assert_raise ArgumentError, ~r/invalid confidence/, fn ->
        finding(:number_type, %{type: "task"}, confidence: :certain)
      end
    end
  end

  describe "identity" do
    test "is the kind and subject only; message, evidence and proposal do not change it" do
      a = finding(:number_type, %{type: "task", field: "points_number"}, message: "one")

      b =
        finding(:number_type, %{field: "points_number", type: "task"},
          message: "two",
          confidence: :low,
          evidence: %{symbols: ["field:task/points_number"], references: []}
        )

      assert a.id == b.id
      assert a.id == Finding.id(:number_type, %{type: "task", field: "points_number"})
      assert a.id =~ ~r/^number_type:[0-9a-f]{16}$/

      refute a.id == Finding.id(:search_index, %{type: "task", field: "points_number"})
      refute a.id == Finding.id(:number_type, %{type: "task", field: "other_number"})
    end

    test "normalize drops duplicate IDs and orders by kind, subject and ID" do
      c = finding(:number_type, %{type: "b", field: "x"})
      a = finding(:number_type, %{type: "a", field: "y"})

      b =
        finding(:list_relationship, %{type: "z", field: "x"},
          proposal: %{transform: :extract_join_resource}
        )

      assert Finding.normalize([c, a, b, a]) == [b, a, c]
    end
  end

  test "sorts evidence and affects, and encodes to JSON-stable maps" do
    ref = fn from ->
      %Reference{from: from, to: "field:task/points_number", kind: :writes_field, path: "/x"}
    end

    f =
      finding(:number_type, %{type: "task", field: "points_number"},
        path: ["user_types", "task", "fields", "points_number"],
        evidence: %{
          symbols: ["b", "a", "b"],
          references: [ref.("action:b"), ref.("action:a")],
          writes: %{count: 1}
        },
        affects: %{workflows: ["workflow:b", "workflow:a"]}
      )

    assert f.path == "/user_types/task/fields/points_number"
    assert f.evidence.symbols == ["a", "b"]
    assert Enum.map(f.evidence.references, & &1.from) == ["action:a", "action:b"]

    assert f.affects == %{
             workflows: ["workflow:a", "workflow:b"],
             pages: [],
             reusables: [],
             privacy_rules: []
           }

    map = Finding.to_map(f)
    assert map["kind"] == "number_type"
    assert map["proposal"]["transform"] == "refine_number_type"
    assert [%{"from" => "action:a", "kind" => "writes_field"} | _] = map["evidence"]["references"]
    assert map |> Jason.encode!() |> Jason.decode!() == map
    assert Jason.encode!(f) == BubbleEx.CanonicalJson.encode(map)
  end
end
