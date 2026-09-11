defmodule BubbleEx.Frontend.GeometryStyles do
  @moduledoc false

  alias BubbleEx.Frontend.{Payload, StaticExpression}
  alias BubbleEx.Frontend.Export.SourceStyles

  @external_resource Path.join(__DIR__, "geometry_styles.js")
  @runtime File.read!(@external_resource)
  @runtime_path "assets/" <> Base.encode16(:crypto.hash(:sha256, @runtime), case: :lower) <> ".js"

  @spec expression(map()) :: term()
  def expression(raw), do: Payload.prop(raw, "html") || Payload.properties(raw)["%ht"]

  @spec candidate?(map()) :: boolean()
  def candidate?(raw), do: match?({:ok, _}, compile(expression(raw), :probe))

  @spec resolve(term(), map()) :: {:ok, term()} | :unknown
  def resolve(expression, scope \\ %{}) do
    case StaticExpression.resolve(expression, :unknown, scope) do
      {:ok, value} when is_number(value) -> {:ok, value}
      _ -> geometry(expression, scope)
    end
  end

  defp geometry(
         %{
           "%x" => "GetElement",
           "%p" => %{"%ei" => ref} = props,
           "%n" => %{"%nm" => message} = next
         } = expression,
         scope
       )
       when is_binary(ref) and byte_size(ref) in 1..256 and map_size(props) == 1 do
    if inert?(expression, ~w(%x %p %n)) and inert?(next, ~w(%x %nm)) and
         next["%x"] in [nil, "Message"] do
      geometry_message(ref, message, scope)
    else
      :unknown
    end
  end

  defp geometry(_expression, _scope), do: :unknown

  defp geometry_message(ref, "get_height", _scope), do: {:ok, %{element: ref, axis: "height"}}
  defp geometry_message(ref, "get_width", _scope), do: {:ok, %{element: ref, axis: "width"}}

  defp geometry_message(_ref, "param_" <> _, :probe),
    do: {:ok, %{element: "probe", axis: "height"}}

  defp geometry_message(ref, "param_" <> _ = key, scope) when is_map(scope) do
    case get_in(scope, [ref, key]) do
      %{element: element, axis: axis} = value
      when is_binary(element) and axis in ~w(width height) ->
        {:ok, value}

      value when is_number(value) ->
        {:ok, value}

      _ ->
        :unknown
    end
  end

  defp geometry_message(_ref, _message, _scope), do: :unknown

  defp inert?(map, keys),
    do:
      Map.drop(map, keys ++ ["is_slidable", "said"]) == %{} and
        map["is_slidable"] in [nil, true, false]

  @spec project(map(), map(), map()) :: map()
  def project(content, %{slot: "html_style", payload: expression}, scope) do
    case compile(expression, scope) do
      {:ok, style} -> Map.put(content, :inline_style, style)
      _ -> content
    end
  end

  def project(content, %{payload: expression}, scope) do
    case resolve(expression, scope) do
      {:ok, %{element: _, axis: _} = ref} -> Map.put(content, :geometry, ref)
      _ -> content
    end
  end

  @spec compile(term(), map() | :probe) :: {:ok, map()} | :unknown
  def compile(expression, scope) do
    with {:ok, parts} <- parts(expression),
         false <-
           Enum.any?(parts, &(is_binary(&1) and String.contains?(&1, "BUBBLEEXDIMENSION"))),
         {:ok, html, refs} <- interpolate(parts, scope),
         true <- byte_size(html) <= 100_000,
         {:ok, tree} <- Floki.parse_fragment(html),
         [{"style", [], children}] <- nonblank(tree),
         css <- Floki.text(children, style: true),
         {css, 0} when css != "" <- SourceStyles.compile(%{blocks: [css], omitted: 0}),
         true <- direct_dimensions?(css, refs) do
      refs = Enum.filter(refs, &String.contains?(css, "var(#{&1.variable})")) |> Enum.uniq()
      {:ok, %{css: css, refs: refs}}
    else
      _ -> :unknown
    end
  end

  defp direct_dimensions?(css, refs) do
    Enum.all?(refs, fn ref ->
      token = "var(#{ref.variable})"
      rule = Regex.compile!("^\\s+[a-z-]+:\\s+" <> Regex.escape(token) <> "(?:\\s+!important)?;$")

      css
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, token))
      |> Enum.all?(&Regex.match?(rule, &1))
    end)
  end

  defp parts(value) when is_binary(value) and byte_size(value) <= 100_000, do: {:ok, [value]}

  defp parts(%{"%x" => "TextExpression", "%e" => entries} = expression)
       when is_map(entries) and map_size(entries) <= 100 do
    if inert?(expression, ~w(%x %e)) and Enum.all?(Map.keys(entries), &numeric_key?/1) do
      {:ok,
       entries
       |> Enum.sort_by(fn {key, _} -> String.to_integer(key) end)
       |> Enum.map(&elem(&1, 1))}
    else
      :unknown
    end
  end

  defp parts(_expression), do: :unknown

  defp numeric_key?(key) when is_binary(key) and byte_size(key) <= 12,
    do: Regex.match?(~r/^\d+$/, key)

  defp numeric_key?(_key), do: false

  defp interpolate(parts, scope) do
    parts
    |> Enum.reduce_while({:ok, "", []}, fn
      part, {:ok, html, refs}
      when is_binary(part) and byte_size(part) + byte_size(html) <= 100_000 ->
        {:cont, {:ok, html <> part, refs}}

      expression, {:ok, html, refs} ->
        case resolve_part(expression, scope) do
          {:ok, number} when is_number(number) ->
            {:cont, {:ok, html <> to_string(number), refs}}

          {:ok, %{element: _, axis: _} = ref} ->
            variable = variable(ref)

            {:cont,
             {:ok, html <> "BUBBLEEXDIMENSION#{length(refs)}",
              refs ++ [Map.put(ref, :variable, variable)]}}

          _ ->
            {:halt, :unknown}
        end
    end)
    |> substitute()
  end

  defp resolve_part(expression, :probe) do
    case geometry(expression, :probe) do
      {:ok, value} -> {:ok, value}
      _ -> resolve(expression)
    end
  end

  defp resolve_part(expression, scope), do: resolve(expression, scope)

  defp substitute({:ok, html, refs}) do
    refs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, html, refs}, fn {ref, index}, {:ok, html, refs} ->
      marker = "BUBBLEEXDIMENSION#{index}"

      if String.contains?(html, marker <> "px") do
        {:cont, {:ok, String.replace(html, marker <> "px", "var(#{ref.variable})"), refs}}
      else
        {:halt, :unknown}
      end
    end)
  end

  defp substitute(:unknown), do: :unknown

  defp variable(ref),
    do:
      "--bubbleex-geometry-" <>
        Base.encode16(:crypto.hash(:sha256, ref.element <> "/" <> ref.axis), case: :lower)

  defp nonblank(nodes), do: Enum.reject(nodes, &(is_binary(&1) and String.trim(&1) == ""))

  @spec runtime_needed?(iodata()) :: boolean()
  def runtime_needed?(html),
    do: html |> IO.iodata_to_binary() |> String.contains?("<style data-bubbleex-geometry=")

  @spec runtime_tag(iodata()) :: String.t()
  def runtime_tag(html) do
    if runtime_needed?(html),
      do: ~s(<script defer src="../../#{@runtime_path}"></script>\n),
      else: ""
  end

  @spec runtime_entries([{String.t(), binary()}]) :: [{String.t(), binary()}]
  def runtime_entries(entries) do
    if Enum.any?(entries, fn {path, body} ->
         String.ends_with?(path, ".html") and runtime_needed?(body)
       end),
       do: [{@runtime_path, @runtime}],
       else: []
  end
end
