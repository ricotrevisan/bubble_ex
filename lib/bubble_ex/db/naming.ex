defmodule BubbleEx.Db.Naming do
  @moduledoc """
  Shared identifier sanitization for encoders that emit code (Elixir modules
  and atoms, TypeScript identifiers) from free-form Bubble display names.

  Bubble names can start with digits ("1st Choice"), contain only non-ASCII
  glyphs (emoji, non-Latin scripts), or collide after sanitization ("Owner!"
  vs "owner?"). Encoders that promise runnable output must guarantee that
  every emitted name is a legal identifier and that no two names in the same
  scope collide. `tokens/1`, `pascal_case/2`, and `snake_case/2` carry the
  sanitization; `claim/3` and `unique_names/4` carry the scope guarantees.
  """

  @doc """
  Splits a free-form Bubble label/id into lowercase word tokens.
  Non-alphanumeric runs are separators; camelCase boundaries start new words.
  """
  @spec tokens(term()) :: [String.t()]
  def tokens(value) do
    value
    |> to_string()
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.split(~r/[^A-Za-z0-9]+/, trim: true)
    |> Enum.map(&String.downcase/1)
  end

  @doc """
  PascalCase for module segments. Digit-leading results get an `N` prefix
  (module segments cannot start with a digit); empty results use `fallback`.
  """
  @spec pascal_case(term(), String.t()) :: String.t()
  def pascal_case(value, fallback \\ "Table") do
    value
    |> tokens()
    |> Enum.map_join("", &String.capitalize/1)
    |> guard("N", fallback)
  end

  @doc """
  snake_case for atom/field names. Digit-leading results get an `n` prefix
  (atom literals cannot start with a digit); empty results use `fallback`.
  A single leading underscore on the input is preserved (Bubble's `_id`).
  """
  @spec snake_case(term(), String.t()) :: String.t()
  def snake_case(value, fallback \\ "field") do
    string = to_string(value)
    base = string |> tokens() |> Enum.join("_") |> guard("n", fallback)

    if String.starts_with?(string, "_"), do: "_" <> base, else: base
  end

  defp guard("", _prefix, fallback), do: fallback
  defp guard(<<c, _::binary>> = name, prefix, _fallback) when c in ?0..?9, do: prefix <> name
  defp guard(name, _prefix, _fallback), do: name

  @doc """
  Claims the first free variant of `base` against `used` (a MapSet of taken
  names): `base` itself, then `suffix.(base, 2)`, `suffix.(base, 3)`, ...
  Returns `{name, used_with_name_added}`.
  """
  @spec claim(String.t(), MapSet.t(), (String.t(), pos_integer() -> String.t())) ::
          {String.t(), MapSet.t()}
  def claim(base, used, suffix \\ fn name, n -> "#{name}_#{n}" end) do
    name =
      if MapSet.member?(used, base) do
        2
        |> Stream.iterate(&(&1 + 1))
        |> Stream.map(&suffix.(base, &1))
        |> Enum.find(&(not MapSet.member?(used, &1)))
      else
        base
      end

    {name, MapSet.put(used, name)}
  end

  @doc """
  Assigns each item a unique name within one scope. Returns a map of
  `key_fun.(item)` to the assigned name. The first item to produce a name
  keeps it bare; later collisions get suffixes via `claim/3`. Names listed
  in `:reserved` count as taken from the start.

  Options:
    * `:suffix` — 2-arity fun building deduped names (default `"name_2"` style)
    * `:reserved` — names pre-marked as taken (default `[]`)
  """
  @spec unique_names([term()], (term() -> term()), (term() -> String.t()), keyword()) ::
          %{term() => String.t()}
  def unique_names(items, key_fun, name_fun, opts \\ []) do
    suffix = Keyword.get(opts, :suffix, fn name, n -> "#{name}_#{n}" end)
    reserved = opts |> Keyword.get(:reserved, []) |> MapSet.new()

    {map, _used} =
      Enum.reduce(items, {%{}, reserved}, fn item, {map, used} ->
        {name, used} = claim(name_fun.(item), used, suffix)
        {Map.put(map, key_fun.(item), name), used}
      end)

    map
  end
end
