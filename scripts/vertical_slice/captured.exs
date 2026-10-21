# The records a Bubble page held in browser memory, as loader rows
# (WTF-584): the files scripts/vertical_slice/render_records.js writes,
# turned into a loader export's rows by data type so `slice.exs records`
# loads them into a slice under their Bubble IDs, the same records the
# Bubble capture showed (see that command).
defmodule VerticalSlice.Captured do
  @moduledoc false

  alias BubbleEx.Model

  # Row members that are not fields but the loader reads (BubbleEx.Load.Scan).
  @not_fields ~w(_id authentication user_signed_up)

  # The client's references carry a cache prefix: `<n>__LOOKUP__<id>`.
  @lookup ~r/^\d+__LOOKUP__/

  @doc """
  Reads record captures (`{"records" => %{id => %{"type", "raw"}}}`) and
  merges them: a record in several captures keeps its first copy.
  """
  def read!(paths) do
    paths
    |> Enum.flat_map(fn path ->
      case path |> File.read!() |> Jason.decode!() do
        %{"records" => records} when is_map(records) ->
          Enum.sort(records)

        _ ->
          raise "#{path}: not a record capture (no \"records\" object; see render_records.js)"
      end
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  @doc """
  The captured records as loader rows by data type, and what was left
  out:

    * a record without a type or raw fields is `skipped`
    * a record of a type the model does not have counts in `unknown_types`
    * `_id` is filled from the record's key when the client's raw record
      has none (some types carry it only as the key)
    * reference prefixes (`<n>__LOOKUP__`) are stripped
    * a member the model has no field for is dropped (`dropped_fields`,
      by type: it would block the load as an unmapped key)
    * a user's `authentication` keeps its email and confirmed status and
      the names of other sign-in methods, nothing else (as the Data API
      export does)
  """
  def rows(%Model{} = model, records) do
    init = %{
      records: length(records),
      skipped: 0,
      ids_filled: 0,
      unknown_types: %{},
      dropped_fields: %{}
    }

    {rows, report} =
      Enum.reduce(records, {%{}, init}, fn {id, record}, {rows, report} ->
        case record do
          %{"type" => type, "raw" => raw} when is_binary(type) and is_map(raw) ->
            type = String.replace_prefix(type, "custom.", "")
            add(model, type, id, raw, rows, report)

          _ ->
            {rows, %{report | skipped: report.skipped + 1}}
        end
      end)

    rows = Map.new(rows, fn {type, list} -> {type, Enum.reverse(list)} end)

    report = %{
      report
      | dropped_fields:
          Map.new(report.dropped_fields, fn {t, set} ->
            {t, set |> MapSet.to_list() |> Enum.sort()}
          end)
    }

    {rows, report}
  end

  defp add(model, type, id, raw, rows, report) do
    if Model.data_type(model, type) == nil do
      {rows, %{report | unknown_types: Map.update(report.unknown_types, type, 1, &(&1 + 1))}}
    else
      {kept, dropped} =
        Enum.split_with(raw, fn {key, _} ->
          key in @not_fields or Model.field(model, type, key) != :error
        end)

      row =
        kept
        |> Map.new(fn {key, value} -> {key, strip(value)} end)
        |> sanitize()

      filled = not is_binary(row["_id"])
      row = if filled, do: Map.put(row, "_id", id), else: row

      dropped_fields =
        if dropped == [],
          do: report.dropped_fields,
          else:
            Map.update(
              report.dropped_fields,
              type,
              MapSet.new(dropped, &elem(&1, 0)),
              &MapSet.union(&1, MapSet.new(dropped, fn {k, _} -> k end))
            )

      {Map.update(rows, type, [row], &[row | &1]),
       %{
         report
         | ids_filled: report.ids_filled + if(filled, do: 1, else: 0),
           dropped_fields: dropped_fields
       }}
    end
  end

  defp strip(value) when is_binary(value), do: String.replace(value, @lookup, "")
  defp strip(value) when is_list(value), do: Enum.map(value, &strip/1)
  defp strip(value), do: value

  defp sanitize(%{"authentication" => %{} = auth} = row) do
    kept =
      Map.new(auth, fn
        {"email", %{} = e} -> {"email", Map.take(e, ["email", "email_confirmed"])}
        {"email", e} when is_binary(e) -> {"email", %{"email" => e}}
        {provider, _} -> {provider, %{}}
      end)

    Map.put(row, "authentication", kept)
  end

  defp sanitize(%{"authentication" => _} = row), do: Map.delete(row, "authentication")
  defp sanitize(row), do: row

  @doc """
  The loader's dangling references, by `type.field`: records the page
  pointed at but never held. Values that read them (an ID comparison, a
  count) differ from Bubble's, which knows the ID (e.g. a condition
  comparing such a reference with an empty value: ours reads it empty).
  """
  def dangling(diagnostics) do
    for %{code: :load_dangling_reference, subject: subject, details: details} <- diagnostics,
        reduce: %{} do
      acc ->
        key = Enum.join(Enum.reject([subject[:type], subject[:field]], &is_nil/1), ".")
        Map.update(acc, key, details[:count] || 1, &(&1 + (details[:count] || 1)))
    end
  end
end
