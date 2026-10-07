defmodule BubbleEx.Target.Elixir.FormatsTzTest do
  # The generated runtime's dates with a real time zone database (`tz`, a
  # test-only dependency): DST gaps and repeated hours, offsets (WTF-456).
  # Not async: the database is the VM-wide `Calendar` setting, set here
  # and restored after each test (async modules run before this one).
  use ExUnit.Case, async: false

  alias BubbleEx.Target.Phoenix.Templates

  @module "FormatsTzCheck"
  @app :formats_tz_check
  @runtime Module.concat([@module, Bubble, Runtime])

  setup_all do
    unless Code.ensure_loaded?(@runtime) do
      source =
        Templates.render("lib/app/bubble/runtime.ex", %{
          module: @module,
          app: @app,
          enforced?: false
        })

      Code.compile_string(source)
    end

    :ok
  end

  setup do
    previous = Calendar.get_time_zone_database()
    Calendar.put_time_zone_database(Tz.TimeZoneDatabase)

    on_exit(fn ->
      Calendar.put_time_zone_database(previous)
      Application.delete_env(@app, :bubble_time_zone)
    end)

    # A variable, not a literal module: it is compiled at run time.
    %{rt: @runtime}
  end

  defp zone(name), do: Application.put_env(@app, :bubble_time_zone, name)

  describe "the repeated hour when clocks go back (New York, 2023-11-05)" do
    test "rounding down stays in the same occurrence of the hour", %{rt: rt} do
      zone("America/New_York")
      # 01:30 EST, the second 01:30 of the night.
      assert rt.date_floor(~U[2023-11-05 06:30:00Z], "hour") == ~U[2023-11-05 06:00:00.000000Z]
      assert rt.date_floor(~U[2023-11-05 06:30:45Z], "minute") == ~U[2023-11-05 06:30:00.000000Z]

      assert rt.date_floor(~U[2023-11-05 06:30:45.5Z], "second") ==
               ~U[2023-11-05 06:30:45.000000Z]

      # 01:30 EDT, the first.
      assert rt.date_floor(~U[2023-11-05 05:30:00Z], "hour") == ~U[2023-11-05 05:00:00.000000Z]
      # The day starts at midnight EDT.
      assert rt.date_floor(~U[2023-11-05 06:30:00Z], "day") == ~U[2023-11-05 04:00:00.000000Z]
      # An expression's own zone, not the app's.
      assert rt.date_floor(~U[2023-11-05 06:30:00Z], "hour", "America/New_York") ==
               ~U[2023-11-05 06:00:00.000000Z]
    end

    test "both 01:30s show as 1:30, with their own abbreviation", %{rt: rt} do
      zone("America/New_York")
      assert rt.format_date(~U[2023-11-05 05:30:00Z], "h:MM tt Z") == "1:30 am EDT"
      assert rt.format_date(~U[2023-11-05 06:30:00Z], "h:MM tt Z") == "1:30 am EST"
    end

    test "adding nothing in the repeated hour changes nothing", %{rt: rt} do
      zone("America/New_York")
      assert rt.date_add(~U[2023-11-05 06:30:00Z], 0, :day) == ~U[2023-11-05 06:30:00Z]
      assert rt.date_add(~U[2023-11-05 05:30:00Z], 0, :month) == ~U[2023-11-05 05:30:00Z]
    end

    test "adding a day into the repeated hour takes its first occurrence", %{rt: rt} do
      zone("America/New_York")
      # 2023-11-04 01:30 EDT + 1 day = 2023-11-05 01:30, ambiguous: EDT.
      assert rt.date_add(~U[2023-11-04 05:30:00Z], 1, :day) == ~U[2023-11-05 05:30:00Z]
    end
  end

  describe "the skipped hour when clocks go forward" do
    test "adding a day across it keeps the wall clock (New York, 2023-03-12)", %{rt: rt} do
      zone("America/New_York")
      # 12:00 EST + 1 day = 12:00 EDT: 23 hours later.
      assert rt.date_add(~U[2023-03-11 17:00:00Z], 1, :day) == ~U[2023-03-12 16:00:00Z]
      assert rt.date_add(~U[2023-03-12 16:00:00Z], -1, :day) == ~U[2023-03-11 17:00:00Z]
      # Hours are durations.
      assert rt.date_add(~U[2023-03-11 17:00:00Z], 24, :hour) == ~U[2023-03-12 17:00:00Z]
    end

    test "a day starting in the gap starts when it begins (São Paulo, 2018-11-04)", %{rt: rt} do
      # Brazilian summer time began at midnight: 00:00-00:59 did not exist.
      zone("America/Sao_Paulo")
      assert rt.date_floor(~U[2018-11-04 14:00:00Z], "day") == ~U[2018-11-04 03:00:00.000000Z]

      assert rt.format_date(~U[2018-11-04 03:00:00Z], "mmm d, h:MM tt o") ==
               "Nov 4, 1:00 am -0200"

      # 2018-11-03 00:30 -03 + 1 day lands in the gap: just after it.
      assert rt.date_add(~U[2018-11-03 03:30:00Z], 1, :day) == ~U[2018-11-04 03:30:00Z]
    end
  end

  describe "a repeated midnight (Havana, 2024-11-03)" do
    test "the day starts at the first midnight; hours keep their occurrence", %{rt: rt} do
      # Cuba's clocks went back from 01:00 CDT to 00:00 CST: midnight came twice.
      zone("America/Havana")
      # Noon CST.
      assert rt.date_floor(~U[2024-11-03 17:00:00Z], "day") == ~U[2024-11-03 04:00:00.000000Z]
      # 00:30 CST, the second midnight hour.
      assert rt.date_floor(~U[2024-11-03 05:30:00Z], "day") == ~U[2024-11-03 04:00:00.000000Z]
      assert rt.date_floor(~U[2024-11-03 05:30:00Z], "hour") == ~U[2024-11-03 05:00:00.000000Z]
    end
  end

  describe "offsets and abbreviations" do
    test "Paris and New York, winter and summer", %{rt: rt} do
      winter = ~U[2023-03-02 15:04:05Z]
      summer = ~U[2023-07-01 12:00:00Z]

      assert rt.format_date(winter, "H:MM Z o p", "Europe/Paris") == "16:04 CET +0100 +01:00"
      assert rt.format_date(summer, "H:MM Z o p", "Europe/Paris") == "14:00 CEST +0200 +02:00"

      assert rt.format_date(winter, "h:MM tt Z o p", "America/New_York") ==
               "10:04 am EST -0500 -05:00"

      assert rt.format_date(summer, "h:MM tt Z o p", "America/New_York") ==
               "8:00 am EDT -0400 -04:00"
    end

    test "the app's zone applies when the expression names none", %{rt: rt} do
      zone("Europe/Paris")
      assert rt.format_date(~U[2023-03-02 23:30:00Z], "mmm d, H:MM") == "Mar 3, 0:30"
      assert rt.display(~U[2023-03-02 23:30:00Z]) == "Mar 3, 2023 12:30 am"
      assert rt.date_part(~U[2023-03-02 23:30:00Z], "date") == 3
      # Friday in Paris, Thursday in UTC (replay 2026-10-07: the zone used).
      assert rt.date_part(~U[2023-03-02 23:30:00Z], "day") == 5
      assert rt.date_part(~U[2023-03-02 23:30:00Z], "day", "UTC") == 4
      # Text (a navigate URL parameter) is in the user's zone, as Bubble's
      # browser writes it; a backend workflow's is UTC (replay 2026-10-07).
      assert rt.text(~U[2023-03-02 23:30:00Z]) == "Mar 3, 2023 12:30 am"
      assert rt.utc_text(~U[2023-03-02 23:30:00Z]) == "Mar 2, 2023 11:30 pm"
      # iso_date is UTC whatever the zone.
      assert rt.format_date(~U[2023-03-02 23:30:00Z], "iso_date") == "2023-03-02T23:30:00.000Z"
    end

    test "months step on the local calendar", %{rt: rt} do
      zone("Europe/Paris")
      # Jan 31 00:30 in Paris is Jan 30 23:30 UTC: a month later is Feb 28 locally.
      assert rt.date_add(~U[2023-01-30 23:30:00Z], 1, :month) == ~U[2023-02-27 23:30:00Z]
    end
  end
end
