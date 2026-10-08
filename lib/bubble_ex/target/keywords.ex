defmodule BubbleEx.Target.Keywords do
  @moduledoc """
  The words of a keyword search (`contains keyword(s)`, IR
  `:text_contains_words`), as the generated runtime reads them
  (`<App>.Bubble.Runtime.keywords/1` and `keyword_patterns/1`, which must
  stay in step with this module): the first 256 characters of the text,
  split on whitespace, empty words dropped, at most the first 32 words.
  The caps bound the work a search box can ask of the database (a long
  input is never split per row). A text with no words matches nothing.

  `patterns/1` gives each word as an `ILIKE` pattern matching it as a
  substring: `\\`, `%` and `_` escaped with a backslash (`LIKE`'s default
  escape character; the patterns are bound as parameters, so the server's
  `standard_conforming_strings` does not apply), wrapped in `%`.
  """

  @max_chars 256
  @max_words 32

  @doc "The caps: `%{chars: 256, words: 32}`."
  @spec caps() :: %{chars: pos_integer(), words: pos_integer()}
  def caps, do: %{chars: @max_chars, words: @max_words}

  @doc "The words of `text` (see the moduledoc); `[]` for anything but a text."
  @spec words(term()) :: [String.t()]
  def words(text) when is_binary(text) do
    text
    |> String.slice(0, @max_chars)
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.take(@max_words)
  end

  def words(_text), do: []

  @doc "The `ILIKE` patterns of `text`'s words."
  @spec patterns(term()) :: [String.t()]
  def patterns(text), do: text |> words() |> Enum.map(&pattern/1)

  defp pattern(word),
    do: "%" <> String.replace(word, ["\\", "%", "_"], &("\\" <> &1)) <> "%"
end
