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

  test ":rounded to is not compiled yet" do
    assert {:ok, %{ir: nil, diagnostics: diagnostics}} =
             compile(chain(estimate(), [msg("round", 1)]))

    assert Enum.any?(diagnostics, &(&1.message =~ ~s("round")))
  end
end
