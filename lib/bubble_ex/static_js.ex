defmodule BubbleEx.StaticJs do
  @moduledoc """
  Reads a Bubble page's `static.js` for secret scanning (WTF-560).

  `static.js` is served beside `dynamic.js` (`BubbleEx.fetch_app/2` with
  `include_static_js: true`). It holds Bubble's runtime and every installed
  plugin's definition and client-side code, so a key hard-coded in a plugin
  reaches every visitor. Its statements are one per line:

    * a marketplace plugin is one line,
      `window.plugins["<plugin id>"] = {"human": "<name>", ...}`;
    * a plugin Bubble ships (Stripe, Google, ...) is the block between
      `window._bubble_page_load_data.hardcoded_plugins['<name>'] = true;` and
      `window.preloaded['plugin/first_party:<name>'] = true;`;
    * anything else is Bubble's runtime.

  `source/2` names which of these a line belongs to, and `attribute/2` adds
  it to TruffleHog findings, so a finding says which plugin holds the key. A
  key in plugin code was usually written by the plugin's author, so the same
  key can appear in every app that installs the plugin.
  """

  alias BubbleEx.PayloadFile
  alias BubbleEx.Secrets.Trufflehog

  @enforce_keys [:text, :plugins, :bubble_plugins]
  defstruct [:text, :plugins, :bubble_plugins]

  @typedoc "An indexed `static.js`: its marketplace plugin lines and Bubble's plugin blocks."
  @type t :: %__MODULE__{
          text: binary(),
          plugins: %{pos_integer() => {String.t(), String.t() | nil}},
          bubble_plugins: [{pos_integer(), pos_integer(), String.t()}]
        }

  @typedoc """
  Where a line of `static.js` is: a marketplace plugin (`:plugin`, with its
  ID and name), a plugin Bubble ships (`:bubble_plugin`, with its name as
  `plugin`) or Bubble's runtime (`:bubble_runtime`).
  """
  @type source :: %{
          kind: :plugin | :bubble_plugin | :bubble_runtime,
          line: pos_integer(),
          plugin_id: String.t() | nil,
          plugin: String.t() | nil
        }

  @plugin_line ~r/\A\s*window\.plugins\["([^"\\]+)"\]\s*=/
  @plugin_name ~r/"human":"((?:[^"\\]|\\.)*)"/
  @bubble_plugin_start ~r/\A\s*window\._bubble_page_load_data\.hardcoded_plugins\['([^'\\]+)'\]\s*=\s*true/
  @bubble_plugin_end ~r/\A\s*window\.preloaded\['plugin\/first_party:([^'\\]+)'\]\s*=\s*true/

  # A plugin's name comes first in its definition; never scan a whole line,
  # which can hold hundreds of kilobytes of plugin code.
  @name_window 4096

  @doc "Indexes a `static.js` body."
  @spec index(binary()) :: t()
  def index(text) when is_binary(text) do
    {plugins, bubble_plugins, _open} =
      text
      |> :binary.split("\n", [:global])
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, [], nil}, &index_line/2)

    %__MODULE__{text: text, plugins: plugins, bubble_plugins: Enum.reverse(bubble_plugins)}
  end

  defp index_line({line, number}, {plugins, blocks, open}) do
    cond do
      match = Regex.run(@plugin_line, line, capture: :all_but_first) ->
        [id] = match
        {Map.put(plugins, number, {id, plugin_name(line)}), blocks, open}

      match = Regex.run(@bubble_plugin_start, line, capture: :all_but_first) ->
        [name] = match
        {plugins, blocks, {number, name}}

      match = open && Regex.run(@bubble_plugin_end, line, capture: :all_but_first) ->
        {from, name} = open

        if match == [name],
          do: {plugins, [{from, number, name} | blocks], nil},
          else: {plugins, blocks, open}

      true ->
        {plugins, blocks, open}
    end
  end

  defp plugin_name(line) do
    head = binary_part(line, 0, min(byte_size(line), @name_window))

    with [escaped] <- Regex.run(@plugin_name, head, capture: :all_but_first),
         {:ok, name} when is_binary(name) <- Jason.decode(~s(") <> escaped <> ~s(")) do
      name
    else
      _ -> nil
    end
  end

  @doc "Names where line `line` (1-based) of `static_js` is."
  @spec source(t() | binary(), pos_integer()) :: source()
  def source(%__MODULE__{} = index, line) when is_integer(line) and line > 0 do
    case Map.fetch(index.plugins, line) do
      {:ok, {id, name}} ->
        %{kind: :plugin, line: line, plugin_id: id, plugin: name}

      :error ->
        bubble_source(index.bubble_plugins, line)
    end
  end

  def source(text, line) when is_binary(text), do: text |> index() |> source(line)

  defp bubble_source(blocks, line) do
    case Enum.find(blocks, fn {from, to, _} -> line in from..to end) do
      {_, _, name} -> %{kind: :bubble_plugin, line: line, plugin_id: nil, plugin: name}
      nil -> %{kind: :bubble_runtime, line: line, plugin_id: nil, plugin: nil}
    end
  end

  @doc """
  Adds `"StaticJs" => %{"kind", "line", "plugin_id", "plugin"}` (string keys
  and values, as the finding's own) to each TruffleHog finding of a scan of
  `static_js`. The line is TruffleHog's; a finding without one is placed at
  the first occurrence of its value. A finding found nowhere is left as is.
  """
  @spec attribute([map()], t() | binary()) :: [map()]
  def attribute(findings, %__MODULE__{} = index) when is_list(findings) do
    Enum.map(findings, fn finding ->
      case finding_line(finding, index.text) do
        nil -> finding
        line -> Map.put(finding, "StaticJs", index |> source(line) |> stringify())
      end
    end)
  end

  def attribute(findings, text) when is_binary(text), do: attribute(findings, index(text))

  defp finding_line(finding, text) do
    case get_in(finding, ["SourceMetadata", "Data", "Filesystem", "line"]) do
      line when is_integer(line) and line > 0 -> line
      _ -> first_occurrence_line(text, finding["Encoded"] || finding["Raw"])
    end
  end

  defp first_occurrence_line(text, value) when is_binary(value) and value != "" do
    case :binary.match(text, value) do
      {offset, _} -> length(:binary.matches(binary_part(text, 0, offset), "\n")) + 1
      :nomatch -> nil
    end
  end

  defp first_occurrence_line(_text, _value), do: nil

  defp stringify(source) do
    %{
      "kind" => Atom.to_string(source.kind),
      "line" => source.line,
      "plugin_id" => source.plugin_id,
      "plugin" => source.plugin
    }
  end

  @doc """
  Scans `static_js` with TruffleHog (`BubbleEx.Secrets.Trufflehog.scan_file/2`,
  taking its options) and attributes each finding (`attribute/2`).
  """
  @spec scan(binary(), keyword()) :: {:ok, [map()]} | {:error, BubbleEx.Error.t()}
  def scan(static_js, opts \\ []) when is_binary(static_js) do
    PayloadFile.with_file(static_js, opts, fn file ->
      with {:ok, findings} <- Trufflehog.scan_file(file, opts) do
        {:ok, attribute(findings, static_js)}
      end
    end)
  end
end
