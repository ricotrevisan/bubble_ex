defmodule BubbleEx.Target.Keywords do
  @moduledoc """
  The input of a keyword search (`contains keyword(s)`, IR
  `:text_contains_words`), as the generated runtime reads it
  (`<App>.Bubble.Runtime.keywords/1` and `keyword_query/1`, which must
  stay in step with this module): the first 256 characters of the text,
  split on whitespace, empty words dropped, at most the first 32 words.
  The caps bound the work a search box can ask of the database.

  Bubble matches whole words, ignoring case and punctuation, every word
  of the input in any order, a hyphen splitting words, with English
  stemming (`betas` finds "beta"); a stop word alone, or an input of
  spaces only, matches nothing (replay 2026-10-14, WTF-387). That is
  PostgreSQL's full-text search: a search tests
  `to_tsvector('english', coalesce(text, '')) @@
  plainto_tsquery('english', coalesce(query, ''))`, `query` being
  `query/1` of the input (its capped words joined by spaces), bound as a
  parameter. PostgreSQL then splits, stems and drops stop words; nothing
  is split per row in Elixir. The in-memory match of the generated
  runtime (`text_contains_words?/2`) reads both texts the same way: a
  tokenizer approximating PostgreSQL's parser and Snowball's English
  (Porter2) stemmer with PostgreSQL's English stop words.
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

  @doc """
  The text a search binds for `text`: its words (`words/1`) joined by
  single spaces, `""` when it has none (which matches nothing).
  """
  @spec query(term()) :: String.t()
  def query(text), do: text |> words() |> Enum.join(" ")
end
