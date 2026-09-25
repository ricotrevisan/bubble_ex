defmodule BubbleEx.Db.Encoder do
  @moduledoc """
  Behaviour shared by every database-schema renderer (DBML, SQL dialects, ...).

  An encoder turns the table view produced by `BubbleEx.Db.Reader.parse/1` (a
  projection of `BubbleEx.Model`) into a textual schema for one target format. `module_for/1` resolves a format
  atom to its encoder module.

  Ash is not an encoder: it maps from `BubbleEx.Model` through
  `BubbleEx.Target.Ash` and prints with `BubbleEx.Target.Ash.Source`.
  """

  alias BubbleEx.{Diagnostic, Error}

  defmodule Result do
    @moduledoc """
    Detailed schema-rendering result. `diagnostics` are the Reader's (the
    Model's) diagnostics plus this target's (stage `{:target, format}`),
    normalized.
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

  @doc """
  The names an encoder derives by case conversion, unique per scope
  (`BubbleEx.Db.Encoder.Names`). Implemented by the encoders that convert
  names; `render/3` reports the suffixed ones.
  """
  @callback names(db_map :: map(), opts :: keyword()) :: BubbleEx.Db.Encoder.Names.t()

  @optional_callbacks names: 2

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
  Whether a Reader relationship is a scalar reference a SQL encoder can
  express as a column pointing at another table's key: resolved, live, and
  not a list (list references are stored as arrays/JSON and never get a
  constraint). Every such reference is either a foreign key
  (`foreign_key?/2`) or documented in a SQL comment.
  """
  @spec scalar_reference?(BubbleEx.Db.Reader.relationship()) :: boolean()
  def scalar_reference?({from, to, _direction}) do
    from != nil and to != nil and not from.deleted and not to.deleted and
      Map.get(from.type, :is_array) != true
  end

  @doc """
  Whether a SQL encoder (PostgreSQL, SQLite, T-SQL) declares a foreign key
  for a Reader relationship. This is the single decision point.

  The `:foreign_keys` option picks the mode:

    * `:none` (default) - no foreign key at all. Bubble has no referential
      integrity: deleting a thing leaves every reference to it in place, so
      real data holds dangling IDs, and a constraint would reject it on load.
      As in `BubbleEx.Target.Ash` (WTF-338) and the Ecto migrations, each
      reference is kept as a plain column and documented in a SQL comment.
    * `:enforced` - a real foreign key on every scalar reference
      (`scalar_reference?/1`) except the built-in `Created By`, for data that
      has been cleaned of dangling references first. Bubble keeps a record's
      creator after the user is deleted, and records made by backend
      workflows or logged-out visitors may have none that exists, so
      `Created By` stays a comment in both modes.
  """
  @spec foreign_key?(BubbleEx.Db.Reader.relationship(), keyword()) :: boolean()
  def foreign_key?({from, _to, _direction} = relationship, opts \\ []) do
    Keyword.get(opts, :foreign_keys, :none) == :enforced and scalar_reference?(relationship) and
      Map.get(from, :system) != :created_by
  end

  @sql_formats [:postgres, :sqlite, :tsql]

  @doc """
  Reads and validates the `:foreign_keys` option (see `foreign_key?/2`):
  `{:ok, :none | :enforced}`, or an `:invalid_input` error for any other
  value. Every SQL encoder's `encode/2` calls it first.
  """
  @spec foreign_keys_mode(keyword()) :: {:ok, :none | :enforced} | {:error, Error.t()}
  def foreign_keys_mode(opts) do
    case Keyword.get(opts, :foreign_keys, :none) do
      mode when mode in [:none, :enforced] ->
        {:ok, mode}

      mode ->
        {:error, Error.new(:invalid_input, "invalid foreign_keys mode", %{mode: mode})}
    end
  end

  @doc """
  Validates the rendering options that apply to `format` before any work is
  done: `:foreign_keys` for the SQL formats (PostgreSQL, SQLite, T-SQL),
  ignored by every other format. `nil` (no format) is always `:ok`.
  """
  @spec validate_options(atom() | nil, keyword()) :: :ok | {:error, Error.t()}
  def validate_options(format, opts) when format in @sql_formats do
    with {:ok, _mode} <- foreign_keys_mode(opts), do: :ok
  end

  def validate_options(_format, _opts), do: :ok

  @doc """
  The scalar references (`scalar_reference?/1`) a SQL encoder keeps without
  a foreign key under `opts` (see `foreign_key?/2`), in Reader order.
  """
  @spec unconstrained_references([BubbleEx.Db.Reader.relationship()], keyword()) ::
          [BubbleEx.Db.Reader.relationship()]
  def unconstrained_references(relationships, opts) do
    Enum.filter(relationships, &(scalar_reference?(&1) and not foreign_key?(&1, opts)))
  end

  @doc """
  The trailing SQL comment block that documents the scalar references kept
  without a foreign key (`unconstrained_references/2`), one
  `-- <from> -> <to>` line each, or `""` when there are none. `describe`
  renders a `{from, to}` column pair in the dialect's quoting. Line breaks in
  names (CR, LF, VT, FF, NEL, LS, PS) are escaped so they cannot end the
  comment and run as SQL.
  """
  @spec reference_comments(
          [BubbleEx.Db.Reader.relationship()],
          keyword(),
          (map(), map() -> String.t())
        ) :: String.t()
  def reference_comments(relationships, opts, describe) do
    case unconstrained_references(relationships, opts) do
      [] ->
        ""

      references ->
        lines =
          Enum.map(references, fn {from, to, _dir} ->
            "-- " <> comment_safe(describe.(from, to))
          end)

        Enum.join(
          ["-- References without a foreign key (Bubble does not enforce referential integrity):"] ++
            lines,
          "\n"
        )
    end
  end

  # Backslash first, so the escapes below stay unambiguous. Besides CR/LF
  # (which end a SQL line comment), the other line terminators some tools
  # split on (VT, FF, NEL, LS, PS) are escaped too.
  @comment_escapes [
    {"\\", "\\\\"},
    {"\r", "\\r"},
    {"\n", "\\n"},
    {"\v", "\\v"},
    {"\f", "\\f"},
    {"\u0085", "\\u0085"},
    {"\u2028", "\\u2028"},
    {"\u2029", "\\u2029"}
  ]

  defp comment_safe(text) do
    Enum.reduce(@comment_escapes, text, fn {char, escape}, acc ->
      String.replace(acc, char, escape)
    end)
  end

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

  @doc """
  Renders a registered schema format and returns artifact-scoped diagnostics.

  Options include `:naming` (`:proper` or `:id`), `:external_types`,
  `:external_type_capabilities` and, for the SQL formats, `:foreign_keys`
  (`:none`, the default, or `:enforced`; see `foreign_key?/2`).
  """
  @spec render(atom(), map(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def render(format, db_map, opts \\ []) do
    plan = BubbleEx.Db.Encoder.Plan.build(db_map, opts)

    with {:ok, module} <- module_for(format),
         {:ok, mode} <- external_type_mode(db_map, opts),
         :ok <- validate_options(format, opts),
         :ok <- validate_capabilities(format, opts),
         encoder_opts =
           opts |> Keyword.put(:external_types, mode) |> Keyword.put(:_external_plan, plan),
         {:ok, content} <- module.encode(db_map, encoder_opts) do
      diagnostics =
        Diagnostic.normalize(
          Map.get(db_map, :diagnostics, []) ++
            projection_diagnostics(db_map, format) ++
            name_diagnostics(module, db_map, format, encoder_opts) ++
            root_diagnostics(db_map, format, mode, plan) ++
            graph_diagnostics(plan, format, mode, opts)
        )

      {:ok, %Result{format: format, content: content, diagnostics: diagnostics}}
    end
  end

  defp name_diagnostics(module, db_map, format, opts) do
    if function_exported?(module, :names, 2),
      do: db_map |> module.names(opts) |> BubbleEx.Db.Encoder.Names.diagnostics(format),
      else: []
  end

  defp projection_diagnostics(db_map, format) do
    for {code, path, message, opts} <- Map.get(db_map, :projection_diagnostics, []),
        do: Diagnostic.new(code, path, message, Keyword.put(opts, :target, format))
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
