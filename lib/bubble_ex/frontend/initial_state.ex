defmodule BubbleEx.Frontend.InitialState do
  @moduledoc false

  alias BubbleEx.Frontend.{Auth, Fetch, Normalized, Payload}

  @spec anonymous?(Fetch.Context.t()) :: boolean()
  def anonymous?(%Fetch.Context{auth: %Auth{session_cookie: nil}}), do: true
  def anonymous?(_context), do: false

  @spec project(Normalized.t(), Fetch.Context.t()) :: Normalized.t()
  def project(model, context) do
    payload = model.source.payload

    %{
      model
      | pages: project_nodes(model.pages, Payload.pages(payload), context),
        reusables: project_nodes(model.reusables, Payload.reusables(payload), context)
    }
  end

  defp project_nodes(nodes, raw_nodes, context) do
    Enum.map(nodes, fn node ->
      raw = raw_nodes[node.map_key] || %{}
      box = if anonymous?(context), do: apply_visibility(node.box, raw["%s"]), else: node.box

      %{
        node
        | box: box,
          content: snapshot_content(node, context.snapshot_at),
          children: project_nodes(node.children, Payload.elements(raw), context)
      }
    end)
  end

  defp snapshot_content(node, %DateTime{} = at) do
    Map.new(node.content || %{}, fn {slot, content} ->
      case snapshot_text(get_in(node.bindings, [slot, :payload]), at) do
        {:ok, text} when slot in ["text", "label"] ->
          {slot, Map.merge(content, %{resolved: text, snapshot_at: DateTime.to_iso8601(at)})}

        _ ->
          {slot, content}
      end
    end)
  end

  defp snapshot_content(node, _at), do: node.content

  defp snapshot_text(%{"%x" => "TextExpression", "%e" => parts} = expression, at)
       when is_map(parts) and not is_map_key(expression, "%n") do
    parts
    |> Enum.sort_by(fn {key, _} -> Integer.parse(key) end)
    |> Enum.reduce_while({:ok, ""}, fn {_key, part}, {:ok, text} ->
      case snapshot_part(part, at) do
        {:ok, value} -> {:cont, {:ok, text <> value}}
        _ -> {:halt, :unknown}
      end
    end)
  end

  defp snapshot_text(_expression, _at), do: :unknown
  defp snapshot_part(part, _at) when is_binary(part), do: {:ok, part}
  defp snapshot_part(part, _at) when is_number(part), do: {:ok, to_string(part)}

  defp snapshot_part(
         %{
           "%x" => "PageData",
           "%p" => %{"%nm" => "Current Date/Time"},
           "%n" =>
             %{
               "%nm" => "format_date",
               "%p" => %{"%ft" => "custom", "custom_format" => "yyyy"} = format
             } =
               message
         },
         at
       )
       when not is_map_key(message, "%n") and map_size(format) == 2,
       do: {:ok, Integer.to_string(at.year)}

  defp snapshot_part(_part, _at), do: :unknown

  defp apply_visibility(box, states) when is_map(states) do
    states
    |> Enum.sort_by(fn {key, _} ->
      case Integer.parse(key) do
        {index, ""} -> {0, index}
        _ -> {1, key}
      end
    end)
    |> Enum.reduce(box, fn {_key, state}, current -> apply_state(current, state) end)
  end

  defp apply_visibility(box, _states), do: box

  defp apply_state(box, %{
         "%c" => %{"%x" => "CurrentUser", "%n" => message},
         "%p" => overrides
       })
       when is_map(message) and is_map(overrides) do
    if message["%nm"] == "not_logged_in" and not Map.has_key?(message, "%n") do
      case Payload.prop(%{"properties" => overrides}, "is_visible") do
        true -> Map.delete(box, :hidden?)
        false -> Map.put(box, :hidden?, true)
        _ -> box
      end
    else
      box
    end
  end

  defp apply_state(box, _state), do: box
end
