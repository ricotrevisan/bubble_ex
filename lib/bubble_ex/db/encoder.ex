defmodule BubbleEx.Db.Encoder do
  @moduledoc """
  Behaviour shared by every database-schema renderer (DBML, SQL dialects, ...).

  An encoder turns the universal `db_map` produced by `BubbleEx.Db.Reader.parse/1`
  into a textual schema for one target format. `module_for/1` resolves a format
  atom to its encoder module.
  """

  alias BubbleEx.Error

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
end
