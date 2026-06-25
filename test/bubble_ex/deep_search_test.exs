defmodule BubbleEx.DeepSearchTest do
  use ExUnit.Case
  doctest BubbleEx.DeepSearch

  alias BubbleEx.DeepSearch

  test "Native finds a base64-encoded secret and reports its path" do
    pat = "ghp_0123456789abcdefABCDEF0123456789abcdef"
    payload = %{"settings" => %{"blob" => Base.encode64("token " <> pat)}}

    assert {:ok, findings} = BubbleEx.Secrets.Native.scan(payload)
    assert Enum.any?(findings, &(&1.decoder == :base64 and &1.path == ["settings", "blob"]))
  end

  describe "find_all_paths/2" do
    test "finds string in simple map" do
      data = %{"name" => "Alice", "email" => "alice@example.com"}

      assert DeepSearch.find_all_paths(data, "alice") == [["email"]]
      assert DeepSearch.find_all_paths(data, "Alice") == [["name"]]
      assert DeepSearch.find_all_paths(data, "@example") == [["email"]]
    end

    test "finds string in nested map" do
      data = %{
        "user" => %{
          "name" => "Bob",
          "contact" => %{
            "email" => "bob@test.com",
            "phone" => "555-1234"
          }
        }
      }

      paths = DeepSearch.find_all_paths(data, "bob")
      assert Enum.sort(paths) == Enum.sort([["user", "contact", "email"]])

      paths = DeepSearch.find_all_paths(data, "Bob")
      assert paths == [["user", "name"]]
    end

    test "finds string in list" do
      data = ["first", "second", "third"]

      assert DeepSearch.find_all_paths(data, "second") == [[1]]
      assert DeepSearch.find_all_paths(data, "ird") == [[2]]
    end

    test "finds string in nested list" do
      data = [
        ["a", "b"],
        ["c", "d", "target"],
        "standalone"
      ]

      assert DeepSearch.find_all_paths(data, "target") == [[1, 2]]
      assert DeepSearch.find_all_paths(data, "standalone") == [[2]]
    end

    test "finds string in mixed nested structure" do
      data = %{
        "items" => [
          %{"id" => "item_1", "name" => "First Item"},
          %{"id" => "item_2", "name" => "Second Item"},
          %{"id" => "item_3", "name" => "Third Item"}
        ],
        "metadata" => %{
          "created_by" => "admin",
          "tags" => ["important", "item_related", "public"]
        }
      }

      paths = DeepSearch.find_all_paths(data, "item_")

      expected = [
        ["metadata", "tags", 1],
        ["items", 2, "id"],
        ["items", 1, "id"],
        ["items", 0, "id"]
      ]

      assert Enum.sort(paths) == Enum.sort(expected)

      paths = DeepSearch.find_all_paths(data, "Item")

      expected = [
        ["items", 2, "name"],
        ["items", 1, "name"],
        ["items", 0, "name"]
      ]

      assert Enum.sort(paths) == Enum.sort(expected)
    end

    test "returns empty list when no matches found" do
      data = %{"name" => "Alice", "age" => 30}

      assert DeepSearch.find_all_paths(data, "Bob") == []
      assert DeepSearch.find_all_paths(data, "xyz") == []
    end

    test "returns empty list for empty data structures" do
      assert DeepSearch.find_all_paths(%{}, "test") == []
      assert DeepSearch.find_all_paths([], "test") == []
    end

    test "handles non-collection types at root" do
      assert DeepSearch.find_all_paths("string", "str") == []
      assert DeepSearch.find_all_paths(123, "1") == []
      assert DeepSearch.find_all_paths(nil, "test") == []
      assert DeepSearch.find_all_paths(true, "true") == []
    end

    test "finds multiple occurrences of the same string" do
      data = %{
        "section1" => %{
          "title" => "Important Info",
          "content" => "This is important"
        },
        "section2" => %{
          "title" => "More Important Stuff",
          "notes" => ["important note 1", "regular note", "important note 2"]
        }
      }

      paths = DeepSearch.find_all_paths(data, "important")

      expected = [
        ["section2", "notes", 2],
        ["section2", "notes", 0],
        ["section1", "content"]
      ]

      assert Enum.sort(paths) == Enum.sort(expected)
    end

    test "handles deeply nested structures" do
      data = %{
        "a" => %{
          "b" => %{
            "c" => %{
              "d" => %{
                "e" => %{
                  "target" => "found me!"
                }
              }
            }
          }
        }
      }

      paths = DeepSearch.find_all_paths(data, "found")
      assert paths == [["a", "b", "c", "d", "e", "target"]]
    end

    test "case sensitivity" do
      data = %{"name" => "TestCase", "value" => "testcase"}

      assert DeepSearch.find_all_paths(data, "Test") == [["name"]]
      assert DeepSearch.find_all_paths(data, "test") == [["value"]]
      assert DeepSearch.find_all_paths(data, "Case") == [["name"]]
      assert DeepSearch.find_all_paths(data, "case") == [["value"]]
    end

    test "partial string matching" do
      data = %{
        "user_id" => "usr_12345",
        "session_id" => "sess_67890",
        "request_id" => "req_abcdef"
      }

      paths = DeepSearch.find_all_paths(data, "_12345")
      expected = [["user_id"]]
      assert Enum.sort(paths) == Enum.sort(expected)

      paths = DeepSearch.find_all_paths(data, "usr_")
      expected = [["user_id"]]
      assert Enum.sort(paths) == Enum.sort(expected)

      paths = DeepSearch.find_all_paths(data, "req_")
      expected = [["request_id"]]
      assert Enum.sort(paths) == Enum.sort(expected)
    end

    test "handles mixed value types in collections" do
      data = %{
        "mixed" => [
          "string value",
          123,
          %{"nested" => "map value"},
          nil,
          ["nested", "list", "value"],
          true,
          3.14
        ]
      }

      paths = DeepSearch.find_all_paths(data, "value")

      expected = [
        ["mixed", 4, 2],
        ["mixed", 2, "nested"],
        ["mixed", 0]
      ]

      assert Enum.sort(paths) == Enum.sort(expected)
    end

    test "returned paths can be used with get_in for maps" do
      data = %{
        "users" => %{
          "alice" => %{"name" => "Alice", "role" => "admin"},
          "bob" => %{"name" => "Bob", "role" => "user"}
        }
      }

      paths = DeepSearch.find_all_paths(data, "admin")
      assert length(paths) == 1

      [path] = paths
      assert get_in(data, path) == "admin"

      paths = DeepSearch.find_all_paths(data, "Bob")
      assert length(paths) == 1

      [path] = paths
      assert get_in(data, path) == "Bob"
    end

    test "returned paths correctly identify list indices" do
      data = %{
        "items" => ["first", "second", "third"]
      }

      paths = DeepSearch.find_all_paths(data, "second")
      assert paths == [["items", 1]]

      # Can't use get_in with list indices, but path is correct
      [path] = paths
      assert path == ["items", 1]

      # Verify we can manually access the value
      assert data["items"] |> Enum.at(1) == "second"
    end

    test "real-world Bubble.io-like structure" do
      data = %{
        "_id" => "app_123456",
        "database" => %{
          "data_types" => [
            %{
              "_id" => "data_type_user",
              "name" => "User",
              "fields" => [
                %{"_id" => "field_email", "name" => "email"},
                %{"_id" => "field_name", "name" => "name"}
              ]
            },
            %{
              "_id" => "data_type_post",
              "name" => "Post",
              "fields" => [
                %{"_id" => "field_title", "name" => "title"},
                %{"_id" => "field_content", "name" => "content"}
              ]
            }
          ]
        },
        "api" => %{
          "endpoints" => [
            "/api/1.1/obj/user",
            "/api/1.1/obj/post"
          ]
        }
      }

      # Find all data type references
      paths = DeepSearch.find_all_paths(data, "data_type_")
      assert length(paths) == 2

      # Find all field references
      paths = DeepSearch.find_all_paths(data, "field_")
      assert length(paths) == 4

      # Find API endpoints
      paths = DeepSearch.find_all_paths(data, "/api/")
      assert length(paths) == 2

      # Verify path structure for nested data
      paths = DeepSearch.find_all_paths(data, "data_type_user")
      [path] = paths
      # Path should point to the correct location in the nested structure
      assert path == ["database", "data_types", 0, "_id"]
    end
  end
end
