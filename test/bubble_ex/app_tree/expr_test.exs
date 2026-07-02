defmodule BubbleEx.AppTree.ExprTest do
  use ExUnit.Case, async: true

  alias BubbleEx.AppTree.{Coverage, Expr}

  describe "render_text/1" do
    test "renders a purely static TextExpression fully" do
      expr = %{"type" => "TextExpression", "entries" => %{"0" => "Go"}}
      assert Expr.render_text(expr) == {:ok, "Go"}
    end

    test "renders known dynamic parts in brackets" do
      expr = %{
        "type" => "TextExpression",
        "entries" => %{
          "0" => "Hello ",
          "1" => %{"type" => "PageData", "properties" => %{"name" => "Current User's name"}}
        }
      }

      assert Expr.render_text(expr) == {:ok, "Hello [Current User's name]"}
    end

    test "entries are ordered numerically, not lexically" do
      entries = Map.new(0..10, fn i -> {Integer.to_string(i), "#{i} "} end)
      expr = %{"type" => "TextExpression", "entries" => entries}
      assert {:ok, text} = Expr.render_text(expr)
      assert text == "0 1 2 3 4 5 6 7 8 9 10 "
    end

    test "unknown dynamic parts degrade to :partial with a placeholder" do
      expr = %{
        "type" => "TextExpression",
        "entries" => %{"0" => "Count: ", "1" => %{"type" => "Search", "properties" => %{}}}
      }

      assert Expr.render_text(expr) == {:partial, "Count: [⟨expr⟩]"}
    end

    test "non-TextExpression input falls back" do
      assert Expr.render_text(nil) == :fallback
      assert Expr.render_text("plain") == :fallback
      assert Expr.render_text(%{"type" => "Other"}) == :fallback
    end
  end

  describe "render_condition/1" do
    test "renders a subject/operator/operand chain" do
      cond_expr = %{
        "type" => "PageData",
        "properties" => %{"name" => "Current Page Width"},
        "next" => %{
          "type" => "Message",
          "name" => "less_than",
          "args" => %{
            "type" => "Breakpoint",
            "properties" => %{"breakpoint_id" => "built-in-mobile-landing"}
          }
        }
      }

      assert Expr.render_condition(cond_expr) ==
               {:ok, "Current Page Width less than breakpoint built-in-mobile-landing"}
    end

    test "renders an operator without operand" do
      cond_expr = %{
        "type" => "PageData",
        "properties" => %{"name" => "Current Date/Time"},
        "next" => %{"type" => "Message", "name" => "is_empty"}
      }

      assert Expr.render_condition(cond_expr) == {:ok, "Current Date/Time is empty"}
    end

    test "unknown structures fall back" do
      assert Expr.render_condition(%{"type" => "Weird"}) == :fallback
      assert Expr.render_condition(nil) == :fallback
    end

    test "chained operator messages fall back" do
      cond_expr = %{
        "type" => "PageData",
        "properties" => %{"name" => "Current Page Width"},
        "next" => %{
          "type" => "Message",
          "name" => "less_than",
          "args" => %{"type" => "Breakpoint", "properties" => %{"breakpoint_id" => "bp"}},
          "next" => %{"type" => "Message", "name" => "and"}
        }
      }

      assert Expr.render_condition(cond_expr) == :fallback
    end
  end

  describe "Coverage" do
    test "zero/bump/merge arithmetic" do
      cov =
        Coverage.zero()
        |> Coverage.bump(:actions, true)
        |> Coverage.bump(:actions, false)
        |> Coverage.bump(:expressions, true)

      assert cov == %{actions: %{total: 2, rendered: 1}, expressions: %{total: 1, rendered: 1}}

      merged = Coverage.merge(cov, cov)
      assert merged == %{actions: %{total: 4, rendered: 2}, expressions: %{total: 2, rendered: 2}}
    end
  end
end
