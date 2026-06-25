defmodule BubbleEx.DeepSearch do
  @moduledoc """
  Provides deep search functionality for traversing nested data structures.

  This module allows you to search through complex nested maps and lists to find
  all paths that lead to values containing a specific target string. It's particularly
  useful for analyzing JSON structures from Bubble.io applications to locate specific
  fields, IDs, or values within deeply nested data.

  ## Features

  - Recursively searches through maps and lists
  - Returns all paths to values containing the target string
  - Handles mixed nesting of maps and lists
  - Case-sensitive string matching

  ## Examples

      # Example with nested maps and lists
      data = %{
        "user" => %{
          "name" => "John Doe",
          "email" => "john@example.com",
          "settings" => %{
            "theme" => "dark",
            "notifications" => ["email", "push"]
          }
        },
        "posts" => [
          %{"title" => "First Post", "content" => "Hello world"},
          %{"title" => "Second Post", "content" => "Another post"}
        ]
      }

      BubbleEx.DeepSearch.find_all_paths(data, "email")
      # => [["user", "settings", "notifications", 0], ["user", "email"]]

      BubbleEx.DeepSearch.find_all_paths(data, "Post")
      # => [["posts", 1, "title"], ["posts", 0, "title"]]

  ## Path Format

  The returned paths are lists where:
  - String elements represent map keys
  - Integer elements represent list indices

  Note: While paths with map keys can be used directly with `get_in/2`,
  paths containing list indices cannot due to Elixir's Access limitations.
  For list access, use `Enum.at/2` or manual traversal.

      # Map-only paths work with get_in
      data = %{"a" => %{"b" => "target"}}
      [path] = BubbleEx.DeepSearch.find_all_paths(data, "target")
      get_in(data, path)
      # => "target"

      # Paths with list indices require manual traversal
      data = %{"items" => ["first", "second", "third"]}
      [["items", 1]] = BubbleEx.DeepSearch.find_all_paths(data, "second")
      data["items"] |> Enum.at(1)
      # => "second"
  """

  @doc """
  Finds all paths in a nested data structure that lead to values containing the target string.

  Searches recursively through maps and lists to find all string values that contain
  the specified target substring. Returns a list of paths, where each path is a list
  of keys and indices that can be used to navigate to the matching value.

  ## Parameters

  - `data` - The data structure to search (map, list, or any other type)
  - `target` - The target string to search for (case-sensitive substring match)

  ## Returns

  A list of paths, where each path is a list of keys (strings) and indices (integers)
  that lead to a value containing the target string. Returns an empty list if no
  matches are found.

  ## Examples

      iex> BubbleEx.DeepSearch.find_all_paths(%{"name" => "Alice", "info" => %{"email" => "alice@example.com"}}, "alice")
      [["info", "email"]]

      iex> BubbleEx.DeepSearch.find_all_paths(["first", "second", %{"nested" => "third"}], "second")
      [[1]]

      iex> BubbleEx.DeepSearch.find_all_paths(%{}, "target")
      []

      iex> BubbleEx.DeepSearch.find_all_paths("simple string", "simple")
      []

  ## Performance Considerations

  For very large data structures, this function may consume significant memory as it
  builds the complete list of paths. Consider implementing pagination or streaming
  for extremely large datasets.
  """
  @spec find_all_paths(any(), String.t()) :: [list(String.t() | non_neg_integer())]
  def find_all_paths(data, target) when is_binary(target) do
    find_all_paths_recursive(data, target, [], [])
  end

  @doc false
  @spec find_all_paths_recursive(any(), String.t(), list(), list()) :: list()
  # `path` is accumulated in reverse (prepend is O(1)); it is reversed back into
  # root-to-leaf order only when a match is recorded.
  defp find_all_paths_recursive(map, target, path, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {key, value}, acc ->
      check_value_all(value, target, [key | path], acc)
    end)
  end

  defp find_all_paths_recursive(list, target, path, acc) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {value, index}, acc ->
      check_value_all(value, target, [index | path], acc)
    end)
  end

  defp find_all_paths_recursive(_, _, _, acc), do: acc

  @doc false
  @spec check_value_all(any(), String.t(), list(), list()) :: list()
  defp check_value_all(value, target, path, acc) do
    cond do
      # Check if value is a string and contains the target substring
      is_binary(value) and String.contains?(value, target) ->
        [Enum.reverse(path) | acc]

      is_map(value) or is_list(value) ->
        find_all_paths_recursive(value, target, path, acc)

      true ->
        acc
    end
  end
end
