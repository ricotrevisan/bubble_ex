defmodule BubbleEx.Frontend.Export.SourceStyles do
  @moduledoc false

  alias BubbleEx.Frontend.Export.Safety

  @max_blocks 32
  @max_block_bytes 262_144
  @properties ~w(
    overflow overflow-x overflow-y overflow-wrap box-sizing display position
    inset top right bottom left width min-width max-width height min-height max-height
    margin margin-top margin-right margin-bottom margin-left
    padding padding-top padding-right padding-bottom padding-left
    gap row-gap column-gap flex flex-direction flex-wrap flex-grow flex-shrink flex-basis
    align-items align-self align-content justify-content justify-items justify-self
    grid-template-columns grid-template-rows grid-auto-flow grid-auto-columns grid-auto-rows
    order z-index opacity visibility transform transform-origin filter
    color background-color border border-width border-color border-style border-radius
    border-top border-right border-bottom border-left box-shadow
    font-family font-size font-weight font-style line-height letter-spacing
    text-align text-transform text-decoration text-indent white-space word-break
    object-fit object-position aspect-ratio
  )
  @tokens ~r</\*[\s\S]*?(?:\*/|\z)|"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|[{};]|[^{};"'/\\]+|[\s\S]>u

  @spec discover(String.t()) :: map()
  def discover(html) do
    case Floki.parse_document(html) do
      {:ok, tree} ->
        elements = Floki.find(tree, "head style")

        retained =
          elements
          |> Enum.take(@max_blocks)
          |> Enum.filter(&unconditional_style?/1)
          |> Enum.map(&Floki.text(&1, style: true))
          |> Enum.filter(&(byte_size(&1) <= @max_block_bytes))

        %{blocks: retained, omitted: length(elements) - length(retained)}

      _ ->
        %{blocks: [], omitted: 0}
    end
  end

  defp unconditional_style?({"style", attributes, _children}) do
    attributes = Map.new(attributes)
    media = attributes |> Map.get("media", "") |> String.trim() |> String.downcase()
    type = attributes |> Map.get("type", "") |> String.trim() |> String.downcase()
    media in ["", "all", "screen"] and type in ["", "text/css"]
  end

  @spec page_name(String.t()) :: String.t()
  def page_name(url) do
    path = URI.parse(url).path || "/"

    path
    |> String.split("/", trim: true)
    |> drop_version_prefix()
    |> List.last()
    |> then(&(&1 || "index"))
    |> URI.decode()
  end

  defp drop_version_prefix(["version-" <> _ | rest]), do: rest
  defp drop_version_prefix(parts), do: parts

  @spec compile(map()) :: {String.t(), non_neg_integer()}
  def compile(%{blocks: blocks, omitted: omitted}) do
    Enum.reduce(blocks, {[], omitted}, fn block, {css, rejected} ->
      {rules, dropped} = compile_block(block)
      {[rules | css], rejected + dropped}
    end)
    |> then(fn {css, rejected} -> {css |> Enum.reverse() |> IO.iodata_to_binary(), rejected} end)
  end

  def compile(_), do: {"", 0}

  defp compile_block(block) do
    all_tokens =
      @tokens
      |> Regex.scan(block, capture: :first)
      |> List.flatten()

    omitted =
      Enum.count(all_tokens, &(String.starts_with?(&1, "/*") and not String.ends_with?(&1, "*/")))

    tokens = Enum.reject(all_tokens, &String.starts_with?(&1, "/*"))

    if Enum.any?(tokens, &(&1 in ["\"", "'", "\\"])) do
      {[], 1}
    else
      state =
        Enum.reduce(
          tokens,
          %{depth: 0, prelude: [], body: [], rules: [], omitted: omitted},
          &token/2
        )

      incomplete =
        if state.depth != 0 or String.trim(Enum.join(state.prelude)) != "", do: 1, else: 0

      state.rules
      |> Enum.reverse()
      |> Enum.reduce({[], state.omitted + incomplete}, &compile_rule/2)
      |> then(fn {css, rejected} -> {Enum.reverse(css), rejected} end)
    end
  end

  defp token("{", %{depth: 0} = state), do: %{state | depth: 1, body: []}

  defp token("}", %{depth: 1} = state) do
    rule =
      {state.prelude |> Enum.reverse() |> Enum.join() |> String.trim(), Enum.reverse(state.body)}

    %{state | depth: 0, prelude: [], body: [], rules: [rule | state.rules]}
  end

  defp token("{", state), do: %{state | depth: state.depth + 1, body: ["{" | state.body]}

  defp token("}", %{depth: depth} = state) when depth > 1,
    do: %{state | depth: depth - 1, body: ["}" | state.body]}

  defp token("}", state), do: %{state | prelude: []}

  defp token(";", %{depth: 0} = state) do
    omitted = if String.trim(Enum.join(state.prelude)) == "", do: 0, else: 1
    %{state | prelude: [], omitted: state.omitted + omitted}
  end

  defp token(value, %{depth: 0} = state), do: %{state | prelude: [value | state.prelude]}
  defp token(value, state), do: %{state | body: [value | state.body]}

  defp compile_rule({selector, body}, {css, rejected}) do
    if valid_selector?(selector) and not Enum.any?(body, &(&1 in ["{", "}"])) do
      {declarations, dropped} = declarations(body)
      rule = if declarations == [], do: [], else: [selector, " {\n", declarations, "}\n"]
      {[rule | css], rejected + dropped}
    else
      {css, rejected + 1}
    end
  end

  defp valid_selector?(""), do: false

  defp valid_selector?(selector) do
    selector
    |> String.split(",")
    |> Enum.all?(fn part ->
      part = String.trim(part)
      part in ["html", "body"] or Regex.match?(~r/^#[A-Za-z_-][A-Za-z0-9_-]*$/, part)
    end)
  end

  defp declarations(tokens) do
    tokens
    |> Enum.chunk_by(&(&1 == ";"))
    |> Enum.reject(&Enum.all?(&1, fn token -> token == ";" end))
    |> Enum.map(&(Enum.join(&1) |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce({[], 0}, fn declaration, {css, rejected} ->
      case compile_declaration(declaration) do
        {:ok, line} -> {[line | css], rejected}
        :error -> {css, rejected + 1}
      end
    end)
    |> then(fn {css, rejected} -> {Enum.reverse(css), rejected} end)
  end

  defp compile_declaration(declaration) do
    case String.split(declaration, ":", parts: 2) do
      [property, value] ->
        property = property |> String.trim() |> String.downcase()
        value = String.trim(value)

        if property in @properties and Safety.safe_css_value?(value),
          do: {:ok, ["  ", property, ": ", value, ";\n"]},
          else: :error

      _ ->
        :error
    end
  end
end
