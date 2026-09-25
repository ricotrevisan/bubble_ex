defmodule BubbleEx.Model.Builder do
  @moduledoc false

  # Reads data types and option sets from decoded app JSON in either key form
  # (`.bubble` exports: `display`, `fields`, `value`, `deleted`; the live
  # payload: `%d`, `%f3`, `%v`, `%del`) into Model structs. Privacy rules and
  # type-level flags come from `BubbleEx.Privacy`, API Connector types from
  # the Reader (`BubbleEx.Model.External`). Nothing in the source is dropped:
  # what is not modeled is kept in `extra`/`raw` and diagnosed.

  alias BubbleEx.{Diagnostic, Privacy}
  alias BubbleEx.Expression.Vocabulary
  alias BubbleEx.Model.{DataType, External, Field, OptionSet, OptionValue, Type}

  @type result :: %{
          data_types: [DataType.t()],
          option_sets: [OptionSet.t()],
          external_types: [BubbleEx.Model.ExternalType.t()],
          extra: map(),
          diagnostics: [Diagnostic.t()]
        }

  @field_members ~w(display %d value %v comment default_val deleted %del creation_source)
  @set_members ~w(display %d comment creation_source attributes values deleted %del)
  @value_members ~w(display %d db_value sort_factor comment deleted %del)

  @system_fields ["_id", "Created Date", "Modified Date", "Created By", "Slug"]

  @spec build(map()) :: result()
  def build(app) do
    {types, types_extra, types_diags} = collection(app, "user_types")
    {sets, sets_extra, sets_diags} = collection(app, "option_sets")
    known = %{ref: MapSet.new(Map.keys(types)), option: MapSet.new(Map.keys(sets))}

    {privacy, privacy_diags} = privacy(types)

    {data_types, type_diags} =
      types |> sorted() |> Enum.map(&data_type(&1, privacy, known)) |> unzip()

    {option_sets, set_diags} =
      sets |> sorted() |> Enum.map(&option_set(&1, known)) |> unzip()

    {data_types, option_sets, external_types, read_diags} =
      External.resolve(data_types, option_sets, app)

    %{
      data_types: data_types,
      option_sets: option_sets,
      external_types: external_types,
      extra: Map.merge(types_extra, sets_extra),
      diagnostics:
        Diagnostic.normalize(
          types_diags ++ sets_diags ++ privacy_diags ++ type_diags ++ set_diags ++ read_diags
        )
    }
  end

  # --- collections -----------------------------------------------------------

  defp collection(app, key) do
    case Map.fetch(app, key) do
      {:ok, map} when is_map(map) ->
        {Map.filter(map, fn {k, _} -> is_binary(k) end), %{}, []}

      {:ok, nil} ->
        {%{}, %{}, []}

      {:ok, other} ->
        diag = Diagnostic.new(:model_malformed_node, [key], "#{key} must be an object")
        {%{}, %{key => other}, [diag]}

      :error ->
        {%{}, %{}, []}
    end
  end

  defp privacy(types) when map_size(types) == 0, do: {%{}, []}

  defp privacy(types) do
    {:ok, %Privacy{data_types: parsed, diagnostics: diags}} =
      Privacy.parse(%{"user_types" => types})

    {Map.new(parsed, &{&1.id, &1}), diags}
  end

  # --- data types --------------------------------------------------------------

  defp data_type({id, raw}, privacy, _known) when not is_map(raw) do
    # Privacy diagnoses the type itself (`:malformed_node`).
    {%DataType{
       id: id,
       path: pointer(["user_types", id]),
       raw: raw,
       privacy: privacy[id].availability
     }, []}
  end

  defp data_type({id, raw}, privacy, known) do
    path = ["user_types", id]
    p = Map.fetch!(privacy, id)
    {fields, extra, diags} = members(raw, ~w(fields %f3), path, %{type: id})
    fields_path = path ++ [members_key(raw, ~w(fields %f3))]

    {fields, field_diags} =
      fields
      |> sorted()
      |> Enum.map(fn {fid, field} ->
        field(fid, field, fields_path ++ [fid], %{type: id, field: fid}, known)
      end)
      |> unzip()

    type = %DataType{
      id: id,
      name: p.name,
      comment: p.comment,
      exposed_api: p.exposed_api,
      deleted: p.deleted == true,
      privacy: p.availability,
      path: pointer(path),
      fields: fields,
      system_fields: system_fields(id, path, MapSet.new(fields, & &1.id), known),
      rules: p.rules,
      extra: Map.merge(p.extra, extra)
    }

    {type, diags ++ field_diags}
  end

  # Bubble's built-in fields: every record has them, and every User an email.
  # Absent from exported field lists; their path is the type's.
  defp system_fields(type_id, path, defined, known) do
    names = if type_id == "user", do: @system_fields ++ ["email"], else: @system_fields

    for name <- names, not MapSet.member?(defined, name) do
      {role, descriptor} = Vocabulary.builtin_field(name) || {:email, "text"}
      {type, nil} = Type.classify(descriptor)

      %Field{
        id: name,
        name: name,
        type: resolve(type, known),
        system: role,
        path: pointer(path)
      }
    end
  end

  # --- fields and attributes ---------------------------------------------------

  defp field(id, raw, path, subject, _known) when not is_map(raw) do
    {type, _} = Type.classify(nil)

    diag =
      Diagnostic.new(:model_malformed_node, path, "field must be an object", subject: subject)

    {%Field{id: id, type: type, path: pointer(path), raw: raw}, [diag]}
  end

  defp field(id, raw, path, subject, known) do
    {descriptor, descriptor_path} =
      case member(raw, ~w(value %v)) do
        {key, value} -> {value, path ++ [key]}
        nil -> {nil, path}
      end

    {type, problem} = Type.classify(descriptor)
    type = resolve(type, known)
    extra = Map.drop(raw, @field_members)

    field = %Field{
      id: id,
      name: text(raw, ~w(display %d)),
      comment: text(raw, ["comment"]),
      type: type,
      default: Map.get(raw, "default_val"),
      creation_source: text(raw, ["creation_source"]),
      deleted: deleted?(raw),
      path: pointer(path),
      extra: extra
    }

    diags =
      type_diagnostics(problem, type, descriptor_path, subject) ++
        uninterpreted(extra, path, subject, "field")

    {field, diags}
  end

  defp resolve(%Type{kind: kind, target: target} = type, known) when kind in [:ref, :option],
    do: %{type | resolved: MapSet.member?(Map.fetch!(known, kind), target)}

  defp resolve(type, _known), do: type

  defp type_diagnostics(:malformed, type, path, subject) do
    message = "missing or malformed type descriptor: #{inspect(type.source)}"
    [Diagnostic.new(:model_malformed_field_type, path, message, subject: subject)]
  end

  defp type_diagnostics(:unsupported, type, path, subject) do
    [
      Diagnostic.new(
        :model_unsupported_field_type,
        path,
        "unsupported type descriptor #{inspect(type.source)}",
        subject: subject,
        details: %{descriptor: type.source}
      )
    ]
  end

  defp type_diagnostics(nil, %Type{resolved: false} = type, path, subject) do
    kind = if type.kind == :ref, do: "data_type", else: "option_set"

    [
      Diagnostic.new(
        :model_unresolved_target,
        path,
        "#{String.replace(kind, "_", " ")} #{inspect(type.target)} is not defined",
        subject: subject,
        details: %{target: type.target, target_kind: kind}
      )
    ]
  end

  defp type_diagnostics(nil, _type, _path, _subject), do: []

  # --- option sets -------------------------------------------------------------

  defp option_set({id, raw}, _known) when not is_map(raw) do
    path = ["option_sets", id]

    diag =
      Diagnostic.new(:model_malformed_node, path, "option set must be an object",
        subject: %{option_set: id}
      )

    {%OptionSet{id: id, path: pointer(path), raw: raw}, [diag]}
  end

  defp option_set({id, raw}, known) do
    path = ["option_sets", id]
    subject = %{option_set: id}
    {attrs, attrs_extra, attrs_diags} = members(raw, ["attributes"], path, subject)
    {values, values_extra, values_diags} = members(raw, ["values"], path, subject)

    {attributes, attribute_diags} =
      attrs
      |> sorted()
      |> Enum.map(fn {aid, attr} ->
        field(aid, attr, path ++ ["attributes", aid], %{option_set: id, field: aid}, known)
      end)
      |> unzip()

    attribute_ids = MapSet.new(attributes, & &1.id)

    {values, value_diags} =
      values
      |> Enum.map(fn {vid, value} ->
        option_value(vid, value, path ++ ["values", vid], id, attribute_ids)
      end)
      |> unzip()

    values = Enum.sort_by(values, &{sort_rank(&1.sort_factor), &1.id})
    extra = raw |> Map.drop(@set_members) |> Map.merge(attrs_extra) |> Map.merge(values_extra)

    set = %OptionSet{
      id: id,
      name: text(raw, ~w(display %d)),
      comment: text(raw, ["comment"]),
      creation_source: text(raw, ["creation_source"]),
      deleted: deleted?(raw),
      path: pointer(path),
      attributes: attributes,
      values: values,
      extra: extra
    }

    diags =
      attrs_diags ++
        values_diags ++
        uninterpreted(Map.drop(raw, @set_members), path, subject, "option set") ++
        attribute_diags ++ value_diags ++ duplicate_keys(values, path, subject)

    {set, diags}
  end

  defp option_value(id, raw, path, set_id, _attribute_ids) when not is_map(raw) do
    diag =
      Diagnostic.new(:model_malformed_node, path, "option value must be an object",
        subject: %{option_set: set_id},
        details: %{value: id}
      )

    {%OptionValue{id: id, key: id, path: pointer(path), raw: raw}, [diag]}
  end

  defp option_value(id, raw, path, set_id, attribute_ids) do
    subject = %{option_set: set_id}
    rest = Map.drop(raw, @value_members)
    {attributes, extra} = Map.split_with(rest, fn {k, _} -> MapSet.member?(attribute_ids, k) end)

    {key, key_diags} =
      case raw["db_value"] do
        key when is_binary(key) and key != "" ->
          {key, []}

        other ->
          {id,
           [
             Diagnostic.new(
               :model_option_key_missing,
               path,
               "option value has no db_value; its Bubble ID #{inspect(id)} is used",
               subject: subject,
               details: %{value: id, db_value: other}
             )
           ]}
      end

    value = %OptionValue{
      id: id,
      key: key,
      name: text(raw, ~w(display %d)),
      comment: text(raw, ["comment"]),
      sort_factor: raw["sort_factor"],
      deleted: deleted?(raw),
      path: pointer(path),
      attributes: attributes,
      extra: extra
    }

    {value, key_diags ++ uninterpreted(extra, path, subject, "option value")}
  end

  # Values that are not deleted and share a stable key: every one after the
  # first (in source order) is diagnosed.
  defp duplicate_keys(values, path, subject) do
    values
    |> Enum.reject(& &1.deleted)
    |> Enum.group_by(& &1.key)
    |> Enum.flat_map(fn {key, [first | rest]} ->
      Enum.map(rest, fn value ->
        Diagnostic.new(
          :model_duplicate_option_key,
          path ++ ["values", value.id],
          "option value #{inspect(value.id)} repeats the key #{inspect(key)}",
          subject: subject,
          details: %{key: key, value: value.id, first: first.id}
        )
      end)
    end)
  end

  defp sort_rank(n) when is_number(n), do: {0, n}
  defp sort_rank(_), do: {1, 0}

  # --- helpers -------------------------------------------------------------------

  # The object held by the first of `keys` present in `raw`. A non-object is
  # kept in the returned `extra` under its key and diagnosed.
  defp members(raw, keys, path, subject) do
    case member(raw, keys) do
      nil ->
        {%{}, %{}, []}

      {_key, nil} ->
        {%{}, %{}, []}

      {_key, map} when is_map(map) ->
        {Map.filter(map, fn {k, _} -> is_binary(k) end), %{}, []}

      {key, other} ->
        diag =
          Diagnostic.new(:model_malformed_node, path ++ [key], "#{key} must be an object",
            subject: subject
          )

        {%{}, %{key => other}, [diag]}
    end
  end

  defp members_key(raw, keys), do: Enum.find(keys, &Map.has_key?(raw, &1))

  defp member(raw, keys) do
    case Enum.find(keys, &Map.has_key?(raw, &1)) do
      nil -> nil
      key -> {key, Map.fetch!(raw, key)}
    end
  end

  defp uninterpreted(extra, path, subject, what) do
    for key <- extra |> Map.keys() |> Enum.sort() do
      Diagnostic.new(
        :model_uninterpreted_member,
        path ++ [key],
        "unexpected #{what} member #{inspect(key)}",
        subject: subject
      )
    end
  end

  defp deleted?(raw), do: Enum.any?(~w(deleted %del), &(Map.get(raw, &1) == true))

  defp text(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp sorted(map), do: Enum.sort_by(map, &elem(&1, 0))

  defp unzip(pairs), do: {Enum.map(pairs, &elem(&1, 0)), Enum.flat_map(pairs, &elem(&1, 1))}

  defp pointer(path), do: Diagnostic.pointer(path)
end
