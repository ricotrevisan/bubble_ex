defmodule BubbleEx.Target.Elixir.DatesOptionsTest do
  # WTF-594 / WTF-597: date differences (`(a - b) :to days`), a date
  # range's start, end and middle, a yes/no formatted as a typed value and
  # options sorted by an attribute, compiled from the expression fixture and
  # run against the generated runtime (templates/lib/app/bubble/runtime.ex.eex,
  # compiled here as a stand-alone module). Synthetic values only.
  use ExUnit.Case, async: true

  import BubbleEx.Test.ExpressionFixture

  alias BubbleEx.Expression.Compiler
  alias BubbleEx.Target.Elixir, as: Target
  alias BubbleEx.Target.Phoenix.Templates

  @module "DatesOptionsCheck"
  @runtime Module.concat([@module, Bubble, Runtime])

  # The fixture's `status` option set as its generated enum would be: Open
  # (sort factor 1, rank 2) and Done (sort factor 2, rank 1).
  defmodule Enums.Status do
    @moduledoc false
    def values, do: ["open", "done"]
    def attributes("open"), do: %{rank: 2}
    def attributes("done"), do: %{rank: 1}
    def attributes(_), do: %{rank: nil}
  end

  setup_all do
    unless Code.ensure_loaded?(@runtime) do
      for template <- ["lib/app/bubble/keywords.ex", "lib/app/bubble/runtime.ex"] do
        template
        |> Templates.render(%{module: @module, app: :dates_options_check, enforced?: false})
        |> Code.compile_string()
      end
    end

    %{rt: @runtime}
  end

  defp elixir(raw, opts \\ []) do
    env = env(Keyword.merge([host: "bT4"], opts))
    {:ok, %{ir: ir}} = Compiler.compile(parse!(raw, env), env)
    namespace = inspect(__MODULE__)

    {:ok, result} =
      Target.compile(ir, project(), runtime: inspect(@runtime), namespace: namespace)

    result
  end

  # `values` by what a binding reads: "page" (the page's thing), "now"
  # (Current Date/Time), "current_user".
  defp run(%{source: source, bindings: bindings}, values) do
    binding =
      for b <- bindings do
        key =
          case b.input do
            {:page_thing, _} -> "page"
            {:page_data, %{"name" => "Current Date/Time"}} -> "now"
            :current_user -> "current_user"
          end

        {String.to_atom(b.var), Map.fetch!(values, key)}
      end

    {value, _} = Code.eval_string(source, binding)
    value
  end

  defp now, do: src("PageData", %{"name" => "Current Date/Time"})
  defp due, do: chain(src("CurrentPageItem"), [msg("due_date")])
  defp window, do: chain(src("CurrentPageItem"), [msg("window_date_range")])
  defp day, do: %{"component_to_extract" => "day"}

  describe "a date minus a date" do
    test "rounded down to days, then to days: whole days in the user's zone" do
      raw =
        chain(now(), [
          msg("rounded_down", nil, day()),
          msg("minus", chain(due(), [msg("rounded_down", nil, day())])),
          msg("to_days")
        ])

      %{source: source} = compiled = elixir(raw)
      assert source =~ "date_diff("
      assert source =~ ":day"

      values = %{
        "now" => ~U[2026-10-21 18:30:00Z],
        "page" => %{due: ~U[2026-10-14 06:00:00Z]}
      }

      assert run(compiled, values) == 7
      assert run(compiled, %{values | "page" => %{due: nil}}) == nil
    end

    test "is exact: fractions of a unit, negative when the right side is later", %{rt: rt} do
      a = ~U[2026-10-21 12:00:00Z]
      b = ~U[2026-10-20 00:00:00Z]
      assert rt.date_diff(a, b, :day) == 1.5
      assert rt.date_diff(a, b, :hour) == 36
      assert rt.date_diff(a, b, :minute) == 2160
      assert rt.date_diff(b, a, :second) == -129_600
      assert rt.date_diff(a, nil, :day) == nil
      assert rt.date_diff(~N[2026-10-21 12:00:00], b, :hour) == 36
    end

    test "days across a clock change are not whole, as an interval is milliseconds", %{rt: rt} do
      # 2026-03-08 is the US daylight saving change: 23 hours between the
      # two local midnights of New York.
      before = ~U[2026-03-08 05:00:00Z]
      later = ~U[2026-03-09 04:00:00Z]
      assert rt.date_diff(later, before, :day) == 23 / 24
    end

    test "an interval used as anything else is not compiled" do
      result = elixir(chain(now(), [msg("minus", due())]))
      assert result.source == nil
      assert [%{message: message}] = result.diagnostics
      assert message =~ "a date interval used as a value"
    end
  end

  describe "a date range's min, max and average" do
    test "its start, end and middle", %{rt: rt} do
      range = %{start: ~U[2026-02-28 05:00:00Z], end: ~U[2026-03-31 04:59:00Z]}

      for {name, expected} <- [
            {"min", range.start},
            {"max", range.end},
            {"average", ~U[2026-03-15 16:59:30.000Z]}
          ] do
        compiled = elixir(chain(window(), [msg(name)]))
        assert run(compiled, %{"page" => %{window: range}}) == expected
        assert run(compiled, %{"page" => %{window: nil}}) == nil
      end

      assert rt.range_middle(%{start: range.start, end: nil}) == nil
      assert rt.range_start(%{"start" => range.start, "end" => nil}) == range.start
    end

    test "a label: the range's end formatted, or a text when it is empty" do
      format = %{"formatting_type" => "custom", "custom_format" => "mmm d"}

      raw =
        text([
          chain(window(), [
            msg("is_not_empty"),
            msg("format_boolean", nil, %{
              "formatting_for_true" =>
                text(["Due: ", chain(window(), [msg("max"), msg("format_date", nil, format)])]),
              "formatting_for_false" => text(["Current"])
            })
          ])
        ])

      compiled = elixir(raw)
      range = %{start: ~U[2026-03-22 12:00:00Z], end: ~U[2026-03-29 12:00:00Z]}
      assert run(compiled, %{"page" => %{window: range}}) == "Due: Mar 29"
      assert run(compiled, %{"page" => %{window: nil}}) == "Current"
    end
  end

  describe "a yes/no formatted as a typed value" do
    test "a text, and a yes/no read as a condition" do
      as_type = fn type, yes, no ->
        msg("format_boolean_as_type", nil, %{
          "data_type" => type,
          "is_list" => false,
          "value_for_true" => yes,
          "value_for_false" => no
        })
      end

      label =
        elixir(
          chain(window(), [msg("is_not_empty"), as_type.("text", text(["set"]), text(["unset"]))])
        )

      assert run(label, %{"page" => %{window: %{start: nil, end: nil}}}) == "set"
      assert run(label, %{"page" => %{window: nil}}) == "unset"

      # `not admin` written as admin formatted as yes/no (no, yes), in a condition.
      negated =
        elixir(
          chain(cu(), [msg("admin_boolean"), as_type.("boolean", false, true)])
          |> then(&chain(&1, [msg("and_", chain(cu(), [msg("coach_boolean")]))]))
        )

      assert run(negated, %{"current_user" => %{admin: false, coach: true}}) == true
      assert run(negated, %{"current_user" => %{admin: true, coach: true}}) == false
    end
  end

  describe "options sorted by an attribute" do
    test "by the attribute's value, not the sort factor; equal keys keep their order", %{rt: rt} do
      sorted = fn desc ->
        chain(opt("status", "all values"), [
          msg("sorted", nil, %{"sort_field" => "rank", "descending" => desc})
        ])
      end

      assert run(elixir(sorted.(false)), %{}) == ["done", "open"]
      assert run(elixir(sorted.(true)), %{}) == ["open", "done"]

      key = &Map.get(%{"a" => 1, "b" => nil, "c" => 1}, &1)
      assert rt.sort_values_by(["c", "b", "a"], key, false) == ["b", "c", "a"]
      assert rt.sort_values_by(["c", "b", "a"], key, true) == ["c", "a", "b"]
      assert rt.sort_values_by(nil, key, false) == []
    end

    test "an attribute that is not a text, number or date is not compiled" do
      raw =
        chain(opt("status", "all values"), [
          msg("sorted", nil, %{"sort_field" => "urgent", "descending" => false})
        ])

      assert %{source: nil, diagnostics: [_]} = elixir(raw)
    end
  end
end
