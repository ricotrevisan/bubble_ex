defmodule BubbleEx.Editor.PluginSchema do
  @moduledoc """
  Discovers editor contracts from the plugins installed on one Bubble branch.

  Only declarative metadata is retained. Plugin JavaScript, headers, shared
  secrets, and API definitions are never executed or returned. Every discovery
  fetches fresh definitions, including mutable `current` versions.
  """
  alias BubbleEx.Editor.{Client, Snapshot}
  alias BubbleEx.Error

  @installed_path ["settings", "client_safe", "plugins"]
  @field_keys ~w(name caption editor value is_list optional default_val options)

  @spec discover(BubbleEx.Editor.Target.t(), [String.t()] | :all, keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def discover(target, groups \\ :all, opts \\ []) do
    with {:ok, snapshot} <- Client.read(target, [@installed_path], opts),
         {:ok, installed} <- Snapshot.fetch(snapshot, @installed_path),
         true <- is_map(installed),
         {:ok, selected} <- select(installed, groups),
         {:ok, schemas} <- fetch_schemas(target, selected, opts) do
      {:ok, %{last_change: snapshot.last_change, schemas: schemas}}
    else
      false -> invalid("installed plugin map is missing")
      :error -> invalid("installed plugin map was omitted")
      {:error, _error} = error -> error
    end
  end

  @spec normalize(String.t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def normalize(group, version, %{"plugin_elements" => elements} = raw)
      when is_map(elements) do
    with {:ok, nodes} <- normalize_elements(group, elements) do
      contract = %{group: group, version: version, name: raw["human"], nodes: nodes}

      hash =
        :crypto.hash(:sha256, :erlang.term_to_binary(contract, [:deterministic]))
        |> Base.encode16(case: :lower)

      {:ok, Map.put(contract, :hash, hash)}
    end
  end

  def normalize(_group, _version, _raw), do: invalid("plugin element contract is unavailable")

  @spec node(map() | nil, String.t()) :: map() | nil
  def node(nil, _type), do: nil

  def node(schemas, type) do
    Enum.find_value(schemas, fn {_group, schema} -> Map.get(schema.nodes, type) end)
  end

  @spec field(map() | nil, String.t(), String.t()) :: map() | nil
  def field(schemas, type, key) do
    case node(schemas, type) do
      nil -> nil
      node -> Map.get(node.fields, key)
    end
  end

  @spec validate_value(map(), term()) :: :ok | {:error, Error.t()}
  def validate_value(field, value) do
    with {:ok, kind} <- field_kind(field) do
      validate_typed_value(field, kind, value)
    end
  end

  defp field_kind(%{"editor" => "DynamicValue", "value" => kind})
       when kind in ~w(text number boolean),
       do: {:ok, kind}

  defp field_kind(%{"editor" => editor}) when editor in ~w(StaticText Color Dropdown),
    do: {:ok, "text"}

  defp field_kind(%{"editor" => "StaticNumber"}), do: {:ok, "number"}
  defp field_kind(%{"editor" => "Checkbox"}), do: {:ok, "boolean"}

  defp field_kind(field),
    do: invalid("unsupported plugin field type", %{editor: field["editor"], type: field["value"]})

  defp validate_typed_value(%{"optional" => true}, _kind, nil), do: :ok

  defp validate_typed_value(%{"editor" => "DynamicValue"}, _kind, %{"%x" => _type}),
    do: invalid("plugin dynamic bindings require expression result-type support")

  defp validate_typed_value(%{"is_list" => true} = field, kind, values) when is_list(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      continue(validate_typed_value(Map.delete(field, "is_list"), kind, value))
    end)
  end

  defp validate_typed_value(%{"is_list" => true}, _kind, _value),
    do: invalid("plugin property requires a list")

  defp validate_typed_value(%{"editor" => "Dropdown", "options" => options}, "text", value)
       when is_binary(options) and is_binary(value) do
    if value in Enum.map(String.split(options, ","), &String.trim/1),
      do: :ok,
      else: invalid("plugin property is not one of its declared options")
  end

  defp validate_typed_value(_field, "text", value) when is_binary(value), do: :ok
  defp validate_typed_value(_field, "number", value) when is_number(value), do: :ok
  defp validate_typed_value(_field, "boolean", value) when is_boolean(value), do: :ok

  defp validate_typed_value(_field, kind, _value),
    do: invalid("plugin property has the wrong value type", %{expected_type: kind})

  defp select(installed, :all),
    do: {:ok, Enum.filter(installed, fn {_id, version} -> is_binary(version) end)}

  defp select(installed, groups) do
    if Enum.all?(groups, &is_binary(Map.get(installed, &1))) do
      {:ok, Enum.map(groups, &{&1, Map.fetch!(installed, &1)})}
    else
      invalid("a declared plugin is not installed on this branch")
    end
  end

  defp fetch_schemas(target, selected, opts) do
    Enum.reduce_while(selected, {:ok, %{}}, fn {group, version}, {:ok, acc} ->
      id = String.replace_suffix(group, "_current", "")

      with {:ok, raw} <- Client.plugin(target, id, version, opts),
           {:ok, schema} <- normalize(group, version, raw) do
        {:cont, {:ok, Map.put(acc, group, schema)}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_elements(group, elements) do
    elements
    |> Enum.reject(fn {_id, element} ->
      is_map(element) and Map.get(element, "platform_type") not in [nil, "web"]
    end)
    |> Enum.reduce_while({:ok, %{}}, fn {id, element}, {:ok, acc} ->
      with true <- is_map(element),
           {:ok, fields} <- fields(Map.get(element, "fields", %{})),
           {:ok, actions} <- members(group, id, Map.get(element, "actions", %{}), :actions),
           {:ok, events} <- members(group, id, Map.get(element, "events", %{}), :workflows),
           {:ok, states} <- fields(Map.get(element, "states", %{})) do
        node = %{
          role: :elements,
          name: element["display"],
          fields: fields,
          states: states,
          platform: element["platform_type"]
        }

        entries = [{group <> "-" <> id, node} | actions ++ events]
        merge_entries(acc, entries)
      else
        _ -> {:halt, invalid("malformed plugin element contract")}
      end
    end)
  end

  defp members(group, owner, values, role) when is_map(values) do
    Enum.reduce_while(values, {:ok, []}, fn {id, member}, {:ok, acc} ->
      with true <- is_map(member), {:ok, fields} <- fields(Map.get(member, "fields", %{})) do
        entry =
          {group <> "-" <> id,
           %{
             role: role,
             owner: group <> "-" <> owner,
             name: member["name"] || member["caption"],
             fields: fields
           }}

        {:cont, {:ok, [entry | acc]}}
      else
        _ -> {:halt, invalid("malformed plugin event/action contract")}
      end
    end)
  end

  defp members(_group, _owner, _values, _role), do: invalid("malformed plugin event/action map")

  defp fields(values) when is_map(values) do
    if Enum.all?(values, fn {id, field} -> is_binary(id) and is_map(field) end),
      do: {:ok, Map.new(values, fn {id, field} -> {id, Map.take(field, @field_keys)} end)},
      else: invalid("malformed plugin fields")
  end

  defp fields(_values), do: invalid("malformed plugin fields")

  defp merge_entries(acc, entries) do
    keys = Enum.map(entries, &elem(&1, 0))

    if length(keys) == length(Enum.uniq(keys)) and not Enum.any?(keys, &Map.has_key?(acc, &1)),
      do: {:cont, {:ok, Map.merge(acc, Map.new(entries))}},
      else: {:halt, invalid("ambiguous plugin node IDs")}
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue(error), do: {:halt, error}
  defp invalid(message, context \\ %{}), do: {:error, Error.new(:invalid_input, message, context)}
end
