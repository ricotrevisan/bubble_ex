defmodule BubbleEx.Db.Sql.Sqlite do
  @moduledoc """
  Encodes a parsed Bubble database map (see `BubbleEx.Db.Reader`) into SQLite DDL:
  a `CREATE TABLE IF NOT EXISTS` per table group/table, with columns, a primary
  key, and any scalar foreign keys declared inline (SQLite does not support
  `ALTER TABLE ... ADD FOREIGN KEY`).

  SQLite has no schema namespaces, so the Bubble group (`custom`/`option`/`api`)
  becomes a table-name prefix (e.g. `custom__Survey Response`). List/array fields
  have no native type and are stored as JSON `TEXT` with no foreign-key
  constraint, mirroring how Bubble stores lists of ids on the record. A
  `PRAGMA foreign_keys = ON;` preamble is emitted because SQLite ignores foreign
  keys unless that pragma is set.

  Primary-key columns are emitted as `NOT NULL`: a table-level `PRIMARY KEY` on a
  non-INTEGER column does not imply `NOT NULL` in SQLite, so without it the text
  `_id`/`Display` key could be NULL (and even duplicate-NULL).
  """

  @behaviour BubbleEx.Db.Encoder

  @type opts :: [naming: :proper | :id | nil]

  @preamble """
  -- SQLite DDL for Bubble app
  -- NOTE: arrays stored as JSON text; FKs require PRAGMA foreign_keys = ON.
  -- NOTE: Bubble groups (custom/option/api) have no SQLite schema equivalent; encoded as a table-name prefix.

  PRAGMA foreign_keys = ON;\
  """

  @impl true
  @spec encode(map(), opts()) :: {:ok, String.t()}
  def encode(parsed_map, opts \\ []) do
    tables =
      parsed_map
      |> Map.get(:tables, [])
      |> Enum.reject(&(&1.group == :api))

    relationships = Map.get(parsed_map, :relationships, [])

    sections =
      [
        @preamble,
        Enum.map_join(tables, "\n\n", &encode_table(&1, relationships, opts))
      ]
      |> Enum.reject(&(&1 == ""))

    {:ok, Enum.join(sections, "\n\n") <> "\n"}
  end

  defp encode_table(table, relationships, opts) do
    columns = Enum.reject(table.columns, & &1.deleted)

    column_cells = Enum.map(columns, &column_cell(&1, opts))

    constraints =
      [pk_constraint(columns, opts) | fk_constraints(table, relationships, opts)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&{&1, ""})

    body = join_cells(column_cells ++ constraints)

    "CREATE TABLE IF NOT EXISTS #{qualified_table(table.group, table_name(table, opts))} (\n" <>
      body <> "\n);"
  end

  # Each cell is a {code, comment} pair. The trailing comma must precede any "--"
  # comment, otherwise the comment swallows the comma and the DDL is invalid.
  defp join_cells(cells) do
    last = length(cells) - 1

    cells
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {{code, comment}, index} ->
      sep = if index == last, do: "", else: ","
      code <> sep <> comment_suffix(comment)
    end)
  end

  defp comment_suffix(""), do: ""
  defp comment_suffix(comment), do: "  -- " <> comment

  defp column_cell(column, opts) do
    {type, comment} = which_type(column.type)
    name = quote_ident(column_name(column, opts))

    check =
      if column.type.type in [:external, :opaque_external] and
           Keyword.get(opts, :external_types, :legacy) != :legacy,
         do: " CHECK (#{name} IS NULL OR json_valid(#{name}))",
         else: ""

    {"  #{name} #{type}#{null_clause(column)}#{check}", comment}
  end

  # A table-level PRIMARY KEY on a non-INTEGER column does not imply NOT NULL in
  # SQLite, so primary-key columns must declare it explicitly or `_id`/`Display`
  # could be NULL (and even duplicate-NULL), defeating the key.
  defp null_clause(%{primary_key: true}), do: " NOT NULL"
  defp null_clause(_column), do: ""

  defp pk_constraint(columns, opts) do
    case Enum.find(columns, & &1.primary_key) do
      nil -> ""
      pk -> "  PRIMARY KEY (#{quote_ident(column_name(pk, opts))})"
    end
  end

  defp fk_constraints(table, relationships, opts) do
    relationships
    |> Enum.filter(fn {from, to, _dir} ->
      from != nil and to != nil and not from.deleted and not to.deleted and
        from.table_id == table.id and Map.get(from.type, :is_array) != true
    end)
    |> Enum.map(fn {from, to, _dir} -> encode_fk(from, to, opts) end)
  end

  defp encode_fk(from, to, opts) do
    "  FOREIGN KEY (#{quote_ident(column_name(from, opts))}) " <>
      "REFERENCES #{qualified_table(to.table_group, ref_table_name(to, opts))} " <>
      "(#{quote_ident(column_name(to, opts))})"
  end

  # Type mapping (IR -> SQLite affinity) -----------------------------------------
  # Returns a {type, comment} pair; comment is "" when there is nothing to note.

  # Lists have no native SQLite type: collapse to TEXT (JSON), no array suffix.
  defp which_type(%{is_array: true} = type),
    do: {"TEXT", "list<#{base_type(type)}>; store as JSON"}

  defp which_type(type), do: {base_type(type), ""}

  defp base_type(%{type: :reference}), do: "TEXT"
  defp base_type(%{type: :enum}), do: "TEXT"
  defp base_type(%{type: :api}), do: "TEXT"
  defp base_type(%{type: type}) when type in [:external, :opaque_external], do: "TEXT"
  defp base_type(%{type: :custom}), do: "TEXT"
  defp base_type(%{type: :utc_datetime_usec}), do: "TEXT"
  defp base_type(%{type: :boolean}), do: "INTEGER"
  defp base_type(%{type: :float}), do: "REAL"
  defp base_type(%{type: :string}), do: "TEXT"
  defp base_type(_type), do: "TEXT"

  # Naming + quoting -------------------------------------------------------------

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

  # SQLite has no schemas; fold the group into a single prefixed identifier.
  defp qualified_table(group, name),
    do: quote_ident("#{group}__#{name}")

  defp quote_ident(name) do
    escaped = String.replace(name, ~s("), ~s(""))
    ~s("#{escaped}")
  end
end
