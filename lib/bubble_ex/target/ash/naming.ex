defmodule BubbleEx.Target.Ash.Naming do
  @moduledoc """
  Ash names derived from Bubble display names (WTF-339).

  Names are target-specific, so they live here and never in
  `BubbleEx.Model`. The rules:

    * **Cleanup.** A leading ordinal prefix (`00.`, `40.`, `1.2)`) and emoji
      are stripped; accents are folded (`Café` → `cafe`); every other run of
      non-alphanumerics separates words, and camel case splits
      (`firstName` → `first`, `name`). `00. Thing - Join` becomes
      `ThingJoin` / `thing_join`, `11. Done` becomes `done`, and
      `40. Sort: Thing Title` becomes `sort_thing_title`.
    * **Fallback.** When cleanup leaves nothing (e.g. `🔥`), the name is
      derived the same way from the Bubble ID, and failing that from a kind
      word (`field`, `Resource`, …).
    * **Leading digits.** A name that would start with a digit gets an `n`
      (`N` for modules) prefix, since Elixir identifiers cannot.
    * **Length.** A name keeps whole words up to 50 characters, so a
      suffixed name stays within PostgreSQL's 63-byte identifier limit.
    * **Reserved words** get a suffix (`_field` for attributes and fields,
      `_table` for tables, `Resource` for modules): see `reserved/1`.
    * **Collisions** in one scope get a numeric suffix (`title_2`,
      `Thing2`) assigned in claim order, which callers make Bubble ID order.

  Names are ASCII identifiers: `^[a-z][a-z0-9_]*$` for snake case and
  `^[A-Z][A-Za-z0-9]*$` for module segments.
  """

  @max 50

  @reserved %{
    attribute:
      ~w(id type inserted_at updated_at nil true false aggregates calculations __meta__ __metadata__ __struct__ __order__ __lateral_join_source__),
    field: ~w(nil true false __struct__),
    table: ~w(schema_migrations),
    module: ~w(Repo Domain Enums Types External Application)
  }

  # Letters NFD does not decompose into a base letter plus marks.
  @fold %{
    "ß" => "ss",
    "ẞ" => "SS",
    "æ" => "ae",
    "Æ" => "AE",
    "œ" => "oe",
    "Œ" => "OE",
    "ø" => "o",
    "Ø" => "O",
    "ł" => "l",
    "Ł" => "L",
    "đ" => "d",
    "Đ" => "D",
    "ð" => "d",
    "Ð" => "D",
    "þ" => "th",
    "Þ" => "TH",
    "ı" => "i"
  }

  @ordinal ~r/^(?>\d+(?:\.\d+)*)\s*[.):\-–—]\s*/u
  @snake ~r/^[a-z][a-z0-9_]*$/
  @pascal ~r/^[A-Z][A-Za-z0-9]*$/

  @type style :: :snake | :pascal
  @type scope :: :attribute | :field | :table | :module | :none

  @doc """
  The words of a display name after cleanup, lowercase ASCII. Empty when
  nothing meaningful is left.

      iex> BubbleEx.Target.Ash.Naming.words("00. Thing - Join")
      ["thing", "join"]
      iex> BubbleEx.Target.Ash.Naming.words("🚀 Launch ✨")
      ["launch"]
  """
  @spec words(term()) :: [String.t()]
  def words(text) when is_binary(text) do
    text
    |> String.replace(~r/^[^\p{L}\p{N}]+/u, "")
    |> String.replace(@ordinal, "")
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(Map.keys(@fold), &Map.fetch!(@fold, &1))
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1 \\2")
    |> String.split(~r/[^A-Za-z0-9]+/, trim: true)
    |> Enum.map(&String.downcase/1)
  end

  def words(_), do: []

  @doc """
  The base name for a definition: from its display name, else its Bubble
  ID, else `fallback`. Not yet checked against reserved words or other
  names (see `claim/4`).

      iex> BubbleEx.Target.Ash.Naming.base(:snake, "40. Sort: Thing Title", "x_text", "field")
      "sort_thing_title"
      iex> BubbleEx.Target.Ash.Naming.base(:pascal, "00. Thing - Join", "t", "Resource")
      "ThingJoin"
      iex> BubbleEx.Target.Ash.Naming.base(:snake, "🔥", "_text", "field")
      "text"
  """
  @spec base(style(), term(), term(), String.t()) :: String.t()
  def base(style, name, id, fallback) do
    case {words(name), words(id)} do
      {[_ | _] = words, _} -> format(style, words)
      {[], [_ | _] = words} -> format(style, words)
      {[], []} -> fallback
    end
  end

  defp format(:snake, words), do: words |> limit() |> Enum.join("_") |> lead("n")

  defp format(:pascal, words),
    do: words |> limit() |> Enum.map_join(&String.capitalize/1) |> lead("N")

  # Whole words up to @max characters; a single overlong word is cut.
  defp limit([first | _] = words) do
    kept =
      words
      |> Enum.scan(&(&2 <> "_" <> &1))
      |> Enum.zip(words)
      |> Enum.take_while(fn {joined, _} -> String.length(joined) <= @max end)
      |> Enum.map(&elem(&1, 1))

    if kept == [], do: [String.slice(first, 0, @max)], else: kept
  end

  defp lead(<<d, _::binary>> = name, prefix) when d in ?0..?9, do: prefix <> name
  defp lead(name, _prefix), do: name

  @doc """
  The snake-case form of a module segment (`ThingJoin` → `thing_join`),
  used for table names.
  """
  @spec underscore(String.t()) :: String.t()
  def underscore(pascal) do
    # A generated segment capitalizes each word, so a capital after a digit
    # starts a word (`V2Api`).
    pascal
    |> String.replace(~r/([0-9])([A-Z])/, "\\1 \\2")
    |> words()
    |> Enum.join("_")
    |> lead("n")
  end

  @doc "The reserved names of a scope."
  @spec reserved(scope()) :: [String.t()]
  def reserved(scope), do: Map.get(@reserved, scope, [])

  @doc "Whether `name` is a valid name of the given style."
  @spec valid?(style(), term()) :: boolean()
  def valid?(:snake, name) when is_binary(name),
    do: Regex.match?(@snake, name) and byte_size(name) <= 63

  def valid?(:pascal, name) when is_binary(name),
    do: Regex.match?(@pascal, name) and byte_size(name) <= 63

  def valid?(_style, _name), do: false

  @doc """
  Claims a name for `base` in a scope whose taken names are `used`: a
  reserved word gets the scope's suffix, then a taken name gets the lowest
  free numeric suffix from 2. Returns the name and the updated set.
  """
  @spec claim(String.t(), MapSet.t(), style(), scope()) :: {String.t(), MapSet.t()}
  def claim(base, used, style, scope) do
    name = if base in reserved(scope), do: base <> reserved_suffix(scope), else: base

    name =
      if MapSet.member?(used, name),
        do: Enum.find_value(2..(MapSet.size(used) + 2), &free(name, &1, used, style)),
        else: name

    {name, MapSet.put(used, name)}
  end

  defp free(name, n, used, style) do
    candidate = suffixed(name, n, style)
    if MapSet.member?(used, candidate), do: nil, else: candidate
  end

  defp suffixed(name, n, :snake), do: "#{name}_#{n}"
  defp suffixed(name, n, :pascal), do: "#{name}#{n}"

  defp reserved_suffix(:table), do: "_table"
  defp reserved_suffix(:module), do: "Resource"
  defp reserved_suffix(_scope), do: "_field"
end
