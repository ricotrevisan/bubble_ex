defmodule BubbleEx.Target.Phoenix.Tailwind do
  @moduledoc """
  CSS declarations as Tailwind v4 utilities (WTF-359 Q4, WTF-370).

  `utilities/1` takes one element's declarations (`{property, value}`, as
  `BubbleEx.Frontend.Export.Css` lowers them for the HTML exporter) and
  returns the classes that set exactly those values, plus the declarations
  it leaves to the residue stylesheet:

    * a standard utility where it sets exactly the declaration
      (`display: flex` → `flex`, `position: absolute` → `absolute`,
      `overflow: hidden` → `overflow-hidden`, a theme color → `text-bubble-primary`)
    * an arbitrary value where Tailwind has a utility for the property
      (`width: 240px` → `w-[240px]`, `padding: 10px 20px` → `p-[10px_20px]`)
    * otherwise an arbitrary property (`[box-shadow:0_2px_4px_#0003]`)

  A declaration stays in the residue when a class cannot carry its value
  (quotes, brackets, backslashes or underscores Tailwind would read as
  spaces), and so does a shorthand with its longhands on one element
  (`border` with `border-color`): Tailwind orders those by property, not
  as the source does. Margin and padding are the exception (their order is
  Tailwind's).

  Residue rules are unlayered CSS, so they win over utilities (layered),
  as the exporter's later rules win over its earlier ones.
  """

  # Standard utilities that set exactly one declaration.
  @exact %{
    {"display", "block"} => "block",
    {"display", "flex"} => "flex",
    {"display", "grid"} => "grid",
    {"display", "inline-flex"} => "inline-flex",
    {"display", "inline-block"} => "inline-block",
    {"display", "contents"} => "contents",
    {"display", "none"} => "hidden",
    {"position", "relative"} => "relative",
    {"position", "absolute"} => "absolute",
    {"position", "fixed"} => "fixed",
    {"position", "static"} => "static",
    {"position", "sticky"} => "sticky",
    {"flex-direction", "row"} => "flex-row",
    {"flex-direction", "column"} => "flex-col",
    {"flex-wrap", "wrap"} => "flex-wrap",
    {"flex-wrap", "nowrap"} => "flex-nowrap",
    {"justify-content", "flex-start"} => "justify-start",
    {"justify-content", "flex-end"} => "justify-end",
    {"justify-content", "center"} => "justify-center",
    {"justify-content", "space-between"} => "justify-between",
    {"justify-content", "space-around"} => "justify-around",
    {"justify-content", "space-evenly"} => "justify-evenly",
    {"align-items", "flex-start"} => "items-start",
    {"align-items", "flex-end"} => "items-end",
    {"align-items", "center"} => "items-center",
    {"align-items", "stretch"} => "items-stretch",
    {"align-items", "baseline"} => "items-baseline",
    {"align-self", "flex-start"} => "self-start",
    {"align-self", "flex-end"} => "self-end",
    {"align-self", "center"} => "self-center",
    {"align-self", "stretch"} => "self-stretch",
    {"align-self", "auto"} => "self-auto",
    {"justify-self", "start"} => "justify-self-start",
    {"justify-self", "end"} => "justify-self-end",
    {"justify-self", "center"} => "justify-self-center",
    {"justify-self", "stretch"} => "justify-self-stretch",
    {"overflow", "hidden"} => "overflow-hidden",
    {"overflow", "auto"} => "overflow-auto",
    {"overflow", "visible"} => "overflow-visible",
    {"overflow", "scroll"} => "overflow-scroll",
    {"white-space", "pre-wrap"} => "whitespace-pre-wrap",
    {"white-space", "normal"} => "whitespace-normal",
    {"white-space", "nowrap"} => "whitespace-nowrap",
    {"object-fit", "fill"} => "object-fill",
    {"object-fit", "contain"} => "object-contain",
    {"object-fit", "cover"} => "object-cover",
    {"appearance", "none"} => "appearance-none",
    {"box-sizing", "content-box"} => "box-content",
    {"box-sizing", "border-box"} => "box-border",
    {"text-align", "left"} => "text-left",
    {"text-align", "center"} => "text-center",
    {"text-align", "right"} => "text-right",
    {"text-align", "justify"} => "text-justify",
    {"visibility", "hidden"} => "invisible",
    {"visibility", "visible"} => "visible",
    {"cursor", "pointer"} => "cursor-pointer"
  }

  # Utilities that take an arbitrary value for exactly one property.
  @arbitrary %{
    "width" => "w",
    "height" => "h",
    "min-width" => "min-w",
    "max-width" => "max-w",
    "min-height" => "min-h",
    "max-height" => "max-h",
    "top" => "top",
    "right" => "right",
    "bottom" => "bottom",
    "left" => "left",
    "padding" => "p",
    "padding-top" => "pt",
    "padding-right" => "pr",
    "padding-bottom" => "pb",
    "padding-left" => "pl",
    "margin" => "m",
    "margin-top" => "mt",
    "margin-right" => "mr",
    "margin-bottom" => "mb",
    "margin-left" => "ml",
    "row-gap" => "gap-y",
    "column-gap" => "gap-x",
    "z-index" => "z",
    "flex-grow" => "grow",
    "flex-shrink" => "shrink",
    "flex-basis" => "basis",
    "opacity" => "opacity"
  }

  # Shorthands Tailwind does not order before their longhands.
  @shorthands ~w(background border border-top border-right border-bottom border-left
                 border-radius border-width border-style border-color font flex grid
                 grid-template grid-area overflow gap text-decoration outline list-style
                 transition animation inset place-items place-content place-self columns
                 transform)

  @typedoc "A declaration: `{property, value}`."
  @type declaration :: {String.t(), term()}

  @doc """
  `{classes, residue}` for one element's declarations. `tokens` maps a
  color custom property (`--color_primary_default`) to its theme utility
  suffix (`bubble-primary`): a `color` of exactly that variable becomes
  `text-bubble-primary`.
  """
  @spec utilities([declaration()], %{String.t() => String.t()}) ::
          {[String.t()], [declaration()]}
  def utilities(declarations, tokens \\ %{}) do
    declarations = Enum.map(declarations, fn {k, v} -> {k, to_string(v)} end)
    families = conflicting(declarations)

    {classes, residue} =
      Enum.reduce(declarations, {[], []}, fn {property, value} = decl, {classes, residue} ->
        cond do
          in_family?(property, families) -> {classes, [decl | residue]}
          class = utility(property, value, tokens) -> {[class | classes], residue}
          true -> {classes, [decl | residue]}
        end
      end)

    {Enum.reverse(classes), Enum.reverse(residue)}
  end

  @doc """
  The utility for one declaration, or nil when it belongs in the residue.
  """
  @spec utility(String.t(), String.t(), map()) :: String.t() | nil
  def utility(property, value, tokens \\ %{}) do
    cond do
      class = @exact[{property, value}] -> class
      class = token_utility(property, value, tokens) -> class
      not carries?(value) -> nil
      prefix = @arbitrary[property] -> "#{prefix}-[#{encode(value)}]"
      custom_or_known?(property) -> "[#{property}:#{encode(value)}]"
      true -> nil
    end
  end

  defp token_utility("color", "var(" <> rest, tokens) do
    case Map.fetch(tokens, String.trim_trailing(rest, ")")) do
      {:ok, suffix} -> "text-" <> suffix
      :error -> nil
    end
  end

  defp token_utility(_property, _value, _tokens), do: nil

  # A property name Tailwind can take in an arbitrary property.
  defp custom_or_known?(property), do: Regex.match?(~r/\A-{0,2}[a-z][a-z0-9-]*\z/, property)

  # Whether a class can carry the value: Tailwind reads `_` as a space
  # (except in custom property names inside `var()`), and quotes,
  # brackets and backslashes cannot appear in a class literal.
  defp carries?(value) do
    without_vars = Regex.replace(~r/var\(--[A-Za-z0-9_-]+/, value, "var(")

    value != "" and not String.contains?(without_vars, "_") and
      Regex.match?(~r/\A[A-Za-z0-9#%.,()+\-*\/ _]+\z/, value)
  end

  defp encode(value), do: value |> String.trim() |> String.replace(~r/\s+/, "_")

  # Shorthand families whose shorthand and longhands both appear.
  defp conflicting(declarations) do
    properties = Enum.map(declarations, &elem(&1, 0))

    for shorthand <- @shorthands,
        shorthand in properties,
        Enum.any?(properties, &String.starts_with?(&1, shorthand <> "-")),
        into: MapSet.new(),
        do: shorthand
  end

  defp in_family?(property, families),
    do: Enum.any?(families, &(property == &1 or String.starts_with?(property, &1 <> "-")))
end
