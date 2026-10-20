defmodule BubbleEx.Target.Phoenix.Structural.HiddenClasses do
  @moduledoc """
  The `hidden_overridable` structural check: an element's visibility on
  page load is only ever its `hidden` attribute, which its visibility
  conditionals (`data-bubble-visible`, `hidden={...}`) and the page hook's
  workflow steps change. A static `hidden` or `invisible` class on such an
  element is never removed, so it would stay hidden whatever they do (at
  a361e4e, a private app's slice had 1,228 of them: 14 of 29 pages lost
  their content).

  An element a breakpoint shows keeps its class without the attribute (the
  media rule overrides it), so it is not reported.
  """

  @doc """
  The diff entries (`op: "hidden_class"`) for the templates among `files`
  (a path to content map: `.heex` and `.ex` files under `lib/`).
  """
  @spec diff(%{String.t() => String.t()}) :: [map()]
  def diff(files) do
    for {path, content} <- Enum.sort(files),
        template?(path),
        tag <- opening_tags(content),
        id = stuck(tag),
        id != nil do
      %{
        op: "hidden_class",
        path: path,
        element: id,
        detail:
          "a static hidden or invisible class on an element whose hidden attribute its " <>
            "conditionals or steps change: it never shows"
      }
    end
  end

  @doc "The template files under `root/lib`, read, as `diff/1` takes them."
  @spec read(Path.t()) :: %{String.t() => String.t()}
  def read(root) do
    root
    |> Path.join("lib/**/*.{heex,ex}")
    |> Path.wildcard()
    |> Map.new(&{Path.relative_to(&1, root), File.read!(&1)})
  end

  defp template?(path),
    do: String.starts_with?(path, "lib/") and Path.extname(path) in [".heex", ".ex"]

  # The Bubble ID of an opening tag with the attribute (or a conditional's
  # `data-bubble-visible`) and a static `hidden` or `invisible` class.
  defp stuck(tag) do
    with [_, id] <- Regex.run(~r/\sdata-bubble-id="([^"]*)"/, tag),
         [_, class] <- Regex.run(~r/\sclass="([^"]*)"/, tag),
         true <- Enum.any?(String.split(class), &(&1 in ["hidden", "invisible"])),
         true <- tag =~ ~r/\shidden(?=[\s>=\/])/ or tag =~ ~r/\sdata-bubble-visible=/ do
      id
    else
      _ -> nil
    end
  end

  # Every opening tag with a `data-bubble-id`, read past HEEx `{...}`
  # attributes and quoted values (they may hold `>`).
  defp opening_tags(content) do
    ~r/<[.A-Za-z][\w.:-]*\s/
    |> Regex.scan(content, return: :index)
    |> Enum.flat_map(fn [{start, _}] ->
      rest = binary_part(content, start, byte_size(content) - start)
      tag = take_tag(rest, 0, 0, nil)
      if String.contains?(tag, "data-bubble-id="), do: [tag], else: []
    end)
  end

  # Up to the `>` that closes the tag: `depth` counts braces, `quote` is the
  # open quote outside braces.
  defp take_tag(rest, at, _depth, _quote) when at >= byte_size(rest), do: rest

  defp take_tag(rest, at, depth, quote) do
    case {:binary.at(rest, at), depth, quote} do
      {?>, 0, nil} -> binary_part(rest, 0, at + 1)
      {?{, d, nil} -> take_tag(rest, at + 1, d + 1, nil)
      {?}, d, nil} when d > 0 -> take_tag(rest, at + 1, d - 1, nil)
      {?", 0, nil} -> take_tag(rest, at + 1, 0, ?")
      {?", 0, ?"} -> take_tag(rest, at + 1, 0, nil)
      {_, d, q} -> take_tag(rest, at + 1, d, q)
    end
  end
end
