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
  # workflow of a plugin type references it, and so does every symbol whose
  # JSON names one of the plugin's data types. Bubble's own plugins (short
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

    typed =
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

    refs = typed ++ data_types(app, symbols)

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

  # Marketplace plugin ID -> {JSON pointer, version or nil}. A key with a
  # `_current` / `_test` suffix installs a development version of the same
  # plugin; the plain key wins when both are present.
  defp installed(app) do
    case get_in(app, @installed) do
      plugins when is_map(plugins) ->
        for {key, value} <- Enum.sort_by(plugins, &elem(&1, 0), :desc),
            is_binary(key),
            id = plugin(key <> "-"),
            into: %{},
            do: {id, {Source.pointer(@installed ++ [key]), version(value)}}

      _ ->
        %{}
    end
  end

  # Plugin data types (`api.<plugin id>.plugin_api.<code>…`, the types of a
  # plugin's API calls and states) named anywhere in the app JSON outside
  # the settings: a use by the innermost indexed symbol holding the name.
  defp data_types(app, symbols) do
    owners = for %Symbol{path: path, id: id} <- symbols, path != "", into: %{}, do: {path, id}

    app
    |> Map.drop(["settings"])
    |> strings([], [])
    |> Enum.flat_map(fn {text, path} ->
      owner = owner(Enum.reverse(path), owners)

      for [_, id, code] <-
            Regex.scan(~r/api\.(\d+x\d+)(?:_[a-z]+)?\.plugin_api\.([A-Za-z0-9]+)/, text),
          owner != nil,
          uniq: true,
          do: %Reference{
            from: owner,
            to: Symbol.id(:plugin, id),
            kind: :uses_plugin,
            path: Source.pointer(Enum.reverse(path)),
            attrs: %{role: :data_type, code: code}
          }
    end)
  end

  # `{string, reversed path}` of every string (and key) naming a plugin API.
  defp strings(map, path, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {k, v}, a ->
      a = if is_binary(k) and String.contains?(k, "plugin_api"), do: [{k, path} | a], else: a
      strings(v, [to_string(k) | path], a)
    end)
  end

  defp strings(list, path, acc) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {v, i}, a -> strings(v, [Integer.to_string(i) | path], a) end)
  end

  defp strings(text, path, acc) when is_binary(text) do
    if String.contains?(text, "plugin_api"), do: [{text, path} | acc], else: acc
  end

  defp strings(_, _, acc), do: acc

  # The innermost symbol whose definition encloses `path`.
  defp owner(path, owners) do
    Enum.find_value(length(path)..1//-1, fn n ->
      Map.get(owners, path |> Enum.take(n) |> Source.pointer())
    end)
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
