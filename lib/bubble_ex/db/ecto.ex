defmodule BubbleEx.Db.Ecto do
  @moduledoc """
  Encodes a parsed Bubble database map (see `BubbleEx.Db.Reader`) into runnable
  Elixir: one `Ecto.Schema` module plus a matching `Ecto.Migration` per table.

  This is the highest-value target for Phoenix developers migrating off Bubble:
  the generated modules drop straight into a project, ready for changesets and
  queries. Each table produces two sections in the returned string, separated by
  comment delimiters: the schema module (`use Ecto.Schema`, fields, `belongs_to`
  associations, and a `changeset/2`) and the migration (`create table(...)` plus
  an `index` per scalar foreign key).

  Type mapping (IR -> Ecto):

    * `:string` -> `:string`
    * `:float` -> `:float`
    * `:boolean` -> `:boolean`
    * `:utc_datetime_usec` -> `:utc_datetime_usec`
    * `:reference` / `:enum` -> `belongs_to` with `type: :string` (Bubble PKs are
      text `_id` / `display`, not integer/UUID). The association keeps the Bubble
      field name, but Ecto requires a distinct foreign key, so the FK column is
      `<field>_id` and `references:` points at the target schema's real primary
      key (`:_id` for user tables, the option-set's PK field for enums) since
      these schemas carry no default `:id` column.
    * `:custom` `bubble_image` / `bubble_file` -> `:string`
    * other `:custom` (`bubble_geo_address`, `bubble_number_range`,
      `bubble_date_range`, `bubble_dateinterval`) -> `:map` (jsonb)

  Lists (`is_array: true`) become `{:array, :string}` columns. A list of
  references also renders as `{:array, :string}` with no association, because
  Ecto has no array foreign-key: the relational semantics of a Bubble list field
  are lost (a join table would be more correct but needs a synthetic key).

  Enums/option sets are lossy: the IR carries no member values, so `Ecto.Enum` is
  impossible. Each option set renders as its own sibling schema module with a
  `:string` primary key, referenced through `belongs_to`.

  `:api` group tables (external placeholders) are skipped, mirroring
  `BubbleEx.Db.Sql.Postgres`.
  """

  @behaviour BubbleEx.Db.Encoder

  @type opts :: [naming: :proper | :id, namespace: String.t()]

  @default_namespace "MyApp"

  @impl true
  @spec encode(map(), opts()) :: {:ok, String.t()}
  def encode(parsed_map, opts \\ []) do
    tables =
      parsed_map
      |> Map.get(:tables, [])
      |> Enum.reject(&(&1.group == :api))

    relationships = scalar_relationships(parsed_map)

    body =
      Enum.map_join(tables, "\n\n", fn table ->
        encode_table(table, relationships, opts)
      end)

    {:ok, body <> "\n"}
  end

  # Only scalar references become associations/indexes; list references have no
  # array foreign-key in Ecto, mirroring how Postgres skips array FKs.
  defp scalar_relationships(parsed_map) do
    parsed_map
    |> Map.get(:relationships, [])
    |> Enum.filter(fn {from, to, _dir} ->
      from != nil and to != nil and not from.deleted and not to.deleted and
        Map.get(from.type, :is_array) != true
    end)
  end

  defp encode_table(table, relationships, opts) do
    columns = Enum.reject(table.columns, & &1.deleted)
    table_refs = Enum.filter(relationships, fn {from, _to, _dir} -> from.table_id == table.id end)

    schema_module(table, columns, table_refs, opts) <>
      "\n\n" <> migration_module(table, columns, table_refs, opts)
  end

  # Schema module ---------------------------------------------------------------

  defp schema_module(table, columns, table_refs, opts) do
    namespace = namespace(opts)
    module = "#{namespace}.#{module_name(table, opts)}"
    table_str = table_name(table, opts)
    {pk_cols, value_cols} = Enum.split_with(columns, & &1.primary_key)

    fields = Enum.map_join(value_cols, "\n", &field_line(&1, table_refs, opts))

    cast_fields =
      value_cols
      |> Enum.map_join(", ", fn column -> ":" <> cast_name(column, table_refs, opts) end)

    "# schema module\n" <>
      "defmodule #{module} do\n" <>
      "  use Ecto.Schema\n" <>
      "  import Ecto.Changeset\n\n" <>
      primary_key_attrs(pk_cols, opts) <>
      "  schema #{quoted(table_str)} do\n" <>
      fields <>
      "\n  end\n\n" <>
      "  def changeset(rec, attrs) do\n" <>
      "    rec |> cast(attrs, [#{cast_fields}]) |> validate_required([#{required(pk_cols, opts)}])\n" <>
      "  end\n" <>
      "end"
  end

  defp primary_key_attrs([], _opts), do: ""

  defp primary_key_attrs([pk | _], opts) do
    "  @primary_key {:#{field_name(pk, opts)}, :string, autogenerate: false}\n" <>
      "  @foreign_key_type :string\n\n"
  end

  defp required([], _opts), do: ""
  defp required([pk | _], opts), do: ":" <> field_name(pk, opts)

  defp field_line(column, table_refs, opts) do
    case Enum.find(table_refs, fn {from, _to, _dir} -> from.id == column.id end) do
      nil -> "    field :#{field_name(column, opts)}, #{ecto_type(column.type)}"
      {from, to, _dir} -> belongs_to_line(from, to, opts)
    end
  end

  # The association name is the Bubble field name, but Ecto requires a distinct
  # foreign-key column, so the FK column is `<field>_id`. `references:` points at
  # the target schema's real primary key (`:_id` for user tables, the option-set's
  # PK field for enums) because these schemas have no default `:id` column.
  defp belongs_to_line(from, to, opts) do
    name = field_name(from, opts)
    fk = fk_column(from, opts)
    references = field_name(to, opts)
    target = "#{namespace(opts)}.#{ref_module_name(to, opts)}"

    "    belongs_to :#{name}, #{target}, foreign_key: :#{fk}, references: :#{references}, type: :string"
  end

  # The single source of truth for a reference's foreign-key column name. Schema,
  # migration, index, and changeset all derive the column from here so they agree.
  defp fk_column(from, opts), do: field_name(from, opts) <> "_id"

  # Reference columns cast their FK column (`<field>_id`), not the association
  # name, keeping the changeset consistent with the schema and migration.
  defp cast_name(column, table_refs, opts) do
    case Enum.find(table_refs, fn {from, _to, _dir} -> from.id == column.id end) do
      nil -> field_name(column, opts)
      {from, _to, _dir} -> fk_column(from, opts)
    end
  end

  # Migration module ------------------------------------------------------------

  defp migration_module(table, columns, table_refs, opts) do
    namespace = namespace(opts)
    table_str = table_name(table, opts)
    module = "#{namespace}.Repo.Migrations.Create#{module_name(table, opts)}"

    {pk_cols, value_cols} = Enum.split_with(columns, & &1.primary_key)

    add_lines =
      [
        Enum.map(pk_cols, &pk_add_line(&1, opts)),
        Enum.map(value_cols, &add_line(&1, table_refs, opts))
      ]
      |> List.flatten()
      |> Enum.join("\n")

    indexes = Enum.map_join(table_refs, "\n", &index_line(&1, table_str, opts))
    index_section = if indexes == "", do: "", else: "\n" <> indexes

    "# migration\n" <>
      "defmodule #{module} do\n" <>
      "  use Ecto.Migration\n\n" <>
      "  def change do\n" <>
      "    create table(#{quoted(table_str)}, primary_key: false) do\n" <>
      add_lines <>
      "\n    end" <>
      index_section <>
      "\n  end\n" <>
      "end"
  end

  defp pk_add_line(column, opts) do
    "      add :#{field_name(column, opts)}, :string, primary_key: true"
  end

  # Reference columns add their FK column (`<field>_id`, `:string`); all others
  # add their own field with the mapped Ecto type.
  defp add_line(column, table_refs, opts) do
    case Enum.find(table_refs, fn {from, _to, _dir} -> from.id == column.id end) do
      nil -> "      add :#{field_name(column, opts)}, #{ecto_type(column.type)}"
      {from, _to, _dir} -> "      add :#{fk_column(from, opts)}, :string"
    end
  end

  defp index_line({from, _to, _dir}, table_str, opts) do
    "    create index(#{quoted(table_str)}, [:#{fk_column(from, opts)}])"
  end

  # Type mapping (IR -> Ecto) ---------------------------------------------------

  defp ecto_type(%{is_array: true} = type), do: "{:array, #{base_type(type)}}"
  defp ecto_type(type), do: base_type(type)

  defp base_type(%{type: :reference}), do: ":string"
  defp base_type(%{type: :enum}), do: ":string"
  defp base_type(%{type: :api}), do: ":string"
  defp base_type(%{type: :custom, custom_type: "bubble_image"}), do: ":string"
  defp base_type(%{type: :custom, custom_type: "bubble_file"}), do: ":string"
  defp base_type(%{type: :custom}), do: ":map"
  defp base_type(%{type: :utc_datetime_usec}), do: ":utc_datetime_usec"
  defp base_type(%{type: :boolean}), do: ":boolean"
  defp base_type(%{type: :float}), do: ":float"
  defp base_type(%{type: :string}), do: ":string"
  defp base_type(_type), do: ":string"

  # Naming ----------------------------------------------------------------------

  defp namespace(opts), do: Keyword.get(opts, :namespace, @default_namespace)

  # :proper (default) derives from display names; :id uses the Bubble ids.
  defp module_name(table, opts), do: pascal_case(by_naming(opts, table.name, table.id))

  defp ref_module_name(column, opts),
    do: pascal_case(by_naming(opts, column.table_name, column.table_id))

  defp table_name(table, opts), do: snake_case(by_naming(opts, table.name, table.id))

  # Field names preserve a single leading underscore so Bubble's `_id` primary
  # key keeps its conventional name (`snake_case/1` alone would drop it).
  defp field_name(column, opts) do
    value = to_string(by_naming(opts, column.name, column.id))

    if String.starts_with?(value, "_") do
      "_" <> snake_case(value)
    else
      snake_case(value)
    end
  end

  defp by_naming(opts, proper, id) do
    case Keyword.get(opts, :naming, :proper) do
      :id -> id
      _ -> proper
    end
  end

  # Splits a free-form Bubble label/id into lowercase word tokens. Non-alphanumeric
  # runs are separators, and case boundaries (camelCase) start new words.
  defp tokens(value) do
    value
    |> to_string()
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.split(~r/[^A-Za-z0-9]+/, trim: true)
    |> Enum.map(&String.downcase/1)
  end

  defp pascal_case(value) do
    value
    |> tokens()
    |> Enum.map_join("", &String.capitalize/1)
    |> fallback("Table")
  end

  defp snake_case(value) do
    value
    |> tokens()
    |> Enum.join("_")
    |> fallback("field")
  end

  defp fallback("", default), do: default
  defp fallback(value, _default), do: value

  # Renders a string as an Elixir double-quoted literal. Plain quotes are used
  # (never the ~s sigil) so that any parentheses in the value compile cleanly.
  defp quoted(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end
end
