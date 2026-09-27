defmodule BubbleEx.Load.Plan do
  @moduledoc """
  What a target stores of each Bubble data type, in Bubble IDs: the
  stack-neutral contract between `BubbleEx.Load` and a target adapter
  (`BubbleEx.Load.Target`). The adapter derives it from its own mapping
  (for Ash, `BubbleEx.Target.Ash.Loader` from a `BubbleEx.Target.Ash.Project`);
  the loader converts every row by it and never looks at target names
  beyond passing them back.

    * `target` - the adapter's name (e.g. `"ash_postgres"`)
    * `tables` - `BubbleEx.Load.Plan.Table`s, one per mapped data type, in
      Bubble ID order
    * `auth` - `BubbleEx.Load.Plan.Auth`: where users' email and
      email-confirmed status go, or nil when the target maps no users
    * `joins` - `BubbleEx.Load.Plan.Join`s: lists of things an owner
      decision normalized to a join table (one row per member), in join
      ID order

  `sha256/1` pins a plan: a loader ledger belongs to one plan.
  """

  alias BubbleEx.CanonicalJson
  alias BubbleEx.Load.Plan.{Auth, Join, Table}

  @enforce_keys [:target, :tables]
  defstruct [:target, :auth, tables: [], joins: []]

  @type t :: %__MODULE__{
          target: String.t(),
          tables: [Table.t()],
          auth: Auth.t() | nil,
          joins: [Join.t()]
        }

  @typedoc """
  How a column stores a value (see `BubbleEx.Load.Convert`):

    * `:text`, `:float`, `:integer`, `:decimal`, `:boolean`
    * `:datetime` - an ISO 8601 UTC timestamp at microsecond precision
    * `:json` - any JSON value, verbatim
    * `{:enum, keys, labels}` - an option key: `keys` the live keys,
      `labels` display text => key for the labels naming one key
    * `{:structured, base, parts}` - a structured Bubble value
      (`BubbleEx.Model.Structured`) as a JSON object, `parts` being
      `[{component_id, member, encoding}]`
    * `{:external, parts}` - an API Connector value as a JSON object,
      `parts` being `[{field_id, member, encoding}]`
    * `{:array, encoding}` - a list, as a JSON array
  """
  @type encoding ::
          :text
          | :float
          | :integer
          | :decimal
          | :boolean
          | :datetime
          | :json
          | {:enum, MapSet.t(String.t()), %{String.t() => String.t()}}
          | {:structured, atom(), [{String.t(), String.t(), encoding()}]}
          | {:external, [{String.t(), String.t(), encoding()}]}
          | {:array, encoding()}

  @doc "The table of data type `type`, or nil."
  @spec table(t(), String.t()) :: Table.t() | nil
  def table(%__MODULE__{tables: tables}, type), do: Enum.find(tables, &(&1.type == type))

  @doc """
  SHA-256 of the plan's canonical JSON (encodings included), so a ledger
  written for one plan is never resumed against another.
  """
  @spec sha256(t()) :: String.t()
  def sha256(%__MODULE__{} = plan), do: plan |> json() |> CanonicalJson.sha256()

  defp json(%MapSet{} = set), do: set |> MapSet.to_list() |> Enum.sort()
  defp json(%_{} = struct), do: struct |> Map.from_struct() |> json()
  defp json(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), json(v)} end)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json()
  defp json(v) when is_atom(v) and v not in [nil, true, false], do: Atom.to_string(v)
  defp json(v), do: v
end

defmodule BubbleEx.Load.Plan.Table do
  @moduledoc """
  One data type's table.

    * `type` - the Bubble data type ID
    * `table` - the target's table name (opaque to the loader)
    * `key` - the column holding the Bubble `_id` (the primary key)
    * `columns` - `BubbleEx.Load.Plan.Column`s, the stored fields
    * `derived` - `BubbleEx.Load.Plan.Derived`s: fields an owner decision
      derives, which have no column; the loader reports drift between the
      stored Bubble value and the derived one
    * `skipped` - `%{field: id, reason: atom}` for fields deliberately not
      stored (e.g. `:deleted`), so their data is reported, not flagged as
      unknown
    * `joined` - the list fields stored in a join table instead of a
      column (`BubbleEx.Load.Plan.Join`)
  """

  alias BubbleEx.Load.Plan.{Column, Derived}

  @enforce_keys [:type, :table, :key]
  defstruct [:type, :table, :key, columns: [], derived: [], skipped: [], joined: []]

  @type t :: %__MODULE__{
          type: String.t(),
          table: String.t(),
          key: String.t(),
          columns: [Column.t()],
          derived: [Derived.t()],
          skipped: [%{field: String.t(), reason: atom()}],
          joined: [String.t()]
        }
