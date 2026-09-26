defmodule BubbleEx.Db.Encoder.LiteralTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Encoder.Literal

  @hostile "a\"b'c\\d\ne\rf\tg\vh\fi\u0085j\u2028k\u2029l\u0000m\u007Fn"

  test "dbml_quoted/1 escapes quotes, backslashes and control characters" do
    assert Literal.dbml_quoted("plain name") == ~s("plain name")

    assert Literal.dbml_quoted(@hostile) ==
             ~S("a\"b'c\\d\ne\rf\tg\vh\fi\u0085j\u2028k\u2029l\u0000m\u007Fn")
  end

  test "js_single_quoted/1 escapes quotes, backslashes and control characters" do
    assert Literal.js_single_quoted("plain name") == "'plain name'"

    assert Literal.js_single_quoted(@hostile) ==
             ~S('a"b\'c\\d\ne\rf\tg\vh\fi\u0085j\u2028k\u2029l\u0000m\u007Fn')
  end

  test "line_comment/1 escapes backslashes and every line terminator" do
    assert Literal.line_comment("x -- */ 'q'") == "x -- */ 'q'"

    assert Literal.line_comment("a\\b\nc\rd\ve\ff\u0085g\u2028h\u2029i") ==
             ~S(a\\b\nc\rd\ve\ff\u0085g\u2028h\u2029i)
  end

  test "the escaped forms stay on one line" do
    for quoted <- [Literal.dbml_quoted(@hostile), Literal.js_single_quoted(@hostile)] do
      refute quoted =~ ~r/[\x{00}-\x{1F}\x{7F}\x{85}\x{2028}\x{2029}]/u
    end
  end
end
