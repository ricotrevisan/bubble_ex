defmodule BubbleEx.AppTree.Render.Workflows do
  @moduledoc """
  Layer 2: WORKFLOWS.md (per page/component) and API.md (backend workflows).
  Known action types render one semantic line each; plugin and unknown types
  print explicitly-unrendered lines and count against coverage.
  """

  alias BubbleEx.AppTree.Coverage

  @element_target ~w(HideElement ShowElement ToggleElement ResetGroup SetFocusToElement
                     AnimateElement DisplayGroupData DisplayListData)
  @bare ~w(ResetInputs TerminateWorkflow PauseWFClient APIReturnData MakeChangeCurrentUser
           ChangeThing NewThing DeleteThing ChangeListOfThings DeleteListOfThings
           ScheduleAPIEvent ScheduleAPIEventOnList ScheduleCustom CancelScheduledAPIEvent
           TriggerCustomEvent TriggerCustomEventFromReusable ChangePage ListGoToPage
           SetCustomState)
  @plugin_type ~r/^\d+x\d+-/

  @spec render(map() | nil, map()) :: {iodata(), Coverage.t()}
  def render(workflows, ctx), do: do_render(workflows || %{}, ctx)

  @spec render_api(map() | nil, map()) :: {iodata(), Coverage.t()}
  def render_api(api, ctx), do: do_render(api || %{}, ctx)

  # Non-map workflows value: render as empty (header only, zero coverage)
  defp do_render(workflows, ctx) when not is_map(workflows) do
    header = "# Workflows: #{ctx.title}\n\n_Generated from workflows/*.json — do not edit._\n"
    {[header, []], Coverage.zero()}
  end

  defp do_render(workflows, ctx) do
    sections =
      workflows
      |> Enum.filter(fn {_, wf} -> is_map(wf) end)
      |> Enum.map(fn {key, wf} -> {trigger(wf, ctx), key, wf} end)
      |> Enum.sort_by(fn {heading, key, _} -> {heading, key} end)

    {blocks, coverage} =
      Enum.reduce(sections, {[], Coverage.zero()}, fn {heading, key, wf}, {blocks, cov} ->
        {lines, cov} = action_lines(wf["actions"], ctx.files[key], ctx, cov)
        source = ctx.files[key] || "(unknown source)"
        block = "## #{heading}\n\n_Source: #{source}_\n\n" <> Enum.join(lines, "\n") <> "\n"
        {blocks ++ [block], cov}
      end)

    header = "# Workflows: #{ctx.title}\n\n_Generated from workflows/*.json — do not edit._\n"
    body = Enum.map(blocks, &["\n", &1])
    {[header, body], coverage}
  end

  defp trigger(wf, ctx) do
    props = wf["properties"] || %{}

    case wf["type"] do
      "CustomEvent" -> ~s(When custom event "#{props["event_name"]}" is triggered)
      "ButtonClicked" -> "When #{element(ctx, props["element_id"])} is clicked"
      "PageLoaded" -> "When the page is loaded"
      "APIEvent" -> ~s(When backend workflow "#{props["wf_name"]}" is called)
      other -> "On #{other}"
    end
  end

  defp action_lines(nil, _raw, _ctx, coverage), do: {["(no actions)"], coverage}

  defp action_lines(actions, raw, ctx, coverage) when is_map(actions) do
    actions
    |> Enum.sort_by(fn {k, _} -> action_order(k) end)
    |> Enum.with_index(1)
    |> Enum.reduce({[], coverage}, fn {{key, action}, n}, {lines, cov} ->
      {line, rendered?} = action_line(action, key, raw, ctx)
      {lines ++ ["#{n}. #{line}"], Coverage.bump(cov, :actions, rendered?)}
    end)
  end

  # Malformed "actions" value (real exports may contain them): no crash.
  defp action_lines(_actions, _raw, _ctx, coverage), do: {["(no actions)"], coverage}

  defp action_order(key) do
    case Integer.parse(key) do
      {i, ""} -> i
      _ -> 1_000_000
    end
  end

  defp action_line(action, key, raw, ctx) when is_map(action) do
    type = action["type"]
    props = action["properties"] || %{}

    cond do
      type in @element_target -> {"#{type}: #{element(ctx, props["element_id"])}", true}
      type == "OpenURL" -> {open_url_line(props["url"]), true}
      type in @bare -> {type, true}
      is_binary(type) and type =~ @plugin_type -> {"Plugin action #{type}", false}
      true -> {"Unrendered action #{type} — see #{raw}#actions.#{key}", false}
    end
  end

  # Malformed action VALUE (real exports may contain them): no crash.
  defp action_line(_action, key, raw, _ctx),
    do: {"Unrendered action (malformed value) — see #{raw}#actions.#{key}", false}

  defp open_url_line(url) when is_binary(url), do: "OpenURL: #{url}"
  defp open_url_line(_url), do: "OpenURL"

  defp element(ctx, id), do: ctx.element_names[id] || "element #{id}"
end
