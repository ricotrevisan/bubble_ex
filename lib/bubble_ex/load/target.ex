defmodule BubbleEx.Load.Target do
  @moduledoc """
  A target stack's side of the data loader (`BubbleEx.Load`), passed as
  `{module, config}`. The loader converts rows by the adapter's
  `BubbleEx.Load.Plan` and hands them over in batches; the adapter only
  checks its schema and writes.

    * `plan/2` - the load plan for this Model (Bubble IDs, target table and
      column names, encodings)
    * `identity/1` - a stable, credential-free name of the database written
      to (e.g. `"postgres:<host>:<port>/<database>"`), which keys the ledger
    * `check_schema/2` - `load_schema_mismatch` diagnostics when the database
      lacks a table or column of the plan, or types it differently, and
      `load_column_extra` for columns it does not write. It reads only
    * `upsert/3` - writes one batch of rows of a table: each row maps column
      names to JSON values (`BubbleEx.Load.Convert`), the key column always
      present. Must be an idempotent upsert on the key: inserting new
      records, replacing the plan's columns of existing ones, and leaving
      identical records untouched. Returns the counts. Must not report stored
      values in errors

  `BubbleEx.Target.Ash.Loader` is the Ash/PostgreSQL adapter.
  """

  alias BubbleEx.{Diagnostic, Error, Model}
  alias BubbleEx.Load.Plan

  @type counts :: %{
          inserted: non_neg_integer(),
          updated: non_neg_integer(),
          unchanged: non_neg_integer()
        }

  @callback plan(config :: term(), Model.t()) :: {:ok, Plan.t()} | {:error, Error.t()}
  @callback identity(config :: term()) :: {:ok, String.t()} | {:error, Error.t()}
  @callback check_schema(config :: term(), Plan.t()) ::
              {:ok, [Diagnostic.t()]} | {:error, Error.t()}
  @callback upsert(config :: term(), Plan.Table.t(), [map()]) ::
              {:ok, counts()} | {:error, Error.t()}
end
