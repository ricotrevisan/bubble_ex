defmodule BubbleEx.Target.Elixir.FormatsTest do
  # Bubble's date and number formats (WTF-456): the generated runtime
  # (templates/lib/app/bubble/runtime.ex.eex, compiled here as a
  # stand-alone module), what Target.Elixir emits for it, and what it
  # reports as approximated. Synthetic values only.
  use ExUnit.Case, async: true

  alias BubbleEx.Expression.IR
  alias BubbleEx.Target.Elixir, as: Target
  alias BubbleEx.Target.Elixir.Formats
  alias BubbleEx.Target.Phoenix.Templates

  @module "FormatsCheck"
  @runtime Module.concat([@module, Bubble, Runtime])

  setup_all do
    unless Code.ensure_loaded?(@runtime) do
      source =
        Templates.render("lib/app/bubble/runtime.ex", %{
          module: @module,
          app: :formats_check,
          enforced?: false
        })

      Code.compile_string(source)
    end

    # A variable, not a literal module: it is compiled at run time.
    %{rt: @runtime}
  end

  @at ~U[2028-03-02 15:04:05.678901Z]

  describe "format_date" do
    test "Bubble's named and custom patterns", %{rt: rt} do
      cases = [
        {"mmm d, yyyy", "Mar 2, 2028"},
        {"mmmm d, yyyy", "March 2, 2028"},
        {"dddd, mmmm d, yyyy", "Thursday, March 2, 2028"},
        {"m/dd/yy", "3/02/28"},
        {"m/dd/yyyy", "3/02/2028"},
        {"HH:MM:ss", "15:04:05"},
        {"h:MM tt", "3:04 pm"},
        {"hh:MM TT", "03:04 PM"},
        {"ddd, mmm d", "Thu, Mar 2"},
        {"mmm 'yy", "Mar '28"},
        {"mmmm dS yyyy", "March 2nd 2028"},
        {"yyyy-mm-dd", "2028-03-02"},
        {"d", "2"},
        {"dd mmm, yyyy", "02 Mar, 2028"},
        {"H:M:s.l L", "15:4:5.678 67"},
        {"t T", "p P"},
        {"mmm d, h:MM tt Z", "Mar 2, 3:04 pm UTC"},
        {"o p", "+0000 +00:00"},
        {"W WW N", "9 09 4"},
        {~s|yyyy "at" 'h' mmm|, "2028 at h Mar"},
        {"mmm d, y", "Mar 2, y"}
      ]

      for {format, expected} <- cases do
        assert rt.format_date(@at, format) == expected, format
      end
    end

    test "ordinals", %{rt: rt} do
      for {day, suffix} <-
            [{1, "st"}, {2, "nd"}, {3, "rd"}, {4, "th"}, {11, "th"}, {12, "th"}] ++
              [{13, "th"}, {21, "st"}, {22, "nd"}, {23, "rd"}, {31, "st"}] do
        {:ok, x} = DateTime.new(Date.new!(2028, 1, day), ~T[00:00:00], "Etc/UTC")
        assert rt.format_date(x, "dS") == "#{day}#{suffix}"
      end
    end

    test "12-hour clock around midnight and noon", %{rt: rt} do
      assert rt.format_date(~U[2028-03-02 00:30:00Z], "h:MM tt") == "12:30 am"
      assert rt.format_date(~U[2028-03-02 12:30:00Z], "h:MM tt") == "12:30 pm"
    end

    test "relative days", %{rt: rt} do
      today = DateTime.utc_now()
      assert rt.format_date(today, "DDDD") == "Today"
      assert rt.format_date(DateTime.add(today, -1, :day), "DDD") == "Ysd"
      assert rt.format_date(DateTime.add(today, 1, :day), "DDDD") == "Tomorrow"
      far = DateTime.add(today, 30, :day)
      assert rt.format_date(far, "DDDD") == rt.format_date(far, "dddd")
    end

    test "iso_date is ISO 8601 in UTC with milliseconds", %{rt: rt} do
      assert rt.format_date(@at, "iso_date") == "2028-03-02T15:04:05.678Z"
      assert rt.format_date(~U[2028-03-02 00:00:00Z], "iso_date") == "2028-03-02T00:00:00.000Z"
    end

    test "the default format, also for dates shown as text", %{rt: rt} do
      assert rt.format_date(@at, nil) == "Mar 2, 2028 3:04 pm"
      assert rt.text(@at) == "Mar 2, 2028 3:04 pm"
      assert rt.text(~D[2028-03-02]) == "Mar 2, 2028 12:00 am"
      refute rt.text(@at) =~ ~r/\d{4}-\d{2}-\d{2}T/
    end

    test "empty and non-date values never raise", %{rt: rt} do
      assert rt.format_date(nil, "mmm d") == nil
      assert rt.format_date("not a date", "mmm d") == "not a date"
      assert rt.format_date(@at, "") == ""
    end

    test "a zone without a time zone database shows in UTC", %{rt: rt} do
      # bubble_ex's test VM has only the UTC database.
      assert rt.time_zone() == "Etc/UTC"
      assert rt.format_date(@at, "h:MM tt Z", "America/Los_Angeles") == "3:04 pm UTC"
      assert rt.format_date(@at, "h:MM tt Z", "UTC") == "3:04 pm UTC"
      assert rt.format_date(@at, "h:MM tt", nil) == "3:04 pm"
    end

    test "a zone the database knows shifts the wall clock", %{rt: rt} do
      # A DateTime already in the zone stands in for a zone database lookup
      # (shifting to its own zone is a no-op).
      shifted = %{
        @at
        | hour: 10,
          time_zone: "America/New_York",
          zone_abbr: "EST",
          utc_offset: -18_000,
          std_offset: 0
      }

      assert rt.format_date(shifted, "h:MM tt o p Z", "America/New_York") ==
               "10:04 am -0500 -05:00 EST"
    end
  end

  describe "format_number" do
    test "decimals, separators, currency and percentages", %{rt: rt} do
      cases = [
        {1234.5, %{}, "1234.5"},
        {1234.0, %{}, "1234"},
        {3, %{"decimal_place" => 2}, "3.00"},
        {2.345, %{"decimal_place" => 2}, "2.35"},
        {2.5, %{"decimal_place" => 0}, "3"},
        {-2.5, %{"decimal_place" => 0}, "-3"},
        {-0.4, %{"decimal_place" => 0}, "0"},
        {1_234_567.891, %{"decimal_place" => 1, "thousand_separator" => "comma"}, "1,234,567.9"},
        {1_234_567.891, %{"decimal_place" => 2, "thousand_separator" => "period"},
         "1.234.567,89"},
        {1_234_567, %{"thousand_separator" => "space"}, "1 234 567"},
        {999, %{"thousand_separator" => "comma"}, "999"},
        {1234.5,
         %{
           "formatting_type" => "currency",
           "decimal_place" => 0,
           "thousand_separator" => "comma",
           "currency_symbol" => "$"
         }, "$1,235"},
        {1234.5, %{"formatting_type" => "currency", "currency_symbol" => "€"}, "€1234.50"},
        {-5, %{"formatting_type" => "currency", "currency_symbol" => "$"}, "-$5.00"},
        {0.256, %{"formatting_type" => "percentage", "decimal_place" => 1}, "25.6%"},
        {0.5, %{"formatting_type" => "percentage", "decimal_place" => 0}, "50%"},
        {Decimal.new("10.005"), %{"decimal_place" => 2}, "10.01"}
      ]

      for {n, options, expected} <- cases do
        assert rt.format_number(n, options) == expected, inspect({n, options})
      end
    end

    test "empty and non-number values never raise", %{rt: rt} do
      assert rt.format_number(nil, %{"decimal_place" => 2}) == nil
      assert rt.format_number("", %{}) == nil
      assert rt.format_number("abc", %{"decimal_place" => 2}) == "abc"
      assert rt.format_number(12, %{"formatting_type" => "scientific"}) == "12"
    end
  end

  describe "calendar operators" do
    test "date_add steps months and years on the calendar", %{rt: rt} do
      assert rt.date_add(~U[2028-01-31 10:00:00Z], 1, :month) == ~U[2028-02-29 10:00:00Z]
      assert rt.date_add(~U[2028-02-29 10:00:00Z], 1, :year) == ~U[2029-02-28 10:00:00Z]
      assert rt.date_add(~U[2028-03-02 10:00:00Z], 2.0, :day) == ~U[2028-03-04 10:00:00Z]
      assert rt.date_add(~U[2028-03-02 10:00:00Z], 1.5, :hour) == ~U[2028-03-02 11:30:00Z]
      assert rt.date_add(~U[2028-03-02 10:00:00Z], 0.5, :day) == ~U[2028-03-02 22:00:00Z]
      assert rt.date_add(nil, 1, :day) == nil
    end

    test "date_floor rounds down to a calendar unit", %{rt: rt} do
      at = ~U[2028-03-02 15:04:05.678901Z]

      for {unit, expected} <- [
            {"year", ~U[2028-01-01 00:00:00.000000Z]},
            {"month", ~U[2028-03-01 00:00:00.000000Z]},
            {"week", ~U[2028-02-27 00:00:00.000000Z]},
            {"day", ~U[2028-03-02 00:00:00.000000Z]},
            {"hour", ~U[2028-03-02 15:00:00.000000Z]},
            {"minute", ~U[2028-03-02 15:04:00.000000Z]},
            {"second", ~U[2028-03-02 15:04:05.000000Z]}
          ] do
        assert rt.date_floor(at, unit) == expected, unit
      end

      assert rt.date_floor(at, "day", "UTC") == ~U[2028-03-02 00:00:00.000000Z]
      assert rt.date_floor(at, "fortnight") == at
      assert rt.date_floor(nil, "day") == nil
    end

    test "date_part extracts a calendar part", %{rt: rt} do
      assert rt.date_part(@at, "year") == 2028
      assert rt.date_part(@at, "month") == 3
      assert rt.date_part(@at, "date") == 2
      assert rt.date_part(@at, "hour", "UTC") == 15
      assert rt.date_part(@at, "millisecond") == 678
      assert rt.date_part(~U[1970-01-01 00:00:01Z], "UNIX") == 1000
      assert rt.date_part(@at, "fortnight") == nil
      assert rt.date_part(nil, "year") == nil
    end
  end

  describe "the pattern Target.Elixir reads" do
    test "tokens/1 splits as the runtime renders" do
      assert Formats.tokens(~s|mmm d, yyyy 'at' h:MMtt ZZ|) == [
               {:token, "mmm"},
               {:text, " "},
               {:token, "d"},
               {:text, ", "},
               {:token, "yyyy"},
               {:text, " "},
               {:quoted, "at"},
               {:text, " "},
               {:token, "h"},
               {:text, ":"},
               {:token, "MM"},
               {:token, "tt"},
               {:text, " "},
               {:token, "ZZ"}
             ]

      # The runtime template embeds the same pattern.
      source =
        Templates.render("lib/app/bubble/runtime.ex", %{module: "X", app: :x, enforced?: false})

      assert source =~ "~r/" <> Formats.date_pattern() <> "/"
    end

    test "approximations name the parts, never Bubble IDs" do
      assert Formats.approximations(:format_date, "mmm d, yyyy") == []
      assert Formats.approximations(:format_date, "iso_date") == []
      assert Formats.approximations(:format_date, nil) == []
      assert Formats.approximations(:format_date, "h:MMtt ZZ") == ["date_format_token:ZZ"]
      assert Formats.approximations(:format_date, "mmm d, y") == ["date_format_letters"]
      assert Formats.approximations(:format_date, "yyyy 'at' h") == []
      assert Formats.approximations(:date_floor, "week") == []
      assert Formats.approximations(:date_floor, "quarter") == ["date_floor_unit:quarter"]
      assert Formats.approximations(:date_part, "UNIX") == []
      assert Formats.approximations(:date_part, "quarter") == ["date_part_unit:quarter"]

      assert Formats.approximations(:format_number, %{
               "formatting_type" => "currency",
               "decimal_place" => 0,
               "thousand_separator" => "comma",
               "currency_symbol" => "$"
             }) == []

      assert Formats.approximations(:format_number, %{
               "formatting_type" => "scientific",
               "decimal_place" => -1,
               "rounding" => "up"
             }) == [
               "number_format_setting:rounding",
               "number_format_value:decimal_place",
               "number_format_value:formatting_type"
             ]
    end
  end

  describe "Target.Elixir" do
    setup do
      %{project: BubbleEx.Test.ExpressionFixture.project()}
    end

    defp date, do: IR.node(:literal, ["x"], "date")

    test "a zone is an argument only when the expression names one", %{project: project} do
      {:ok, plain} =
        Target.compile(IR.node(:format_date, [date(), "mmm d", nil], "text"), project)

      assert plain.source == ~s|Bubble.Runtime.format_date("x", "mmm d")|
      assert plain.diagnostics == []
      assert plain.runtime == [:format_date]

      {:ok, static} =
        Target.compile(IR.node(:format_date, [date(), "mmm d", "UTC"], "text"), project)

      assert static.source == ~s|Bubble.Runtime.format_date("x", "mmm d", "UTC")|

      zone = IR.node(:literal, ["America/New_York"], "text")

      {:ok, dynamic} =
        Target.compile(IR.node(:date_floor, [date(), "day", zone], "date"), project)

      assert dynamic.source == ~s|Bubble.Runtime.date_floor("x", "day", "America/New_York")|

      {:ok, default} = Target.compile(IR.node(:format_date, [date(), nil, nil], "text"), project)
      assert default.source == ~s|Bubble.Runtime.format_date("x", nil)|
    end

    test "an approximated format compiles with a warning", %{project: project} do
      ir =
        IR.node(
          :concat,
          [
            IR.node(:format_date, [date(), "h:MMtt ZZ", nil], "text"),
            IR.node(:format_number, [IR.node(:literal, [1], "number"), %{"x" => 1}], "text")
          ],
          "text"
        )

      {:ok, result} = Target.compile(ir, project, path: "/p")
      assert is_binary(result.source)

      assert [
               %{
                 code: :elixir_format_approximated,
                 severity: :warning,
                 path: "/p",
                 details: %{constructs: ["date_format_token:ZZ", "number_format_setting:x"]}
               }
             ] = result.diagnostics
    end

    test "the compiled source runs against the generated runtime", %{project: project} do
      ir = IR.node(:format_date, [IR.node(:literal, [nil], "date"), "mmm d, yyyy", nil], "text")
      {:ok, %{source: source}} = Target.compile(ir, project, runtime: inspect(@runtime))

      {value, _} =
        Code.eval_string(String.replace(source, "nil", "~U[2028-03-02 00:00:00Z]", global: false))

      assert value == "Mar 2, 2028"
    end
  end
end
