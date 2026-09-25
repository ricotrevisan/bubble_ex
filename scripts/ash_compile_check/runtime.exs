# Runtime proof for BubbleEx.Target.Ash (run by scripts/ash_compile_check.sh
# in the scratch project, after the generated migrations): inserts four rows
# into every generated resource through its create action and reads each
# back, requiring every attribute value to survive unchanged:
#
#   * the Bubble ID primary key with surrounding whitespace, and ""
#   * strings: "" kept distinct from nil, whitespace not trimmed
#   * floats, booleans, microsecond dates and lists of them
#   * belongs_to source attributes holding IDs of records that do not exist
#     (there is no foreign key)
#   * lists of IDs in their order
#   * enum values, typed-struct values
#   * Types.JsonValue: an object, a number, a string and a list

for repo <- Application.fetch_env!(:ash_compile_check, :ecto_repos) do
  {:ok, _} = repo.start_link()
end

defmodule RuntimeCheck do
  @instant ~U[2024-05-06 07:08:09.123456Z]
  @json [%{"a" => [1, %{"b" => nil}], "c" => "d"}, 5, "x", [1, "two", nil, 3.5]]

  def run do
    resources =
      for domain <- Application.fetch_env!(:ash_compile_check, :ash_domains),
          resource <- Ash.Domain.Info.resources(domain),
          do: resource

    failures = Enum.flat_map(resources, &check/1)

    if failures != [] do
      Enum.each(failures, &IO.puts/1)
      raise "runtime check failed: #{length(failures)} mismatches"
    end

    IO.puts("runtime check passed: #{length(resources)} resources, #{4 * length(resources)} rows")
  end

  defp check(resource) do
    [pk] = Ash.Resource.Info.primary_key(resource)
    refs = for r <- Ash.Resource.Info.relationships(resource), into: MapSet.new(), do: r.source_attribute
    attributes = Ash.Resource.Info.attributes(resource)

    Enum.flat_map(0..3, fn i ->
      input =
        Map.new(attributes, fn a ->
          value =
            cond do
              a.name == pk -> Enum.at(["  a b  ", "", "row 3", "row-4"], i)
              MapSet.member?(refs, a.name) -> "missing record #{i}"
              true -> sample(a.type, a.constraints, i)
            end

          {a.name, value}
        end)

      record =
        resource
        |> Ash.Changeset.for_create(:create, input)
        |> Ash.create!()

      read = Ash.get!(resource, Map.fetch!(input, pk))

      for a <- attributes,
          {:ok, expected} = Ash.Type.cast_input(a.type, input[a.name], a.constraints),
          actual = Map.fetch!(read, a.name),
          actual != expected or Map.fetch!(record, a.name) != expected do
        "#{inspect(resource)}.#{a.name} row #{i}: wrote #{inspect(input[a.name])}, " <>
          "expected #{inspect(expected)}, read #{inspect(actual)}"
      end
    end)
  end

  defp sample({:array, type}, constraints, i) do
    items = Keyword.get(constraints, :items, [])

    case type do
      Ash.Type.String -> Enum.map(["id-c", "id-a", "id-b"], &"#{&1}-#{i}")
      _ -> for n <- 0..2, v = sample(type, items, i + n + 1), not is_nil(v), do: v
    end
  end

  defp sample(Ash.Type.String, _c, i), do: Enum.at(["", nil, " keep  spaces ", "z"], i)
  defp sample(Ash.Type.Float, _c, i), do: Enum.at([1.5, 0.0, -2.25, 1.0e20], i)
  defp sample(Ash.Type.Integer, _c, i), do: i
  defp sample(Ash.Type.Boolean, _c, i), do: Enum.at([true, false, nil, true], i)
  defp sample(Ash.Type.UtcDatetimeUsec, _c, i), do: DateTime.add(@instant, i * 61, :second)
  defp sample(Ash.Type.Map, _c, i), do: %{"k" => i}

  defp sample(type, _c, i) do
    Code.ensure_loaded!(type)

    cond do
      String.ends_with?(inspect(type), ".JsonValue") ->
        Enum.at(@json, i)

      function_exported?(type, :values, 0) ->
        case type.values() do
          [] -> nil
          values -> Enum.at(values, rem(i, length(values)))
        end

      Spark.Dsl.is?(type, Ash.TypedStruct) ->
        Map.new(Ash.TypedStruct.Info.fields(type), &{&1.name, sample(&1.type, &1.constraints || [], i)})

      true ->
        raise "no sample for #{inspect(type)}"
    end
  end
end

RuntimeCheck.run()
