defmodule BubbleEx.Verify.Json do
  @moduledoc false

  # Strict decoding helpers shared by the `BubbleEx.Verify` formats. Every
  # failure is `{:error, %BubbleEx.Error{kind: :invalid_input}}` whose
  # message names the format ("scenario", "seed", ...).

  alias BubbleEx.{CanonicalJson, Error}

  @sha256 ~r/\A[0-9a-f]{64}\z/
  # Symbolic IDs (scenario, seed, persona, record and op keys): safe as file
  # names and in URLs, never a path.
  @symbol ~r/\A[A-Za-z0-9][A-Za-z0-9_.:\-]*\z/

  @doc "Decodes JSON text, then `decode.(map)`."
  def from_json(text, what, decode) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, map} -> decode.(map)
      {:error, e} -> error("invalid #{what} JSON", %{reason: Exception.message(e)})
    end
  end

  def from_json(other, what, _decode), do: error("#{what} JSON must be a string", %{value: other})

  @doc "Canonical JSON text."
  def encode(map), do: CanonicalJson.encode(map)

  @doc """
  Checks the envelope: an object with string members, only `allowed`, every
  one of `required`, `format` equal to `format` and a supported
  `schema_version`.
  """
  def envelope(map, format, version, allowed, required, what) when is_map(map) do
    with :ok <- members(map, allowed, required, what) do
      cond do
        map["format"] != format ->
          error("#{what} format must be #{inspect(format)}", %{format: map["format"]})

        map["schema_version"] != version ->
          error("unsupported #{what} schema_version", %{
            schema_version: map["schema_version"],
            supported: version
          })

        true ->
          :ok
      end
    end
  end

  def envelope(other, _format, _version, _allowed, _required, what),
    do: error("a #{what} must be a JSON object", %{value: other})

  @doc "Only `allowed` string members, and every `required` one."
  def members(map, allowed, required, what) when is_map(map) do
    keys = Map.keys(map)

    cond do
      not Enum.all?(keys, &is_binary/1) ->
        error("#{what} members must be strings", %{members: Enum.reject(keys, &is_binary/1)})

      (extra = keys -- allowed) != [] ->
        error("unknown #{what} members", %{members: Enum.sort(extra)})

      (missing = required -- keys) != [] ->
        error("missing #{what} members", %{members: missing})

      true ->
        :ok
    end
  end

  def members(other, _allowed, _required, what),
    do: error("#{what} must be a JSON object", %{value: other})

  @doc "A non-empty string."
  def string(value, _name) when is_binary(value) and value != "", do: {:ok, value}
  def string(value, name), do: error("#{name} must be a non-empty string", %{value: value})

  @doc "A non-empty string or nil."
  def optional_string(nil, _name), do: {:ok, nil}
  def optional_string(value, name), do: string(value, name)

  @doc "A symbolic ID (letters, digits, `_ . : -`; not starting with punctuation)."
  def symbol(value, name) when is_binary(value) do
    if value =~ @symbol,
      do: {:ok, value},
      else: error("#{name} must be a symbolic ID", %{value: value})
  end

  def symbol(value, name), do: error("#{name} must be a symbolic ID", %{value: value})

  @doc "A lowercase hex SHA-256."
  def sha256(value, name) when is_binary(value) do
    if value =~ @sha256,
      do: {:ok, value},
      else: error("#{name} must be a lowercase hex SHA-256", %{value: value})
  end

  def sha256(value, name), do: error("#{name} must be a lowercase hex SHA-256", %{value: value})

  @doc "A SHA-256 or nil."
  def optional_sha256(nil, _name), do: {:ok, nil}
  def optional_sha256(value, name), do: sha256(value, name)

  @doc "One of `allowed` atoms, given as its string."
  def enum(value, allowed, name) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> error("unknown #{name}", %{value: value, allowed: allowed})
      atom -> {:ok, atom}
    end
  end

  def enum(value, allowed, name), do: error("unknown #{name}", %{value: value, allowed: allowed})

  @doc "An enum or nil."
  def optional_enum(nil, _allowed, _name), do: {:ok, nil}
  def optional_enum(value, allowed, name), do: enum(value, allowed, name)

  @doc "An ISO 8601 timestamp (with offset), as a UTC `DateTime`."
  def timestamp(value, name) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
      {:error, _} -> error("#{name} must be an ISO 8601 timestamp", %{value: value})
    end
  end

  def timestamp(value, name), do: error("#{name} must be an ISO 8601 timestamp", %{value: value})

  @doc "A timestamp or nil."
  def optional_timestamp(nil, _name), do: {:ok, nil}
  def optional_timestamp(value, name), do: timestamp(value, name)

  @doc "A non-negative integer (or nil when `optional`)."
  def count(nil, _name, :optional), do: {:ok, nil}
  def count(n, _name, _) when is_integer(n) and n >= 0, do: {:ok, n}
  def count(n, name, _), do: error("#{name} must be a non-negative integer", %{value: n})

  @doc "A boolean."
  def boolean(value, _name) when is_boolean(value), do: {:ok, value}
  def boolean(value, name), do: error("#{name} must be a boolean", %{value: value})

  @doc "Maps `fun` (returning `{:ok, v} | {:error, e}`) over a list."
  def list(values, _name, fun) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  def list(value, name, _fun), do: error("#{name} must be a list", %{value: value})

  @doc "Maps `fun` over an object's values, keeping its (non-empty string) keys."
  def object(map, name, fun) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      with {:ok, k} <- string(k, "#{name} key"),
           {:ok, v} <- fun.(v) do
        {:cont, {:ok, Map.put(acc, k, v)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  def object(value, name, _fun), do: error("#{name} must be an object", %{value: value})

  @doc "A sorted list of unique strings, each accepted by `fun`."
  def string_set(values, name, fun \\ &string/2) do
    with {:ok, list} <- list(values, name, &fun.(&1, name)) do
      case list -- Enum.uniq(list) do
        [] -> {:ok, Enum.sort(list)}
        dups -> error("#{name} has duplicates", %{duplicates: Enum.uniq(dups)})
      end
    end
  end

  @doc "Errors unless the values of `key` in `items` are unique."
  def unique(items, key, name) do
    case items |> Enum.frequencies_by(key) |> Enum.filter(fn {_, n} -> n > 1 end) do
      [] ->
        :ok

      dups ->
        error("duplicate #{name}", %{duplicates: dups |> Enum.map(&elem(&1, 0)) |> Enum.sort()})
    end
  end

  @doc "JSON form of a term: atoms as strings, timestamps as ISO 8601."
  def json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  def json(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), json(v)} end)

  def json(list) when is_list(list), do: Enum.map(list, &json/1)
  def json(value) when value in [true, false, nil], do: value
  def json(atom) when is_atom(atom), do: Atom.to_string(atom)
  def json(value), do: value

  @doc "An `:invalid_input` error."
  def error(message, context \\ %{}),
    do: {:error, Error.new(:invalid_input, message, context)}
end
