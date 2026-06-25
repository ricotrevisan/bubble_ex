defmodule BubbleEx.Db.Xano do
  @moduledoc """
  Encodes a parsed Bubble database map (see `BubbleEx.Db.Reader`) into a
  Xano-flavored table-schema JSON document.

  [Xano](https://www.xano.com/bubble/) is a no-code backend marketed as a Bubble
  alternative. The output is a JSON array of table objects, each with a `name`
  and a list of `fields`. Each field carries a real Xano `type`
  (`text`, `int`, `decimal`, `bool`, `timestamp`, `json`, `enum`) and a `style`
  of `"single"` or `"list"` — Xano models a list field as a base type with
  `"style": "list"` rather than a distinct type, so there is no `list`/`child`
  shape. References degrade to `text` and enums use Xano's native `enum` type
  (with an empty placeholder `values` config), both carrying a `description` that
  records the relationship/option-set that could not be expressed automatically,
  because Xano links relationships in its GUI and the IR carries no option-set
  member values.

  ## Format caveat

  This output models the schema in Xano's *field vocabulary* (the types/attributes
  Xano's database surfaces). It is a faithful representation but is **not**
  guaranteed to be a drop-in payload for the current Xano Metadata API import
  endpoint, whose exact request shape (per-field wrapping, the precise list
  attribute key, and the enum `values` config layout) is not fully documented
  publicly and may differ by Xano version. Treat it as a schema description to
  adapt to the Metadata API import shape, not a turnkey import file. A leading
  `_note` object in the array records the same caveat in-band.

  Table and field names are snake_cased. `:api`-group placeholder tables are
  skipped and `deleted` columns are dropped, mirroring `BubbleEx.Db.Sql.Postgres`.
  """

  @behaviour BubbleEx.Db.Encoder

  @type opts :: [naming: :proper | :id]

  @note %{
    _note:
      "Schema described in Xano's field vocabulary (type + style). " <>
        "Not guaranteed drop-in for the current Metadata API import endpoint; " <>
        "adapt field wrapping, the list attribute, and the enum values config as needed."
  }

  @impl true
  @spec encode(map(), opts()) :: {:ok, String.t()}
  def encode(parsed_map, opts \\ []) do
    rel_index = relationship_index(parsed_map)

    tables =
      parsed_map
      |> Map.get(:tables, [])
      |> Enum.reject(&(&1.group == :api))
      |> Enum.map(&encode_table(&1, rel_index, opts))

    {:ok, Jason.encode!([@note | tables], pretty: true) <> "\n"}
  end

  defp encode_table(table, rel_index, opts) do
    fields =
      table.columns
      |> Enum.reject(& &1.deleted)
      |> Enum.map(&encode_field(&1, rel_index, opts))

    %{name: snake(table_name(table, opts)), fields: fields}
  end

  defp encode_field(column, rel_index, opts) do
    %{
      name: snake(column_name(column, opts)),
      type: xano_type(column.type),
      style: style(column.type)
    }
    |> maybe_enum_values(column.type)
    |> maybe_description(column, rel_index, opts)
  end

  # Lists are a base type with `style: "list"`; everything else is `single`.
  defp style(%{is_array: true}), do: "list"
  defp style(_type), do: "single"

  # Enums use Xano's native `enum` type; the IR has no member values, so emit an
  # empty placeholder `values` config to be filled in once known.
  defp maybe_enum_values(field, %{type: :enum}), do: Map.put(field, :values, [])
  defp maybe_enum_values(field, _type), do: field

  defp maybe_description(field, %{type: %{type: :reference}} = column, rel_index, opts) do
    Map.put(field, :description, ref_description(column, rel_index, opts))
  end

  defp maybe_description(field, %{type: %{type: :enum}} = column, rel_index, opts) do
    Map.put(field, :description, enum_description(column, rel_index, opts))
  end

  defp maybe_description(field, %{primary_key: true} = _column, _rel_index, _opts) do
    Map.put(field, :description, "Bubble primary key (link manually in Xano)")
  end

  defp maybe_description(field, _column, _rel_index, _opts), do: field

  defp ref_description(column, rel_index, opts) do
    case Map.get(rel_index, column.id) do
      nil ->
        "ref:#{snake(column.type.custom_type)} (link manually in Xano)"

      to ->
        "ref:#{snake(ref_table_name(to, opts))}.#{snake(column_name(to, opts))} " <>
          "(link manually in Xano)"
    end
  end

  defp enum_description(column, rel_index, opts) do
    name =
      case Map.get(rel_index, column.id) do
        nil -> snake(column.type.custom_type)
        to -> snake(ref_table_name(to, opts))
      end

    "enum:#{name} (option values not in IR)"
  end

  # Maps `from` column id => `to` column for references and enums.
  defp relationship_index(parsed_map) do
    parsed_map
    |> Map.get(:relationships, [])
    |> Enum.reduce(%{}, fn
      {from, to, _dir}, acc when not is_nil(from) and not is_nil(to) ->
        Map.put(acc, from.id, to)

      _entry, acc ->
        acc
    end)
  end

  # Type mapping (IR -> Xano) ----------------------------------------------------
  # `xano_type/1` returns the base Xano type regardless of arity; the array-ness
  # is carried by `style/1`, since Xano has no separate `list` type.

  defp xano_type(%{type: :reference}), do: "text"
  defp xano_type(%{type: :enum}), do: "enum"
  defp xano_type(%{type: :api}), do: "text"
  defp xano_type(%{type: :custom, custom_type: "bubble_image"}), do: "text"
  defp xano_type(%{type: :custom, custom_type: "bubble_file"}), do: "text"
  defp xano_type(%{type: :custom}), do: "json"
  defp xano_type(%{type: :utc_datetime_usec}), do: "timestamp"
  defp xano_type(%{type: :boolean}), do: "bool"
  defp xano_type(%{type: :float}), do: "decimal"
  defp xano_type(%{type: :string}), do: "text"
  defp xano_type(_type), do: "text"

  # Naming -----------------------------------------------------------------------

  # :proper (default) uses display names; :id uses the Bubble ids.
  defp column_name(column, opts), do: by_naming(opts, column.name, column.id)
  defp table_name(table, opts), do: by_naming(opts, table.name, table.id)
  defp ref_table_name(column, opts), do: by_naming(opts, column.table_name, column.table_id)

  defp by_naming(opts, proper, id) do
    case Keyword.get(opts, :naming, :proper) do
      :id -> id
      _ -> proper
    end
  end

  # Snake-cases a name: lowercases and replaces runs of non-alphanumerics with a
  # single underscore. Trailing underscores from a trailing separator are
  # trimmed, but a leading underscore is preserved so the Bubble primary key
  # `_id` stays `_id` rather than collapsing to `id`.
  defp snake(name) do
    cleaned =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim_trailing("_")

    if cleaned == "", do: "_", else: cleaned
  end
end
