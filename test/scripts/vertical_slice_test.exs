defmodule BubbleEx.Scripts.VerticalSliceTest do
  # The vertical slice's pipeline (scripts/vertical_slice, WTF-378): its
  # privacy mode and sign-in persona.
  use ExUnit.Case, async: true

  Code.require_file("../../scripts/vertical_slice/pipeline.exs", __DIR__)
  Code.require_file("../../scripts/vertical_slice/seed.exs", __DIR__)

  alias VerticalSlice.{Pipeline, Synthetic}

  @enforced_app "test/support/target/phoenix/enforced.json"

  describe "privacy_mode/1" do
    test "defaults to omit, accepts enforced, refuses anything else" do
      assert Pipeline.privacy_mode(nil) == :omit
      assert Pipeline.privacy_mode("") == :omit
      assert Pipeline.privacy_mode("omit") == :omit
      assert Pipeline.privacy_mode("enforced") == :enforced

      for bad <- ["unverified", "ENFORCED", "on"] do
        assert_raise ArgumentError, ~r/SLICE_PRIVACY/, fn -> Pipeline.privacy_mode(bad) end
      end
    end
  end

  describe "build/3" do
    setup do
      %{app: Pipeline.load_app(@enforced_app)}
    end

    test "maps with privacy: :omit unless told otherwise", %{app: app} do
      built = Pipeline.build(app, [], module: "Slice")
      assert built.project.privacy == :omit
      assert Enum.all?(built.project.resources, &(&1.policies == []))
    end

    test "maps with the compiled policies with privacy: :enforced", %{app: app} do
      built = Pipeline.build(app, [], module: "Slice", privacy: :enforced)
      assert built.project.privacy == :enforced
      assert Enum.any?(built.project.resources, &(&1.policies != []))

      {:ok, files} = Pipeline.render(built, name: "Slice", module: "Slice")
      assert files |> Map.keys() |> Enum.any?(&String.ends_with?(&1, "/privacy.ex"))
    end
  end

  describe "Synthetic.rows/2" do
    # WTF-500: user i's membership must belong to user i. Pointing every
    # reference at the next record made the signed-in user's membership
    # belong to another user, and the policies refused every read through it.
    test "keeps each index one world: references to another type point at the same index" do
      app = %{
        "user_types" => %{
          "user" => %{
            "display" => "User",
            "fields" => %{
              "membership_custom_membership" => %{
                "display" => "Membership",
                "value" => "custom.membership"
              }
            }
          },
          "membership" => %{
            "display" => "Membership",
            "fields" => %{
              "member_user" => %{"display" => "Member", "value" => "user"},
              "parent_custom_membership" => %{
                "display" => "Parent",
                "value" => "custom.membership"
              },
              "guests_list_user" => %{"display" => "Guests", "value" => "list.user"}
            }
          }
        }
      }

      {:ok, model} = BubbleEx.Model.build(app)
      rows = Synthetic.rows(model, 3)
      ids = Synthetic.ids(model, 3)
      id = fn type, i -> Enum.at(ids[type], i - 1) end

      for i <- 1..3 do
        user = Enum.at(rows["user"], i - 1)
        membership = Enum.at(rows["membership"], i - 1)

        assert user["membership_custom_membership"] == id.("membership", i)
        assert membership["member_user"] == id.("user", i)
        assert membership["Created By"] == id.("user", i)
        # Its own type: the next record, never itself.
        assert membership["parent_custom_membership"] == id.("membership", rem(i, 3) + 1)
        assert hd(membership["guests_list_user"]) == id.("user", i)
      end
    end
  end

  describe "Synthetic.rows/2, the twins (WTF-530)" do
    setup do
      %{model: Pipeline.build(Pipeline.load_app(@enforced_app), [], module: "Slice").model}
    end

    test "writes false booleans instead of dropping them", %{model: model} do
      rows = Synthetic.rows(model, 3)
      # User 2 is a primary record with false booleans; user 4 is user 1's twin.
      for user <- [Enum.at(rows["user"], 1), Enum.at(rows["user"], 3)] do
        assert Map.fetch(user, "admin_boolean") == {:ok, false}
      end
    end

    test "writes a primary and a twin per world, bounded and deterministic", %{model: model} do
      rows = Synthetic.rows(model, 3)
      ids = Synthetic.ids(model, 3)
      assert Synthetic.records(3) == 6
      assert rows == Synthetic.rows(model, 3)

      for {type, list} <- rows do
        assert length(list) == 6
        assert Enum.map(list, & &1["_id"]) == ids[type]
        assert list |> Enum.map(& &1["_id"]) |> Enum.uniq() |> length() == 6
      end

      emails = for u <- rows["user"], do: u["authentication"]["email"]["email"]
      assert emails == for(i <- 1..6, do: Synthetic.email(i))
    end

    test "a twin keeps its primary's references and owner and negates its booleans",
         %{model: model} do
      rows = Synthetic.rows(model, 3)
      types = Map.new(model.data_types, &{&1.id, &1})

      for {type, list} <- rows, i <- 1..3 do
        primary = Enum.at(list, i - 1)
        twin = Enum.at(list, i + 2)
        fields = types[type].fields

        for f <- fields, f.system == nil, not f.deleted do
          case f.type do
            %{kind: :ref} ->
              assert twin[f.id] == primary[f.id], "#{type}.#{f.id} of world #{i}"

            %{kind: :scalar, base: :boolean, cardinality: :one} ->
              assert is_boolean(primary[f.id])
              assert twin[f.id] == not primary[f.id], "#{type}.#{f.id} of world #{i}"

            _ ->
              :ok
          end
        end

        assert twin["Created By"] == primary["Created By"]
      end
    end

    # A list filtered on a flag ("not archived") must not be empty for a
    # signed-in user only because all of its records carry the same flags.
    test "every owner has, per type, each boolean both true and false", %{model: model} do
      rows = Synthetic.rows(model, 3)
      user_ids = MapSet.new(rows["user"], & &1["_id"])
      live = fn type, shape -> for f <- type.fields, live_field?(f, shape), do: f.id end

      checks =
        for type <- model.data_types,
            not type.deleted,
            booleans = live.(type, :boolean),
            booleans != [],
            key <- ["Created By" | live.(type, :user_ref)],
            {owner, owned} <- Enum.group_by(rows[type.id], & &1[key]),
            b <- booleans do
          assert MapSet.member?(user_ids, owner)

          assert owned |> Enum.map(& &1[b]) |> Enum.uniq() |> Enum.sort() == [false, true],
                 "#{type.id}.#{b} owned by #{owner} through #{key}"

          {type.id, b, key, owner}
        end

      # user, task, note and project carry booleans, note an owner field
      # too: five (type, boolean, owner key) pairs, three owners each.
      assert length(checks) == 5 * 3
    end
  end

  defp live_field?(%{system: nil, deleted: false, type: type}, :boolean),
    do: match?(%{kind: :scalar, base: :boolean, cardinality: :one}, type)

  defp live_field?(%{system: nil, deleted: false, type: type}, :user_ref),
    do: match?(%{kind: :ref, target: "user", cardinality: :one}, type)

  defp live_field?(_field, _shape), do: false

  describe "Synthetic.persona/2" do
    test "defaults to user 1 and takes an index up to n" do
      assert Synthetic.persona(nil, 3) == 1
      assert Synthetic.persona("", 3) == 1
      assert Synthetic.persona("2", 3) == 2
      assert Synthetic.persona("3", 3) == 3
      assert Synthetic.email(Synthetic.persona("2", 3)) == "slice-user-2@example.test"
    end

    test "refuses an index outside the seeded users" do
      for bad <- ["0", "4", "-1", "two", "1.5"] do
        assert_raise ArgumentError, ~r/SLICE_PERSONA/, fn -> Synthetic.persona(bad, 3) end
      end
    end
  end

  # The drive's expected blocked requests (WTF-465): exact linked image
  # URLs, never Bubble's storage (scripts/vertical_slice/linked_images.mjs).
  test "the drive expects only the exact linked image URLs" do
    {output, status} =
      System.cmd("node", ["--test", "scripts/vertical_slice/linked_images.test.mjs"],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ ~r/# pass 6|ℹ pass 6/
  end
end
