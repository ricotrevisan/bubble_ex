defmodule BubbleEx.Db.Dbml do
  @moduledoc """
  Encodes a parsed Bubble database map (see `BubbleEx.Db.Reader`) into DBML
  (Database Markup Language) text.
  """

  @behaviour BubbleEx.Db.Encoder

  @type opts :: [
          project_note: String.t() | nil,
          naming: :proper | :id | nil
        ]

  @impl true
  @spec encode(map(), opts()) :: {:ok, String.t()}
  def encode(parsed_map, opts \\ []) do
    project_note = Keyword.get(opts, :project_note)

    tables = Map.get(parsed_map, :tables)

    tables_dbml =
      tables
      |> Enum.reduce("", fn table, acc ->
        acc <> encode_table(table, opts)
      end)

    references_dbml = encode_relationships(parsed_map, opts)
    dbml = tables_dbml <> references_dbml

    project_specs =
      """
      Project "#{parsed_map.bubble_id}" {
        database_type: "Bubble.io"
        Note: '''
          bubble-to-dbml generator by rico.wtf#{if project_note, do: "\n#{project_note}"}
        '''
      }

      """

    dbml = project_specs <> dbml

    {:ok, dbml}
  end

  defp encode_table(table, opts) do
    naming = Keyword.get(opts, :naming, :proper)

    columns =
      table
      |> Map.get(:columns)
      |> Enum.reject(& &1.deleted)
      |> Enum.reduce("", fn column, acc ->
        acc <> encode_column(column, opts)
      end)

    table_name =
      case naming do
        :proper -> ~s("#{table.name}")
        :id -> quote_identifier(table.id)
      end

    ~s(Table #{to_string(table.group)}.#{table_name} {\n) <>
      columns <>
      "\n}\n"
  end

  defp encode_column(column, opts) do
    naming = Keyword.get(opts, :naming, :proper)

    type = which_type(column.type)
    settings = if column.primary_key, do: " [pk]", else: nil

    column_name =
      case naming do
        :proper -> ~s("#{column.name}")
        :id -> quote_identifier(column.id)
      end

    ~s(\t#{column_name} #{type}#{settings}\n)
  end

  defp encode_relationships(parsed_map, opts) do
    relationships =
      Map.get(parsed_map, :relationships)
      |> Enum.filter(fn {from, to, _} ->
        from != nil and to != nil
      end)
      |> Enum.reject(fn {from, to, _} ->
        from.deleted or to.deleted
      end)

    relationships
    |> Enum.reduce("", fn relationship, acc ->
      acc <> encode_relationship(relationship, opts)
    end)
  end

  defp encode_relationship({from, to, direction}, opts) do
    naming = Keyword.get(opts, :naming, :proper)

    # reference format
    # "Ref name_optional: schema1.table1.column1 < schema2.table2.column2"
    direction = which_direction(direction)

    {from_table, from_column, to_table, to_column} =
      case naming do
        :proper ->
          {
            ~s("#{from.table_name}"),
            ~s("#{from.name}"),
            ~s("#{to.table_name}"),
            ~s("#{to.name}")
          }

        :id ->
          {
            quote_identifier(from.table_id),
            quote_identifier(from.id),
            quote_identifier(to.table_id),
            quote_identifier(to.id)
          }
      end

    "\nRef: " <>
      ~s(#{to_string(from.table_group)}.#{from_table}.#{from_column}) <>
      direction <>
      ~s(#{to_string(to.table_group)}.#{to_table}.#{to_column})
  end

  # Arrays render as their scalar type plus "[]", so the two stay consistent.
  defp which_type(%{is_array: true} = type),
    do: which_type(Map.delete(type, :is_array)) <> "[]"

  defp which_type(%{type: :enum} = type), do: type.custom_type <> ".id"
  defp which_type(%{type: :api} = type), do: "api." <> ~s("#{type.custom_type}")
  defp which_type(%{type: :reference} = type), do: type.custom_type <> ".id"
  defp which_type(%{type: :custom, custom_type: custom_type}), do: custom_type
  defp which_type(%{type: :utc_datetime_usec}), do: "datetime"
  defp which_type(%{type: :boolean}), do: "bool"
  defp which_type(%{type: :string}), do: "varchar"
  defp which_type(type), do: to_string(type.type)

  defp which_direction(:many_to_one), do: " > "
  defp which_direction(:many_to_many), do: " <> "
  defp which_direction(:one_to_many), do: " < "
  defp which_direction(:one_to_one), do: " - "
  defp which_direction(_), do: " - "

  @doc """
  Quotes a DBML identifier if it contains characters that are not safe to use
  unquoted (anything outside `[a-zA-Z0-9_]`). Returns the identifier unchanged
  when it is already safe.
  """
  @spec quote_identifier(String.t()) :: String.t()
  def quote_identifier(str) do
    if String.match?(str, ~r/[^a-zA-Z0-9_]/) do
      ~s("#{str}")
    else
      str
    end
  end
end
