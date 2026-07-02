defmodule BubbleEx.Db.EncoderTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Encoder

  describe "module_for/1" do
    test "resolves the dbml format" do
      assert Encoder.module_for(:dbml) == {:ok, BubbleEx.Db.Dbml}
    end

    test "resolves the postgres format" do
      assert Encoder.module_for(:postgres) == {:ok, BubbleEx.Db.Sql.Postgres}
    end

    test "returns a closed-kind error for an unknown format" do
      assert {:error, %BubbleEx.Error{kind: :unknown_format} = error} =
               Encoder.module_for(:mongodb)

      assert error.context == %{format: :mongodb}
    end

    test "resolves :ash" do
      assert BubbleEx.Db.Encoder.module_for(:ash) == {:ok, BubbleEx.Db.Ash}
    end
  end
end
