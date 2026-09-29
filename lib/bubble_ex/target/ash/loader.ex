defmodule BubbleEx.Target.Ash.Loader do
  @moduledoc """
  The Ash/PostgreSQL adapter of the data loader (`BubbleEx.Load`,
  WTF-357): loads into the database of a project generated from a
  `BubbleEx.Target.Ash.Project` (migrated by AshPostgres), through a query
  function, so BubbleEx needs no database driver.

      target =
        BubbleEx.Target.Ash.Loader.target(project,
          query: &MyApp.Repo.query/2,
          checkout: &MyApp.Repo.checkout/1
        )
      {:ok, report} = BubbleEx.Load.dry_run(export, model, target)

  `query` is called as `query.(sql, params)` and returns `{:ok, result}`
  with `result.rows` (`Ecto.Adapters.SQL.query/4`, `Repo.query/2` and
  `Postgrex.query/3` do) or `{:error, reason}`. Options: `:query`
  (required), `:schema` (default `"public"`), and `:checkout` (required
  for a real run), a function that runs a function on one database
  connection, `&Repo.checkout/1`: a real run holds a PostgreSQL advisory
  lock for its whole length (`with_lock/2`), a session lock, which holds
  only on the connection that took it, so every statement of the run must
  go to that connection. `Repo.checkout/1` does that for `Repo.query/2`
  (a pooled query function would otherwise spread the run over the pool,
  and another run could take the lock on the same connection, or leave
  it held). The lock records the connection's `pg_backend_pid()`: every
  prune statement fails unless it runs there, and so does the unlock.
  Without `:checkout` a real run is refused; a dry run needs none.

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
  `BubbleEx.Load.Plan.Derived` entries (no column, drift reported); each
  join resource (`project.joins`: a list normalized by
  `normalize_list_to_join` or `membership_policy`) becomes a
  `BubbleEx.Load.Plan.Join` (its table, the two ID columns and each
  list's membership column), and its lists are the owners' `joined`
  fields. The User resource's `email` attribute takes users' emails, and
  its `confirmed_at` attribute (`BubbleEx.Target.Ash`, WTF-413; the
  attribute whose source is `%{auth: "confirmed_at"}`) is the plan's
  `confirmed_column`: a confirmed user's Created Date, nil for the others
  (see `BubbleEx.Load`, "Users"). A Project without it (mapped before
  WTF-413) plans no `confirmed_column` and the loader reports the status
  as unmapped.

  ## Writes

  One statement per batch: the rows as one JSON parameter, expanded by
  `jsonb_populate_recordset` to the table's own column types,

      INSERT INTO "public"."task" AS t ("id", "title", ...)
      SELECT "id", "title", ... FROM jsonb_populate_recordset(NULL::"public"."task", $1::text::jsonb)
      ON CONFLICT ("id") DO UPDATE SET "title" = EXCLUDED."title", ...
      WHERE (t."title", ...) IS DISTINCT FROM (EXCLUDED."title", ...)
      RETURNING (xmax = 0)

  so a batch is atomic, an identical record is not rewritten, and the
  counts come back (inserted, updated, unchanged). The users' confirmed
  column (WTF-413) is the exception to "the row replaces the columns": a
  nil does not clear a stored confirmation while the user's email is
  unchanged,

      "confirmed_at" = CASE WHEN EXCLUDED."confirmed_at" IS NULL
        AND t."email" IS NOT DISTINCT FROM EXCLUDED."email"
        THEN t."confirmed_at" ELSE EXCLUDED."confirmed_at" END

  (the same expression in the `IS DISTINCT FROM` guard), so a delta sync
  keeps a confirmation made in the target (a magic-link sign-in) of a
  user Bubble has unconfirmed. A user whose email changed had it cleared
  first (`BubbleEx.Load`), so they take Bubble's status. There are no foreign
  keys (WTF-338), so tables load in any order. An error names the
  PostgreSQL error code and constraint, never a stored value.

  A join table's rows upsert per list, on the two ID columns, setting only
  that list's membership column (its position, or a flag), so a row of
  one list never changes the other's:

      INSERT INTO "public"."user_workspaces" AS t ("user_id", "workspace_id", "members_position")
      SELECT ... FROM jsonb_populate_recordset(NULL::"public"."user_workspaces", $1::text::jsonb)
      ON CONFLICT ("user_id", "workspace_id") DO UPDATE SET "members_position" = EXCLUDED."members_position"
      WHERE t."members_position" IS DISTINCT FROM EXCLUDED."members_position"
      RETURNING (xmax = 0)

  The upserts delete nothing: a member removed from a list in Bubble since
  an earlier load keeps its row, and the loader reports it
  (`join_members/4`, `:load_join_stale_member`) and blocks the real run
  before any writes, unless it prunes.

  ## Pruning (WTF-414)

  With `prune: true` the loader deletes rows it wrote that the export no
  longer holds (`BubbleEx.Load`, "Pruning"), after the upserts, one
  statement per batch (so each batch is one transaction): records by key
  (`delete/3`),

      DELETE FROM "public"."task" WHERE "id" = ANY($1::text[]) RETURNING "id"

  and join rows per list (`prune_join/4`): a row that is a member of the
  list and of no other is deleted, one another list holds loses only this
  list's column,

      WITH b AS (SELECT "user_id", "workspace_id" FROM jsonb_populate_recordset(NULL::"public"."user_workspaces", $1::text::jsonb)),
      d AS (DELETE FROM ... t USING b WHERE <the pair> AND t."members_position" IS NOT NULL
            AND NOT (t."workspaces_position" IS NOT NULL) RETURNING 1),
      c AS (UPDATE ... t SET "members_position" = NULL FROM b WHERE <the pair>
            AND t."members_position" IS NOT NULL AND (t."workspaces_position" IS NOT NULL) RETURNING 1)
      SELECT (SELECT count(*) FROM d)::int, (SELECT count(*) FROM c)::int

  (the two touch disjoint rows). `keys/2` reads a table's keys, to plan it.
  """

  @behaviour BubbleEx.Load.Target

  alias BubbleEx.{Diagnostic, Error, Model}
  alias BubbleEx.Load.Plan
  alias BubbleEx.Load.Plan.{Auth, Column, Derived, Table}
  alias BubbleEx.Target.Ash.{Aggregate, Attribute, Calculation, Project, Relationship, Resource}

  @json {:module, "Types.JsonValue"}

  @enforce_keys [:project, :query]
  defstruct [:project, :query, :checkout, schema: "public"]

  @type t :: %__MODULE__{
          project: Project.t(),
          query: function(),
          checkout: function() | nil,
          schema: String.t()
        }

  @doc "The loader target (`{module, config}`) for `project`; see the moduledoc."
  @spec target(Project.t(), keyword()) :: {module(), t()}
  def target(%Project{} = project, opts) do
    query = Keyword.fetch!(opts, :query)
    true = is_function(query, 2)

    checkout = Keyword.get(opts, :checkout)
    true = checkout == nil or is_function(checkout, 1)

    {__MODULE__,
     %__MODULE__{
       project: project,
       query: query,
       checkout: checkout,
       schema: Keyword.get(opts, :schema, "public")
     }}
  end

  # --- the plan ----------------------------------------------------------------------

  @impl true
  def plan(%__MODULE__{project: project}, %Model{} = model) do
    by_module = Map.new(project.resources, &{&1.module, &1})
    ctx = %{project: project, model: model, by_module: by_module}

    tables = Enum.map(project.resources, &table(&1, ctx))
    joins = Enum.map(project.joins, &join/1)
    {:ok, %Plan{target: "ash_postgres", tables: tables, auth: auth(project), joins: joins}}
  rescue
    e in [KeyError, MatchError, FunctionClauseError] ->
      {:error,
       Error.new(:invalid_input, "the Project does not match the Model", %{
         reason: Exception.message(e) |> String.slice(0, 200)
       })}
  end

  defp auth(%Project{} = project) do
    case Enum.find(project.resources, &(&1.source.type == "user")) do
      %Resource{} = user ->
        email = Enum.find(user.attributes, &(&1.source[:field] == "email"))
        confirmed = confirmed_at(user)

        %Auth{
          type: "user",
          email_column: email && column_name(email),
          confirmed_column: confirmed && column_name(confirmed)
        }

      nil ->
        nil
    end
  end

  # The User's `confirmed_at` attribute (it maps no Bubble field).
  defp confirmed_at(%Resource{} = user),
    do: Enum.find(user.attributes, &(&1.source[:auth] == "confirmed_at"))

  # The column users' confirmed timestamp goes to, for `table` (the users'
  # table only), as a plan column the schema check and the upsert handle
  # like the others. It maps no field, so it is not in the table's columns.
  defp auth_columns(%Auth{type: type, confirmed_column: column}, %Table{type: type})
       when is_binary(column),
       do: [%Column{field: "authentication", column: column, encoding: :datetime}]

  defp auth_columns(_auth, _table), do: []

  defp table(%Resource{} = r, ctx) do
    type = r.source.type
    pk = Enum.find(r.attributes, & &1.primary_key?)
    counted = counted_lists(r, ctx)

    columns =
      for %Attribute{primary_key?: false, source: %{field: _}} = a <- r.attributes do
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
      derived: derived(r, ctx),
      joined:
        for(%Relationship{kind: :many_to_many} = rel <- r.relationships, do: rel.source.field)
    }
  end

  defp join(%Resource{join: join} = r) do
    %Plan.Join{
      id: join.id,
      table: r.table,
      left: Map.take(join.left, [:type, :column]),
      right: Map.take(join.right, [:type, :column]),
      sides:
        Enum.map(join.sides, fn side ->
          %{
            type: side.type,
            field: side.field,
            owner: side.owner,
            column: side.marker.column,
            kind: side.marker.kind
          }
        end)
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
          # a count over a join: the stored list's existing members
          :many_to_many -> {:list, rel.source.field}
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
  def check_schema(%__MODULE__{} = c, %Plan{tables: tables} = plan) do
    sql = """
    SELECT table_name, column_name, udt_name, is_nullable
    FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = ANY($2)
    """

    names = Enum.map(tables, & &1.table) ++ Enum.map(plan.joins, & &1.table)

    with {:ok, rows} <- run(c, sql, [c.schema, names]) do
      actual =
        Enum.group_by(rows, &Enum.at(&1, 0), fn [_, col, udt, nullable] ->
          {col, {udt, nullable}}
        end)

      diags =
        Enum.flat_map(tables, fn table ->
          table = %{table | columns: table.columns ++ auth_columns(plan.auth, table)}
          table_diags(table, Map.get(actual, table.table))
        end) ++
          Enum.flat_map(plan.joins, fn j ->
            table_diags(join_table(j), Map.get(actual, j.table), [j.left.column, j.right.column])
          end)

      {:ok, Diagnostic.normalize(diags)}
    end
  end

  # A join table checked like a data type's: its first list's owner is
  # the subject, the left ID the key (both IDs are NOT NULL: the primary
  # key), the right ID text, the positions integers and the flags booleans.
  defp join_table(%Plan.Join{} = j) do
    [side | _] = j.sides

    %Table{
      type: side.type,
      table: j.table,
      key: j.left.column,
      columns:
        [%Column{field: side.field, column: j.right.column, encoding: :text}] ++
          for(
            %{column: c, kind: kind, field: f} <- j.sides,
            do: %Column{
              field: f,
              column: c,
              encoding: if(kind == :position, do: :integer, else: :boolean)
            }
          )
    }
  end

  defp table_diags(table, columns, keys \\ nil)

  defp table_diags(table, nil, _keys) do
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

  defp table_diags(table, columns, keys) do
    actual = Map.new(columns)
    key = %Column{field: "_id", column: table.key, encoding: :text}
    keys = keys || [table.key]

    mismatches =
      for col <- [key | table.columns],
          diag = column_diag(table, col, Map.get(actual, col.column), col.column in keys),
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

  defp column_diag(table, col, nil, _key?) do
    Diagnostic.new(
      :load_schema_mismatch,
      "",
      "the column #{table.table}.#{col.column} does not exist",
      subject: %{type: table.type, field: col.field},
      details: %{table: table.table, column: col.column, missing: :column}
    )
  end

  # Every column but the key may receive nil (Bubble has no required
  # fields), so NOT NULL is a mismatch too.
  defp column_diag(table, col, {udt, nullable}, key?) do
    expected = udts(col.encoding)

    cond do
      udt not in expected ->
        Diagnostic.new(
          :load_schema_mismatch,
          "",
          "#{table.table}.#{col.column} is #{udt}, not #{hd(expected)}",
          subject: %{type: table.type, field: col.field},
          details: %{table: table.table, column: col.column, expected: expected, actual: udt}
        )

      nullable == "NO" and not key? ->
        Diagnostic.new(
          :load_schema_mismatch,
          "",
          not_null_message(table, col),
          subject: %{type: table.type, field: col.field},
          details: %{table: table.table, column: col.column, actual: :not_null}
        )

      true ->
        nil
    end
  end

  defp not_null_message(table, %Column{field: "email"} = col) do
    "#{table.table}.#{col.column} is NOT NULL (the User's email with `allow_nil? false`): " <>
      "Bubble users may have no email, and the loader clears changed emails before " <>
      "writing them (swaps). Make the email attribute allow nil and migrate (magic-link " <>
      "sign-in still needs an email), then load; users without one cannot sign in until " <>
      "they get one"
  end

  defp not_null_message(table, col),
    do: "#{table.table}.#{col.column} is NOT NULL; Bubble values may be empty"

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
    auth = auth(c.project)
    columns = table.columns ++ auth_columns(auth, table)
    sql = upsert_sql(c.schema, %{table | columns: columns}, keep_confirmed(auth, table))

    case run(c, sql, [Jason.encode!(rows)]) do
      {:ok, returned} ->
        inserted = Enum.count(returned, &(&1 == [true]))
        updated = length(returned) - inserted
        {:ok, %{inserted: inserted, updated: updated, unchanged: length(rows) - length(returned)}}

      {:error, %Error{} = e} ->
        {:error, %{e | context: Map.put(e.context, :type, table.type)}}
    end
  end

  @impl true
  def existing(%__MODULE__{} = c, %Table{} = table, column) do
    sql =
      "SELECT #{ident(table.key)}, #{ident(column)}::text FROM #{qualified(c.schema, table)} " <>
        "WHERE #{ident(column)} IS NOT NULL"

    with {:ok, rows} <- run(c, sql, []), do: {:ok, Enum.map(rows, fn [k, v] -> {k, v} end)}
  end

  @impl true
  def clear(%__MODULE__{} = _c, %Table{}, _column, []), do: :ok

  def clear(%__MODULE__{} = c, %Table{} = table, column, keys) do
    sql =
      "UPDATE #{qualified(c.schema, table)} SET #{ident(column)} = NULL " <>
        "WHERE #{ident(table.key)} = ANY($1)"

    with {:ok, _} <- run(c, sql, [keys]), do: :ok
  end

  @impl true
  def join_members(%__MODULE__{} = _c, %Plan.Join{}, _side, []), do: {:ok, []}

  def join_members(%__MODULE__{} = c, %Plan.Join{} = join, side, owners) do
    owner = if side.owner == :left, do: join.left.column, else: join.right.column

    {filter, params} =
      case owners do
        :all -> {"", []}
        ids -> {" AND #{ident(owner)} = ANY($1)", [ids]}
      end

    membership =
      case side.kind do
        :flag -> "#{ident(side.column)} = TRUE"
        :position -> "#{ident(side.column)} IS NOT NULL"
      end

    sql =
      "SELECT #{ident(join.left.column)}, #{ident(join.right.column)} FROM #{qualified(c.schema, join)} " <>
        "WHERE #{membership}#{filter}"

    with {:ok, rows} <- run(c, sql, params), do: {:ok, Enum.map(rows, fn [l, r] -> {l, r} end)}
  end

  @impl true
  def upsert_join(%__MODULE__{} = c, %Plan.Join{} = join, side, rows) do
    case run(c, join_upsert_sql(c.schema, join, side), [Jason.encode!(rows)]) do
      {:ok, returned} ->
        inserted = Enum.count(returned, &(&1 == [true]))
        updated = length(returned) - inserted
        {:ok, %{inserted: inserted, updated: updated, unchanged: length(rows) - length(returned)}}

      {:error, %Error{} = e} ->
        {:error, %{e | context: Map.put(e.context, :join, join.id)}}
    end
  end

  # --- the marker and the lock (WTF-414) ---------------------------------------------------

  @marker "bubble_ex_load_target"

  @impl true
  def marker(%__MODULE__{} = c, mode) do
    table = ident(c.schema) <> "." <> ident(@marker)

    with {:ok, [[exists]]} <- run(c, "SELECT to_regclass($1) IS NOT NULL", [table]) do
      cond do
        exists -> read_marker(c, table)
        mode == :read -> {:ok, nil}
        true -> create_marker(c, table)
      end
    end
  end

  defp read_marker(c, table) do
    case run(c, "SELECT id::text FROM #{table}", []) do
      {:ok, [[id]]} -> {:ok, id}
      {:ok, []} -> {:ok, nil}
      {:ok, _} -> {:error, Error.new(:invalid_input, "the load marker table holds several rows")}
      error -> error
    end
  end

  # One row, ever: the singleton column's unique constraint keeps a second
  # insert out (the run holds the advisory lock anyway).
  defp create_marker(c, table) do
    with {:ok, _} <-
           run(
             c,
             "CREATE TABLE IF NOT EXISTS #{table} (id uuid PRIMARY KEY, " <>
               "singleton boolean NOT NULL DEFAULT true UNIQUE CHECK (singleton))",
             []
           ),
         {:ok, _} <-
           run(
             c,
             "INSERT INTO #{table} (id) VALUES ($1::text::uuid) ON CONFLICT (singleton) DO NOTHING",
             [uuid()]
           ),
         do: read_marker(c, table)
  end

  defp uuid do
    <<a::48, _::4, b::12, _::2, d::62>> = :crypto.strong_rand_bytes(16)
    <<u::128>> = <<a::48, 4::4, b::12, 2::2, d::62>>
    hex = u |> Integer.to_string(16) |> String.pad_leading(32, "0") |> String.downcase()

    Enum.join(
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ],
      "-"
    )
  end

  @backend {__MODULE__, :locked_backend}

  # A session lock is only a lock on one connection: a real run needs
  # `:checkout` (e.g. `&Repo.checkout/1`), which keeps its statements on
  # the connection that took the lock. The lock is taken with that
  # connection's `pg_backend_pid()`; every prune statement fails unless it
  # runs on that backend (`guard_sql/1`), and so does the unlock.
  @impl true
  def with_lock(%__MODULE__{checkout: nil}, _fun),
    do:
      {:error,
       Error.new(
         :invalid_input,
         "a real load needs the :checkout option (e.g. checkout: &MyApp.Repo.checkout/1): " <>
           "the advisory lock holds only on one connection",
         %{reason: :checkout}
       )}

  def with_lock(%__MODULE__{} = c, fun), do: c.checkout.(fn -> locked(c, fun) end)

  defp locked(c, fun) do
    key = lock_key(c.schema)

    case run(c, "SELECT pg_try_advisory_lock($1), pg_backend_pid()", [key]) do
      {:ok, [[true, backend]]} ->
        Process.put(@backend, backend)

        try do
          result = fun.()
          unlocked(result, unlock(c, key, backend))
        catch
          kind, reason ->
            unlock(c, key, backend)
            :erlang.raise(kind, reason, __STACKTRACE__)
        after
          Process.delete(@backend)
        end

      {:ok, [[false, _]]} ->
        {:error,
         Error.new(:invalid_input, "another load holds this target's lock", %{reason: :locked})}

      {:ok, _} ->
        {:error, Error.new(:request_failed, "unexpected advisory lock result")}

      error ->
        error
    end
  end

  defp unlock(c, key, backend) do
    case run(c, "SELECT pg_advisory_unlock($1), pg_backend_pid()", [key]) do
      {:ok, [[true, ^backend]]} ->
        :ok

      _ ->
        {:error,
         Error.new(
           :request_failed,
           "the advisory lock was not released on the connection that took it " <>
             "(is :checkout keeping the run on one connection?)",
           %{reason: :lock_session}
         )}
    end
  end

  defp unlocked(result, :ok), do: result
  defp unlocked(_result, error), do: error

  # The backend holding the run's lock (nil outside `with_lock/2`).
  defp locked_backend do
    case Process.get(@backend) do
      nil ->
        {:error,
         Error.new(:invalid_input, "pruning outside the target's lock", %{reason: :not_locked})}

      backend ->
        {:ok, backend}
    end
  end

  @doc false
  # A condition that raises (division by zero) unless the statement runs
  # on the backend that holds the lock, parameter `$n`: a prune statement
  # on another connection fails before it deletes anything.
  @spec guard_sql(pos_integer()) :: String.t()
  def guard_sql(n), do: "1 / (pg_backend_pid() = $#{n}::int)::int = 1"

  @doc false
  # The advisory lock's key: per database (advisory locks are) and schema.
  @spec lock_key(String.t()) :: integer()
  def lock_key(schema) do
    <<key::signed-64, _::binary>> = :crypto.hash(:sha256, "bubble_ex.load:" <> schema)
    key
  end

  # --- pruning (WTF-414) -----------------------------------------------------------------

  @impl true
  def keys(%__MODULE__{} = c, %Table{} = table) do
    sql = "SELECT #{ident(table.key)} FROM #{qualified(c.schema, table)}"
    with {:ok, rows} <- run(c, sql, []), do: {:ok, Enum.map(rows, fn [k] -> k end)}
  end

  @impl true
  def delete(%__MODULE__{}, %Table{}, []), do: {:ok, 0}

  def delete(%__MODULE__{} = c, %Table{} = table, keys) do
    with {:ok, backend} <- locked_backend() do
      case run(c, delete_sql(c.schema, table), [keys, backend]) do
        {:ok, rows} -> {:ok, length(rows)}
        {:error, %Error{} = e} -> {:error, %{e | context: Map.put(e.context, :type, table.type)}}
      end
    end
  end

  @doc false
  # One statement per batch, so a batch deletes all or nothing; only on
  # the locked backend (`$2`).
  @spec delete_sql(String.t(), Table.t()) :: String.t()
  def delete_sql(schema, %Table{} = table) do
    key = ident(table.key)

    "DELETE FROM #{qualified(schema, table)} WHERE #{key} = ANY($1::text[]) " <>
      "AND #{guard_sql(2)} RETURNING #{key}"
  end

  @impl true
  def prune_join(%__MODULE__{}, %Plan.Join{}, _side, []), do: {:ok, %{deleted: 0, cleared: 0}}

  def prune_join(%__MODULE__{} = c, %Plan.Join{} = join, side, pairs) do
    rows = Enum.map(pairs, fn {l, r} -> %{join.left.column => l, join.right.column => r} end)

    with {:ok, backend} <- locked_backend() do
      case run(c, prune_join_sql(c.schema, join, side), [Jason.encode!(rows), backend]) do
        {:ok, [[deleted, cleared]]} ->
          {:ok, %{deleted: deleted, cleared: cleared}}

        {:ok, _} ->
          {:error, Error.new(:request_failed, "unexpected prune result", %{join: join.id})}

        {:error, %Error{} = e} ->
          {:error, %{e | context: Map.put(e.context, :join, join.id)}}
      end
    end
  end

  @doc false
  # Removes rows from one list of a join table in one statement (so one
  # transaction): a row that is a member of the list and of no other is
  # deleted; one another list also holds keeps that list's column and
  # loses this list's. The two sub-statements touch disjoint rows.
  @spec prune_join_sql(String.t(), Plan.Join.t(), Plan.Join.side()) :: String.t()
  def prune_join_sql(schema, %Plan.Join{} = join, side) do
    target = qualified(schema, join)
    {l, r} = {ident(join.left.column), ident(join.right.column)}
    col = ident(side.column)

    others =
      case for(s <- join.sides, s.column != side.column, do: member_sql("t", s)) do
        [] -> "FALSE"
        list -> "(" <> Enum.join(list, " OR ") <> ")"
      end

    match =
      "t.#{l} = b.#{l} AND t.#{r} = b.#{r} AND #{member_sql("t", side)} AND #{guard_sql(2)}"

    "WITH b AS (SELECT #{l}, #{r} FROM jsonb_populate_recordset(NULL::#{target}, $1::text::jsonb)), " <>
      "d AS (DELETE FROM #{target} AS t USING b WHERE #{match} AND NOT #{others} RETURNING 1), " <>
      "c AS (UPDATE #{target} AS t SET #{col} = NULL FROM b WHERE #{match} AND #{others} RETURNING 1) " <>
      "SELECT (SELECT count(*) FROM d)::int, (SELECT count(*) FROM c)::int"
  end

  # A row is a member of a list when its position is set or its flag is true.
  defp member_sql(alias, %{column: column, kind: :flag}),
    do: "#{alias}.#{ident(column)} IS TRUE"

  defp member_sql(alias, %{column: column, kind: :position}),
    do: "#{alias}.#{ident(column)} IS NOT NULL"

  @doc false
  # The upsert statement of one list of a join table: keyed by its two ID
  # columns, setting only the list's membership column.
  @spec join_upsert_sql(String.t(), Plan.Join.t(), Plan.Join.side()) :: String.t()
  def join_upsert_sql(schema, %Plan.Join{} = join, side) do
    target = qualified(schema, join)
    keys = Enum.map([join.left.column, join.right.column], &ident/1)
    col = ident(side.column)
    all = Enum.join(keys ++ [col], ", ")

    "INSERT INTO #{target} AS t (#{all}) " <>
      "SELECT #{all} FROM jsonb_populate_recordset(NULL::#{target}, $1::text::jsonb) " <>
      "ON CONFLICT (#{Enum.join(keys, ", ")}) DO UPDATE SET #{col} = EXCLUDED.#{col} " <>
      "WHERE t.#{col} IS DISTINCT FROM EXCLUDED.#{col} RETURNING (xmax = 0)"
  end

  defp qualified(schema, table), do: ident(schema) <> "." <> ident(table.table)

  @doc false
  # The upsert statement of a table (see the moduledoc).
  # `keep` is `{confirmed_column, email_column}` for the users' table:
  # see the moduledoc.
  @spec upsert_sql(String.t(), Table.t(), {String.t(), String.t()} | nil) :: String.t()
  def upsert_sql(schema, %Table{} = table, keep \\ nil) do
    target = ident(schema) <> "." <> ident(table.table)
    key = ident(table.key)
    columns = Enum.map(table.columns, & &1.column)
    others = Enum.map(columns, &ident/1)
    all = Enum.join([key | others], ", ")

    conflict =
      case others do
        [] ->
          "ON CONFLICT (#{key}) DO NOTHING"

        _ ->
          new = Enum.map(columns, &new_value(&1, keep))
          set = Enum.map_join(Enum.zip(others, new), ", ", fn {c, v} -> "#{c} = #{v}" end)
          mine = Enum.map_join(others, ", ", &"t.#{&1}")
          theirs = Enum.join(new, ", ")

          "ON CONFLICT (#{key}) DO UPDATE SET #{set} " <>
            "WHERE ROW(#{mine}) IS DISTINCT FROM ROW(#{theirs})"
      end

    "INSERT INTO #{target} AS t (#{all}) " <>
      "SELECT #{all} FROM jsonb_populate_recordset(NULL::#{target}, $1::text::jsonb) " <>
      conflict <> " RETURNING (xmax = 0)"
  end

  # The users' confirmed column: see the moduledoc.
  defp keep_confirmed(%Auth{type: type, confirmed_column: c, email_column: e}, %Table{type: type})
       when is_binary(c) and is_binary(e),
       do: {c, e}

  defp keep_confirmed(_auth, _table), do: nil

  defp new_value(column, {column, email}) do
    {c, e} = {ident(column), ident(email)}

    "CASE WHEN EXCLUDED.#{c} IS NULL AND t.#{e} IS NOT DISTINCT FROM EXCLUDED.#{e} " <>
      "THEN t.#{c} ELSE EXCLUDED.#{c} END"
  end

  defp new_value(column, _keep), do: "EXCLUDED." <> ident(column)

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