end

defmodule BubbleEx.Load.Plan.Join do
  @moduledoc """
  A join table (WTF-352 cut 3): lists of things an owner decision
  normalized (`normalize_list_to_join`, `membership_policy`), one row per
  member, keyed by the two record IDs.

    * `id` - the join's ID (the finding's `join:<hash>`)
    * `table` - the target's table name
    * `left`, `right` - `%{type, column}`: the data type of each record ID
      and the column holding it; together the primary key
    * `sides` - the lists it stores, `%{type, field, owner, position}`:
      data type `type`'s list `field` holds, per row, the record of the
      `owner` column (`:left` or `:right`) listing the other one;
      `position` is the column of the member's index in the list (from 0),
      or nil when the order is not kept. Two sides are two lists mirroring
      each other: one row stands for both (the loader loads their union and
      reports the members listed on one side only)
  """

  @enforce_keys [:id, :table, :left, :right, :sides]
  defstruct [:id, :table, :left, :right, :sides]

  @type column :: %{type: String.t(), column: String.t()}
  @type side :: %{
          type: String.t(),
          field: String.t(),
          owner: :left | :right,
          position: String.t() | nil
        }
  @type t :: %__MODULE__{
          id: String.t(),
          table: String.t(),
          left: column(),
          right: column(),
          sides: [side()]
        }
end

defmodule BubbleEx.Load.Plan.Column do
  @moduledoc """
  A stored field.

    * `field` - the Bubble field ID (built-in ones included: `Created
      Date`, `Modified Date`, `Created By`, `Slug`, `email`)
    * `column` - the target column name
    * `encoding` - `t:BubbleEx.Load.Plan.encoding/0`
    * `references` - `%{target: type, cardinality: :one | :many}` when the
      column holds Bubble IDs of records, else nil
    * `text_ref` - true when the field is text converted to references by
      an owner decision (`text_to_reference`): values are trimmed, an
      empty text is nil and a value not shaped like a Bubble unique ID is
      reported and loaded as nil
    * `drop_dangling` - true for a list whose count is derived as its
      length (`derive_count`): IDs of records the export does not hold are
      dropped, as Bubble's `:count` does not count them
    * `files` - true for a file or image field: Bubble file URLs are
      rewritten to the target storage's references
  """

  @enforce_keys [:field, :column, :encoding]
  defstruct [
    :field,
    :column,
    :encoding,
    :references,
    text_ref: false,
    drop_dangling: false,
    files: false
  ]

  @type t :: %__MODULE__{
          field: String.t(),
          column: String.t(),
          encoding: BubbleEx.Load.Plan.encoding(),
          references: %{target: String.t(), cardinality: :one | :many} | nil,
          text_ref: boolean(),
          drop_dangling: boolean(),
          files: boolean()
        }
end

defmodule BubbleEx.Load.Plan.Derived do
  @moduledoc """
  A field derived by an owner decision, with no column. `path` is how the
  derived value is reached from the record, each step one of
  `{:ref, field}` (follow this type's reference field `field`) or
  `{:reverse, type, field}` (the records of `type` whose reference field
  `field` holds this record's ID: a derived `has_many`).

    * `{:related, path, {type, field}}` (`derive_from_related`) - the
      value of `field` on the record reached by `path`
    * `{:count, path}` (`derive_count`) - the number of records the path
      reaches when it ends in a `{:reverse, ...}` step; otherwise the
      length of the list `path` ends at, given as `{:list, field}`
    * `{:reverse, type, field}` (`derive_reverse_relationship`) - the
      records of `type` pointing back through `field`
  """

  @enforce_keys [:field, :derivation]
  defstruct [:field, :derivation]

  @type step :: {:ref, String.t()} | {:reverse, String.t(), String.t()} | {:list, String.t()}
  @type t :: %__MODULE__{
          field: String.t(),
          derivation:
            {:related, [step()], {String.t(), String.t()}}
            | {:count, [step()]}
            | {:reverse, String.t(), String.t()}
        }
end

defmodule BubbleEx.Load.Plan.Auth do
  @moduledoc """
  Where users go: `type` is the Bubble data type of users (`"user"`),
  `email_column` the column of their email (a Plan column of field
  `email`), `confirmed_column` the column of their email-confirmed status
  (a boolean), or nil when the target has none (the status is then
  reported, and kept in the export).
  """

  @enforce_keys [:type]
  defstruct [:type, :email_column, :confirmed_column]

  @type t :: %__MODULE__{
          type: String.t(),
          email_column: String.t() | nil,
          confirmed_column: String.t() | nil
        }
end
