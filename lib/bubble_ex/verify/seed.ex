defmodule BubbleEx.Verify.Seed do
  @moduledoc """
  A seed set: synthetic records and the personas that act on them, loaded
  identically into the Bubble replay branch and the target app (WTF-358
  §3.6). Stored as `.wtf/verification/seeds/<id>.json` in the owner repo.

  ```json
  {
    "format": "bubble_ex.verify.seed",
    "schema_version": 1,
    "id": "privacy_matrix",
    "personas": {
      "anonymous": {"user": null},
      "w1_member": {"user": "user_w1"}
    },
    "records": [
      {"key": "task_w1", "type": "custom.task",
       "fields": {"Created By": {"ref": "user_w1"}, "title_text": {"text": ""}}},
      {"key": "user_w1", "type": "user",
       "fields": {"email": {"text": "w1@replay.wtf.invalid"}}}
    ]
  }
  ```

    * `records` - each has a symbolic `key` (the seed ledger binds it to the
      Bubble ID the Bubble loader gets back), a `type` Bubble ID and
      `fields` keyed by field Bubble ID, holding `BubbleEx.Verify.Value`s. A
      `ref` names another record's key. Sorted by key; keys are unique.
      A seed describes records **as stored after creation**: a field it
      omits is what creation leaves (its default, if it has one, under the
      interpreter's `defaults_applied_at_creation`; matrix seeds write
      defaults out). A field set to `null` is **explicitly empty**: for a
      field with a default, a loader must clear it after creating the
      record (whether Bubble can store it empty at creation is unverified)
    * `personas` - symbolic personas: `user` is the key of a `user` record,
      or `null` for an anonymous visitor. Never passwords or tokens: the
      driver creates those per run

  **Synthetic data only.** Seeds are committed, so anything else is
  `:invalid_input`:

    * every email address in a text value must use a reserved domain
      (`.invalid`, `.test`, `.example`, `.localhost`, or
      `example.com`/`.net`/`.org`)
    * every file and image URL must be on such a domain (a real Bubble
      file URL can reach a private upload)
    * a phone-like digit run in text (7 to 15 digits, optionally with `+`,
      spaces, dots, dashes or parentheses) must end in a fictional
      `555-01xx` number; `json` values are not checked for these
  """

  alias BubbleEx.{CanonicalJson, Error}
  alias BubbleEx.Verify.{Json, Value}

  @format "bubble_ex.verify.seed"
  @schema_version 1
  @members ~w(format schema_version id personas records)

  @email ~r/[A-Za-z0-9._%+\-]+@([A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+)/
  @phone ~r/(?<![\w.])\+?\(?\d[\d ().\-]{5,}\d(?![\w])/
  @reserved_tlds ~w(invalid test example localhost)
  @reserved_domains ~w(example.com example.net example.org)

  @type seed_record :: %{key: String.t(), type: String.t(), fields: %{String.t() => Value.t()}}
  @type persona :: %{user: String.t() | nil}
  @type t :: %__MODULE__{
          id: String.t(),
          personas: %{String.t() => persona()},
          records: [seed_record()]
        }

  @enforce_keys [:id]
  defstruct [:id, personas: %{}, records: []]

  @doc "The `format` member."
  @spec format() :: String.t()
  def format, do: @format

  @doc "The JSON format version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds and validates a seed from atom-keyed attributes (as `from_map/1`)."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      id: attrs[:id],
      personas: Map.get(attrs, :personas, %{}),
      records: Map.get(attrs, :records, [])
    }
    |> to_map()
    |> from_map()
  end

  @doc "Decodes and validates the JSON form."
  @spec from_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(map) do
    with :ok <- Json.envelope(map, @format, @schema_version, @members, @members, "seed"),
         {:ok, id} <- Json.symbol(map["id"], "seed id"),
         {:ok, records} <- Json.list(map["records"], "seed records", &record/1),
         :ok <- Json.unique(records, & &1.key, "seed record keys"),
         {:ok, personas} <- Json.object(map["personas"], "seed personas", &persona/1),
         seed = %__MODULE__{id: id, personas: personas, records: Enum.sort_by(records, & &1.key)},
         :ok <- persona_ids(personas),
         :ok <- references(seed),
         :ok <- persona_users(seed),
         :ok <- synthetic(seed) do
      {:ok, seed}
    end
  end

  defp record(map) do
    with :ok <- Json.members(map, ~w(key type fields), ~w(key type fields), "seed record"),
         {:ok, key} <- Json.symbol(map["key"], "seed record key"),
         {:ok, type} <- Json.string(map["type"], "seed record type"),
         {:ok, fields} <- Json.object(map["fields"], "seed record fields", &Value.cast/1) do
      {:ok, %{key: key, type: type, fields: fields}}
    end
  end

  defp persona(map) do
    with :ok <- Json.members(map, ~w(user), ~w(user), "persona"),
         {:ok, user} <- persona_user(map["user"]) do
      {:ok, %{user: user}}
    end
  end

  defp persona_user(nil), do: {:ok, nil}
  defp persona_user(key), do: Json.symbol(key, "persona user")

  defp persona_ids(personas) do
    case Enum.reject(Map.keys(personas), &(&1 =~ ~r/\A[a-z0-9_]+\z/)) do
      [] -> :ok
      bad -> Json.error("persona IDs must be lowercase letters, digits and _", %{personas: bad})
    end
  end

  defp references(seed) do
    keys = MapSet.new(seed.records, & &1.key)

    dangling =
      for %{key: key, fields: fields} <- seed.records,
          {field, value} <- fields,
          ref <- Value.refs(value),
          not MapSet.member?(keys, ref),
          do: %{record: key, field: field, ref: ref}

    if dangling == [],
      do: :ok,
      else: Json.error("seed references unknown records", %{refs: dangling})
  end

  defp persona_users(seed) do
    users = for %{type: "user", key: key} <- seed.records, into: MapSet.new(), do: key

    bad =
      for {id, %{user: user}} <- seed.personas,
          user != nil and not MapSet.member?(users, user),
          do: id

    if bad == [],
      do: :ok,
      else:
        Json.error("persona users must be user records of the seed", %{personas: Enum.sort(bad)})
  end

  defp synthetic(seed) do
    values = for %{key: key, fields: fields} <- seed.records, {f, v} <- fields, do: {key, f, v}

    checks = [
      {"seed emails must use a reserved domain", &email_leak?/1},
      {"seed file and image URLs must use a reserved domain", &url_leak?/1},
      {"seed phone numbers must be fictional (555-01xx)", &phone_leak?/1}
    ]

    Enum.find_value(checks, :ok, fn {message, leak?} -> leaks(values, message, leak?) end)
  end

  defp leaks(values, message, leak?) do
    case for({key, field, value} <- values, leak?.(value), do: %{record: key, field: field}) do
      [] -> nil
      at -> Json.error(message <> " (synthetic data only)", %{at: at})
    end
  end

  defp email_leak?(value) do
    Enum.any?(texts(value), fn text ->
      Enum.any?(Regex.scan(@email, text), fn [_, domain] -> not reserved?(domain) end)
    end)
  end

  defp url_leak?({kind, url}) when kind in [:file, :image] do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> not reserved?(host)
      _ -> true
    end
  end

  defp url_leak?({:list, items}), do: Enum.any?(items, &url_leak?/1)
  defp url_leak?(_), do: false

  # Text only: JSON payloads carry timestamps and IDs that look like numbers.
  defp phone_leak?({:json, _}), do: false

  defp phone_leak?(value) do
    Enum.any?(texts(value), fn text ->
      @phone
      |> Regex.scan(text)
      |> Enum.any?(fn [run] ->
        digits = String.replace(run, ~r/\D/, "")
        byte_size(digits) in 7..15 and not (digits =~ ~r/55501\d\d\z/)
      end)
    end)
  end

  defp texts({:text, s}), do: [s]
  defp texts({:list, items}), do: Enum.flat_map(items, &texts/1)
  defp texts({:geographic_address, %{formatted_address: s}}) when is_binary(s), do: [s]
  defp texts({:json, term}), do: term |> Jason.encode!() |> List.wrap()
  defp texts(_), do: []

  defp reserved?(domain) do
    domain = String.downcase(domain)
    tld = domain |> String.split(".") |> List.last()

    tld in @reserved_tlds or
      Enum.any?(@reserved_domains, &(domain == &1 or String.ends_with?(domain, "." <> &1)))
  end

  @doc "JSON form."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = seed) do
    %{
      "format" => @format,
      "schema_version" => @schema_version,
      "id" => seed.id,
      "personas" => Map.new(seed.personas, fn {id, p} -> {id, %{"user" => p.user}} end),
      "records" =>
        seed.records
        |> Enum.sort_by(& &1.key)
        |> Enum.map(fn r ->
          %{
            "key" => r.key,
            "type" => r.type,
            "fields" => Map.new(r.fields, fn {k, v} -> {k, Value.to_json(v)} end)
          }
        end)
    }
  end

  @doc "Canonical JSON text."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = seed), do: seed |> to_map() |> Json.encode()

  @doc "Decodes JSON text (see `from_map/1`)."
  @spec from_json(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_json(text), do: Json.from_json(text, "seed", &from_map/1)

  @doc "SHA-256 of the canonical JSON: what recordings and scenarios pin as `seed_sha256`."
  @spec sha256(t()) :: String.t()
  def sha256(%__MODULE__{} = seed), do: seed |> to_map() |> CanonicalJson.sha256()

  @doc "The record with `key`, or nil."
  @spec record(t(), String.t()) :: seed_record() | nil
  def record(%__MODULE__{records: records}, key), do: Enum.find(records, &(&1.key == key))
end
