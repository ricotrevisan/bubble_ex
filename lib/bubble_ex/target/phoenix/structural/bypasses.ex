defmodule BubbleEx.Target.Phoenix.Structural.Bypasses do
  @moduledoc """
  The privacy-bypass inventory of Elixir source (WTF-386,
  `bypass_inventory`): every place that turns authorization off, read
  from the parsed code (`Code.string_to_quoted_with_comments/2`), not by
  grepping text.

  A **site** is either

    * `:authorize_false` - a literal `authorize?: false` given to a call, a
      keyword list, a map or a module attribute (also
      `Keyword.put(opts, :authorize?, false)`), or
    * `:runtime_start` - a generated workflow body's
      `Runtime.start(input, context, "<workflow id>", false)`, the switch
      `BubbleEx.Target.Ash.Workflows` uses for a workflow that ignores
      privacy rules in Bubble.

  Each site is classified:

    * `:listed` - a `:runtime_start` of a workflow in the bypass list (the
      workflows that ignore privacy rules in Bubble)
    * `:marked` - an `:authorize_false` with a `# bubble:ignores_privacy
      <workflow id>` comment on its line or the line above, naming a listed
      workflow
    * `:scaffold` - an `:authorize_false` in a file that is bubble_ex's
      own output: generated, or owned but still as scaffolded (its SHA-256
      is the manifest's). A `:runtime_start` is never `:scaffold`: the
      generator writes one only for a listed workflow
    * `:unlisted` - anything else: a silent bypass, a structural failure

  Approximate by nature: a bypass built at runtime (`authorize?:
  some_variable`, `apply/3`) is not seen. It is an inventory, not a
  proof.
  """

  @marker ~r/#\s*bubble:ignores_privacy\s+(?:workflow:)?(\S+)/

  @type site :: %{
          path: String.t(),
          line: pos_integer() | nil,
          kind: :authorize_false | :runtime_start,
          workflow: String.t() | nil,
          class: :listed | :marked | :scaffold | :unlisted
        }

  @doc """
  The sites of every `.ex`/`.exs` file in `files` (path => content), sorted
  by path and line. Options:

    * `:allowed` - Bubble IDs of the workflows allowed to bypass
    * `:scaffold` - paths whose sites are bubble_ex's own (`:scaffold`)

  Returns the sites and the paths that do not parse (reported, never
  silently skipped).
  """
  @spec inventory(%{String.t() => binary()}, keyword()) :: %{
          sites: [site()],
          unparsable: [String.t()]
        }
  def inventory(files, opts) do
    allowed = opts |> Keyword.get(:allowed, []) |> MapSet.new()
    scaffold = opts |> Keyword.get(:scaffold, []) |> MapSet.new()

    {sites, unparsable} =
      files
      |> Enum.filter(fn {path, _} -> Path.extname(path) in [".ex", ".exs"] end)
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn {path, source}, {sites, bad} ->
        case sites(source) do
          {:ok, found} ->
            classified =
              Enum.map(found, &classify(Map.put(&1, :path, path), allowed, scaffold))

            {sites ++ classified, bad}

          :error ->
            {sites, [path | bad]}
        end
      end)

    %{sites: sites, unparsable: Enum.reverse(unparsable)}
  end

  # A workflow body is scaffolded for the workflows the lowering bypasses
  # only: another one is unlisted wherever it is.
  defp classify(%{kind: :runtime_start, workflow: w} = site, allowed, _scaffold) do
    site
    |> Map.delete(:marker)
    |> Map.put(:class, if(MapSet.member?(allowed, w), do: :listed, else: :unlisted))
  end

  defp classify(%{kind: :authorize_false} = site, allowed, scaffold) do
    cond do
      MapSet.member?(scaffold, site.path) -> Map.put(site, :class, :scaffold)
      site.marker && MapSet.member?(allowed, site.marker) -> Map.put(site, :class, :marked)
      true -> Map.put(site, :class, :unlisted)
    end
    |> Map.put(:workflow, site.marker)
    |> Map.delete(:marker)
  end

  @doc """
  The bypass sites of one source text, with the `# bubble:ignores_privacy`
  marker (a workflow's Bubble ID) on or above each `:authorize_false`
  site; `:error` when it does not parse.
  """
  @spec sites(String.t()) :: {:ok, [map()]} | :error
  def sites(source) do
    case Code.string_to_quoted_with_comments(source, emit_warnings: false) do
      {:ok, ast, comments} ->
        markers =
          for %{line: line, text: text} <- comments,
              [_, id] <- [Regex.run(@marker, text)],
              into: %{},
              do: {line, id}

        {_, found} = Macro.prewalk(ast, [], &collect/2)

        {:ok,
         found
         |> Enum.uniq()
         |> Enum.sort_by(&{&1.line || 0, &1.kind})
         |> Enum.map(&mark(&1, markers))}

      {:error, _} ->
        :error
    end
  end

  defp mark(%{kind: :authorize_false, line: line} = site, markers),
    do: Map.put(site, :marker, line && (markers[line] || markers[line - 1]))

  defp mark(site, _markers), do: Map.put(site, :marker, nil)

  # Runtime.start(input, context, "<id>", false)
  defp collect(
         {{:., _, [{:__aliases__, _, aliases}, :start]}, meta, [_, _, id, false]} = node,
         acc
       )
       when is_list(aliases) and is_binary(id) do
    if List.last(aliases) == :Runtime,
      do: {node, [%{kind: :runtime_start, line: meta[:line], workflow: id} | acc]},
      else: {node, acc}
  end

  defp collect({_callee, meta, args} = node, acc) when is_list(args) and is_list(meta) do
    if authorize_false?(args),
      do: {node, [%{kind: :authorize_false, line: meta[:line], workflow: nil} | acc]},
      else: {node, acc}
  end

  defp collect(node, acc), do: {node, acc}

  # A keyword list argument or map pair `authorize?: false`, or the
  # arguments `:authorize?, false` side by side.
  defp authorize_false?(args) do
    Enum.any?(args, fn
      {:authorize?, false} -> true
      list when is_list(list) -> Enum.any?(list, &match?({:authorize?, false}, &1))
      _ -> false
    end) or Enum.any?(Enum.chunk_every(args, 2, 1, :discard), &(&1 == [:authorize?, false]))
  end
end
