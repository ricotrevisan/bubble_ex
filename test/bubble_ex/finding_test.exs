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
        assert {:ok, %{category: category, transforms: [_ | _], doc: doc}} = Kinds.fetch(kind)
        assert category in Kinds.categories()
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
          proposal: %{transform: :normalize_list_to_join}
        )

      assert Finding.normalize([c, a, b]) == [b, a, c]
    end

    test "normalize raises when two findings share an ID" do
      a = finding(:number_type, %{type: "a", field: "y"})

      assert_raise ArgumentError, ~r/duplicate finding IDs/, fn ->
        Finding.normalize([a, %{a | message: "other"}])
      end
    end

    test "proposal_sha256 follows the proposal and evidence, not the message or paths" do
      ref = %Reference{from: "action:a", to: "field:t/f", kind: :writes_field, path: "/x"}

      a =
        finding(:number_type, %{type: "t", field: "f"},
          evidence: %{symbols: [], references: [ref]}
        )

      b =
        finding(:number_type, %{type: "t", field: "f"},
          message: "other",
          confidence: :low,
          evidence: %{symbols: [], references: [%{ref | path: "/moved"}]}
        )

      c =
        finding(:number_type, %{type: "t", field: "f"},
          proposal: %{transform: :refine_number_type, field: "field:t/f", to: :integer}
        )

      assert a.proposal_sha256 == b.proposal_sha256
      assert a.proposal_sha256 =~ ~r/^[0-9a-f]{64}$/
      refute a.proposal_sha256 == c.proposal_sha256
      assert a.id == c.id
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
        affects: %{maintainers: %{workflows: ["workflow:b", "workflow:a"]}},
        related: ["x", "a", "x"]
      )

    assert f.path == "/user_types/task/fields/points_number"
    assert f.evidence.symbols == ["a", "b"]
    assert Enum.map(f.evidence.references, & &1.from) == ["action:a", "action:b"]

    empty = %{workflows: [], pages: [], reusables: [], privacy_rules: []}

    assert f.affects == %{
             readers: empty,
             maintainers: %{empty | workflows: ["workflow:a", "workflow:b"]}
           }

    assert f.related == ["a", "x"]
    assert f.category == :decision

    map = Finding.to_map(f)
    assert map["kind"] == "number_type"
    assert map["category"] == "decision"
    assert map["proposal_sha256"] == f.proposal_sha256
    assert map["proposal"]["transform"] == "refine_number_type"
    assert [%{"from" => "action:a", "kind" => "writes_field"} | _] = map["evidence"]["references"]
    assert map |> Jason.encode!() |> Jason.decode!() == map
    assert Jason.encode!(f) == BubbleEx.CanonicalJson.encode(map)
  end
end
