if Code.ensure_loaded?(Exqlite.Sqlite3) do
  defmodule BubbleEx.Buildprint.V5.Sqlite do
    @moduledoc false

    # Reads a Buildprint v5 index (`.buildprint/index.sqlite`) through the
    # optional `exqlite` dependency. Defined only when `exqlite` is loaded;
    # `BubbleEx.Buildprint.V5` checks for this module and returns a
    # `:dependency_missing` error without it.
    #
    # The file is opened read-only and immutable (`file:<path>?mode=ro&immutable=1`
    # with `SQLITE_OPEN_READONLY`, then `PRAGMA query_only`): SQLite takes no
    # locks, creates no `-wal`/`-shm`/journal files and cannot write. Only
    # `metadata`, `snapshot_roots` and aggregate counts of `symbols` are read.

    alias BubbleEx.Error
    alias Exqlite.Sqlite3

    # Symbol kinds counted for the load check, and their names in counts.
    @symbol_kinds %{
      "dataType" => "data_types",
      "field" => "fields",
      "optionSet" => "option_sets",
      "page" => "pages",
      "apiCall" => "api_calls",
      "workflow" => "workflows"
    }

    @type read :: %{
            metadata: %{String.t() => String.t()},
            roots: [%{root_key: String.t(), json: String.t(), content_sha256: String.t()}],
            symbol_counts: %{String.t() => non_neg_integer()}
          }

    @spec read(Path.t()) :: {:ok, read()} | {:error, Error.t()}
    def read(path) do
      with {:ok, conn} <- open(path) do
        try do
          read_tables(conn)
        after
          Sqlite3.close(conn)
        end
      end
    end

    @doc false
    # The SQLite URI for `path`: every byte outside the unreserved set and `/`
    # is percent-encoded, so `?`, `#` and `%` in a path cannot add parameters.
    @spec uri(Path.t()) :: String.t()
    def uri(path) do
      encoded = path |> Path.expand() |> URI.encode(&(URI.char_unreserved?(&1) or &1 == ?/))
      "file:" <> encoded <> "?mode=ro&immutable=1"
    end

    defp open(path) do
      with true <- File.regular?(path),
           {:ok, conn} <- Sqlite3.open(uri(path), mode: :readonly),
           :ok <- Sqlite3.execute(conn, "PRAGMA query_only = ON") do
        {:ok, conn}
      else
        _ -> {:error, Error.new(:parse_failed, "cannot open the Buildprint index read-only")}
      end
    end

    defp read_tables(conn) do
      kinds = Map.keys(@symbol_kinds)
      placeholders = Enum.map_join(kinds, ", ", fn _ -> "?" end)

      with {:ok, metadata} <- query(conn, "SELECT key, value FROM metadata", []),
           {:ok, roots} <-
             query(
               conn,
               "SELECT root_key, json, content_sha256 FROM snapshot_roots ORDER BY root_key",
               []
             ),
           {:ok, symbols} <-
             query(
               conn,
               "SELECT kind, count(*) FROM symbols WHERE kind IN (#{placeholders}) GROUP BY kind",
               kinds
             ) do
        {:ok,
         %{
           metadata: Map.new(metadata, fn [key, value] -> {key, value} end),
           roots:
             Enum.map(roots, fn [key, json, sha] ->
               %{root_key: key, json: json, content_sha256: sha}
             end),
           symbol_counts:
             Map.new(@symbol_kinds, fn {kind, name} ->
               {name, Enum.find_value(symbols, 0, fn [k, n] -> if k == kind, do: n end)}
             end)
         }}
      end
    end

    defp query(conn, sql, args) do
      case Sqlite3.prepare(conn, sql) do
        {:ok, statement} ->
          try do
            with :ok <- Sqlite3.bind(statement, args),
                 do: conn |> Sqlite3.fetch_all(statement) |> query_result()
          after
            Sqlite3.release(conn, statement)
          end

        error ->
          query_result(error)
      end
    end

    defp query_result({:ok, rows}), do: {:ok, rows}

    # SQLite's reason is not passed on: the table's contents stay out of errors.
    defp query_result(_),
      do: {:error, Error.new(:parse_failed, "the Buildprint index lacks an expected table")}
  end
end
