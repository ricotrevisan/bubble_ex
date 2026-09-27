defmodule BubbleEx.Load.Convert do
  @moduledoc """
  Converts one stored Bubble value (as the Data API returns it) into the
  JSON a target column stores, by the field's `BubbleEx.Model.Type` and
  the column's `t:BubbleEx.Load.Plan.encoding/0`. Stack-neutral: the
  output is plain JSON (strings, numbers, booleans, maps, lists, nil), and
  what does not fit is reported as issues, never dropped silently.

  | Stored | Loaded |
  |--------|--------|
  | text | the string, verbatim (no trim; `""` is not empty) |
  | number | a float; `:integer` only when integral, `:decimal` as given |
  | yes/no | the boolean |
  | date (ISO 8601 or epoch ms) | ISO 8601 UTC at microsecond precision |
  | file, image | the target storage's reference when copied; else the URL (`//` → `https://`) |
  | a thing, list of things | the Bubble ID(s), dangling ones kept (reported) |
  | option | its key; a display text naming one option is mapped (reported); others empty (reported) |
  | geographic address (`address`/`lat`/`lng`) | `{formatted_address, lat, lng}` |
  | date range, number range (`start`/`end`, `min`/`max`, or a pair) | their parts |
  | API Connector value | its fields by the column's parts |
  | anything else (`:json`) | verbatim |
  | a list | a JSON array, order kept; items that do not fit are dropped (reported); an empty list is empty (nil) |

  `text_to_reference` columns (`text_ref`) are trimmed; an empty text is
  empty; a value not shaped like a Bubble unique ID (`<digits>x<digits>`)
  is reported and empty. `drop_dangling` lists lose the IDs of records
  the export does not hold (reported).

  An issue is `{code, detail}`: `code` a `:load_*` diagnostic code,
  `detail` an atom or short term naming what (never the stored value).
  """

  alias BubbleEx.Load.Files
  alias BubbleEx.Load.Plan.Column
  alias BubbleEx.Model.{Field, Type}

  @record_id ~r/\A[0-9]{1,20}x[0-9]{1,24}\z/

  @type issue :: {atom(), term()}
  @type ctx :: %{
          optional(:app_hosts) => [String.t()],
          optional(:ids) => %{String.t() => MapSet.t(String.t())},
          optional(:files) => %{String.t() => String.t()},
          optional(:failed_files) => MapSet.t(String.t())
        }

  @doc "Whether `id` is shaped like a Bubble unique ID."
  @spec record_id?(term()) :: boolean()
  def record_id?(id) when is_binary(id), do: id =~ @record_id
  def record_id?(_), do: false

  @doc """
  Converts `raw`, the stored value of `field`, for `column`. Returns the
  JSON value and the issues.
  """
  @spec value(Field.t(), Column.t(), term(), ctx()) :: {term(), [issue()]}
  def value(_field, _column, nil, _ctx), do: {nil, []}

  def value(field, %Column{encoding: {:array, enc}} = column, raw, ctx) when is_list(raw) do
    {items, issues} =
      Enum.reduce(raw, {[], []}, fn item, {items, issues} ->
        {v, item_issues} = item(field, column, enc, item, ctx)
        {if(is_nil(v), do: items, else: [v | items]), item_issues ++ issues}
      end)

    {items, drop_issues} = drop_dangling(column, Enum.reverse(items), ctx)
    {if(items == [], do: nil, else: items), Enum.reverse(issues) ++ drop_issues}
  end

  def value(_field, %Column{encoding: {:array, _}}, _raw, _ctx),
    do: {nil, [{:load_type_mismatch, :not_a_list}]}

  def value(field, column, raw, ctx), do: item(field, column, column.encoding, raw, ctx)

  # --- one value -------------------------------------------------------------------

  defp item(_field, _column, _enc, nil, _ctx), do: {nil, []}

  defp item(_field, %Column{text_ref: true} = column, _enc, raw, ctx) when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        {nil, []}

      id ->
        if record_id?(id),
          do: reference(column, id, ctx),
          else: {nil, [{:load_invalid_reference, :not_an_id}]}
    end
  end

  defp item(_field, %Column{references: %{}} = column, :text, raw, ctx) when is_binary(raw),
    do: reference(column, raw, ctx)

  defp item(%Field{type: %Type{kind: :file_ref}}, %Column{files: true}, :text, raw, ctx)
       when is_binary(raw),
       do: file(raw, ctx)

  defp item(%Field{type: %Type{kind: :scalar, base: :text}}, _column, :text, raw, ctx)
       when is_binary(raw) do
    if Files.urls_in_text(raw, Map.get(ctx, :app_hosts, [])) == [],
      do: {raw, []},
      else: {raw, [{:load_file_url_in_text, :text}]}
  end

  defp item(%Field{type: %Type{kind: :structured, base: base}}, _column, enc, raw, _ctx),
    do: encode(enc, structured(base, raw))

  defp item(_field, _column, enc, raw, _ctx), do: encode(enc, raw)

  defp reference(%Column{references: %{target: target}}, id, ctx) do
    case ctx do
      %{ids: %{^target => ids}} ->
        if MapSet.member?(ids, id),
          do: {id, []},
          else: {id, [{:load_dangling_reference, shape(id)}]}

      _ ->
        {id, []}
    end
  end

  defp reference(_column, id, _ctx), do: {id, []}

  defp shape(id), do: if(record_id?(id), do: :missing, else: :not_an_id)

  defp file(raw, ctx) do
    url = Files.normalize(raw)

    cond do
      not Files.bubble?(url, Map.get(ctx, :app_hosts, [])) ->
        {raw, [{:load_file_not_bubble, :external}]}

      ref = Map.get(Map.get(ctx, :files, %{}), url) ->
        {ref, []}

      true ->
        {url, [{:load_file_failed, :not_copied}]}
    end
  end

  # IDs of records the export does not hold, dropped from a counted list.
  defp drop_dangling(%Column{drop_dangling: true, references: %{target: t}}, items, ctx) do
    case ctx do
      %{ids: %{^t => ids}} ->
        {kept, dropped} = Enum.split_with(items, &MapSet.member?(ids, &1))
        {kept, if(dropped == [], do: [], else: [{:load_deleted_ids_dropped, length(dropped)}])}

      _ ->
        {items, []}
    end
  end

  defp drop_dangling(_column, items, _ctx), do: {items, []}

  # --- structured values --------------------------------------------------------------

  # The Data API's geographic address has `address`, `lat` and `lng`
  # (unverified against Bubble; `formatted_address` is accepted too); a
  # bare text is the address alone. Ranges are objects or pairs.
  defp structured(:geographic_address, %{} = raw) do
    %{
      "formatted_address" => Map.get(raw, "address", Map.get(raw, "formatted_address")),
      "lat" => Map.get(raw, "lat"),
      "lng" => Map.get(raw, "lng")
    }
  end

  defp structured(:geographic_address, raw) when is_binary(raw),
    do: %{"formatted_address" => raw, "lat" => nil, "lng" => nil}

  defp structured(:date_range, [a, b]), do: %{"start" => a, "end" => b}
  defp structured(:number_range, [a, b]), do: %{"min" => a, "max" => b}
  defp structured(_base, raw), do: raw

  @doc """
  Strips NUL characters from every string of a converted value (PostgreSQL
  text and jsonb cannot hold them). Returns the value and whether any was
  stripped.
  """
  @spec strip_nul(term()) :: {term(), boolean()}
  def strip_nul(s) when is_binary(s) do
    if String.contains?(s, <<0>>), do: {String.replace(s, <<0>>, ""), true}, else: {s, false}
  end

  def strip_nul(list) when is_list(list) do
    {items, found} = Enum.map_reduce(list, false, fn v, f -> strip(v, f) end)
    {items, found}
  end

  def strip_nul(%{} = map) do
    {pairs, found} =
      Enum.map_reduce(map, false, fn {k, v}, f ->
        {k, fk} = strip_nul(k)
        {v, fv} = strip_nul(v)
        {{k, v}, f or fk or fv}
      end)

    {Map.new(pairs), found}
  end

  def strip_nul(v), do: {v, false}

  defp strip(v, found) do
    {v, f} = strip_nul(v)
    {v, found or f}
  end

  # --- encodings -------------------------------------------------------------------------

  @doc """
  Encodes a JSON value for `encoding`, leniently for its class (a number
  for a float, ISO text or epoch milliseconds for a date).
  """
  @spec encode(BubbleEx.Load.Plan.encoding(), term()) :: {term(), [issue()]}
  def encode(_enc, nil), do: {nil, []}
  def encode(:json, raw), do: {raw, []}
  def encode(:text, raw) when is_binary(raw), do: {raw, []}
  def encode(:float, raw) when is_number(raw), do: {raw / 1, []}
  def encode(:decimal, raw) when is_number(raw), do: {raw, []}
  def encode(:boolean, raw) when is_boolean(raw), do: {raw, []}

  def encode(:integer, raw) when is_integer(raw), do: {raw, []}

  def encode(:integer, raw) when is_float(raw) do
    if raw == Float.round(raw) and abs(raw) < 9.0e18,
      do: {trunc(raw), []},
      else: {nil, [{:load_type_mismatch, :not_integral}]}
  end

  def encode(:datetime, raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> {iso(dt), []}
      {:error, _} -> {nil, [{:load_type_mismatch, :not_a_date}]}
    end
  end

  def encode(:datetime, raw) when is_integer(raw) do
    case DateTime.from_unix(raw, :millisecond) do
      {:ok, dt} -> {iso(dt), []}
      {:error, _} -> {nil, [{:load_type_mismatch, :not_a_date}]}
    end
  end

  def encode({:enum, keys, labels}, raw) when is_binary(raw) do
    cond do
      MapSet.member?(keys, raw) -> {raw, []}
      key = Map.get(labels, raw) -> {key, [{:load_option_by_label, :label}]}
      true -> {nil, [{:load_unknown_option, :unknown}]}
    end
  end

  def encode({:structured, _base, parts}, %{} = raw), do: parts(parts, raw)
  def encode({:external, parts}, %{} = raw), do: parts(parts, raw)

  def encode({:array, enc}, raw) when is_list(raw) do
    {items, issues} =
      Enum.reduce(raw, {[], []}, fn item, {items, issues} ->
        case encode(enc, item) do
          {nil, i} -> {items, i ++ issues}
          {v, i} -> {[v | items], i ++ issues}
        end
      end)

    {if(items == [], do: nil, else: Enum.reverse(items)), Enum.reverse(issues)}
  end

  def encode(enc, _raw), do: {nil, [{:load_type_mismatch, mismatch(enc)}]}

  defp parts(parts, raw) do
    {pairs, issues} =
      Enum.map_reduce(parts, [], fn {id, member, enc}, issues ->
        {v, i} = encode(enc, Map.get(raw, id))
        {{member, v}, issues ++ i}
      end)

    {Map.new(pairs), issues}
  end

  defp mismatch({kind, _, _}), do: kind
  defp mismatch({kind, _}), do: kind
  defp mismatch(kind), do: kind

  defp iso(%DateTime{} = dt) do
    {us, _} = dt.microsecond

    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> Map.put(:microsecond, {us, 6})
    |> DateTime.to_iso8601()
  end
end
