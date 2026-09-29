defmodule BubbleEx.Buildprint.V5 do
  @moduledoc """
  Reads the Bubble app JSON out of a Buildprint v5 workspace.

  A v5 workspace (a `buildprint project clone` directory) holds BubbleScript
  `.ts` sources plus `.buildprint/index.sqlite`, whose `snapshot_roots` table
  keeps Bubble's raw editor app JSON: one `__preamble__` row with the whole
  app object (pages and reusable elements only as stubs), one fragment row
  per source file (a partial app object holding complete definitions, e.g.
  `%{"user_types" => %{id => type}}`) and a `__manifest__` row listing every
  row's SHA-256. This module reads that data file; it never reads the `.ts`
  sources and never writes to the workspace.

  `load/2` returns the app in the shape `BubbleEx.Model.build/2` (and every
  other reader of `.bubble` JSON or `BubbleEx.fetch_app/2` payloads) takes:

    * **Read-only.** The index is opened with `mode=ro&immutable=1` and
      `PRAGMA query_only` (see `BubbleEx.Buildprint.V5.Sqlite`).
    * **Versions.** The index's `formatVersion` and `schemaVersion` (and
      `.buildprint/state.json`'s `formatVersion`, when present) must be in an
      allowlist (`supported_versions/0`); anything else is an
      `:unknown_format` error rather than a best-effort read.
    * **Integrity.** Every row's `content_sha256` must be the SHA-256 of its
      JSON, root keys must be unique, and the manifest must list exactly the
      rows it describes, each once. An index with a pending write-ahead log
      (a non-empty `index.sqlite-wal`) or a rollback journal
      (`index.sqlite-journal`) is refused: an immutable open would silently
      ignore them and read stale data. An index larger than
      `:max_index_bytes` (default 512 MB) is refused too.
    * **Merge.** Fragments are applied onto the preamble and win: each
      definition a fragment holds (a data type, option set, page, reusable
      element, workflow, style, API Connector group, ...) replaces the
      preamble's copy as a whole, provided the fragment's root key (its
      source path) owns that section (`data-types/` writes `user_types`,
      `api-connector/` writes `settings.client_safe.apiconnector2`, ...;
      other members are ignored), so a stub or a `deleted` flag the fragment
      does not carry does not survive. Deleted definitions are kept with
      their `deleted` flag, as Bubble and `BubbleEx.Model` expect. Buildprint's
      own top-level members (`__bp_*`, `_index`) are dropped, and of
      `settings` only `client_safe` is kept.
    * **Checks.** The app is built into a `BubbleEx.Model` (returned as
      `model`), and the counts of its data types, fields, option sets and API
      calls, plus the app's pages and workflows (`counts/2`, deleted ones
      included), are compared with the index's `symbols` table; each
      difference is a `:buildprint_count_mismatch` diagnostic.

  Diagnostics carry counts and section names only, never a key, value,
  display name or file name read from the workspace. Buildprint shows
  secrets only as opaque `secret("$bp…")` handles in the `.ts` sources, and
  the raw JSON holds only `client_safe` settings; any string that
  nevertheless contains a handle is replaced by `""` (a key containing one
  drops its member) and counted in a `:buildprint_secret_handle` diagnostic.

  The manifest's `snapshotJsonSha256` hashes Buildprint's serialization of
  the snapshot, which is not reproducible from the stored rows (member
  order and number formatting are not recorded); `load/2` reports whether
  the canonical JSON of the merged app matches it (`snapshot.reproduced`)
  and emits an informational `:buildprint_snapshot_unverified` diagnostic
  when it does not. The per-row hashes above are verified instead.

  SQLite access needs the optional `exqlite` dependency. Without it,
  `load/2` returns a `:dependency_missing` error; add
  `{:exqlite, "~> 0.41"}` to the application's dependencies. bubble_ex
  decides at compile time whether `exqlite` is present, so after adding it
  to an application that already compiled bubble_ex, recompile it with
  `mix deps.compile bubble_ex --force`.
  """

  alias BubbleEx.{CanonicalJson, Diagnostic, Error, Model}
  alias BubbleEx.Buildprint.V5.Sqlite

  # Defined only when the optional `exqlite` dependency is loaded.
  @compile {:no_warn_undefined, Sqlite}

  @format_versions ["bubblescript-31"]
  @schema_versions ["16"]
  @manifest_versions [5]

  # App members a fragment may hold, keyed by definition ID.
  @entity_sections ~w(user_types option_sets pages element_definitions mobile_views api styles comments)
  # Sections whose preamble entries are stubs a fragment completes.
  @stub_sections ~w(pages element_definitions mobile_views)
  @owner_sections ~w(pages element_definitions mobile_views)

  # Which app members a fragment may write, by its root key's first path
  # segment: whole sections, and keys of `settings.client_safe`
  # (`:connector` = only `apiconnector2`, `:any` = any but `apiconnector2`).
  @fragment_owners %{
    "api-connector" => {[], :connector},
    "backend-workflows" => {~w(api comments), ~w(api_wf_folder_list)},
    "comments" => {~w(comments), []},
    "data-types" => {~w(user_types comments), []},
    "mobile-views" => {~w(mobile_views comments), []},
    "option-sets" => {~w(option_sets comments), []},
    "pages" => {~w(pages comments), []},
    "reusable-elements" => {~w(element_definitions comments), []},
    "settings" => {[], :any},
    "styles" =>
      {~w(styles comments), ~w(color_tokens color_tokens_user font_tokens font_tokens_user)}
  }

  @state_limit 1_000_000
  @max_index_bytes 512 * 1024 * 1024
  @secret_handle ~r/\$bp/
  @sha256_hex ~r/\A[0-9a-f]{64}\z/

  defstruct app: %{},
            model: nil,
            format_version: nil,
            schema_version: nil,
            counts: %{},
            symbol_counts: %{},
            snapshot: %{},
            diagnostics: []

  @type t :: %__MODULE__{
          app: map(),
          model: Model.t(),
          format_version: String.t(),
          schema_version: String.t(),
          counts: %{String.t() => non_neg_integer()},
          symbol_counts: %{String.t() => non_neg_integer()},
          snapshot: %{expected: String.t() | nil, reproduced: boolean()},
          diagnostics: [Diagnostic.t()]
        }

  @typedoc "A fragment row: its root key and its decoded JSON (a partial app object)."
  @type fragment :: {String.t(), term()}

  @doc "The accepted `formatVersion`, `schemaVersion` and manifest `version` values."
  @spec supported_versions() :: %{
          format: [String.t()],
          schema: [String.t()],
          manifest: [pos_integer()]
        }
  def supported_versions,
    do: %{format: @format_versions, schema: @schema_versions, manifest: @manifest_versions}

  @doc "Whether the optional `exqlite` dependency (needed by `load/2`) is available."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Sqlite)

  @doc """
  Whether `path` is a Buildprint v5 workspace: a directory holding
  `.buildprint/index.sqlite`, or the `.buildprint` directory itself.
  """
  @spec workspace?(Path.t()) :: boolean()
  def workspace?(path) when is_binary(path), do: File.regular?(index_path(path))

  @doc """
  Loads the app JSON of the workspace at `path` (see `workspace?/1`).

  Returns `{:ok, %BubbleEx.Buildprint.V5{}}` with the merged `app`, its
  `model`, the versions read, `counts/2`, the index's symbol counts, the
  snapshot hash check and normalized diagnostics. Fails with
  `:dependency_missing` (no `exqlite`), `:invalid_input` (not a
  workspace), `:unknown_format` (a version outside the allowlist) or
  `:parse_failed` (a missing table, a malformed or tampered row, a pending
  write-ahead log or journal) or `:body_too_large` (an index larger than
  the limit).

  ## Options

    * `:max_index_bytes` - the largest `index.sqlite` read (default 512 MB)
  """
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def load(path, opts \\ []) when is_binary(path) and is_list(opts) do
    with :ok <- ensure_available(),
         :ok <- ensure_workspace(path),
         :ok <- ensure_settled(index_path(path)),
         :ok <-
           ensure_size(index_path(path), Keyword.get(opts, :max_index_bytes, @max_index_bytes)),
         {:ok, state_format} <- read_state(path),
         {:ok, read} <- Sqlite.read(index_path(path)),
         {:ok, format, schema} <- check_versions(read.metadata, state_format),
         {:ok, preamble, fragments, manifest} <- split_roots(read.roots),
         {app, merge_diagnostics} = merge(preamble, fragments),
         {:ok, model} <- Model.build(app) do
      counts = counts(app, model)

      expected =
        sha256_hex(manifest["snapshotJsonSha256"]) ||
          sha256_hex(read.metadata["snapshotJsonSha256"])

      reproduced = is_binary(expected) and CanonicalJson.sha256(app) == expected

      diagnostics =
        merge_diagnostics ++
          count_diagnostics(counts, read.symbol_counts) ++ snapshot_diagnostics(reproduced)

      {:ok,
       %__MODULE__{
         app: app,
         model: model,
         format_version: format,
         schema_version: schema,
         counts: counts,
         symbol_counts: read.symbol_counts,
         snapshot: %{expected: expected, reproduced: reproduced},
         diagnostics: Diagnostic.normalize(diagnostics)
       }}
    end
  end

  @doc """
  Applies `fragments` onto `preamble` (see the moduledoc) and returns the
  app with its diagnostics. `fragments` are `{root_key, decoded JSON}` pairs,
  applied in order. Pure; `load/2` calls it after reading the index.
  """
  @spec merge(map(), [fragment() | term()]) :: {map(), [Diagnostic.t()]}
  def merge(preamble, fragments) when is_map(preamble) and is_list(fragments) do
    base = drop_buildprint_members(preamble)
    acc = %{app: base, covered: MapSet.new(), ignored: 0, overlaps: 0, dropped_settings: 0}
    acc = Enum.reduce(fragments, acc, &apply_fragment/2)

    {settings, dropped_settings} = client_safe_only(acc.app["settings"])

    {app, handles} =
      acc.app
      |> put_settings(settings)
      |> drop_buildprint_members()
      |> redact()

    diagnostics =
      stub_diagnostics(base, acc.covered) ++
        counted(
          acc.ignored,
          &Diagnostic.new(
            :buildprint_fragment_ignored,
            ["snapshot_roots"],
            "fragment rows or members outside the app sections were ignored",
            details: %{count: &1}
          )
        ) ++
        counted(
          acc.overlaps,
          &Diagnostic.new(
            :buildprint_fragment_overlap,
            ["snapshot_roots"],
            "definitions held by more than one fragment; the last by root key was kept",
            details: %{count: &1}
          )
        ) ++
        counted(
          acc.dropped_settings + dropped_settings,
          &Diagnostic.new(
            :buildprint_settings_dropped,
            ["settings"],
            "settings other than client_safe were dropped unread",
            details: %{count: &1}
          )
        ) ++
        counted(
          handles,
          &Diagnostic.new(
            :buildprint_secret_handle,
            [],
            "strings or keys holding a Buildprint secret handle were redacted",
            details: %{count: &1}
          )
        )

    {app, Diagnostic.normalize(diagnostics)}
  end

  @doc """
  Counts compared with the Buildprint `symbols` index, deleted definitions
  included: the `model`'s data types, fields, option sets and API Connector
  calls (as `BubbleEx.Model.summary/1` counts them), and the app's pages
  and workflows (backend workflows plus the workflows of pages, reusable
  elements and mobile views; JSON-object entries only).
  """
  @spec counts(map(), Model.t()) :: %{String.t() => non_neg_integer()}
  def counts(app, %Model{} = model) when is_map(app) do
    owner_workflows =
      for section <- @owner_sections,
          {_, owner} <- objects(app[section]),
          reduce: 0,
          do: (n -> n + map_size(objects(owner["workflows"])))

    model
    |> Model.summary()
    |> Map.take(~w(data_types fields option_sets api_calls))
    |> Map.merge(%{
      "pages" => map_size(objects(app["pages"])),
      "workflows" => map_size(objects(app["api"])) + owner_workflows
    })
  end

  # --- reading --------------------------------------------------------------

  defp ensure_available do
    if available?(),
      do: :ok,
      else:
        {:error,
         Error.new(
           :dependency_missing,
           "reading a Buildprint v5 workspace needs the optional exqlite dependency; add {:exqlite, \"~> 0.41\"} to your deps",
           %{dependency: :exqlite}
         )}
  end

  defp ensure_workspace(path) do
    if workspace?(path),
      do: :ok,
      else: {:error, Error.new(:invalid_input, "not a Buildprint v5 workspace")}
  end

  # `immutable=1` makes SQLite ignore a write-ahead log or hot journal, so
  # committed changes still in one would silently be missing.
  defp ensure_settled(index) do
    wal = File.stat(index <> "-wal")

    cond do
      match?({:ok, %File.Stat{size: size}} when size > 0, wal) ->
        {:error, pending("write-ahead log (index.sqlite-wal)")}

      File.exists?(index <> "-journal") ->
        {:error, pending("rollback journal (index.sqlite-journal)")}

      true ->
        :ok
    end
  end

  defp pending(what),
    do:
      Error.new(
        :parse_failed,
        "the Buildprint index has a pending #{what}; let Buildprint finish (or checkpoint it) and retry",
        %{reason: :pending_writes}
      )

  defp ensure_size(index, limit) when is_integer(limit) and limit > 0 do
    case File.stat(index) do
      {:ok, %File.Stat{size: size}} when size <= limit ->
        :ok

      {:ok, %File.Stat{size: size}} ->
        {:error,
         Error.new(:body_too_large, "the Buildprint index exceeds :max_index_bytes", %{
           size: size,
           limit: limit
         })}

      {:error, _} ->
        {:error, Error.new(:parse_failed, "cannot read the Buildprint index")}
    end
  end

  defp ensure_size(_index, _limit),
    do: {:error, Error.new(:invalid_input, ":max_index_bytes must be a positive integer")}

  defp buildprint_dir(path) do
    if Path.basename(path) == ".buildprint", do: path, else: Path.join(path, ".buildprint")
  end

  defp index_path(path), do: path |> buildprint_dir() |> Path.join("index.sqlite")

  # `.buildprint/state.json` repeats the format version; read it when present.
  defp read_state(path) do
    file = path |> buildprint_dir() |> Path.join("state.json")

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @state_limit <-
           File.stat(file),
         {:ok, text} <- File.read(file),
         {:ok, %{} = state} <- Jason.decode(text) do
      {:ok, state["formatVersion"]}
    else
      {:error, :enoent} -> {:ok, nil}
      _ -> {:error, Error.new(:parse_failed, "unreadable .buildprint/state.json")}
    end
  end

  defp check_versions(metadata, state_format) do
    format = metadata["formatVersion"]
    schema = metadata["schemaVersion"]

    cond do
      format not in @format_versions ->
        unknown("formatVersion", format, @format_versions)

      state_format not in [nil, format] ->
        unknown("state.json formatVersion", state_format, [format])

      schema not in @schema_versions ->
        unknown("schemaVersion", schema, @schema_versions)

      true ->
        {:ok, format, schema}
    end
  end

  defp unknown(what, value, supported) do
    {:error,
     Error.new(:unknown_format, "unsupported Buildprint #{what}", %{
       field: what,
       value: printable(value),
       supported: supported
     })}
  end

  # Versions are short tokens; anything else is not echoed back.
  defp printable(value) when is_binary(value) and byte_size(value) <= 40 do
    if value =~ ~r/\A[A-Za-z0-9._-]*\z/ and not (value =~ @secret_handle),
      do: value,
      else: "(unprintable)"
  end

  defp printable(nil), do: nil
  defp printable(_), do: "(unprintable)"

  defp split_roots(roots) do
    with :ok <- verify_rows(roots),
         :ok <- verify_hashes(roots),
         {:ok, manifest} <- manifest(roots),
         :ok <- verify_manifest(manifest, roots),
         {:ok, preamble} <- preamble(roots) do
      fragments =
        for %{root_key: key, json: json} <- roots,
            key not in ["__preamble__", "__manifest__"],
            do: {key, decode_fragment(json)}

      if Enum.any?(fragments, &match?({_, {:error, _}}, &1)),
        do: {:error, Error.new(:parse_failed, "a Buildprint snapshot row is not valid JSON")},
        else: {:ok, preamble, fragments, manifest}
    end
  end

  # Text columns only (SQLite's typing is per value), each root key once.
  defp verify_rows(roots) do
    cond do
      not Enum.all?(
        roots,
        &(is_binary(&1.root_key) and is_binary(&1.json) and is_binary(&1.content_sha256))
      ) ->
        {:error, Error.new(:parse_failed, "a Buildprint snapshot row is not text")}

      length(Enum.uniq_by(roots, & &1.root_key)) != length(roots) ->
        {:error, Error.new(:parse_failed, "a Buildprint snapshot root key appears twice")}

      true ->
        :ok
    end
  end

  defp verify_hashes(roots) do
    if Enum.all?(roots, &(sha256(&1.json) == &1.content_sha256)),
      do: :ok,
      else: {:error, Error.new(:parse_failed, "a Buildprint snapshot row fails its content hash")}
  end

  defp manifest(roots) do
    with %{json: json} <- Enum.find(roots, &(&1.root_key == "__manifest__")),
         {:ok, %{"version" => version} = manifest} when version in @manifest_versions <-
           Jason.decode(json) do
      {:ok, manifest}
    else
      nil ->
        {:error, Error.new(:parse_failed, "the Buildprint index has no snapshot manifest")}

      {:ok, %{"version" => version}} ->
        unknown("manifest version", to_string_safe(version), @manifest_versions)

      _ ->
        {:error, Error.new(:parse_failed, "the Buildprint snapshot manifest is malformed")}
    end
  end

  defp to_string_safe(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_safe(value), do: value

  defp verify_manifest(%{"roots" => listed}, roots) when is_list(listed) do
    keys = Enum.map(listed, &(is_map(&1) && &1["rootKey"]))

    listed =
      MapSet.new(listed, fn
        %{"rootKey" => key, "contentSha256" => sha} -> {key, sha}
        _ -> :malformed
      end)

    stored =
      for %{root_key: key, content_sha256: sha} <- roots,
          key != "__manifest__",
          into: MapSet.new(),
          do: {key, sha}

    if length(Enum.uniq(keys)) == length(keys) and MapSet.equal?(listed, stored),
      do: :ok,
      else:
        {:error,
         Error.new(:parse_failed, "the Buildprint snapshot manifest does not match its rows")}
  end

  defp verify_manifest(_, _),
    do: {:error, Error.new(:parse_failed, "the Buildprint snapshot manifest is malformed")}

  defp preamble(roots) do
    with %{json: json} <- Enum.find(roots, &(&1.root_key == "__preamble__")),
         {:ok, %{} = preamble} <- Jason.decode(json) do
      {:ok, preamble}
    else
      _ -> {:error, Error.new(:parse_failed, "the Buildprint snapshot has no readable preamble")}
    end
  end

  defp decode_fragment(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      {:error, _} -> {:error, :json}
    end
  end

  # --- merging --------------------------------------------------------------

  defp apply_fragment({root_key, fragment}, acc) when is_binary(root_key) and is_map(fragment) do
    case owner(root_key) do
      {sections, client_safe} -> apply_members(fragment, sections, client_safe, acc)
      nil -> %{acc | ignored: acc.ignored + max(map_size(fragment), 1)}
    end
  end

  defp apply_fragment(_, acc), do: %{acc | ignored: acc.ignored + 1}

  defp owner(root_key) do
    case String.split(root_key, "/", parts: 2) do
      [prefix, _] -> Map.get(@fragment_owners, prefix)
      _ -> nil
    end
  end

  defp apply_members(fragment, sections, client_safe, acc) do
    Enum.reduce(fragment, acc, fn
      {section, entries}, acc when section in @entity_sections and is_map(entries) ->
        if section in sections,
          do: put_entities(acc, [section], entries),
          else: %{acc | ignored: acc.ignored + 1}

      {"settings", settings}, acc when is_map(settings) and client_safe != [] ->
        apply_settings(settings, client_safe, acc)

      _, acc ->
        %{acc | ignored: acc.ignored + 1}
    end)
  end

  defp apply_settings(settings, allowed, acc) do
    Enum.reduce(settings, acc, fn
      {"client_safe", client_safe}, acc when is_map(client_safe) ->
        Enum.reduce(client_safe, acc, &apply_client_safe(&1, allowed, &2))

      {"client_safe", _}, acc ->
        %{acc | ignored: acc.ignored + 1}

      _, acc ->
        %{acc | dropped_settings: acc.dropped_settings + 1}
    end)
  end

  defp apply_client_safe({"apiconnector2", groups}, :connector, acc) when is_map(groups),
    do: put_entities(acc, ["settings", "client_safe", "apiconnector2"], groups)

  defp apply_client_safe({key, value}, allowed, acc) do
    if client_safe_key?(key, allowed),
      do: put_entities(acc, ["settings", "client_safe"], %{key => value}),
      else: %{acc | ignored: acc.ignored + 1}
  end

  defp client_safe_key?("apiconnector2", _allowed), do: false
  defp client_safe_key?(_key, :any), do: true
  defp client_safe_key?(key, allowed) when is_list(allowed), do: key in allowed
  defp client_safe_key?(_key, _allowed), do: false

  # Each entry replaces the app's entry at `path ++ [key]` as a whole.
  defp put_entities(acc, path, entries) do
    Enum.reduce(entries, acc, fn {key, value}, acc ->
      id = {path, key}
      overlaps = if MapSet.member?(acc.covered, id), do: acc.overlaps + 1, else: acc.overlaps

      %{
        acc
        | app: put_path(acc.app, path ++ [key], value),
          covered: MapSet.put(acc.covered, id),
          overlaps: overlaps
      }
    end)
  end

  # Creates (or replaces non-object) containers along the way.
  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    child = if is_map(map[key]), do: map[key], else: %{}
    Map.put(map, key, put_path(child, rest, value))
  end

  defp client_safe_only(%{} = settings) do
    dropped = settings |> Map.delete("client_safe") |> map_size()

    case settings["client_safe"] do
      %{} = client_safe -> {%{"client_safe" => client_safe}, dropped}
      nil -> {%{}, dropped}
      _ -> {%{}, dropped + 1}
    end
  end

  defp client_safe_only(nil), do: {nil, 0}
  defp client_safe_only(_), do: {nil, 1}

  defp put_settings(app, nil), do: Map.delete(app, "settings")
  defp put_settings(app, settings), do: Map.put(app, "settings", settings)

  defp drop_buildprint_members(app),
    do: app |> Map.reject(fn {key, _} -> buildprint_member?(key) end)

  defp buildprint_member?("_index"), do: true
  defp buildprint_member?("__bp" <> _), do: true
  defp buildprint_member?(_), do: false

  # Replaces strings holding a secret handle by "" and drops members whose
  # key holds one; returns the app and how many it touched.
  defp redact(value), do: redact(value, 0)

  defp redact(map, n) when is_map(map) do
    Enum.reduce(map, {%{}, n}, fn {key, value}, {acc, n} ->
      if is_binary(key) and key =~ @secret_handle do
        {acc, n + 1}
      else
        {value, n} = redact(value, n)
        {Map.put(acc, key, value), n}
      end
    end)
  end

  defp redact(list, n) when is_list(list) do
    {items, n} = Enum.map_reduce(list, n, &redact/2)
    {items, n}
  end

  defp redact(string, n) when is_binary(string) do
    if string =~ @secret_handle, do: {"", n + 1}, else: {string, n}
  end

  defp redact(other, n), do: {other, n}

  # --- diagnostics ------------------------------------------------------------

  defp stub_diagnostics(preamble, covered) do
    for section <- @stub_sections,
        stubs =
          Enum.count(objects(preamble[section]), fn {key, _} ->
            not MapSet.member?(covered, {[section], key})
          end),
        stubs > 0 do
      Diagnostic.new(
        :buildprint_stub_unresolved,
        [section],
        "#{stubs} #{section} entries are preamble stubs no fragment completes; kept as stubs",
        details: %{section: section, count: stubs}
      )
    end
  end

  defp counted(0, _diagnostic), do: []
  defp counted(count, diagnostic), do: [diagnostic.(count)]

  defp count_diagnostics(counts, symbol_counts) do
    for {kind, symbols} <- Enum.sort(symbol_counts),
        loaded = Map.get(counts, kind, 0),
        loaded != symbols do
      Diagnostic.new(
        :buildprint_count_mismatch,
        ["symbols", kind],
        "#{kind}: #{loaded} loaded, #{symbols} in the Buildprint symbol index",
        details: %{kind: kind, loaded: loaded, symbols: symbols}
      )
    end
  end

  defp snapshot_diagnostics(true), do: []

  defp snapshot_diagnostics(false) do
    [
      Diagnostic.new(
        :buildprint_snapshot_unverified,
        ["snapshot_roots"],
        "the manifest's snapshotJsonSha256 is not reproducible from the stored rows; each row's content hash was verified instead"
      )
    ]
  end

  # --- helpers ----------------------------------------------------------------

  defp objects(%{} = map), do: Map.filter(map, fn {_, v} -> is_map(v) end)
  defp objects(_), do: %{}

  defp sha256_hex(value) when is_binary(value),
    do: if(value =~ @sha256_hex, do: value)

  defp sha256_hex(_), do: nil

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
