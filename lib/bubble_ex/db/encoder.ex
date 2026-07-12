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
    plan = BubbleEx.Db.Encoder.Plan.build(db_map, opts)

    with {:ok, module} <- module_for(format),
         {:ok, mode} <- external_type_mode(db_map, opts),
         :ok <- validate_capabilities(format, opts),
         {:ok, content} <-
           module.encode(
             db_map,
             opts |> Keyword.put(:external_types, mode) |> Keyword.put(:_external_plan, plan)
           ) do
      warnings =
        (Map.get(db_map, :warnings, []) ++
           renderer_warnings(db_map, format, mode, plan) ++
           graph_warnings(plan, format, mode, opts))
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
          target == format and target in Map.keys(allowed) and is_list(values) and
            Enum.all?(values, &(&1 in Map.fetch!(allowed, target)))
        end)

    if valid?,
      do: :ok,
      else:
        {:error, Error.new(:invalid_input, "invalid external type capability", %{format: format})}
  end

  defp renderer_warnings(db_map, format, mode, plan) do
    db_map
    |> Map.get(:tables, [])
    |> Enum.flat_map(& &1.columns)
    |> Enum.filter(
      &(&1.type.type in [:external, :opaque_external] and root_loss?(&1, format, mode, plan))
    )
    |> Enum.map(fn column ->
      %{
        kind: :external_type_rendering,
        target: format,
        source: column.type[:target],
        field: %{table_group: column.table_group, table_id: column.table_id, field_id: column.id},
        occurrences: [
          %{
            root: %{
              table_group: column.table_group,
              table_id: column.table_id,
              field_id: column.id
            },
            path: []
          }
        ],
        cardinality: column.type.cardinality,
        reason: root_reason(column, format, mode, plan),
        fallback: if(mode == :legacy, do: :legacy, else: :json),
        mode: mode
      }
    end)
    |> Enum.sort_by(&{&1.source || "", &1.field.table_id, &1.field.field_id})
  end

  defp root_loss?(_column, _format, mode, _plan) when mode in [:opaque, :legacy], do: true
  defp root_loss?(%{type: %{type: :opaque_external}}, _format, :preserve, _plan), do: true

  defp root_loss?(_column, format, :preserve, _plan) when format in [:dbml, :sqlite, :tsql],
    do: true

  defp root_loss?(column, _format, :preserve, plan),
    do: not BubbleEx.Db.Encoder.Plan.resolved?(plan, column.type.target)

  defp root_reason(_column, _format, :opaque, _plan), do: :selected_opaque_mode
  defp root_reason(_column, _format, :legacy, _plan), do: :selected_legacy_mode

  defp root_reason(%{type: %{type: :opaque_external}}, _format, :preserve, _plan),
    do: :unresolved_root

  defp root_reason(_column, format, :preserve, _plan) when format in [:dbml, :sqlite, :tsql],
    do: :target_opaque

  defp root_reason(_column, _format, :preserve, _plan), do: :unresolved_root

  defp graph_warnings(_plan, _format, mode, _opts) when mode != :preserve, do: []

  defp graph_warnings(plan, format, :preserve, opts) do
    shape_formats = [:postgres, :ecto, :ash, :zod, :xano, :convex]

    if format in shape_formats do
      plan.nodes
      |> Map.values()
      |> Enum.flat_map(fn node ->
        node.fields
        |> Enum.filter(&(&1.type.type == :external))
        |> Enum.flat_map(fn field ->
          cond do
            not BubbleEx.Db.Encoder.Plan.resolved?(plan, field.type.target) ->
              [graph_warning(plan, format, node.id, field, :unresolved_nested_target)]

            format != :zod and not recursive_capability?(format, opts) and
                BubbleEx.Db.Encoder.Plan.cycle_edge?(plan, node.id, field.id) ->
              [graph_warning(plan, format, node.id, field, :cycle_edge)]

            true ->
              []
          end
        end)
      end)
    else
      []
    end
  end

  defp recursive_capability?(:ecto, opts),
    do:
      :recursive_embeds in (opts
                            |> Keyword.get(:external_type_capabilities, %{})
                            |> Map.get(:ecto, []))

  defp recursive_capability?(:ash, opts),
    do:
      :recursive_new_type in (opts
                              |> Keyword.get(:external_type_capabilities, %{})
                              |> Map.get(:ash, []))

  defp recursive_capability?(_format, _opts), do: false

  defp graph_warning(plan, format, source, field, reason) do
    %{
      kind: :external_type_rendering,
      target: format,
      source: source,
      field: %{external_type_id: source, field_id: field.id},
      occurrences: BubbleEx.Db.Encoder.Plan.occurrences(plan, source, field.id),
      cardinality: field.type.cardinality,
      reason: reason,
      fallback: :json,
      mode: :preserve
    }
  end
end
