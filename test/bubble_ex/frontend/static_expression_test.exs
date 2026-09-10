defmodule BubbleEx.Frontend.StaticExpressionTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend.StaticExpression

  test "literal lists and parent values resolve without executing runtime expressions" do
    expression = %{
      "%x" => "ArbitraryText",
      "%p" => %{"arbitrary_text" => text("one\ntwo")},
      "%n" => %{"%nm" => "split_by", "%p" => %{"separator" => text("\n")}}
    }

    assert StaticExpression.resolve(expression) == {:ok, ["one", "two"]}
    assert StaticExpression.resolve(%{"%x" => "ElementParent"}, "one") == {:ok, "one"}
    assert StaticExpression.resolve(%{"%x" => "ElementParent"}) == :unknown
    assert StaticExpression.resolve(%{"%x" => "Search"}) == :unknown

    chained = put_in(expression, ["%n", "%n"], %{"%nm" => "unknown_operator"})
    assert StaticExpression.resolve(chained) == :unknown
  end

  test "concatenation uses numeric part order and keeps unsupported parts unresolved" do
    expression = %{
      "%x" => "TextExpression",
      "%e" => %{
        "0" => "Item ",
        "1" => %{"%x" => "ElementParent"},
        "2" => " has ",
        "10" => "details"
      }
    }

    assert StaticExpression.resolve(expression, 7) == {:ok, "Item 7 has details"}
    assert StaticExpression.resolve(expression) == :unknown
  end

  test "literal list evaluation has bounded input and output" do
    assert StaticExpression.resolve(String.duplicate("x", 100_001)) == :unknown

    assert StaticExpression.resolve(%{"%x" => "ElementParent"}, String.duplicate("x", 100_001)) ==
             :unknown

    expression = %{
      "%x" => "ArbitraryText",
      "%p" => %{"arbitrary_text" => text(String.duplicate("x,", 101))},
      "%n" => %{"%nm" => "split_by", "%p" => %{"separator" => text(",")}}
    }

    assert StaticExpression.resolve(expression) == :unknown
  end

  test "numeric list conversion consumes the whole value and rejects unknown arguments" do
    expression = %{
      "%x" => "ArbitraryText",
      "%p" => %{"arbitrary_text" => text("1 2.5")},
      "%n" => %{
        "%nm" => "split_by",
        "%p" => %{"separator" => text(" ")},
        "%n" => %{"%nm" => "convert_to_number"}
      }
    }

    assert StaticExpression.resolve(expression) == {:ok, [1, 2.5]}

    assert expression
           |> put_in(["%p", "arbitrary_text"], text("1 nope"))
           |> StaticExpression.resolve() == :unknown

    assert expression
           |> put_in(["%n", "%n", "%p"], %{"unknown" => true})
           |> StaticExpression.resolve() == :unknown
  end

  defp text(value), do: %{"%x" => "TextExpression", "%e" => %{"0" => value}}
end
