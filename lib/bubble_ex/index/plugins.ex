defmodule BubbleEx.Index.Plugins do
  @moduledoc false

  # Plugin symbols and `:uses_plugin` references (WTF-376).
  #
  # A marketplace plugin's elements, actions and events have types
  # `"<plugin id>-<code>"`, where the plugin ID is `<digits>x<digits>`
  # (a `_current` / `_test` suffix names a development version of the same
  # plugin). Every plugin installed in `settings.client_safe.plugins` (either
  # key form of the member values: a version string or `true`) and every
  # plugin a type names is a `:plugin` symbol; each element, action and
  # workflow of a plugin type references it. Bubble's own plugins (short
  # slugs such as `apiconnector2`) are not marketplace plugins and are left
  # out: the API Connector is modeled on its own.

  alias BubbleEx.Index.{Reference, Symbol}
  alias BubbleEx.Workflows.Source

  @installed ["settings", "client_safe", "plugins"]

  @roles %{element: :element, action: :action, workflow: :event}

  @doc """
  The plugin ID of an element, action or event type (`"<id>-<code>"`,
  with `_current`/`_test` version suffixes ignored), or nil.
  """
  @spec plugin(term()) :: String.t() | nil
  def plugin(type) when is_binary(type) do
    case Regex.run(~r/^(\d+x\d+)(?:_[a-z]+)?-/, type) do
      [_, id] -> id
      _ -> nil
    end
  end

  def plugin(_), do: nil

  @doc "The member code of a plugin type (`AAC` of `<id>-AAC`), or nil."
  @spec code(term()) :: String.t() | nil
  def code(type) when is_binary(type) do
    case Regex.run(~r/^\d+x\d+(?:_[a-z]+)?-(.+)\z/, type) do
      [_, code] -> code
      _ -> nil
    end
  end

  def code(_), do: nil

  @doc """
  `{plugin symbols, uses_plugin references}` of `app`, given the element,
  action and workflow symbols already indexed.
  """
  @spec build(map(), [Symbol.t()]) :: {[Symbol.t()], [Reference.t()]}
  def build(app, symbols) do
    installed = installed(app)

    refs =
      for %Symbol{kind: kind} = s <- symbols,
          role = Map.get(@roles, kind),
          type = type(s),
          id = plugin(type),
          do: %Reference{
            from: s.id,
            to: Symbol.id(:plugin, id),
            kind: :uses_plugin,
            path: s.path,
            attrs: %{role: role, code: code(type)}
          }

    used = refs |> Enum.map(&bubble_id(&1.to)) |> MapSet.new()

    plugins =
      installed
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(used)
      |> Enum.sort()
      |> Enum.map(&symbol(&1, installed))

    {plugins, refs}
  end

  defp type(%Symbol{kind: :workflow, attrs: attrs}), do: attrs[:event_type]
  defp type(%Symbol{attrs: attrs}), do: attrs[:type]

  defp bubble_id("plugin:" <> id), do: id

  # Marketplace plugin ID -> {JSON pointer, version or nil}.
  defp installed(app) do
    case get_in(app, @installed) do
      plugins when is_map(plugins) ->
        for {key, value} <- plugins,
            is_binary(key),
            plugin(key <> "-") == key,
            into: %{},
            do: {key, {Source.pointer(@installed ++ [key]), version(value)}}

      _ ->
        %{}
    end
  end

  defp version(value) when is_binary(value) and value != "", do: value
  defp version(_), do: nil

  defp symbol(id, installed) do
    {path, attrs} =
      case Map.fetch(installed, id) do
        {:ok, {path, version}} -> {path, compact(%{installed: true, version: version})}
        :error -> {"", %{installed: false}}
      end

    %Symbol{id: Symbol.id(:plugin, id), kind: :plugin, bubble_id: id, path: path, attrs: attrs}
  end

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
