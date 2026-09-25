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

  defstruct tables: %{}, columns: %{}, extra: %{}, suffixed: [], truncated: []

  @type variants() :: (pos_integer() -> [term()])
  @type item() :: {:table | :column, map(), [term()], [term()]}
  @type t() :: %__MODULE__{
          tables: %{{atom(), String.t()} => [term()]},
          columns: %{{atom(), String.t(), String.t()} => [term()]},
          extra: %{term() => [term()]},
          suffixed: [item()],
          truncated: [{:table | :column, map(), String.t(), [term()]}]
        }

  @doc """
  Assigns the names of `tables` (Reader tables; deleted columns are
  skipped). Options:

    * `:table` (required) - `fn table -> variants end`, the names a table
      needs for its `n`th variant (`BubbleEx.Db.Naming.dedupe/2`), or
      `{variants, uncut}` when the variants are cut to a maximum length
      (`uncut` is the first name before the cut; a cut is reported)
    * `:column` - the same for a column; without it columns keep the names
      the encoder gives them (it does not convert them)
    * `:reserved` - names already taken in the table scope
    * `:extra` - `fn names -> [{key, variants}] end`, more names claimed in
      the table scope once tables and columns have theirs (e.g. Ecto index
      names, which PostgreSQL keeps in the tables' namespace); read them
      with `extra/2`
  """
  @spec build([map()], keyword()) :: t()
  def build(tables, spec) do
    table_spec = Keyword.fetch!(spec, :table)
    column_spec = Keyword.get(spec, :column)
    table_items = Enum.map(tables, &{:table, table_key(&1), &1, table_spec.(&1)})

    {table_names, table_suffixed} =
      claim(table_items, Keyword.get(spec, :reserved, []))

    {columns, column_items, column_suffixed} =
      if column_spec,
        do: columns(tables, column_spec),
        else: {%{}, [], []}

    names = %__MODULE__{
      tables: table_names,
      columns: columns,
      suffixed: table_suffixed ++ column_suffixed,
      truncated: truncated(table_items, table_names) ++ truncated(column_items, columns)
    }

    case Keyword.get(spec, :extra) do
      nil ->
        names

      extra ->
        used = Keyword.get(spec, :reserved, []) ++ Enum.concat(Map.values(table_names))
        {extra_names, _suffixed} = extra.(names) |> Naming.dedupe(used)
        %{names | extra: extra_names}
    end
  end

  defp claim(items, reserved) do
    by_key = Map.new(items, fn {scope, key, item, _spec} -> {key, {scope, item}} end)

    {names, suffixed} =
      items
      |> Enum.map(fn {_scope, key, _item, spec} -> {key, variants(spec)} end)
      |> Naming.dedupe(reserved)

    {names,
     Enum.map(suffixed, fn {key, first, chosen} ->
       {scope, item} = Map.fetch!(by_key, key)
       {scope, item, first, chosen}
     end)}
  end

  defp variants({variants, _uncut}), do: variants
  defp variants(variants), do: variants

  # Items whose first name was cut: `{scope, item, uncut, names}`.
  defp truncated(items, names) do
    for {scope, key, item, {variants, uncut}} <- items,
        primary(variants.(1)) != uncut,
        do: {scope, item, uncut, Map.fetch!(names, key)}
  end

  defp columns(tables, column_spec) do
    Enum.reduce(tables, {%{}, [], []}, fn table, {names, all_items, suffixed} ->
      {builtin, rest} =
        table.columns
        |> Enum.reject(& &1.deleted)
        |> Enum.split_with(&(&1.primary_key or Map.get(&1, :system) != nil))

      items = Enum.map(builtin ++ rest, &{:column, column_key(&1), &1, column_spec.(&1)})
      {table_names, table_suffixed} = claim(items, [])

      {Map.merge(names, table_names), all_items ++ items, suffixed ++ table_suffixed}
    end)
  end

  @doc "The names `build/2`'s `:extra` claimed for `key`, or nil."
  @spec extra(t(), term()) :: [term()] | nil
  def extra(%__MODULE__{extra: extra}, key), do: Map.get(extra, key)

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
  per table or column that did not keep its first name, and one
  `:db_converted_name_truncated` per table or column whose name was cut to
  the target's maximum length.
  """
  @spec diagnostics(t(), atom()) :: [Diagnostic.t()]
  def diagnostics(%__MODULE__{suffixed: suffixed, truncated: truncated}, format) do
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
    end) ++
      Enum.map(truncated, fn {scope, item, uncut, chosen} ->
        rendered = primary(chosen)

        Diagnostic.new(
          :db_converted_name_truncated,
          path(scope, item),
          "#{scope} name #{inspect(uncut)} is longer than the target allows; rendered as #{inspect(rendered)}",
          target: format,
          subject: subject(scope, item),
          details: %{
            name: uncut,
            rendered: rendered,
            length: String.length(uncut),
            scope: Atom.to_string(scope)
          }
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
