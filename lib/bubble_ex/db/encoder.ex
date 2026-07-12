defmodule BubbleEx.Db.Encoder do
  @moduledoc """
  Behaviour shared by every database-schema renderer (DBML, SQL dialects, ...).

  An encoder turns the universal `db_map` produced by `BubbleEx.Db.Reader.parse/1`
  into a textual schema for one target format. `module_for/1` resolves a format
  atom to its encoder module.
  """

  alias BubbleEx.Error

  defmodule Result do
    @moduledoc "Detailed schema-rendering result."
    @enforce_keys [:format, :content, :warnings]
    defstruct [:format, :content, :warnings]

    @type t() :: %__MODULE__{format: atom(), content: String.t(), warnings: [map()]}
  end

  @callback encode(db_map :: map(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, Error.t()}

  # format atom => encoder module. New adapters register here.
  @formats %{
    dbml: BubbleEx.Db.Dbml,
    postgres: BubbleEx.Db.Sql.Postgres,
    sqlite: BubbleEx.Db.Sql.Sqlite,
    tsql: BubbleEx.Db.Sql.Tsql,
    ecto: BubbleEx.Db.Ecto,
    ash: BubbleEx.Db.Ash,
    zod: BubbleEx.Db.Zod,
    xano: BubbleEx.Db.Xano,
    convex: BubbleEx.Db.Convex
  }

  @doc """
  Resolves a format atom to its encoder module, or an `:unknown_format` error.
  """
  @spec module_for(atom()) :: {:ok, module()} | {:error, Error.t()}
  def module_for(format) when is_map_key(@formats, format),
    do: {:ok, Map.fetch!(@formats, format)}

  def module_for(format) do
    {:error,
     Error.new(:unknown_format, "unknown schema format: #{inspect(format)}", %{format: format})}
  end

  @doc "Renders a registered schema format and returns artifact-scoped warnings."
  @spec render(atom(), map(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def render(format, db_map, opts \\ []) do
    with {:ok, module} <- module_for(format),
         {:ok, mode} <- external_type_mode(db_map, opts),
         :ok <- validate_capabilities(format, opts),
         {:ok, content} <- module.encode(db_map, Keyword.put(opts, :external_types, mode)) do
      warnings =
        (Map.get(db_map, :warnings, []) ++ renderer_warnings(db_map, format, mode))
        |> Enum.sort_by(&inspect/1)

      {:ok, %Result{format: format, content: content, warnings: warnings}}
    end
  end

  defp external_type_mode(db_map, opts) do
    default = if Map.has_key?(db_map, :external_types), do: :preserve, else: :legacy

    case Keyword.get(opts, :external_types, default) do
      mode when mode in [:preserve, :opaque, :legacy] -> {:ok, mode}
      mode -> {:error, Error.new(:invalid_input, "invalid external_types mode", %{mode: mode})}
    end
  end

  defp validate_capabilities(format, opts) do
    capabilities = Keyword.get(opts, :external_type_capabilities, %{})
    allowed = %{ecto: [:recursive_embeds], ash: [:recursive_new_type], tsql: [:native_json]}

    valid? =
      is_map(capabilities) and
        Enum.all?(capabilities, fn {target, values} ->
          target in Map.keys(allowed) and is_list(values) and
            Enum.all?(values, &(&1 in Map.fetch!(allowed, target)))
        end)

    if valid?,
      do: :ok,
      else:
        {:error, Error.new(:invalid_input, "invalid external type capability", %{format: format})}
  end

  defp renderer_warnings(db_map, _format, :preserve) when map_size(db_map) == 0, do: []

  defp renderer_warnings(db_map, format, mode) do
    db_map
    |> Map.get(:tables, [])
    |> Enum.flat_map(& &1.columns)
    |> Enum.filter(&(&1.type.type in [:external, :opaque_external]))
    |> Enum.map(fn column ->
      %{
        kind: :external_type_rendering,
        target: format,
        source: column.type[:target],
        field: %{table_group: column.table_group, table_id: column.table_id, field_id: column.id},
        cardinality: column.type.cardinality,
        reason: if(mode == :preserve, do: :target_opaque, else: :selected_mode),
        fallback: :json,
        mode: mode
      }
    end)
    |> Enum.sort_by(&{&1.source || "", &1.field.table_id, &1.field.field_id})
  end
end
