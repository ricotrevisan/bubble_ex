defmodule BubbleEx.Db.Reader do
  @moduledoc """
  The table view of an app's data that the `BubbleEx.Db.Encoder`s render
  (DBML, SQL, Ecto, Zod, Xano, Convex): a projection of `BubbleEx.Model`.

      {:ok, db_map} = BubbleEx.Db.Reader.parse(app)
      # or, from a Model already built:
      db_map = BubbleEx.Db.Reader.project(model, app)

  The Reader does not read data types, fields, option sets or API Connector
  types itself: `BubbleEx.Model` is the one interpretation, and this module
  only selects and reshapes it.

  ## Projection

    * A table per data type (group `:custom`) and per option set (group
      `:option`) that is neither deleted nor malformed (`raw`). User is always
      present, as in the Model (a source without one gets Bubble's built-in
      User).
    * Custom tables get a `_id` primary-key column (Bubble's unique id).
      Option tables get a `db_value` primary-key column (the value's stable
      key, `BubbleEx.Model.OptionValue.key`) and a `display` column (its
      display text), then the declared attributes.
    * Deleted and malformed fields and attributes are left out. A declared
      field whose Bubble ID is a primary-key or `display` column's is left
      out too (the injected column stands for it).
    * `values` are an option set's values that are not deleted, in the
      Model's order (`sort_factor`, then Bubble ID), with `db_value` holding
      the stable key.
    * Order is the Model's: data types, then option sets, each in Bubble ID
      order; within a table the injected columns come first, then fields in
      Bubble ID order. Relationships follow column order.
    * A display name the source does not supply falls back to the Bubble ID.
      Names stay usable as SQL identifiers: table names are unique across
      all tables and column names within a table, case-insensitively and
      never a key column's; a repeat gets the first free `_2`, `_3`, ...
      suffix, in Bubble ID order (data types before option sets).
    * An option value repeating an earlier value's stable key is left out of
      `values`, so `db_value` stays a key.
    * `external_types` are the API Connector types reachable from the
      projected columns.
    * `diagnostics` are the Model's diagnostics about the tables: stages
      `:read` and `:model`, and the privacy parse's type-level
      `:malformed_node` / `:uninterpreted_field`, not privacy-rule or
      expression ones. `projection_diagnostics` are what the projection itself
      changed (`:db_name_suffixed`, `:db_duplicate_option_value_dropped`,
      `:db_reference_to_omitted`); `BubbleEx.Db.Encoder.render/3` emits them
      at stage `{:target, format}`.

  ## Column types

  | Model `Type` | column type |
  |---|---|
  | scalar text / number / boolean / date | `:string` / `:float` / `:boolean` / `:utc_datetime_usec` |
  | file_ref image / file | `:custom` `bubble_image` / `bubble_file` |
  | structured | `:custom` `bubble_geo_address`, `bubble_date_range`, `bubble_number_range`, `bubble_dateinterval` |
  | ref | `:reference` with `custom_type` the target data type |
  | option | `:enum` with `custom_type` the target option set |
  | external | `:external` (see `external_value/0`) |
  | opaque | `:opaque_external` |
  | unknown | `:unsupported`, `raw` the descriptor as supplied |

  A list (`cardinality: :many`) sets `is_array: true`.
  """

  alias BubbleEx.{Diagnostic, Error, Model}
  alias BubbleEx.Model.{DataType, ExternalType, Field, OptionSet, Type}
  alias BubbleEx.Model.External.Resolver

  @type table_group() :: :custom | :option

  @type external_value() ::
          %{type: :scalar, scalar: atom(), cardinality: :one | :many, raw: String.t()}
          | %{
              type: :external,
              target: String.t(),
              cardinality: :one | :many,
              raw: String.t()
            }
          | %{
              type: :opaque_external,
              target: nil,
              cardinality: :one | :many | :unknown,
              raw: term()
            }

  @type column_type() ::
          %{
            required(:type) =>
              :string
              | :float
              | :boolean
              | :utc_datetime_usec
              | :custom
              | :reference
              | :enum
              | :unsupported,
            optional(:custom_type) => String.t(),
            optional(:is_array) => true,
            optional(:raw) => term()
          }
          | external_value()

  @type column() :: %{
          table_id: String.t(),
          table_name: String.t(),
          table_group: table_group(),
          id: String.t(),
          name: String.t(),
          type: column_type(),
          primary_key: boolean(),
          deleted: false,
          default: term(),
          source_path: String.t() | nil
        }

  @type relationship_direction() :: :many_to_one | :many_to_many
  @type relationship() :: {column(), column() | nil, relationship_direction()}
  @type option_value() :: %{id: String.t(), name: String.t() | nil, db_value: String.t()}
  @type table() :: %{
          id: String.t(),
          name: String.t(),
          group: table_group(),
          columns: [column()],
          values: [option_value()]
        }

  @typedoc """
  A diagnostic the projection records for `BubbleEx.Db.Encoder.render/3` to
  emit at stage `{:target, format}`: the arguments of `BubbleEx.Diagnostic.new/4`
  without the target.
  """
  @type projection_diagnostic() :: {atom(), String.t(), String.t(), keyword()}

  @type db_map() :: %{
          bubble_id: String.t() | nil,
          tables: [table()],
          relationships: [relationship()],
          external_types: [map()],
          diagnostics: [Diagnostic.t()],
          projection_diagnostics: [projection_diagnostic()]
        }

  # Primary-key column IDs, matched when resolving references.
  @custom_pk "_id"
  @option_pk "db_value"
  @option_display "display"

  @structured %{
    geographic_address: "bubble_geo_address",
    date_range: "bubble_date_range",
    number_range: "bubble_number_range",
    date_interval: "bubble_dateinterval"
  }

  @scalars %{text: :string, number: :float, boolean: :boolean, date: :utc_datetime_usec}

  @doc """
  Builds the `BubbleEx.Model` from decoded app JSON (either key form) and
  projects it (`project/2`). Malformed input is preserved and diagnosed by
  the Model, never a crash; input that is not a JSON object is an
  `:invalid_input` error.
  """
  @spec parse(term()) :: {:ok, db_map()} | {:error, Error.t()}
  def parse(app) do
    with {:ok, model} <- Model.build(app), do: {:ok, project(model, app)}
  end

  @doc """
  Projects a `BubbleEx.Model` into the table view. `source`, the app JSON the
  Model was built from, only locates each column's type descriptor
  (`source_path`); without it `source_path` is the field's own pointer.
  """
  @spec project(Model.t(), map()) :: db_map()
  def project(%Model{} = model, source \\ %{}) do
    defs =
      for(%DataType{deleted: false, raw: nil} = t <- model.data_types, do: {:custom, t}) ++
        for %OptionSet{deleted: false, raw: nil} = s <- model.option_sets, do: {:option, s}

    {named, _taken, name_notes} =
      Enum.reduce(defs, {[], MapSet.new(), []}, fn {group, def}, {acc, taken, notes} ->
        {name, taken, notes} = claim(def.name || def.id, taken, notes, name_note(group, def))
        {[{group, def, name} | acc], taken, notes}
      end)

    {tables, table_notes} =
      named |> Enum.reverse() |> Enum.map(&table(&1, source)) |> Enum.unzip()

    columns = Enum.flat_map(tables, & &1.columns)
    pks = for c <- columns, c.primary_key, into: %{}, do: {{c.table_group, c.table_id}, c}
    {relationships, relationship_notes} = relationships(columns, pks, omitted(model))

    %{
      bubble_id: model.bubble_id,
      tables: tables,
      relationships: relationships,
      external_types: external_types(model.external_types, columns),
      diagnostics: Enum.filter(model.diagnostics, &relevant?/1),
      projection_diagnostics:
        Enum.reverse(name_notes) ++ List.flatten(table_notes) ++ relationship_notes
    }
  end

  # The Model's diagnostics about what the tables show: API Connector types
  # (`:read`), data types, fields and option sets (`:model`), and data types
  # that are malformed or carry unexpected members (the privacy parse's
  # type-level `:parse` codes). Privacy-rule and expression diagnostics are
  # not about the tables.
  defp relevant?(%Diagnostic{stage: stage}) when stage in [:read, :model], do: true

  defp relevant?(%Diagnostic{stage: :parse, code: code, subject: subject, path: path})
       when code in [:malformed_node, :uninterpreted_field] do
    Map.keys(subject) == [:type] and not String.contains?(path, "/privacy_role")
  end

  defp relevant?(_diagnostic), do: false

  # Definitions the Model has but the tables leave out (deleted or malformed).
  defp omitted(model) do
    (for(%DataType{} = t <- model.data_types, t.deleted or not is_nil(t.raw), do: {:custom, t.id}) ++
       for(
         %OptionSet{} = s <- model.option_sets,
         s.deleted or not is_nil(s.raw),
         do: {:option, s.id}
       ))
    |> MapSet.new()
  end

  # --- tables ------------------------------------------------------------------

  defp table({:custom, %DataType{} = type, name}, source) do
    table = %{id: type.id, name: name, group: :custom}

    {columns, notes} =
      columns(table, [injected(table, @custom_pk, "_id", type.path)], type.fields, source)

    {Map.merge(table, %{columns: columns, values: []}), notes}
  end

  defp table({:option, %OptionSet{} = set, name}, source) do
    table = %{id: set.id, name: name, group: :option}

    keys = [
      injected(table, @option_pk, "db_value", set.path),
      %{injected(table, @option_display, "Display", set.path) | primary_key: false}
    ]

    {columns, column_notes} = columns(table, keys, set.attributes, source)
    {values, value_notes} = values(set)
    {Map.merge(table, %{columns: columns, values: values}), column_notes ++ value_notes}
  end

  # The option set's values that are not deleted, one per stable key: a value
  # repeating an earlier value's key (in the Model's order) is left out, so
  # `db_value` stays a key.
  defp values(set) do
    {values, _keys, notes} =
      Enum.reduce(set.values, {[], MapSet.new(), []}, fn
        %{deleted: false, raw: nil} = value, {acc, keys, notes} ->
          if MapSet.member?(keys, value.key) do
            note =
              {:db_duplicate_option_value_dropped, value.path,
               "option value #{inspect(value.id)} repeats the key #{inspect(value.key)}; left out of the table's values",
               subject: %{option_set: set.id}, details: %{value: value.id, key: value.key}}

            {acc, keys, [note | notes]}
          else
            row = %{id: value.id, name: value.name, db_value: value.key}
            {[row | acc], MapSet.put(keys, value.key), notes}
          end

        _value, acc ->
          acc
      end)

    {Enum.reverse(values), Enum.reverse(notes)}
  end

  defp injected(table, id, name, path) do
    %{
      table_id: table.id,
      table_name: table.name,
      table_group: table.group,
      id: id,
      name: name,
      type: %{type: :string},
      primary_key: true,
      deleted: false,
      default: nil,
      source_path: path
    }
  end

  # The injected key columns, then the live fields in Bubble ID order. A field
  # whose Bubble ID is a key column's is left out (the key stands for it). A
  # field whose display name repeats an earlier column's, case-insensitively
  # (SQL identifiers are), gets the first free `_2`, `_3`, ... suffix.
  defp columns(table, keys, fields, source) do
    key_ids = Enum.map(keys, & &1.id)
    taken = MapSet.new(keys, &fold(&1.name))

    {columns, _taken, notes} =
      for(%Field{deleted: false, raw: nil} = f <- fields, f.id not in key_ids, do: f)
      |> Enum.reduce({[], taken, []}, fn field, {acc, taken, notes} ->
        subject = subject(table.group, table.id, field.id)
        note = &name_note(&1, &2, field.path, subject, "field")
        {name, taken, notes} = claim(field.name || field.id, taken, notes, note)
        {[column(table, field, name, source) | acc], taken, notes}
      end)

    {keys ++ Enum.reverse(columns), Enum.reverse(notes)}
  end

  defp column(table, field, name, source) do
    %{
      table_id: table.id,
      table_name: table.name,
      table_group: table.group,
      id: field.id,
      name: name,
      type: column_type(field.type),
      primary_key: false,
      deleted: false,
      default: field.default,
      source_path:
        Resolver.descriptor_pointer(source, table.group, table.id, field.id) || field.path
    }
  end

  defp subject(:custom, owner, field), do: %{type: owner, field: field}
  defp subject(:option, owner, field), do: %{option_set: owner, field: field}

  # Claims `name` against `taken` (case-folded names): the name itself, or
  # the first free `name_2`, `name_3`, ... A suffixed name adds
  # `note.(name, claimed)` to `notes`.
  defp claim(name, taken, notes, note) do
    if MapSet.member?(taken, fold(name)) do
      claimed =
        2
        |> Stream.iterate(&(&1 + 1))
        |> Stream.map(&"#{name}_#{&1}")
        |> Enum.find(&(not MapSet.member?(taken, fold(&1))))

      {claimed, MapSet.put(taken, fold(claimed)), [note.(name, claimed) | notes]}
    else
      {name, MapSet.put(taken, fold(name)), notes}
    end
  end

  defp fold(name), do: String.downcase(name)

  defp name_note(group, def) do
    subject = if group == :custom, do: %{type: def.id}, else: %{option_set: def.id}
    &name_note(&1, &2, def.path, subject, "table")
  end

  defp name_note(name, claimed, path, subject, scope) do
    {:db_name_suffixed, path,
     "#{scope} name #{inspect(name)} repeats an earlier #{scope}'s; rendered as #{inspect(claimed)}",
     subject: subject, details: %{name: name, rendered: claimed, scope: scope}}
  end

  # --- column types ------------------------------------------------------------

  @doc false
  @spec column_type(Type.t()) :: column_type()
  def column_type(%Type{kind: :external} = type), do: external_value(type)
  def column_type(%Type{kind: :opaque} = type), do: external_value(type)
  def column_type(%Type{} = type), do: type |> base() |> list(type.cardinality)

  defp base(%Type{kind: :scalar, base: base}), do: %{type: Map.fetch!(@scalars, base)}

  defp base(%Type{kind: :file_ref, base: :image}),
    do: %{type: :custom, custom_type: "bubble_image"}

  defp base(%Type{kind: :file_ref, base: :file}), do: %{type: :custom, custom_type: "bubble_file"}

  defp base(%Type{kind: :structured, base: base}),
    do: %{type: :custom, custom_type: Map.fetch!(@structured, base)}

  defp base(%Type{kind: :ref, target: target}), do: %{type: :reference, custom_type: target}
  defp base(%Type{kind: :option, target: target}), do: %{type: :enum, custom_type: target}
  defp base(%Type{kind: :unknown, source: source}), do: %{type: :unsupported, raw: source}

  defp list(type, :many), do: Map.put(type, :is_array, true)
  defp list(type, _cardinality), do: type

  defp external_value(%Type{kind: :scalar} = t),
    do: %{type: :scalar, scalar: t.base, cardinality: t.cardinality, raw: t.source}

  defp external_value(%Type{kind: :external} = t),
    do: %{type: :external, target: t.target, cardinality: t.cardinality, raw: t.source}

  defp external_value(%Type{kind: :opaque} = t),
    do: %{type: :opaque_external, target: nil, cardinality: t.cardinality, raw: t.source}

  # --- relationships -----------------------------------------------------------

  # A reference links to the referenced table's primary key: `_id` for a data
  # type, `db_value` for an option set. A target that is not projected leaves
  # `to` nil: an undefined one is the Model's `model_unresolved_target`; a
  # deleted or malformed one is noted here. A single reference is
  # many-to-one; a list of references many-to-many.
  defp relationships(columns, pks, omitted) do
    relationships =
      for %{type: %{type: kind, custom_type: target} = type} = column <- columns,
          kind in [:reference, :enum] do
        group = if kind == :enum, do: :option, else: :custom
        direction = if type[:is_array], do: :many_to_many, else: :many_to_one
        {column, pks[{group, target}], direction, {group, target}}
      end

    notes =
      for {from, nil, _direction, {group, target} = key} <- relationships,
          MapSet.member?(omitted, key) do
        kind = if group == :custom, do: "data_type", else: "option_set"

        {:db_reference_to_omitted, from.source_path,
         "#{String.replace(kind, "_", " ")} #{inspect(target)} is deleted or malformed; #{from.table_id}.#{from.id} keeps its column but has no relationship",
         subject: subject(from.table_group, from.table_id, from.id),
         details: %{target: target, target_kind: kind}}
      end

    {Enum.map(relationships, fn {from, to, direction, _} -> {from, to, direction} end), notes}
  end

  # --- external types ----------------------------------------------------------

  # The API Connector types reachable from the projected columns, in the
  # shape `BubbleEx.Db.Encoder.Plan` reads.
  defp external_types(types, columns) do
    by_id = Map.new(types, &{&1.id, &1})
    roots = for %{type: %{type: :external, target: target}} <- columns, do: target

    roots
    |> Enum.reduce(MapSet.new(), &reach(&1, by_id, &2))
    |> Enum.sort()
    |> Enum.map(&external_type(Map.fetch!(by_id, &1)))
  end

  defp reach(id, by_id, seen) do
    if MapSet.member?(seen, id) or not Map.has_key?(by_id, id) do
      seen
    else
      by_id[id].fields
      |> Enum.filter(&(&1.type.kind == :external))
      |> Enum.reduce(MapSet.put(seen, id), &reach(&1.type.target, by_id, &2))
    end
  end

  defp external_type(%ExternalType{} = t) do
    %{
      id: t.id,
      caption: t.name,
      provenance: %{connector_id: t.connector, call_id: t.call},
      resolution: t.resolution,
      source_path: t.path,
      fields:
        Enum.map(t.fields, fn f ->
          %{id: f.id, caption: f.name, path: f.response_path, type: external_value(f.type)}
        end)
    }
  end
end
