defmodule BubbleEx.Db.Encoder.Names do
  @moduledoc """
  The names an encoder derives from display names (or Bubble IDs) by case
  conversion, unique in every scope (WTF-391). This is the single decision
  point for the converting encoders: `BubbleEx.Db.Ecto` (snake_case fields,
  `<field>_id` foreign keys, snake_case tables, PascalCase modules),
  `BubbleEx.Db.Convex` (camelCase), `BubbleEx.Db.Xano` (snake_case) and
  `BubbleEx.Db.Zod` (PascalCase schema consts and types).

  The Reader's names are unique case-insensitively, but conversion can merge
  them again: `Created Date` and a field `created_date`, or `Created-By` and
  `Created By`, both become `created_date` / `createdBy`, and a field
  `created_by_id` becomes the foreign key of the built-in `Created By`.

  Rules (`build/2`):

    * Scopes: table names across the rendered tables; column names within one
      table. `:reserved` names are taken in the table scope from the start.
    * Tables claim their names in Reader order (data types, then option sets,
      each in Bubble ID order). Within a table the key and built-in columns
      (primary key, `Display`, `Created Date`, `Created By`, ...) claim first,
      then the other columns in Reader order (Bubble ID order). So a
      built-in field always keeps its name, and a user field repeating a
      name gets a suffix.
    * Everything a table or column needs is claimed together: an Ecto
      reference claims its association and its foreign key column, so the
      suffixed pair is `created_by_2` / `created_by_2_id`.
    * An item that cannot take its first variant takes the first free
      `variant/4` (`_2`, `_3`, ... or `2`, `3`, ... by format) and is
      reported by `diagnostics/2` as `:db_converted_name_suffixed`.
  """

  alias BubbleEx.Db.Naming
  alias BubbleEx.Diagnostic

  defstruct tables: %{}, columns: %{}, suffixed: []

  @type variants() :: (pos_integer() -> [term()])
  @type t() :: %__MODULE__{
          tables: %{{atom(), String.t()} => [term()]},
          columns: %{{atom(), String.t(), String.t()} => [term()]},
          suffixed: [{:table | :column, map(), [term()], [term()]}]
        }

  @doc """
  Assigns the names of `tables` (Reader tables; deleted columns are
  skipped). Options:

    * `:table` (required) - `fn table -> variants end`, the names a table
      needs for its `n`th variant (`BubbleEx.Db.Naming.dedupe/2`)
    * `:column` - `fn column -> variants end`; without it columns keep the
      names the encoder gives them (it does not convert them)
    * `:reserved` - names already taken in the table scope
  """
  @spec build([map()], keyword()) :: t()
  def build(tables, spec) do
    table_variants = Keyword.fetch!(spec, :table)
    column_variants = Keyword.get(spec, :column)

    {table_names, table_suffixed} =
      tables
      |> Enum.map(&{table_key(&1), table_variants.(&1)})
      |> Naming.dedupe(Keyword.get(spec, :reserved, []))

    by_key = Map.new(tables, &{table_key(&1), &1})

    {columns, column_suffixed} =
      if column_variants,
        do: columns(tables, column_variants),
        else: {%{}, []}

    suffixed =
      Enum.map(table_suffixed, fn {key, first, chosen} ->
        {:table, Map.fetch!(by_key, key), first, chosen}
      end) ++ column_suffixed

    %__MODULE__{tables: table_names, columns: columns, suffixed: suffixed}
  end

  defp columns(tables, column_variants) do
    Enum.reduce(tables, {%{}, []}, fn table, {names, suffixed} ->
      {builtin, rest} =
        table.columns
        |> Enum.reject(& &1.deleted)
        |> Enum.split_with(&(&1.primary_key or Map.get(&1, :system) != nil))

      ordered = builtin ++ rest
      by_key = Map.new(ordered, &{column_key(&1), &1})

      {table_names, table_suffixed} =
        ordered
        |> Enum.map(&{column_key(&1), column_variants.(&1)})
        |> Naming.dedupe()

      table_suffixed =
        Enum.map(table_suffixed, fn {key, first, chosen} ->
          {:column, Map.fetch!(by_key, key), first, chosen}
        end)

      {Map.merge(names, table_names), suffixed ++ table_suffixed}
    end)
  end

  @doc """
  The names of a table, given the table or any of its columns (e.g. the
  target of a reference), or nil when `build/2` did not see it.
  """
  @spec table(t(), map()) :: [term()] | nil
  def table(%__MODULE__{tables: tables}, table_or_column),
    do: Map.get(tables, table_key(table_or_column))

  @doc "The names of a column, or nil when `build/2` did not see it."
  @spec column(t(), map()) :: [term()] | nil
  def column(%__MODULE__{columns: columns}, column), do: Map.get(columns, column_key(column))

  @doc """
  One `:db_converted_name_suffixed` diagnostic (stage `{:target, format}`)
  per table or column that did not keep its first name.
  """
  @spec diagnostics(t(), atom()) :: [Diagnostic.t()]
  def diagnostics(%__MODULE__{suffixed: suffixed}, format) do
    Enum.map(suffixed, fn {scope, item, first, chosen} ->
      name = primary(first)
      rendered = primary(chosen)

      Diagnostic.new(
        :db_converted_name_suffixed,
        path(scope, item),
        "#{scope} name #{inspect(name)} is taken after conversion (by an earlier #{scope} or a reserved name); rendered as #{inspect(rendered)}",
        target: format,
        subject: subject(scope, item),
        details: %{name: name, rendered: rendered, scope: Atom.to_string(scope)}
      )
    end)
  end

  defp primary([{_namespace, name} | _]), do: name
  defp primary([name | _]), do: name

  defp table_key(%{table_group: group, table_id: id}), do: {group, id}
  defp table_key(%{group: group, id: id}), do: {group, id}

  defp column_key(column), do: {column.table_group, column.table_id, column.id}

  defp path(:column, column), do: Map.get(column, :source_path) || table_path(table_key(column))
  defp path(:table, table), do: table_path(table_key(table))

  defp table_path({:option, id}), do: Diagnostic.pointer(["option_sets", id])
  defp table_path({_group, id}), do: Diagnostic.pointer(["user_types", id])

  defp subject(:table, %{group: :option, id: id}), do: %{option_set: id}
  defp subject(:table, %{id: id}), do: %{type: id}

  defp subject(:column, %{table_group: :option} = column),
    do: %{option_set: column.table_id, field: column.id}

  defp subject(:column, column), do: %{type: column.table_id, field: column.id}
end
