defmodule BubbleEx.Target.Elixir.Formats do
  @moduledoc """
  Bubble's date and number formats (`:formatted as`, `rounded down to`,
  `extract`) as the generated runtime implements them (WTF-456), and what
  it only approximates.

  A date pattern is read as Bubble reads it (the `dateformat` masks):
  `d`/`dd`/`ddd`/`dddd` day, `DDD`/`DDDD` relative day, `m`/`mm`/`mmm`/`mmmm`
  month, `yy`/`yyyy` year, `h`/`hh`/`H`/`HH` hour, `M`/`MM` minute,
  `s`/`ss` second, `l`/`L` milliseconds/centiseconds, `t`/`tt`/`T`/`TT`
  am/pm, `Z` zone abbreviation, `o`/`p` UTC offset, `S` ordinal suffix,
  `W`/`WW` ISO week, `N` ISO weekday, text in quotes verbatim; anything
  else is shown as written. `extract date` is the day of the month and
  `extract day` the weekday, 0 = Sunday (replay 2026-10-07), both in the
  time zone used. `iso_date` is ISO 8601 in UTC, nil Bubble's default.

  Approximated (reported, never an error): `ZZ` (shown as `Z`), letters a
  pattern shows as written (usually a misspelt token or an unknown named
  format), units outside `@floor_units`/`@part_units`, and number settings
  outside the ones below. `tokens/1` and the runtime template share one
  pattern (tested).
  """

  @date_pattern ~S/ZZ|d{1,4}|D{3,4}|m{1,4}|yy(?:yy)?|([HhMsTt])\1?|W{1,2}|[LlopSZN]|"[^"]*"|'[^']*'/

  @approximated_tokens ~w(ZZ)
  @floor_units ~w(year month week day hour minute second)
  @part_units ~w(year month date day hour minute second millisecond UNIX)

  @number_types [nil, "currency", "percentage"]
  @separators [nil, "comma", "period", "space", "none"]
  @number_settings ~w(formatting_type decimal_place thousand_separator currency_symbol)

  @doc "The date pattern tokens' regular expression source (the runtime template uses it)."
  @spec date_pattern() :: String.t()
  def date_pattern, do: @date_pattern

  @doc """
  A date pattern's parts in order: `{:token, t}` for a pattern token,
  `{:quoted, s}` for quoted text (quotes removed) and `{:text, s}` for
  other text; both are shown as written.
  """
  @spec tokens(String.t()) :: [{:token | :quoted | :text, String.t()}]
  def tokens(format) when is_binary(format) do
    whole = Regex.compile!("\\A(?:" <> @date_pattern <> ")\\z")

    @date_pattern
    |> Regex.compile!()
    |> Regex.split(format, include_captures: true, trim: true)
    |> Enum.map(fn part ->
      cond do
        not Regex.match?(whole, part) -> {:text, part}
        quoted?(part) -> {:quoted, String.slice(part, 1..-2//1)}
        true -> {:token, part}
      end
    end)
  end

  defp quoted?(part), do: String.starts_with?(part, ["\"", "'"])

  @doc """
  The parts of a format the runtime only approximates, as construct names
  (no Bubble IDs): `op` is the IR op, `setting` its format, unit or number
  options.
  """
  @spec approximations(atom(), term()) :: [String.t()]
  def approximations(:format_date, nil), do: []
  def approximations(:format_date, "iso_date"), do: []

  def approximations(:format_date, format) when is_binary(format) do
    format
    |> tokens()
    |> Enum.flat_map(fn
      {:token, t} when t in @approximated_tokens ->
        ["date_format_token:" <> t]

      {:text, text} ->
        if String.match?(text, ~r/[A-Za-z]/), do: ["date_format_letters"], else: []

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  def approximations(:date_floor, unit) when unit in @floor_units, do: []
  def approximations(:date_floor, unit), do: ["date_floor_unit:#{unit}"]
  def approximations(:date_part, unit) when unit in @part_units, do: []
  def approximations(:date_part, unit), do: ["date_part_unit:#{unit}"]

  def approximations(:format_number, options) when is_map(options) do
    Enum.flat_map(options, fn
      {"formatting_type", v} when v in @number_types -> []
      {"thousand_separator", v} when v in @separators -> []
      {"decimal_place", v} when is_nil(v) or (is_integer(v) and v >= 0) -> []
      {"currency_symbol", v} when is_nil(v) or is_binary(v) -> []
      {k, _} when k in @number_settings -> ["number_format_value:#{k}"]
      {k, _} -> ["number_format_setting:#{k}"]
    end)
    |> Enum.sort()
  end

  def approximations(op, _setting), do: ["#{op}_setting"]
end
