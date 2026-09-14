defmodule BubbleEx.Editor.IdTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Editor.Id

  test "generates unique opaque IDs with a stable CLI namespace" do
    ids = Id.generate(100)

    assert length(ids) == 100
    assert length(Enum.uniq(ids)) == 100
    assert Enum.all?(ids, &Regex.match?(~r/\Abx_[A-Za-z0-9_-]{20}\z/, &1))
  end
end
