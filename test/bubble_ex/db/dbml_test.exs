defmodule BubbleEx.Db.DbmlTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Dbml

  describe "quote_identifier/1" do
    test "leaves safe identifiers unquoted" do
      assert Dbml.quote_identifier("test") == "test"
      assert Dbml.quote_identifier("_test") == "_test"
      assert Dbml.quote_identifier("te_st") == "te_st"
    end

    test "quotes identifiers containing special characters" do
      assert Dbml.quote_identifier("%d") == ~s("%d")
      assert Dbml.quote_identifier("d%d") == ~s("d%d")
      assert Dbml.quote_identifier("string has spaces") == ~s("string has spaces")
    end
  end
end
