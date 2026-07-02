defmodule BubbleEx.AppTree.Render.Settings do
  @moduledoc "Layer 2: SETTINGS.md — domain, API exposure, and installed-plugin summary."

  @spec render(term()) :: iodata()
  def render(settings) do
    client_safe = safe_map(settings)["client_safe"] |> safe_map()
    plugins = safe_map(client_safe["plugins"])
    plugin_ids = plugins |> Map.keys() |> Enum.sort()

    [
      "# Settings\n\n_Generated from settings.json — do not edit._\n\n",
      "- Domain: #{client_safe["app_topdomain"] || "(unknown)"}\n",
      "- Data API exposed: #{client_safe["exposes_get_api"] || false}\n",
      "- Workflow API exposed: #{client_safe["exposes_wf_api"] || false}\n",
      "\n## Installed plugins (#{length(plugin_ids)})\n\n",
      Enum.map(plugin_ids, &"- #{&1}\n"),
      "\n_Note: `settings.json` contains the full client_safe payload; the `secure` section ships redacted by Bubble._\n"
    ]
  end

  # `settings` (or any nested value it points at) may be a non-map value in a
  # hostile export; treat that the same as absent instead of crashing.
  defp safe_map(v) when is_map(v), do: v
  defp safe_map(_), do: %{}
end
