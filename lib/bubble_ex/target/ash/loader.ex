defmodule BubbleEx.Target.Ash.Loader do
  @moduledoc """
  The Ash/PostgreSQL adapter of the data loader (`BubbleEx.Load`,
  WTF-357): loads into the database of a project generated from a
  `BubbleEx.Target.Ash.Project` (migrated by AshPostgres), through a query
  function, so BubbleEx needs no database driver.

      target = BubbleEx.Target.Ash.Loader.target(project, query: &MyApp.Repo.query/2)
      {:ok, report} = BubbleEx.Load.dry_run(export, model, target)

  `query` is called as `query.(sql, params)` and returns `{:ok, result}`
  with `result.rows` (`Ecto.Adapters.SQL.query/4`, `Repo.query/2` and
  `Postgrex.query/3` do) or `{:error, reason}`. Options: `:query`
  (required), `:schema` (default `"public"`).

  ## The plan (`BubbleEx.Load.Plan`)

  One table per resource; the primary key column holds the Bubble `_id`;
  one column per attribute (its `column`, else its name), with the
  encoding of its Ash type:

  | Ash type | Encoding | PostgreSQL |
  |----------|----------|------------|
  | `:string`, `:ci_string` | text | `text` (`citext`) |
  | `:float` / `:integer` / `:decimal` | float / integer / decimal | `float8` / `int8` / `numeric` |
  | `:boolean` | boolean | `bool` |
  | `:utc_datetime_usec` | datetime | `timestamp` (or `timestamptz`) |
  | a generated enum | its keys (labels mapped) | `text` |
  | a typed struct (structured or API Connector) | an object by field name | `jsonb` |
  | `Types.JsonValue` | JSON, verbatim | `jsonb` |
  | `{:array, t}` | an array of t | `t[]` |

  Owner decisions, as `project.applied` and the resources record them:
  `text_to_reference` attributes are converted (`text_ref`); a list whose
  length a `derive_count` calculation counts drops dangling IDs; derived
  calculations, count aggregates and `has_many` relationships become
  `BubbleEx.Load.Plan.Derived` entries (no column, drift reported). The
  User resource's `email` attribute takes users' emails; the project has
  no column for the email-confirmed status (reported by the loader).

  ## Writes

  One statement per batch: the rows as one JSON parameter, expanded by
  `jsonb_populate_recordset` to the table's own column types,

      INSERT INTO "public"."task" AS t ("id", "title", ...)
      SELECT "id", "title", ... FROM jsonb_populate_recordset(NULL::"public"."task", $1::text::jsonb)
      ON CONFLICT ("id") DO UPDATE SET "title" = EXCLUDED."title", ...
      WHERE (t."title", ...) IS DISTINCT FROM (EXCLUDED."title", ...)
      RETURNING (xmax = 0)

  so a batch is atomic, an identical record is not rewritten, and the
  counts come back (inserted, updated, unchanged). There are no foreign
  keys (WTF-338), so tables load in any order. An error names the
  PostgreSQL error code and constraint, never a stored value.
  """

  @behaviour BubbleEx.Load.Target

  alias BubbleEx.{Diagnostic, Error, Model}
  alias BubbleEx.Load.Plan
  alias BubbleEx.Load.Plan.{Auth, Column, Derived, Table}
  alias BubbleEx.Target.Ash.{Aggregate, Attribute, Calculation, Project, Relationship, Resource}

  @json {:module, "Types.JsonValue"}

  @enforce_keys [:project, :query]
  defstruct [:project, :query, schema: "public"]

  @type t :: %__MODULE__{project: Project.t(), query: function(), schema: String.t()}

  @doc "The loader target (`{module, config}`) for `project`; see the moduledoc."
  @spec target(Project.t(), keyword()) :: {module(), t()}
  def target(%Project{} = project, opts) do
    query = Keyword.fetch!(opts, :query)
    true = is_function(query, 2)

    {__MODULE__,
     %__MODULE__{project: project, query: query, schema: Keyword.get(opts, :schema, "public")}}
  end

  # --- the plan ----------------------------------------------------------------------

  @impl true
  def plan(%__MODULE__{project: project}, %Model{} = model) do
    by_module = Map.new(project.resources, &{&1.module, &1})
    ctx = %{project: project, model: model, by_module: by_module}

    tables = Enum.map(project.resources, &table(&1, ctx))

    auth =
      case Enum.find(project.resources, &(&1.source.type == "user")) do
        %Resource{} = user ->
          email = Enum.find(user.attributes, &(&1.source[:field] == "email"))
          %Auth{type: "user", email_column: email && column_name(email), confirmed_column: nil}

        nil ->
          nil
      end

    {:ok, %Plan{target: "ash_postgres", tables: tables, auth: auth}}
  rescue
    e in [KeyError, MatchError, FunctionClauseError] ->
      {:error,
       Error.new(:invalid_input, "the Project does not match the Model", %{
         reason: Exception.message(e) |> String.slice(0, 200)
       })}
  end

  defp table(%Resource{} = r, ctx) do
    type = r.source.type
    pk = Enum.find(r.attributes, & &1.primary_key?)
    counted = counted_lists(r, ctx)

    columns =
      for %Attribute{primary_key?: false} = a <- r.attributes do
        field = a.source.field

        %Column{
          field: field,
          column: column_name(a),
          encoding: encoding(a.type, ctx),
          references: a.references,
          text_ref: text_ref?(ctx.project, type, field),
          drop_dangling: MapSet.member?(counted, field),
          files: file_field?(ctx.model, type, field)
        }
      end

    %Table{
      type: type,
      table: r.table,
      key: column_name(pk),
      columns: columns,
      derived: derived(r, ctx)
    }
  end

  defp column_name(%Attribute{column: nil, name: name}), do: name
  defp column_name(%Attribute{column: column}), do: column

  defp text_ref?(project, type, field),
    do:
      Enum.any?(
        project.applied,
        &(&1.transform == :text_to_reference and &1.subject == %{type: type, field: field})
      )

  defp file_field?(model, type, field) do
    match?({:ok, %{type: %{kind: :file_ref}}}, Model.field(model, type, field))
  end

  # --- encodings -----------------------------------------------------------------------

  defp encoding(type, _ctx) when type in [:string, :ci_string], do: :text
  defp encoding(:float, _ctx), do: :float
  defp encoding(:integer, _ctx), do: :integer
  defp encoding(:decimal, _ctx), do: :decimal
  defp encoding(:boolean, _ctx), do: :boolean
  defp encoding(:utc_datetime_usec, _ctx), do: :datetime
  defp encoding(@json, _ctx), do: :json
  defp encoding({:array, type}, ctx), do: {:array, encoding(type, ctx)}

  defp encoding({:module, module}, ctx) do
    enum = Enum.find(ctx.project.enums, &(&1.module == module))
    struct = Enum.find(ctx.project.typed_structs, &(&1.module == module))

    cond do
      enum -> enum_encoding(enum)
      struct -> struct_encoding(struct, ctx)
      true -> :json
    end
  end

  defp encoding(_type, _ctx), do: :json

  defp enum_encoding(enum) do
    keys = MapSet.new(enum.values, & &1.value)

    labels =
      enum.values
      |> Enum.filter(&is_binary(&1.label))
      |> Enum.group_by(& &1.label, & &1.value)
      |> Enum.filter(fn {label, keys_of} ->
        length(keys_of) == 1 and not MapSet.member?(keys, label)
      end)
      |> Map.new(fn {label, [key]} -> {label, key} end)

    {:enum, keys, labels}
  end

  defp struct_encoding(%{source: %{structured: base}} = s, ctx),
    do:
      {:structured, base,
       Enum.map(s.fields, &{&1.source.component, &1.name, encoding(&1.type, ctx)})}

  defp struct_encoding(%{source: %{external_type: _}} = s, ctx),
    do: {:external, Enum.map(s.fields, &{&1.source.field, &1.name, encoding(&1.type, ctx)})}

  # --- derived fields --------------------------------------------------------------------

  defp derived(r, ctx) do
    calcs =
      for %Calculation{kind: :derived} = c <- r.calculations,
          d = calculation(c, r, ctx),
          do: d

    aggs = for %Aggregate{} = g <- r.aggregates, do: aggregate(g, r, ctx)

    reverse =
      for %Relationship{kind: :has_many} = rel <- r.relationships do
        %Derived{
          field: rel.source.field,
          derivation: reverse_step(rel, ctx) |> reverse_derivation()
        }
      end

    Enum.sort_by(calcs ++ aggs ++ reverse, & &1.field)
  end

  defp reverse_derivation({:reverse, t, f}), do: {:reverse, t, f}

  # `derive_from_related`: expr(rel.rel.attribute)
  defp calculation(%Calculation{expr: %{expr: {:ref, [_ | _] = rels, attribute}}} = c, r, ctx) do
    {steps, owner} = steps(rels, r, ctx)
    source = attribute_field(owner, attribute)
    %Derived{field: c.source.field, derivation: {:related, steps, {owner.source.type, source}}}
  end

  # `derive_count` as a length: expr(length(path.list || []))
  defp calculation(
         %Calculation{expr: %{expr: {:call, "length", [{:op, "||", {:ref, rels, list}, _}]}}} = c,
         r,
         ctx
       ) do
    {steps, owner} = steps(rels, r, ctx)

    %Derived{
      field: c.source.field,
      derivation: {:count, steps ++ [{:list, attribute_field(owner, list)}]}
    }
  end

  defp calculation(_c, _r, _ctx), do: nil

  defp aggregate(%Aggregate{path: path} = g, r, ctx) do
    {steps, _owner} = steps(path, r, ctx)
    %Derived{field: g.source.field, derivation: {:count, steps}}
  end

  # Relationship names (public or private twins) to plan steps.
  defp steps(rels, r, ctx) do
    Enum.map_reduce(rels, r, fn name, current ->
      rel = relationship(current, name)
      destination = Map.fetch!(ctx.by_module, rel.destination)

      step =
        case rel.kind do
          :belongs_to -> {:ref, rel.source.field}
          :has_many -> reverse_step(rel, ctx)
        end

      {step, destination}
    end)
  end

  defp reverse_step(%Relationship{kind: :has_many} = rel, ctx) do
    destination = Map.fetch!(ctx.by_module, rel.destination)
    {:reverse, destination.source.type, attribute_field(destination, rel.destination_attribute)}
  end

  defp relationship(r, name) do
    Enum.find(r.relationships ++ r.privacy_relationships, &(&1.name == name)) ||
      raise KeyError, key: name, term: r.module
  end

  defp attribute_field(r, name) do
    case Enum.find(r.attributes, &(&1.name == name)) do
      %Attribute{source: %{field: field}} -> field
      nil -> raise KeyError, key: name, term: r.module
    end
  end

  # The lists whose length a derive_count calculation of this resource
  # counts, when they are this resource's own (other resources' lists are
  # marked from their own calculations below).
  defp counted_lists(r, ctx) do
    for resource <- ctx.project.resources,
        %Calculation{kind: :derived} = c <- resource.calculations,
        %Derived{derivation: {:count, steps}} <- [calculation(c, resource, ctx)],
        {:list, field} = List.last(steps),
        owner_type(steps, resource, ctx) == r.source.type,
        into: MapSet.new(),
        do: field
  end

  defp owner_type(steps, resource, ctx) do
    Enum.reduce(Enum.drop(steps, -1), resource.source.type, fn
      {:ref, field}, type ->
        case Model.field(ctx.model, type, field) do
          {:ok, %{type: %{target: target}}} -> target
          _ -> nil
        end

      {:reverse, t, _f}, _type ->
        t
    end)
  end

  # --- identity ---------------------------------------------------------------------------

  @impl true
  def identity(%__MODULE__{} = c) do
    sql =
      "SELECT current_database(), coalesce(host(inet_server_addr()), 'local'), inet_server_port()"

    case run(c, sql, []) do
      {:ok, [[db, host, port]]} -> {:ok, "postgres:#{host}:#{port || 0}/#{db}/#{c.schema}"}
      {:ok, _} -> {:error, Error.new(:request_failed, "cannot identify the database")}
      error -> error
    end
  end

  # --- schema -----------------------------------------------------------------------------

  @impl true
  def check_schema(%__MODULE__{} = c, %Plan{tables: tables}) do
    sql = """
    SELECT table_name, column_name, udt_name
    FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = ANY($2)
    """

    with {:ok, rows} <- run(c, sql, [c.schema, Enum.map(tables, & &1.table)]) do
      actual = Enum.group_by(rows, &Enum.at(&1, 0), fn [_, col, udt] -> {col, udt} end)

      {:ok,
       Diagnostic.normalize(Enum.flat_map(tables, &table_diags(&1, Map.get(actual, &1.table))))}
    end
  end

  defp table_diags(table, nil) do
    [
      Diagnostic.new(
        :load_schema_mismatch,
        "",
        "the table #{table.table} of #{table.type} does not exist",
        subject: %{type: table.type},
        details: %{table: table.table, missing: :table}
      )
    ]
  end

  defp table_diags(table, columns) do
    actual = Map.new(columns)
    key = %Column{field: "_id", column: table.key, encoding: :text}

    mismatches =
      for col <- [key | table.columns],
          diag = column_diag(table, col, Map.get(actual, col.column)),
          do: diag

    planned = MapSet.new([table.key | Enum.map(table.columns, & &1.column)])
    extra = actual |> Map.keys() |> Enum.reject(&MapSet.member?(planned, &1)) |> Enum.sort()

    extra_diag =
      if extra == [],
        do: [],
        else: [
          Diagnostic.new(
            :load_column_extra,
            "",
            "#{table.table} has columns the loader does not write",
            subject: %{type: table.type},
            details: %{table: table.table, columns: extra}
          )
        ]

    mismatches ++ extra_diag
  end

  defp column_diag(table, col, nil) do
    Diagnostic.new(
      :load_schema_mismatch,
      "",
      "the column #{table.table}.#{col.column} does not exist",
      subject: %{type: table.type, field: col.field},
      details: %{table: table.table, column: col.column, missing: :column}
    )
  end

  defp column_diag(table, col, udt) do
    expected = udts(col.encoding)

    if udt in expected,
      do: nil,
      else:
        Diagnostic.new(
          :load_schema_mismatch,
          "",
          "#{table.table}.#{col.column} is #{udt}, not #{hd(expected)}",
          subject: %{type: table.type, field: col.field},
          details: %{table: table.table, column: col.column, expected: expected, actual: udt}
        )
  end

  defp udts(:text), do: ["text", "citext", "varchar"]
  defp udts(:float), do: ["float8"]
  defp udts(:integer), do: ["int8", "int4"]
  defp udts(:decimal), do: ["numeric"]
  defp udts(:boolean), do: ["bool"]
  defp udts(:datetime), do: ["timestamp", "timestamptz"]
  defp udts({:enum, _, _}), do: ["text", "varchar"]
  defp udts({:array, enc}), do: Enum.map(udts(enc), &("_" <> &1))
  defp udts(_json), do: ["jsonb"]

  # --- writes ------------------------------------------------------------------------------

  @impl true
  def upsert(%__MODULE__{} = c, %Table{} = table, rows) do
    sql = upsert_sql(c.schema, table)

    case run(c, sql, [Jason.encode!(rows)]) do
      {:ok, returned} ->
        inserted = Enum.count(returned, &(&1 == [true]))
        updated = length(returned) - inserted
        {:ok, %{inserted: inserted, updated: updated, unchanged: length(rows) - length(returned)}}

      {:error, %Error{} = e} ->
        {:error, %{e | context: Map.put(e.context, :type, table.type)}}
    end
  end

  @doc false
  # The upsert statement of a table (see the moduledoc).
  @spec upsert_sql(String.t(), Table.t()) :: String.t()
  def upsert_sql(schema, %Table{} = table) do
    target = ident(schema) <> "." <> ident(table.table)
    key = ident(table.key)
    others = Enum.map(table.columns, &ident(&1.column))
    all = Enum.join([key | others], ", ")

    conflict =
      case others do
        [] ->
          "ON CONFLICT (#{key}) DO NOTHING"

        _ ->
          set = Enum.map_join(others, ", ", &"#{&1} = EXCLUDED.#{&1}")
          mine = Enum.map_join(others, ", ", &"t.#{&1}")
          theirs = Enum.map_join(others, ", ", &"EXCLUDED.#{&1}")

          "ON CONFLICT (#{key}) DO UPDATE SET #{set} " <>
            "WHERE ROW(#{mine}) IS DISTINCT FROM ROW(#{theirs})"
      end

    "INSERT INTO #{target} AS t (#{all}) " <>
      "SELECT #{all} FROM jsonb_populate_recordset(NULL::#{target}, $1::text::jsonb) " <>
      conflict <> " RETURNING (xmax = 0)"
  end

  defp ident(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")

  # Runs a statement; errors carry the PostgreSQL error code and
  # constraint, never the message (it may quote a stored value).
  defp run(%__MODULE__{query: query}, sql, params) do
    case query.(sql, params) do
      {:ok, %{rows: rows}} ->
        {:ok, rows || []}

      {:error, reason} ->
        {:error, db_error(reason)}

      _other ->
        {:error, Error.new(:request_failed, "the query function returned an unexpected value")}
    end
  rescue
    e -> {:error, db_error(e)}
  end

  defp db_error(%{postgres: %{} = pg}) do
    Error.new(:request_failed, "PostgreSQL refused the statement", %{
      sqlstate: Map.get(pg, :code),
      constraint: Map.get(pg, :constraint),
      table: Map.get(pg, :table),
      column: Map.get(pg, :column)
    })
  end

  defp db_error(%{__exception__: true} = e),
    do: Error.new(:request_failed, "the database call failed", %{reason: e.__struct__})

  defp db_error(reason) when is_atom(reason),
    do: Error.new(:request_failed, "the database call failed", %{reason: reason})

  defp db_error(_reason), do: Error.new(:request_failed, "the database call failed")
end
