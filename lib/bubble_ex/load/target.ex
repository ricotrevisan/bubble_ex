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
      present, and for users the plan's `Plan.Auth` `confirmed_column` when
      it has one (`check_schema/2` checks that column too). Must be an idempotent upsert on the key: inserting new
      records, replacing the plan's columns of existing ones, and leaving
      identical records untouched. Returns the counts. Must not report stored
      values in errors
    * `existing/3` - the records of a table holding a value in a column,
      as `{key, value}` pairs (users' emails: the loader checks the
      export's emails against the target's unique identity before writing)
    * `clear/4` - sets a column to nil for the records with the given keys
      (the first phase of an email swap)

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
  @callback existing(config :: term(), Plan.Table.t(), column :: String.t()) ::
              {:ok, [{String.t(), term()}]} | {:error, Error.t()}
  @callback clear(config :: term(), Plan.Table.t(), column :: String.t(), [String.t()]) ::
              :ok | {:error, Error.t()}
end
