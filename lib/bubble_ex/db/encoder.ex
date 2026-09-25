defmodule BubbleEx.Db.Encoder do
  @moduledoc """
  Behaviour shared by every database-schema renderer (DBML, SQL dialects, ...).

  An encoder turns the universal `db_map` produced by `BubbleEx.Db.Reader.parse/1`
  into a textual schema for one target format. `module_for/1` resolves a format
  atom to its encoder module.

  Ash is not an encoder: it maps from `BubbleEx.Model` through
  `BubbleEx.Target.Ash` and prints with `BubbleEx.Target.Ash.Source`.
  """

  alias BubbleEx.{Diagnostic, Error}

  defmodule Result do
    @moduledoc """
    Detailed schema-rendering result. `diagnostics` are the Reader's
    diagnostics plus this target's (stage `{:target, format}`), normalized.
    """
    @enforce_keys [:format, :content, :diagnostics]
    defstruct [:format, :content, :diagnostics]

    @type t() :: %__MODULE__{
            format: atom(),
            content: String.t(),
            diagnostics: [BubbleEx.Diagnostic.t()]
          }
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

  @doc "Renders a registered schema format and returns artifact-scoped diagnostics."
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
      diagnostics =
        Diagnostic.normalize(
          Map.get(db_map, :diagnostics, []) ++
            root_diagnostics(db_map, format, mode, plan) ++
            graph_diagnostics(plan, format, mode, opts)
        )

      {:ok, %Result{format: format, content: content, diagnostics: diagnostics}}
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
    allowed = %{ecto: [:recursive_embeds], tsql: [:native_json]}

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

  defp root_diagnostics(db_map, format, mode, plan) do
    db_map
    |> Map.get(:tables, [])
    |> Enum.flat_map(& &1.columns)
    |> Enum.filter(
      &(&1.type.type in [:external, :opaque_external] and root_loss?(&1, format, mode, plan))
    )
    |> Enum.map(fn column ->
      Diagnostic.new(
        root_code(column, format, mode, plan),
        Map.get(column, :source_path) || table_pointer(column),
        "#{column.table_id}.#{column.id} is rendered as " <>
          if(mode == :legacy, do: "its legacy form", else: "JSON"),
        target: format,
        subject: column_subject(column),
        details: %{
          external_type: column.type[:target],
          cardinality: column.type.cardinality,
          fallback: if(mode == :legacy, do: :legacy, else: :json),
          mode: mode
        }
      )
    end)
  end

  defp column_subject(%{table_group: :option} = column),
    do: %{option_set: column.table_id, field: column.id}

  defp column_subject(column), do: %{type: column.table_id, field: column.id}

  defp table_pointer(%{table_group: :option, table_id: id}), do: ["option_sets", id]
  defp table_pointer(%{table_id: id}), do: ["user_types", id]

  defp root_loss?(_column, _format, mode, _plan) when mode in [:opaque, :legacy], do: true
  defp root_loss?(%{type: %{type: :opaque_external}}, _format, :preserve, _plan), do: true

  defp root_loss?(_column, format, :preserve, _plan) when format in [:dbml, :sqlite, :tsql],
    do: true

  defp root_loss?(column, _format, :preserve, plan),
    do: not BubbleEx.Db.Encoder.Plan.resolved?(plan, column.type.target)

  defp root_code(_column, _format, :opaque, _plan), do: :external_type_opaque_mode
  defp root_code(_column, _format, :legacy, _plan), do: :external_type_legacy_mode

  defp root_code(%{type: %{type: :opaque_external}}, _format, :preserve, _plan),
    do: :external_type_unresolved_root

  defp root_code(_column, format, :preserve, _plan) when format in [:dbml, :sqlite, :tsql],
    do: :external_type_target_opaque

  defp root_code(_column, _format, :preserve, _plan), do: :external_type_unresolved_root

  defp graph_diagnostics(_plan, _format, mode, _opts) when mode != :preserve, do: []

  defp graph_diagnostics(plan, format, :preserve, opts) do
    shape_formats = [:postgres, :ecto, :zod, :xano, :convex]

    if format in shape_formats do
      plan.nodes
      |> Map.values()
      |> Enum.flat_map(fn node ->
        node.fields
        |> Enum.filter(&(&1.type.type == :external))
        |> Enum.flat_map(fn field ->
          cond do
            not BubbleEx.Db.Encoder.Plan.resolved?(plan, field.type.target) ->
              [graph_diagnostic(:external_type_unresolved_nested, plan, format, node.id, field)]

            format != :zod and not recursive_capability?(format, opts) and
                BubbleEx.Db.Encoder.Plan.cycle_edge?(plan, node.id, field.id) ->
              [graph_diagnostic(:external_type_cycle_edge, plan, format, node.id, field)]

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

  defp recursive_capability?(_format, _opts), do: false

  defp graph_diagnostic(code, plan, format, source, field) do
    Diagnostic.new(
      code,
      plan.nodes[source][:source_path] || "",
      "#{source} field #{field.id} is rendered as JSON",
      target: format,
      subject: %{external_type: source, field: field.id},
      details: %{
        external_type: field.type.target,
        embedded_path: Diagnostic.pointer([source, "fields", field.id]),
        occurrences: BubbleEx.Db.Encoder.Plan.occurrences(plan, source, field.id),
        cardinality: field.type.cardinality,
        fallback: :json,
        mode: :preserve
      }
    )
  end
end
