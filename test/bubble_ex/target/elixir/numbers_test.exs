defmodule BubbleEx.Target.Elixir.NumbersTest do
  # WTF-598: a number's `:ceiling` and `:floor`, compiled from the
  # expression fixture and run against the generated runtime
  # (templates/lib/app/bubble/runtime.ex.eex, compiled here as a
  # stand-alone module). Synthetic values only.
  use ExUnit.Case, async: true

  import BubbleEx.Test.ExpressionFixture

  alias BubbleEx.Expression.{Compiler, IR}
  alias BubbleEx.Target.Elixir, as: Target
  alias BubbleEx.Target.Phoenix.Templates

  @module "NumbersCheck"
  @runtime Module.concat([@module, Bubble, Runtime])

  setup_all do
    unless Code.ensure_loaded?(@runtime) do
      for template <- ["lib/app/bubble/keywords.ex", "lib/app/bubble/runtime.ex"] do
        template
        |> Templates.render(%{module: @module, app: :numbers_check, enforced?: false})
        |> Code.compile_string()
      end
    end

    %{rt: @runtime}
  end

  defp compile(raw) do
    env = env(host: "bT4")
    Compiler.compile(parse!(raw, env), env)
  end

  defp elixir(raw) do
    {:ok, %{ir: ir}} = compile(raw)
    {:ok, result} = Target.compile(ir, project(), runtime: inspect(@runtime))
    result
  end

  defp run(%{source: source, bindings: bindings}, values) do
    binding =
      for b <- bindings do
        key =
          case b.input do
            {:page_thing, _} -> "page"
            {:page_data, %{"name" => "Current Date/Time"}} -> "now"
          end

        {String.to_atom(b.var), Map.fetch!(values, key)}
      end

    {value, _} = Code.eval_string(source, binding)
    value
  end

  defp estimate, do: chain(src("CurrentPageItem"), [msg("estimate_number")])
  defp now, do: src("PageData", %{"name" => "Current Date/Time"})
  defp due, do: chain(src("CurrentPageItem"), [msg("due_date")])

  describe ":ceiling and :floor" do
    test "compile to the IR's :ceiling and :floor, typed number" do
      for {name, op} <- [{"ceil", :ceiling}, {"floor", :floor}] do
        assert {:ok, %{ir: %IR{op: ^op, type: "number", args: [%IR{op: :field}]}}} =
                 compile(chain(estimate(), [msg(name)]))
      end
    end

    test "run toward positive and negative infinity, to a whole number", %{rt: rt} do
      for {x, ceiling, floor} <- [
            {2.3, 3, 2},
            {2.0, 2, 2},
            {-2.3, -2, -3},
            {-0.5, 0, -1},
            {7, 7, 7}
          ] do
        assert rt.ceiling(x) === ceiling
        assert rt.floor(x) === floor
      end

      for {x, ceiling, floor} <- [
            {"1.2", "2", "1"},
            {"-1.2", "-1", "-2"},
            {"3", "3", "3"},
            {"0.2", "1", "0"}
          ] do
        assert Decimal.equal?(rt.ceiling(Decimal.new(x)), Decimal.new(ceiling))
        assert Decimal.equal?(rt.floor(Decimal.new(x)), Decimal.new(floor))
      end

      # Never "-0": JavaScript shows Math.ceil(-0.2) as 0.
      assert rt.text(rt.ceiling(Decimal.new("-0.2"))) == "0"
      assert rt.text(rt.ceiling(-0.2)) == "0"

      # A float too large to have a fraction shows as JavaScript shows it.
      assert rt.floor(1.0e300) === 1.0e300
      assert rt.text(rt.floor(1.0e300)) == "1e+300"

      for empty <- [nil, "", "text"] do
        assert rt.ceiling(empty) == empty
        assert rt.floor(empty) == empty
      end
    end

    test "a page thing's number, empty when the number is" do
      compiled = elixir(chain(estimate(), [msg("ceil")]))
      assert compiled.source =~ "ceiling("
      assert run(compiled, %{"page" => %{estimate: 4.2}}) == 5
      assert run(compiled, %{"page" => %{estimate: nil}}) == nil

      compiled = elixir(chain(estimate(), [msg("floor")]))
      assert run(compiled, %{"page" => %{estimate: 4.8}}) == 4
    end

    test "whole days since a date: (now - date) :to days :floor" do
      raw = chain(now(), [msg("minus", due()), msg("to_days"), msg("floor")])
      compiled = elixir(raw)
      assert compiled.source =~ "floor("
      assert compiled.source =~ "date_diff("

      values = %{"now" => ~U[2026-10-21 18:00:00Z], "page" => %{due: ~U[2026-10-19 06:00:00Z]}}
      assert run(compiled, values) == 2
      assert run(compiled, %{values | "page" => %{due: nil}}) == nil
    end

    test "on anything but a number they are not compiled" do
      for name <- ["ceil", "floor"] do
        assert {:ok, %{ir: nil, diagnostics: diagnostics}} = compile(chain(due(), [msg(name)]))
        assert Enum.any?(diagnostics, &(&1.message =~ inspect(name)))
      end
    end
  end

  describe ":rounded to (WTF-609)" do
    test "compiles to the IR's :round_to, typed number" do
      assert {:ok, %{ir: %IR{op: :round_to, type: "number", args: [%IR{op: :field}, places]}}} =
               compile(chain(estimate(), [msg("round", 1)]))

      assert %IR{type: "number"} = places
    end

    # Observed on Bubble 2026-10-23: a text element showing
    # `<number> :rounded to <places>` for each of these numbers.
    @observed [
      {2.5, 0, 3},
      {3.5, 0, 4},
      {0.5, 0, 1},
      {1.5, 0, 2},
      {-0.5, 0, 0},
      {-1.5, 0, -1},
      {-2.5, 0, -2},
      {-0.4, 0, 0},
      {1.25, 1, 1.3},
      {1.35, 1, 1.4},
      {1.45, 1, 1.5},
      {-1.25, 1, -1.2},
      {0.05, 1, 0.1},
      {1.005, 2, 1},
      {2.675, 2, 2.68},
      {1.015, 2, 1.01},
      {8.345, 2, 8.35},
      {1.255, 2, 1.25},
      {1234.5, 0, 1235},
      {2.4999999, 0, 2},
      {1.23456789, 3, 1.235}
    ]

    test "rounds as Bubble: a half toward positive infinity, scaled as a float", %{rt: rt} do
      for {x, places, shown} <- @observed do
        assert rt.text(rt.round_to(x, places)) == rt.text(shown),
               "#{x} :rounded to #{places}: Bubble shows #{shown}"
      end

      # A whole result is an integer, never -0.
      assert rt.round_to(2.5, 0) === 3
      assert rt.round_to(-0.4, 0) === 0
      assert rt.text(rt.round_to(-0.5, 0)) == "0"
      # Math.round(0.49999999999999994) is 0, not 1.
      assert rt.round_to(0.49999999999999994, 0) === 0
      assert rt.round_to(7, 1) === 7
    end

    test "a Decimal rounds as its float and stays a Decimal; empty stays empty", %{rt: rt} do
      assert Decimal.equal?(rt.round_to(Decimal.new("1.25"), 1), Decimal.new("1.3"))
      assert Decimal.equal?(rt.round_to(Decimal.new("-2.5"), 0), Decimal.new("-2"))
      assert Decimal.equal?(rt.round_to(Decimal.new("1.005"), 2), Decimal.new("1"))
      assert rt.round_to(1.25, Decimal.new(1)) == 1.3

      assert rt.round_to(1.0e300, 2) === 1.0e300
      assert rt.round_to(10 ** 400, 1) === 10 ** 400
      big = Decimal.new("1e400")
      assert rt.round_to(big, 1) === big
      assert rt.round_to(1.5, 400) === 1.5

      for empty <- [nil, "", "text"] do
        assert rt.round_to(empty, 1) == nil
        assert rt.round_to(1.25, empty) == nil
      end
    end

    test "a page thing's number, empty when the number is" do
      compiled = elixir(chain(estimate(), [msg("round", 1)]))
      assert compiled.source =~ "round_to("
      assert run(compiled, %{"page" => %{estimate: 1.25}}) == 1.3
      assert run(compiled, %{"page" => %{estimate: -1.25}}) == -1.2
      assert run(compiled, %{"page" => %{estimate: nil}}) == nil
    end

    test "days since a date, rounded: (now - date) :to days :rounded to 0" do
      raw = chain(now(), [msg("minus", due()), msg("to_days"), msg("round", 0)])
      compiled = elixir(raw)
      assert compiled.source =~ "round_to("
      assert compiled.source =~ "date_diff("

      # 2.5 days: :to days is 2.5, rounded to 3.
      values = %{"now" => ~U[2026-10-21 18:00:00Z], "page" => %{due: ~U[2026-10-19 06:00:00Z]}}
      assert run(compiled, values) == 3
    end

    test "on anything but a number it is not compiled" do
      assert {:ok, %{ir: nil, diagnostics: diagnostics}} =
               compile(chain(due(), [msg("round", 1)]))

      assert Enum.any?(diagnostics, &(&1.message =~ ~s("round")))
    end
  end
end
