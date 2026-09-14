defmodule BubbleEx.Editor.Snapshot do
  @moduledoc "Fresh values returned for exact Bubble editor paths."

  @enforce_keys [:appname, :version, :last_change, :entries]
  defstruct [:appname, :version, :last_change, :entries]

  @type path :: [String.t()]
  @type t :: %__MODULE__{
          appname: String.t(),
          version: String.t(),
          last_change: non_neg_integer(),
          entries: %{required(String.t()) => %{path: path(), value: term()}}
        }

  @spec key(path()) :: String.t()
  def key(path), do: Jason.encode!(path)

  @spec fetch(t(), path()) :: {:ok, term()} | :error
  def fetch(%__MODULE__{entries: entries}, path) do
    case Map.fetch(entries, key(path)) do
      {:ok, %{value: value}} -> {:ok, value}
      :error -> :error
    end
  end
end
