defmodule BubbleEx.Db.Sql.Postgres do
  @moduledoc """
  Encodes a parsed Bubble database map (see `BubbleEx.Db.Reader`) into PostgreSQL
  DDL: a `CREATE SCHEMA` per table group, a `CREATE TABLE` (columns + primary key)
  per table, and an `ALTER TABLE ... ADD FOREIGN KEY` per scalar reference.

  List/array references become native array columns (`text[]`) with no foreign-key
  constraint, mirroring how Bubble stores lists of ids on the record.
  """

  @behaviour BubbleEx.Db.Encoder

  @type opts :: [naming: :proper | :id | nil]

  @impl true
  @spec encode(map(), opts()) :: {:ok, String.t()}
  def encode(parsed_map, opts \\ []) do
    plan =
      Keyword.get_lazy(opts, :_external_plan, fn ->
        BubbleEx.Db.Encoder.Plan.build(parsed_map, opts)
      end)

    opts = Keyword.put(opts, :_external_plan, plan)

    tables =
      parsed_map
      |> Map.get(:tables, [])
      |> Enum.reject(&(&1.group == :api))

    sections =
      [
        encode_schemas(tables),
        encode_external_types(parsed_map, opts),
        Enum.map_join(tables, "\n\n", &encode_table(&1, opts)),
        encode_foreign_keys(parsed_map, opts)
      ]
      |> Enum.reject(&(&1 == ""))

    {:ok, Enum.join(sections, "\n\n") <> "\n"}
  end

  defp encode_schemas(tables) do
    tables
    |> Enum.map(& &1.group)
    |> Enum.uniq()
    |> Enum.map_join("\n", fn group ->
      ~s(CREATE SCHEMA IF NOT EXISTS #{quote_ident(to_string(group))};)
    end)
  end

  defp encode_table(table, opts) do
    columns = Enum.reject(table.columns, & &1.deleted)

    column_lines =
      Enum.map_join(columns, ",\n", fn column ->
        ~s(  #{quote_ident(column_name(column, opts))} #{which_type(column.type, opts)})
      end)

    pk_line =
      case Enum.find(columns, & &1.primary_key) do
        nil -> ""
        pk -> ",\n  PRIMARY KEY (#{quote_ident(column_name(pk, opts))})"
      end

    "CREATE TABLE #{qualified_table(table.group, table_name(table, opts))} (\n" <>
      column_lines <> pk_line <> "\n);"
  end

  defp encode_foreign_keys(parsed_map, opts) do
    parsed_map
    |> Map.get(:relationships, [])
    |> Enum.filter(fn {from, to, _dir} ->
      from != nil and to != nil and not from.deleted and not to.deleted and
        Map.get(from.type, :is_array) != true
    end)
    |> Enum.map_join("\n", fn {from, to, _dir} -> encode_fk(from, to, opts) end)
  end

  defp encode_fk(from, to, opts) do
    "ALTER TABLE #{qualified_table(from.table_group, ref_table_name(from, opts))} " <>
      "ADD FOREIGN KEY (#{quote_ident(column_name(from, opts))}) " <>
      "REFERENCES #{qualified_table(to.table_group, ref_table_name(to, opts))} " <>
      "(#{quote_ident(column_name(to, opts))});"
  end

  # Type mapping (IR -> Postgres) ------------------------------------------------

  defp which_type(%{type: :external, target: target, cardinality: cardinality}, opts) do
    base =
      case Keyword.get(opts, :external_types, :legacy) do
        :preserve ->
          if(BubbleEx.Db.Encoder.Plan.resolved?(plan(opts), target),
            do: quote_ident(external_name(target, opts)),
            else: "jsonb"
          )

        :opaque ->
          "jsonb"

        :legacy ->
          "text"
      end

    if cardinality == :many and base != "jsonb", do: base <> "[]", else: base
  end

  defp which_type(%{type: :opaque_external}, _opts), do: "jsonb"
  defp which_type(%{is_array: true} = type, _opts), do: base_type(type) <> "[]"
  defp which_type(type, _opts), do: base_type(type)

  defp encode_external_types(_parsed_map, opts) do
    if Keyword.get(opts, :external_types, :legacy) == :preserve do
      plan = plan(opts)

      plan.order
      |> Enum.map(&Map.fetch!(plan.nodes, &1))
      |> Enum.map_join("\n", fn external ->
        fields =
          Enum.map_join(
            external.fields,
            ",\n",
            &"  #{quote_ident(BubbleEx.Db.Encoder.Plan.field_name(plan, external.id, &1))} #{external_field_type(&1, external.id, opts)}"
          )

        "CREATE TYPE #{quote_ident(external_name(external.id, opts))} AS (\n#{fields}\n);"
      end)
    else
      ""
    end
  end

  defp external_field_type(
         %{type: %{type: :scalar, scalar: scalar, cardinality: cardinality}},
         _parent,
         _opts
       ) do
    base =
      %{
        text: "text",
        number: "double precision",
        boolean: "boolean",
        date: "timestamptz",
        date_unix: "bigint"
      }[scalar]

    if cardinality == :many, do: base <> "[]", else: base
  end

  defp external_field_type(
         %{id: field_id, type: %{type: :external, target: target, cardinality: cardinality}},
         parent,
         opts
       ) do
    plan = plan(opts)

    if BubbleEx.Db.Encoder.Plan.cycle_edge?(plan, parent, field_id) or
         not BubbleEx.Db.Encoder.Plan.resolved?(plan, target) do
      "jsonb"
    else
      base = quote_ident(external_name(target, opts))
      if cardinality == :many, do: base <> "[]", else: base
    end
  end

  defp external_field_type(_, _, _), do: "jsonb"

  defp external_name(id, opts), do: BubbleEx.Db.Encoder.Plan.name(plan(opts), id)
  defp plan(opts), do: Keyword.fetch!(opts, :_external_plan)

  defp base_type(%{type: :reference}), do: "text"
  defp base_type(%{type: :enum}), do: "text"
  defp base_type(%{type: :api}), do: "text"
  defp base_type(%{type: :custom, custom_type: "bubble_image"}), do: "text"
  defp base_type(%{type: :custom, custom_type: "bubble_file"}), do: "text"
  defp base_type(%{type: :custom}), do: "jsonb"
  defp base_type(%{type: :utc_datetime_usec}), do: "timestamptz"
  defp base_type(%{type: :boolean}), do: "boolean"
  defp base_type(%{type: :float}), do: "double precision"
  defp base_type(%{type: :string}), do: "text"
  defp base_type(_type), do: "text"

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

  defp qualified_table(group, name),
    do: ~s(#{quote_ident(to_string(group))}.#{quote_ident(name)})

  defp quote_ident(name) do
    ~s("#{String.replace(name, ~s("), ~s(""))}")
  end
end
