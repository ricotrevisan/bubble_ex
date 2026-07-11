defmodule BubbleEx.Db.Reader do
  @moduledoc """
  Module that reads a Bubble's app's payload and converts to an universal db format
  """

  @type table_group() :: :api | :custom | :option

  @type column_type() :: %{
          type:
            :string
            | :float
            | :boolean
            | :utc_datetime_usec
            | :custom
            | :reference
            | :enum
            | :api
            | :unsupported,
          custom_type: String.t() | nil,
          is_array: boolean() | nil,
          raw: String.t()
        }

  @type column() :: %{
          table_id: String.t(),
          table_name: String.t(),
          table_group: table_group(),
          id: String.t(),
          name: String.t(),
          type: column_type(),
          primary_key: boolean(),
          deleted: boolean(),
          default: term()
        }

  @type relationship_direction() :: :one_to_one | :one_to_many | :many_to_many | :many_to_one
  @type relationship() :: {column(), column(), relationship_direction()}
  @type table() :: %{
          id: String.t(),
          name: String.t(),
          group: table_group(),
          columns: [column()],
          values: [map()]
        }

  @type db_map() :: %{
          bubble_id: String.t(),
          tables: [table()],
          relationships: [relationship()]
        }

  # @table_types [:custom, :option, :api]

  # Primary-key column ids injected by ensure_primary_key/2 and matched by
  # find_target_pk/2 when resolving references: custom data types get "_id",
  # option sets get "display". Keep the injection and the lookup in lockstep.
  @custom_pk_id "_id"
  @option_pk_id "display"

  @spec parse(map()) :: {:ok, db_map()}
  def parse(attrs) do
    attrs = normalize_export_shape(attrs)
    bubble_id = attrs["_id"]

    user_types = generate_tables(attrs, :custom)
    option_sets = generate_tables(attrs, :option)
    tables = Enum.sort_by(user_types ++ option_sets, &{&1.name, &1.id})
    columns = flatten_columns(tables)

    api = generate_tables(columns, :api)

    columns = flatten_columns(tables ++ api)
    relationships = generate_relationships(columns)

    db_map = %{
      bubble_id: bubble_id,
      tables: tables,
      # option_sets: option_sets,
      # user_types: user_types,
      relationships:
        Enum.sort_by(relationships, fn {from, _, _} -> {from.table_name, from.name, from.id} end)
    }

    {:ok, db_map}
  end

  defp generate_tables(attrs, :custom) do
    case Map.get(attrs, "user_types") do
      nil ->
        []

      user_types ->
        user_types
        |> ensure_primary_key(:custom)
        |> Enum.map(&generate_table(&1, :custom))
    end
  end

  defp generate_tables(attrs, :option) do
    case Map.get(attrs, "option_sets") do
      nil ->
        []

      option_sets ->
        option_sets
        |> ensure_primary_key(:option)
        |> Enum.map(&generate_table(&1, :option))
    end
  end

  defp generate_tables(columns, :api) do
    columns
    |> Enum.filter(&(&1.type.type == :api))
    |> Enum.group_by(& &1.type.custom_type)
    |> Enum.map(fn {table, _columns} ->
      [table_id | [column_id | _]] = String.split(table, ".")

      columns = [
        %{
          table_id: table_id,
          table_name: table_id,
          table_group: :api,
          id: column_id,
          name: column_id,
          type: %{type: :string},
          primary_key: false,
          deleted: true
        }
      ]

      %{
        id: table_id,
        name: table_id,
        group: :api,
        columns: columns
      }
    end)

    # |> Enum.map(&generate_table(&1, :api))
  end

  # def generate_table(column, :api) do
  #   %{

  #   }
  # end

  defp generate_table(table_data, table_group) do
    {table_id, data} = table_data
    table_name = data["%d"]

    table = %{
      id: table_id,
      name: table_name,
      group: table_group
    }

    columns =
      data
      |> which_column(table_group)
      |> Enum.map(&generate_column(&1, table))
      |> Enum.reject(& &1.deleted)
      |> Enum.sort_by(&{&1.name, &1.id})

    table
    |> Map.put(:columns, columns)
    |> Map.put(:values, option_values(data, table_group))
  end

  defp which_column(data, table_group) do
    case table_group do
      :custom -> Map.get(data, "%f3")
      :option -> Map.get(data, "attributes")
    end
  end

  defp generate_column(column_data, table) do
    {column_id, data} = column_data
    column_name = data["%d"]
    type = which_type(data["%v"])

    %{
      table_id: table.id,
      table_name: table.name,
      table_group: table.group,
      id: column_id,
      name: column_name,
      type: type,
      primary_key: primary_key?(table.group, column_id),
      deleted: Map.get(data, "%del", false),
      default: Map.get(data, "default_val")
    }
  end

  defp primary_key?(:custom, @custom_pk_id), do: true
  defp primary_key?(:option, @option_pk_id), do: true
  defp primary_key?(_group, _id), do: false

  defp generate_relationships(columns) do
    columns
    |> Enum.filter(&(&1.type.type in [:reference, :enum]))
    |> Enum.map(fn column ->
      to = find_target_pk(columns, column.type)
      direction = which_direction(column.type)
      {column, to, direction}
    end)
  end

  # A reference must link to the referenced table's primary key, not to whatever
  # column happens to be found first. Custom types carry a Reader-injected "_id"
  # PK; option sets carry an injected "display" PK.
  defp find_target_pk(columns, %{type: :enum, custom_type: table_id}),
    do: find_pk_column(columns, table_id, @option_pk_id)

  defp find_target_pk(columns, %{custom_type: table_id}),
    do: find_pk_column(columns, table_id, @custom_pk_id)

  defp find_pk_column(columns, table_id, pk_id) do
    Enum.find(columns, fn column -> column.table_id == table_id and column.id == pk_id end)
  end

  # A single reference column means many rows can point at one target
  # (many-to-one); a list-of-references column means many rows each point at
  # many targets (many-to-many).
  @spec which_direction(column_type()) :: relationship_direction()
  defp which_direction(column)
  defp which_direction(%{is_array: true}), do: :many_to_many
  defp which_direction(_), do: :many_to_one

  @spec which_type(String.t()) :: column_type()
  defp which_type("list.custom." <> type = _value) do
    %{
      type: :reference,
      custom_type: type,
      is_array: true
    }
  end

  defp which_type("list.api." <> type = _value) do
    %{
      type: :api,
      custom_type: type,
      is_array: true
    }
  end

  defp which_type("custom." <> type = _value) do
    %{
      type: :reference,
      custom_type: type
    }
  end

  defp which_type("api." <> type = _value) do
    %{
      type: :api,
      custom_type: type
    }
  end

  defp which_type("option." <> rest = _value) do
    %{type: :enum, custom_type: rest}
  end

  defp which_type("list." <> type) do
    %{
      is_array: true
    }
    |> Map.merge(which_type(type))
  end

  defp which_type("user"), do: %{type: :reference, custom_type: "user"}
  defp which_type("image"), do: %{type: :custom, custom_type: "bubble_image"}
  defp which_type("file"), do: %{type: :custom, custom_type: "bubble_file"}

  defp which_type("geographic_address"),
    do: %{type: :custom, custom_type: "bubble_geo_address"}

  defp which_type("number_range"), do: %{type: :custom, custom_type: "bubble_number_range"}

  defp which_type("date_range"),
    do: %{type: :custom, custom_type: "bubble_date_range"}

  defp which_type("dateinterval"), do: %{type: :custom, custom_type: "bubble_dateinterval"}

  defp which_type("date"), do: %{type: :utc_datetime_usec}
  defp which_type("boolean"), do: %{type: :boolean}
  defp which_type("number"), do: %{type: :float}
  defp which_type("text"), do: %{type: :string}
  defp which_type(raw), do: %{type: :unsupported, raw: raw}

  defp option_values(_data, :custom), do: []

  defp option_values(data, :option) do
    data
    |> Map.get("values", %{})
    |> Enum.reject(fn {_id, value} -> Map.get(value, "%del", false) end)
    |> Enum.map(fn {id, value} ->
      %{id: id, name: value["%d"] || value["display"], db_value: value["db_value"]}
    end)
    |> Enum.sort_by(&{&1.name, &1.id})
  end

  defp ensure_primary_key(tables, :custom) do
    id = %{
      "%d" => "_id",
      "%v" => "text"
    }

    tables
    |> Enum.map(fn table ->
      {key, value} = table
      columns = Map.get(value, "%f3") |> Map.put(@custom_pk_id, id)

      {key, Map.put(value, "%f3", columns)}
    end)
  end

  defp ensure_primary_key(option_sets, :option) do
    display = %{
      "%d" => "Display",
      "%v" => "text"
    }

    option_sets
    |> Enum.map(fn item ->
      {key, value} = item

      value =
        if Map.has_key?(value, "attributes") do
          attributes = value["attributes"] |> Map.put(@option_pk_id, display)
          Map.put(value, "attributes", attributes)
        else
          value
          |> Map.put("attributes", %{@option_pk_id => display})
        end

      {key, value}
    end)
  end

  defp flatten_columns(tables) do
    tables
    |> Enum.map(& &1.columns)
    |> List.flatten()
  end

  # --- .bubble.json export-shape support -------------------------------------
  #
  # Exports downloaded from Bubble use readable keys (display/fields/value,
  # display/values) where the live-scraped app JSON uses %d/%f3/%v and
  # "attributes". Normalize the export shape into the scraped shape so the
  # rest of the pipeline (and every Db.Encoder) is unaffected.

  defp normalize_export_shape(attrs) do
    attrs
    |> Map.replace_lazy("user_types", fn entries ->
      normalize_entries(entries, &normalize_user_type/1)
    end)
    |> Map.replace_lazy("option_sets", fn entries ->
      normalize_entries(entries, &normalize_option_set/1)
    end)
  end

  defp normalize_entries(entries, fun) when is_map(entries) do
    Map.new(entries, fn
      {key, value} when is_map(value) -> {key, fun.(value)}
      other -> other
    end)
  end

  defp normalize_entries(entries, _fun), do: entries

  defp normalize_user_type(%{"fields" => fields} = value) when not is_map_key(value, "%f3") do
    %{"%d" => value["display"], "%f3" => normalized_fields(fields)}
  end

  # A custom data type with zero custom fields has only a "display" key in the
  # export shape (no "fields" key at all, since there's nothing to list).
  defp normalize_user_type(%{"display" => d} = value)
       when not is_map_key(value, "fields") and not is_map_key(value, "%f3") and
              not is_map_key(value, "%d") do
    %{"%d" => d, "%f3" => %{}}
  end

  defp normalize_user_type(value), do: value

  defp normalized_fields(fields) when is_map(fields) do
    Map.new(fields, fn {field_id, field} ->
      {field_id, %{"%d" => field["display"], "%v" => field["value"]}}
    end)
  end

  defp normalized_fields(_fields), do: %{}

  defp normalize_option_set(%{"values" => values} = value) when not is_map_key(value, "%d") do
    %{"%d" => value["display"], "attributes" => derive_attributes(values)}
  end

  defp normalize_option_set(value), do: value

  defp derive_attributes(values) when is_map(values) do
    entries = values |> Map.values() |> Enum.filter(&is_map/1)

    entries
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "display"))
    |> Map.new(fn attr ->
      samples = entries |> Enum.map(&Map.get(&1, attr)) |> Enum.reject(&is_nil/1)
      type = if samples != [] and Enum.all?(samples, &is_number/1), do: "number", else: "text"
      {attr, %{"%d" => attr, "%v" => type}}
    end)
  end

  defp derive_attributes(_), do: %{}
end
