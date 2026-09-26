defmodule BubbleEx.Verify.Value do
  @moduledoc """
  A canonical Bubble value, as seeds, scenarios and recordings carry it:
  typed in Bubble's own vocabulary (WTF-338 semantics, no target types), so
  a second target stack compares against the same data.

  JSON form: `null` (Bubble's empty) or an object with exactly one member
  naming the value's type:

  | JSON | Elixir | Rule |
  |------|--------|------|
  | `null` | `nil` | empty; distinct from `{"text": ""}` |
  | `{"text": "…"}` | `{:text, s}` | kept verbatim: no trimming, `""` is not empty, and no Unicode normalization (Bubble stores and compares text as given, so NFC `é` and NFD `e\u0301` are different values; a hash over them differs) |
  | `{"number": 3.0}` | `{:number, 3.0}` | always a float (`3` decodes to `3.0`; `-0.0` to `0.0`) |
  | `{"boolean": true}` | `{:boolean, b}` | |
  | `{"date": 1727222400000}` | `{:date, ms}` | integer milliseconds since the Unix epoch, UTC |
  | `{"file": "…"}`, `{"image": "…"}` | `{:file, url}`, `{:image, url}` | the URL; Bubble's protocol-relative `//host/…` becomes `https://host/…` |
  | `{"ref": "seed_key"}` | `{:ref, key}` | a record, by its seed or recording key |
  | `{"option": "key"}` | `{:option, key}` | an option value's stable key |
  | `{"geographic_address": {…}}` | `{:geographic_address, map}` | components of `BubbleEx.Model.Structured`: `formatted_address` (string), `lat`, `lng` (floats); each may be `null` |
  | `{"date_range": {"start": ms, "end": ms}}` | `{:date_range, map}` | integer ms, each may be `null` |
  | `{"number_range": {"min": 1.0, "max": 2.0}}` | `{:number_range, map}` | floats, each may be `null` |
  | `{"date_interval": 86400000.0}` | `{:date_interval, ms}` | float milliseconds |
  | `{"json": …}` | `{:json, term}` | any JSON value, kept verbatim (the Ash target's `Types.JsonValue`) |
  | `{"list": [v, …]}` | `{:list, [v]}` | ordered; no `null` items, no nested lists, one item type. `{"list": []}` decodes to `null`: Bubble has one empty state for a list (`is empty` holds for both, and the Data API omits both), so an empty list and an unset one compare equal |

  Structured component maps use atom keys in Elixir (`%{lat: 1.0, …}`) and
  every component is present.
  """

  alias BubbleEx.Model.Structured
  alias BubbleEx.Verify.Json

  @type structured :: %{optional(atom()) => String.t() | float() | integer() | nil}
  @type scalar ::
          {:text, String.t()}
          | {:number, float()}
          | {:boolean, boolean()}
          | {:date, integer()}
          | {:file, String.t()}
          | {:image, String.t()}
          | {:ref, String.t()}
          | {:option, String.t()}
          | {:geographic_address | :date_range | :number_range, structured()}
          | {:date_interval, float()}
          | {:json, term()}
  @type t :: nil | scalar() | {:list, [scalar()]}

  # Component names as atoms, fixed at compile time from the catalog.
  @components for entry <- Structured.all(),
                  c <- entry.components,
                  into: %{},
                  do: {c.id, String.to_atom(c.id)}

  @tags ~w(text number boolean date file image ref option geographic_address
           date_range number_range date_interval json list)

  @doc "The type tags, as they appear in JSON."
  @spec tags() :: [String.t()]
  def tags, do: @tags

  @doc "Decodes and canonicalizes the JSON form."
  @spec cast(term()) :: {:ok, t()} | {:error, BubbleEx.Error.t()}
  def cast(nil), do: {:ok, nil}

  def cast(%{"list" => items} = map) when map_size(map) == 1 and is_list(items) do
    with {:ok, values} <- Json.list(items, "list", &item/1),
         :ok <- homogeneous(values) do
      {:ok, if(values == [], do: nil, else: {:list, values})}
    end
  end

  def cast(map) when is_map(map) and map_size(map) == 1 do
    [{tag, raw}] = Map.to_list(map)
    scalar(tag, raw)
  end

  def cast(other),
    do: Json.error("a value must be null or an object with one type member", %{value: other})

  @doc "Decodes a value that may not be `null` (a list item)."
  @spec item(term()) :: {:ok, scalar()} | {:error, BubbleEx.Error.t()}
  def item(%{"list" => _}), do: Json.error("lists do not nest")
  def item(nil), do: Json.error("a list item may not be null")
  def item(raw), do: cast(raw)

  defp homogeneous(values) do
    case values |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
      tags when length(tags) <= 1 -> :ok
      tags -> Json.error("list items must share one type", %{types: tags})
    end
  end

  defp scalar("text", s) when is_binary(s), do: {:ok, {:text, s}}
  defp scalar("number", n) when is_number(n), do: {:ok, {:number, float(n)}}
  defp scalar("boolean", b) when is_boolean(b), do: {:ok, {:boolean, b}}
  defp scalar("date", ms) when is_integer(ms), do: {:ok, {:date, ms}}
  defp scalar("date_interval", n) when is_number(n), do: {:ok, {:date_interval, float(n)}}
  defp scalar("json", term), do: {:ok, {:json, term}}

  defp scalar(tag, "//" <> rest) when tag in ~w(file image) do
    if rest == "",
      do: Json.error("invalid #{tag} value", %{value: "//"}),
      else: {:ok, {String.to_existing_atom(tag), "https://" <> rest}}
  end

  defp scalar(tag, s) when tag in ~w(file image ref option) and is_binary(s) and s != "",
    do: {:ok, {String.to_existing_atom(tag), s}}

  defp scalar(tag, map)
       when tag in ~w(geographic_address date_range number_range) and is_map(map),
       do: structured(String.to_existing_atom(tag), map)

  defp scalar(tag, raw) when tag in @tags,
    do: Json.error("invalid #{tag} value", %{value: raw})

  defp scalar(tag, _raw), do: Json.error("unknown value type", %{type: tag, allowed: @tags})

  defp structured(base, map) do
    components = Structured.fetch(base).components
    names = Enum.map(components, & &1.id)

    with :ok <- Json.members(map, names, names, "#{base}"),
         {:ok, parts} <- Json.list(components, "#{base}", &part(base, &1, map[&1.id])) do
      {:ok, {base, Map.new(parts)}}
    end
  end

  defp part(base, %{id: id, base: kind}, value) do
    case component(kind, value) do
      {:ok, v} -> {:ok, {Map.fetch!(@components, id), v}}
      :error -> Json.error("invalid #{base} #{id}", %{value: value})
    end
  end

  defp component(_kind, nil), do: {:ok, nil}
  defp component(:text, s) when is_binary(s), do: {:ok, s}
  defp component(:number, n) when is_number(n), do: {:ok, float(n)}
  defp component(:date, ms) when is_integer(ms), do: {:ok, ms}
  defp component(_kind, _value), do: :error

  # Floats only, and one zero.
  defp float(n) when n == 0, do: 0.0
  defp float(n), do: n / 1

  @doc "The JSON form of a canonical value."
  @spec to_json(t()) :: term()
  def to_json(nil), do: nil
  def to_json({:list, items}), do: %{"list" => Enum.map(items, &to_json/1)}

  def to_json({base, parts}) when base in [:geographic_address, :date_range, :number_range],
    do: %{Atom.to_string(base) => Map.new(parts, fn {k, v} -> {Atom.to_string(k), v} end)}

  def to_json({tag, value}), do: %{Atom.to_string(tag) => value}

  @doc """
  Canonicalizes an already-typed value (e.g. built in Elixir): the same as
  `to_json/1` then `cast/1`.
  """
  @spec canonical(t()) :: {:ok, t()} | {:error, BubbleEx.Error.t()}
  def canonical(value), do: value |> to_json() |> cast()

  @doc "The record keys a value references (`ref` values, in lists too)."
  @spec refs(t()) :: [String.t()]
  def refs({:ref, key}), do: [key]
  def refs({:list, items}), do: Enum.flat_map(items, &refs/1)
  def refs(_), do: []
end
