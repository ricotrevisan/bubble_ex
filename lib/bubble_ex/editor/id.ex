defmodule BubbleEx.Editor.Id do
  @moduledoc """
  Generates opaque IDs for Bubble definitions created by the editor CLI.

  IDs are random rather than derived from Bubble's shared counter. Creation
  plans still guard every generated ID through `_index.id_to_path`, so a
  collision is rejected by the fresh pre-write read.
  """

  @spec generate(pos_integer()) :: [String.t()]
  def generate(count) when is_integer(count) and count > 0 and count <= 1_000 do
    Enum.map(1..count, fn _index ->
      suffix = :crypto.strong_rand_bytes(15) |> Base.url_encode64(padding: false)
      "bx_" <> suffix
    end)
  end
end
