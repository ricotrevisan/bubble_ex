defmodule BubbleEx.Db.Sql.Tsql do
  @moduledoc """
  Encodes a parsed Bubble database map (see `BubbleEx.Db.Reader`) into Microsoft
  SQL Server / Azure SQL T-SQL DDL: a `CREATE SCHEMA` (followed by a `GO` batch
  separator) per table group, a `CREATE TABLE` (columns + a named primary-key
  constraint) per table, and a trailing `--` comment listing each scalar
  reference (`[custom].[Order].[customer] -> [custom].[User].[_id]`).

  By default (`foreign_keys: :none`) no foreign key is declared: Bubble has no
  referential integrity, so real data holds dangling references that a
  constraint would reject on load. `WITH NOCHECK` would not help, since SQL
  Server skips only the existing rows and still checks every new insert; a
  disabled (`NOCHECK CONSTRAINT`) key is untrusted and one `CHECK CONSTRAINT`
  away from rejecting the data, so a comment says the same more safely. With
  `foreign_keys: :enforced` each scalar reference except the built-in
  `Created By` gets an `ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY` instead
  (see `BubbleEx.Db.Encoder.foreign_key?/2`).

  Identifiers are bracket-quoted (`[name]`, with embedded `]` doubled). Key-bearing
  columns (the primary key and scalar reference/enum columns, which can back a
  foreign key or a join) use `NVARCHAR(450)` so they stay indexable; other text
  columns use `NVARCHAR(MAX)`.

  SQL Server has no native array type, so Bubble list fields (`is_array: true`)
  become a single `NVARCHAR(MAX)` column annotated with a
  `/* list<...>: consider a junction table */` comment and carry no foreign-key
  constraint, mirroring how the Postgres encoder drops list references.
  """

  @behaviour BubbleEx.Db.Encoder

  @type opts :: [naming: :proper | :id | nil, foreign_keys: :none | :enforced]

  @impl true
  @spec encode(map(), opts()) :: {:ok, String.t()} | {:error, BubbleEx.Error.t()}
  def encode(parsed_map, opts \\ []) do
    with {:ok, _mode} <- BubbleEx.Db.Encoder.foreign_keys_mode(opts),
         do: render(parsed_map, opts)
  end

  defp render(parsed_map, opts) do
    tables =
      parsed_map
      |> Map.get(:tables, [])
      |> Enum.reject(&(&1.group == :api))

    sections =
      [
        encode_schemas(tables),
        Enum.map_join(tables, "\n\n", &encode_table(&1, opts)),
        encode_foreign_keys(parsed_map, opts),
        encode_references(parsed_map, opts)
      ]
      |> Enum.reject(&(&1 == ""))

    {:ok, Enum.join(sections, "\n\n") <> "\n"}
  end

  defp encode_schemas(tables) do
    tables
    |> Enum.map(& &1.group)
    |> Enum.uniq()
    |> Enum.map_join("\n", fn group ->
      "CREATE SCHEMA #{quote_ident(to_string(group))};\nGO"
    end)
  end

  defp encode_table(table, opts) do
    columns = Enum.reject(table.columns, & &1.deleted)

    column_lines =
      Enum.map_join(columns, ",\n", fn column ->
        "  #{quote_ident(column_name(column, opts))} #{which_type(column, opts)}"
      end)

    pk_line =
      case Enum.find(columns, & &1.primary_key) do
        nil ->
          ""

        pk ->
          ",\n  CONSTRAINT #{quote_ident(pk_constraint_name(table, opts))} " <>
            "PRIMARY KEY (#{quote_ident(column_name(pk, opts))})"
      end

    "CREATE TABLE #{qualified_table(table.group, table_name(table, opts))} (\n" <>
      column_lines <> pk_line <> "\n);"
  end

  defp encode_foreign_keys(parsed_map, opts) do
    parsed_map
    |> Map.get(:relationships, [])
    |> Enum.filter(&BubbleEx.Db.Encoder.foreign_key?(&1, opts))
    |> Enum.map_join("\n", fn {from, to, _dir} -> encode_fk(from, to, opts) end)
  end

  # Scalar references without a constraint, kept as documentation.
  defp encode_references(parsed_map, opts) do
    parsed_map
    |> Map.get(:relationships, [])
    |> BubbleEx.Db.Encoder.reference_comments(opts, fn from, to ->
      qualified_column(from.table_group, ref_table_name(from, opts), column_name(from, opts)) <>
        " -> " <>
        qualified_column(to.table_group, ref_table_name(to, opts), column_name(to, opts))
    end)
  end

  defp qualified_column(group, table, column),
    do: qualified_table(group, table) <> "." <> quote_ident(column)

  defp encode_fk(from, to, opts) do
    "ALTER TABLE #{qualified_table(from.table_group, ref_table_name(from, opts))}\n" <>
      "  ADD CONSTRAINT #{quote_ident(fk_constraint_name(from, opts))}\n" <>
      "  FOREIGN KEY (#{quote_ident(column_name(from, opts))})\n" <>
      "  REFERENCES #{qualified_table(to.table_group, ref_table_name(to, opts))} " <>
      "(#{quote_ident(column_name(to, opts))});"
  end

  # Type mapping (IR -> T-SQL) ---------------------------------------------------

  # List fields collapse to a single text column with a junction-table hint.
  defp which_type(%{type: %{is_array: true} = type}, _opts),
    do: "NVARCHAR(MAX) /* list<#{base_type_name(type)}>: consider a junction table */"

  # Key-bearing columns stay indexable at NVARCHAR(450); everything else NVARCHAR(MAX).
  defp which_type(%{type: %{type: :reference}}, _opts), do: "NVARCHAR(450)"
  defp which_type(%{type: %{type: :enum}}, _opts), do: "NVARCHAR(450)"
  defp which_type(%{primary_key: true, type: %{type: :string}}, _opts), do: "NVARCHAR(450)"

  defp which_type(%{type: %{type: type}} = column, opts)
       when type in [:external, :opaque_external] do
    mode = Keyword.get(opts, :external_types, :legacy)
    name = quote_ident(column_name(column, opts))
    native? = :native_json in capability(opts, :tsql)

    cond do
      mode == :legacy -> "NVARCHAR(MAX)"
      native? -> "JSON"
      true -> "NVARCHAR(MAX) CHECK (#{name} IS NULL OR ISJSON(#{name}) = 1)"
    end
  end

  defp which_type(%{type: type}, _opts), do: base_type(type)

  defp capability(opts, target),
    do: opts |> Keyword.get(:external_type_capabilities, %{}) |> Map.get(target, [])

  defp base_type(%{type: :api}), do: "NVARCHAR(MAX)"
  defp base_type(%{type: :custom}), do: "NVARCHAR(MAX)"
  defp base_type(%{type: :utc_datetime_usec}), do: "DATETIME2"
  defp base_type(%{type: :boolean}), do: "BIT"
  defp base_type(%{type: :float}), do: "FLOAT"
  defp base_type(%{type: :string}), do: "NVARCHAR(MAX)"
  defp base_type(_type), do: "NVARCHAR(MAX)"

  # Human label for the list<...> comment, naming the element's logical type.
  defp base_type_name(%{type: :reference}), do: "ref"
  defp base_type_name(%{type: :enum}), do: "enum"
  defp base_type_name(%{type: :float}), do: "float"
  defp base_type_name(%{type: :boolean}), do: "bit"
  defp base_type_name(%{type: :utc_datetime_usec}), do: "datetime"
  defp base_type_name(_type), do: "text"

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

  defp pk_constraint_name(table, opts), do: "PK_#{slug(table_name(table, opts))}"

  defp fk_constraint_name(from, opts),
    do: "FK_#{slug(ref_table_name(from, opts))}_#{slug(column_name(from, opts))}"

  # Constraint-name slug: lowercase, non-alphanumerics collapsed to underscores.
  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp qualified_table(group, name),
    do: "#{quote_ident(to_string(group))}.#{quote_ident(name)}"

  defp quote_ident(name) do
    "[" <> String.replace(name, "]", "]]") <> "]"
  end
end
