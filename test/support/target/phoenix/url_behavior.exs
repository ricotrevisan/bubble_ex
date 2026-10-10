defmodule PhxCheckWeb.UrlBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # `Get data from page URL` (WTF-508), as replayed against Bubble on
  # 2026-10-07 (WTF-387), lowered from test/support/target/phoenix/url.json
  # and run by scripts/phoenix_compile_check.sh in the generated project
  # (copied to test/url_behavior_test.exs, with a database), with
  # privacy: :omit and :enforced. All data is invented.
  #
  # Note's privacy rules: `owner_` (the Note's Owner is the Current User)
  # views everything; everyone else views nothing.
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PhxCheckWeb.Bubble

  @u1 "1700000000000x900000000000000001"
  @u2 "1700000000000x900000000000000002"
  @n1 "1700000000000x100000000000000001"
  @n2 "1700000000000x100000000000000002"

  # A time zone database with one zone two hours ahead of UTC, as the
  # replay's browser was (Europe/Berlin in October): the generated app
  # ships none.
  defmodule PlusTwo do
    @behaviour Calendar.TimeZoneDatabase
    @period %{utc_offset: 7200, std_offset: 0, zone_abbr: "PT2"}

    @impl true
    def time_zone_period_from_utc_iso_days(_iso_days, "Test/PlusTwo"), do: {:ok, @period}
    def time_zone_period_from_utc_iso_days(_iso_days, _zone), do: {:error, :time_zone_not_found}

    @impl true
    def time_zone_periods_from_wall_datetime(_naive, "Test/PlusTwo"), do: {:ok, @period}
    def time_zone_periods_from_wall_datetime(_naive, _zone), do: {:error, :time_zone_not_found}
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows)
      Application.delete_env(:phx_check, :bubble_time_zone)
      Application.delete_env(:phx_check, :bubble_dev_markers)
      Calendar.put_time_zone_database(Calendar.UTCOnlyTimeZoneDatabase)
    end)

    u1 = Ash.Seed.seed!(PhxCheck.User, %{id: @u1, email: "one@example.com"})
    u2 = Ash.Seed.seed!(PhxCheck.User, %{id: @u2, email: "two@example.com"})
    Ash.Seed.seed!(PhxCheck.Note, %{id: @n1, title: "First", owner_id: @u1})
    Ash.Seed.seed!(PhxCheck.Note, %{id: @n2, title: "Second", owner_id: @u2})
    %{u1: u1, u2: u2}
  end

  defp enforced? do
    privacy = Module.concat(PhxCheck, Privacy)

    Code.ensure_loaded?(privacy) and function_exported?(privacy, :mode, 0) and
      apply(privacy, :mode, []) == :enforced
  end

  defp data_access_on,
    do: Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(
      Ash.Resource.put_metadata(user, :token, token)
    )
  end

  defp selector(id, nil), do: ~s([data-bubble-id="#{id}"])
  defp selector(id, scope), do: ~s([data-bubble-scope="#{scope}"] [data-bubble-id="#{id}"])

  # An element's text, its markers and spacing dropped.
  defp text(view, id, scope \\ nil) do
    view
    |> element(selector(id, scope))
    |> render()
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp hidden?(view, id, scope \\ nil) do
    html = view |> element(selector(id, scope)) |> render()
    [open] = Regex.run(~r/\A<[^>]*>/s, html)
    open =~ ~r/\shidden(\s|>|=)/
  end

  # The viewport's width as the page's hook reports it (WTF-520); what
  # reads it is read again after the input debounce.
  defp report_width(view, width) do
    render_hook(view, "bubble:page_width", %{"width" => width})
    Process.sleep(250)
  end

  # The queries `fun` makes, in any process (the LiveView's own included).
  defp queries(fun) do
    handler = "url-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:phx_check, :repo, :query],
        fn _, _, meta, _ -> send(parent, {:url_query, meta.source}) end,
        nil
      )

    try do
      result = fun.()
      {result, collect_queries([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp collect_queries(acc) do
    receive do
      {:url_query, source} -> collect_queries([source | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp read(query, name, type),
    do: Bubble.url_value(Bubble.url_query(query), [], {:query, name}, type)

  # The same instant (a date read from milliseconds keeps their precision).
  defp at?(%DateTime{} = date, expected), do: DateTime.compare(date, expected) == :eq
  defp at?(_date, _expected), do: false

  describe "query parameters" do
    test "text: + and %20 are spaces, a repeated key joins its values with commas", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/?q=a+b")
      assert text(view, "bQ") == "Q: a b"

      {:ok, view, _html} = live(conn, "/?q=a%20b&q=second")
      assert text(view, "bQ") == "Q: a b,second"

      {:ok, view, _html} = live(conn, "/?q=x,y")
      assert text(view, "bQ") == "Q: x,y"

      # `tags[]` is its own key, apart from `tags`.
      {:ok, view, _html} = live(conn, "/?tags[]=a&tags[]=b&tags=c")
      assert text(view, "bTags") == "Tags: a,b"
      # "Is a list" was not replayed: not read (the text stays a marker).
      assert text(view, "bMany") == ""

      {:ok, view, _html} = live(conn, "/?q=")
      assert text(view, "bQ") == "Q:"
    end

    test "query text is read as written, whatever Phoenix's params hold" do
      assert Bubble.url_query("t=a&t=b") == %{"t" => "a,b"}
      assert Bubble.url_query("tags%5B%5D=a&tags[]=b") == %{"tags[]" => "a,b"}
      assert Bubble.url_query("q=%zz+1&&=x&k") == %{"q" => "%zz 1", "" => "x"}
      assert Bubble.url_query("q=%FF") == %{"q" => "�"}
      assert Bubble.url_query(nil) == %{}
    end

    test "numbers parse, anything else is empty", %{conn: conn} do
      for {raw, shown} <- [{"3", "N: 3"}, {"3.5", "N: 3.5"}, {"-2", "N: -2"}, {"abc", "N:"}] do
        {:ok, view, _html} = live(conn, "/?n=#{raw}")
        assert text(view, "bN") == shown, raw
      end

      # Too long, or past JavaScript's exact integers: empty, never a
      # crash or a number the database refuses (not replayed).
      long = String.duplicate("9", 400) <> ".5"
      {:ok, view, _html} = live(conn, "/?n=" <> long)
      assert text(view, "bN") == "N:"
      assert read("n=" <> long, "n", "number") == nil
      assert read("n=99999999999999999999", "n", "number") == nil
      assert read("n=9007199254740991", "n", "number") == 9_007_199_254_740_991
      assert read("n=9007199254740992", "n", "number") == nil
      assert read("n=-12345.25", "n", "number") == -12_345.25

      assert read("n=", "n", "number") == nil
      assert read("n=1e3", "n", "number") == nil
      assert read("n=.5", "n", "number") == 0.5
    end

    test "yes/no: yes, true and 1 are yes; no and false are no; anything else is empty (so no)",
         %{conn: conn} do
      for raw <- ~w(yes Yes true TRUE 1) do
        {:ok, view, _html} = live(conn, "/?on=#{raw}")
        refute hidden?(view, "bOn"), raw
        assert hidden?(view, "bOff"), raw
        assert hidden?(view, "bOnEmpty"), raw
      end

      for raw <- ~w(no false) do
        {:ok, view, _html} = live(conn, "/?on=#{raw}")
        assert hidden?(view, "bOn"), raw
        refute hidden?(view, "bOff"), raw
        assert hidden?(view, "bOnEmpty"), raw
      end

      # Empty, and an empty yes/no is no in `is no` (WTF-529), as Bubble
      # reads it; `is empty` stays exact.
      for query <- ["on=0", "on=y", "on=", ""] do
        {:ok, view, _html} = live(conn, "/?" <> query)
        assert hidden?(view, "bOn"), query
        refute hidden?(view, "bOff"), query
        refute hidden?(view, "bOnEmpty"), query
      end
    end

    test "dates parse in Bubble's forms; one with no time is local midnight", %{conn: conn} do
      midnight = ~U[2026-10-07 00:00:00Z]

      for raw <- ["2026-10-07", "10/07/2026", "Oct 7, 2026", "1791331200000"] do
        assert at?(read("d=" <> URI.encode_www_form(raw), "d", "date"), midnight), raw
      end

      assert at?(read("d=2026-10-07T23:30:00Z", "d", "date"), ~U[2026-10-07 23:30:00Z])
      assert at?(read("d=October+7,+2026+12:00+pm", "d", "date"), ~U[2026-10-07 12:00:00Z])

      for raw <- ["abc", "2026-13-01", "02/30/2026", "Oct 7", ""] do
        assert read("d=" <> URI.encode_www_form(raw), "d", "date") == nil, raw
      end

      {:ok, view, _html} = live(conn, "/?d=2026-10-07")
      assert text(view, "bWhen") == "When: Oct 7, 2026 12:00 am"

      # A bare year, as JavaScript reads one (not replayed).
      assert at?(read("d=2026", "d", "date"), ~U[2026-01-01 00:00:00Z])

      # In the app's time zone: midnight there.
      Calendar.put_time_zone_database(PlusTwo)
      Application.put_env(:phx_check, :bubble_time_zone, "Test/PlusTwo")
      assert at?(read("d=2026-10-07", "d", "date"), ~U[2026-10-06 22:00:00Z])
      assert at?(read("d=Oct+7,+2026", "d", "date"), ~U[2026-10-06 22:00:00Z])
      assert at?(read("d=2026-10-07T23:30:00Z", "d", "date"), ~U[2026-10-07 23:30:00Z])
      assert at?(read("d=1791331200000", "d", "date"), ~U[2026-10-07 00:00:00Z])
    end
  end

  describe "the path" do
    test "item 1 is the page's name; empty segments are dropped; nothing is decoded", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")
      assert text(view, "bSeg1") == "Seg1:"
      assert text(view, "bPath") == "Path:"
      assert hidden?(view, "bSegX")

      {:ok, view, _html} = live(conn, "/index/x")
      assert text(view, "bSeg1") == "Seg1: index"
      assert text(view, "bSeg2") == "Seg2: x"
      assert text(view, "bPath") == "Path: x"
      refute hidden?(view, "bSegX")
      # In a reusable element too.
      assert text(view, "bNavSeg", "bNav") == "Nav: index"
      refute hidden?(view, "bNavX", "bNav")

      # Pages route up to /<page>/<x>: a third segment is never read (a
      # marker, shown empty).
      assert text(view, "bSeg3") == ""

      {:ok, view, _html} = live(conn, "/index/a%20b")
      assert text(view, "bSeg2") == "Seg2: a%20b"

      {:ok, view, _html} = live(conn, "/index/e+f/")
      assert text(view, "bSeg2") == "Seg2: e+f"

      # The URL changing on the same page re-renders what reads it.
      render_patch(view, "/index/x")
      refute hidden?(view, "bSegX")
      refute hidden?(view, "bNavX", "bNav")
    end

    test "item 1 is the Bubble page's name, not its route's" do
      assert Bubble.url_segments("/api-page/z", "api") == ["api", "z"]
      assert Bubble.url_segments("//p//a/b/", "p") == ["p", "a", "b"]
      assert Bubble.url_segments("/", "index") == []
    end

    test "on a page whose route is not its name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/api-page/z")
      assert text(view, "bApiSeg") == "Seg1: api"
    end
  end

  describe "empty and case-insensitive texts" do
    # WTF-514: Bubble has no empty text apart from empty (inferred, not
    # replayed): a missing path segment (nil) is an empty text (`""`).
    test "an empty text is empty: a missing segment is it, and so is ?q=", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      refute hidden?(view, "bSegEmpty")
      refute hidden?(view, "bSegIsQ")

      {:ok, view, _html} = live(conn, "/?q=")
      refute hidden?(view, "bSegIsQ")

      {:ok, view, _html} = live(conn, "/?q=x")
      assert hidden?(view, "bSegIsQ")

      {:ok, view, _html} = live(conn, "/index/x")
      assert hidden?(view, "bSegEmpty")
      assert hidden?(view, "bSegIsQ")

      {:ok, view, _html} = live(conn, "/index/x?q=x")
      refute hidden?(view, "bSegIsQ")
    end

    # WTF-515: the User's email is a case-insensitive text (Ash.CiString):
    # shown as its text, compared as text.
    test "the current user's email shows and compares as text", %{conn: conn, u1: u1} do
      {:ok, view, _html} = live(sign_in(conn, u1), "/?e=one%40example.com")
      assert text(view, "bEmail") == "Email: one@example.com"
      refute hidden?(view, "bEmailIsE")

      {:ok, view, _html} = live(sign_in(conn, u1), "/?e=two%40example.com")
      assert hidden?(view, "bEmailIsE")

      {:ok, view, _html} = live(conn, "/?e=")
      assert text(view, "bEmail") == "Email:"
      assert hidden?(view, "bEmailIsE")
    end
  end

  describe "a thing in the URL" do
    test "is read by its unique ID through Ash as the user; an unknown ID is empty", %{
      conn: conn,
      u1: u1
    } do
      data_access_on()

      {:ok, view, _html} = live(sign_in(conn, u1), "/?note=#{@n1}")
      assert text(view, "bNoteTitle") == "Note: First"

      for raw <- ["1234x5678", "abc", "#{@n1}x", ""] do
        {:ok, view, _html} = live(sign_in(conn, u1), "/?note=" <> URI.encode_www_form(raw))
        assert text(view, "bNoteTitle") == "Note:", raw
      end
    end

    test "privacy rules apply: another user's thing is empty when enforced", %{
      conn: conn,
      u1: u1
    } do
      data_access_on()
      {:ok, view, _html} = live(sign_in(conn, u1), "/?note=#{@n2}")
      {:ok, logged_out, _html} = live(conn, "/?note=#{@n1}")

      if enforced?() do
        assert text(view, "bNoteTitle") == "Note:"
        assert text(logged_out, "bNoteTitle") == "Note:"
      else
        assert text(view, "bNoteTitle") == "Note: Second"
        assert text(logged_out, "bNoteTitle") == "Note: First"
      end
    end

    test "in every cell of a repeating group, and in a reusable rendered per cell", %{
      conn: conn,
      u1: u1
    } do
      data_access_on()
      # The path's segments are the list: two cells.
      {:ok, view, _html} = live(sign_in(conn, u1), "/index/x?note=#{@n1}")
      html = render(view)
      assert length(Regex.scan(~r/Cell note: First/, html)) == 2
      assert length(Regex.scan(~r/Card note: First/, html)) == 2

      {:ok, view, _html} = live(sign_in(conn, u1), "/index/x?note=1234x5678")
      html = render(view)
      refute html =~ "Cell note: First"
      refute html =~ "Card note: First"
    end

    test "nothing is read with data access off", %{conn: conn, u1: u1} do
      {:ok, view, _html} = live(sign_in(conn, u1), "/?note=#{@n1}")
      assert text(view, "bNoteTitle") == "Note:"
    end
  end

  describe "workflows" do
    test "read typed parameters and things as the user", %{conn: conn, u1: u1} do
      data_access_on()
      {:ok, view, _html} = live(sign_in(conn, u1), "/?n=3&note=#{@n1}")
      render_click(view, "bubble:click", %{"scope" => "", "element" => "bCopy"})
      assert text(view, "bCount") == "Count: 3"
      assert text(view, "bNoted") == "Noted: First"

      {:ok, view, _html} = live(sign_in(conn, u1), "/?n=abc&note=#{@n2}")
      render_click(view, "bubble:click", %{"scope" => "", "element" => "bCopy"})
      assert text(view, "bCount") == "Count:"

      if enforced?(),
        do: assert(text(view, "bNoted") == "Noted:"),
        else: assert(text(view, "bNoted") == "Noted: Second")
    end
  end

  # The wide page (WTF-520): the Side nav's Compact property is `Current
  # page width > 767 and compact`, its label hidden when Compact is yes.
  describe "the viewport's width" do
    test "the connect params carry the first one: the first connected render has it", %{
      conn: conn,
      u1: u1
    } do
      data_access_on()
      conn = sign_in(conn, u1)

      {:ok, view, _html} =
        conn |> put_connect_params(%{"bubble_page_width" => 1024}) |> live("/wide?compact=yes")

      assert hidden?(view, "bSideLabel", "bWideNav")

      # The static render has no width: empty > 767 is no.
      static = conn |> get("/wide?compact=yes") |> html_response(200)
      [open] = Regex.run(~r/<p[^>]*data-bubble-id="bSideLabel"[^>]*>/s, static)
      refute open =~ ~r/\shidden(\s|>|=)/

      # Narrow, or no parameter: shown.
      {:ok, view, _html} =
        conn |> put_connect_params(%{"bubble_page_width" => 600}) |> live("/wide?compact=yes")

      refute hidden?(view, "bSideLabel", "bWideNav")

      {:ok, view, _html} =
        conn |> put_connect_params(%{"bubble_page_width" => 1024}) |> live("/wide")

      refute hidden?(view, "bSideLabel", "bWideNav")

      # A malformed one is none.
      {:ok, view, _html} =
        conn |> put_connect_params(%{"bubble_page_width" => "1024"}) |> live("/wide?compact=yes")

      refute hidden?(view, "bSideLabel", "bWideNav")
    end

    test "a reported width is read again, with a URL parameter", %{conn: conn, u1: u1} do
      data_access_on()
      {:ok, view, _html} = live(sign_in(conn, u1), "/wide?compact=yes")

      # No connect params here: empty, and empty > 767 is no.
      refute hidden?(view, "bSideLabel", "bWideNav")

      report_width(view, 1024)
      assert hidden?(view, "bSideLabel", "bWideNav")

      report_width(view, 767)
      refute hidden?(view, "bSideLabel", "bWideNav")

      report_width(view, 768)
      assert hidden?(view, "bSideLabel", "bWideNav")

      # A burst is read once, at its last width.
      for w <- [1000, 600, 1200, 700], do: render_hook(view, "bubble:page_width", %{"width" => w})
      Process.sleep(250)
      refute hidden?(view, "bSideLabel", "bWideNav")
    end

    test "only a whole number of pixels in range is taken", %{conn: conn, u1: u1} do
      data_access_on()
      {:ok, view, _html} = live(sign_in(conn, u1), "/wide?compact=yes")

      for bad <- ["1024", 1024.5, -1, 100_001, nil, %{"w" => 1}] do
        report_width(view, bad)
        refute hidden?(view, "bSideLabel", "bWideNav"), inspect(bad)
      end

      render_hook(view, "bubble:page_width", %{"other" => 1024})
      Process.sleep(250)
      refute hidden?(view, "bSideLabel", "bWideNav")
    end

    test "a click workflow and a condition read it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/wide")
      render_click(view, "bubble:click", %{"scope" => "", "element" => "bWideBtn"})
      assert text(view, "bWideShown") == "Width:"
      assert text(view, "bWideCond") == "Cond:"

      report_width(view, 600)
      assert text(view, "bWideCond") == "Cond:"

      report_width(view, 800)
      render_click(view, "bubble:click", %{"scope" => "", "element" => "bWideBtn"})
      assert text(view, "bWideShown") == "Width: 800"
      assert text(view, "bWideCond") == "Cond: wide"
    end

    test "a report while a typed input's workflow is pending runs it once, on the latest", %{
      conn: conn,
      u1: u1
    } do
      data_access_on()
      {:ok, view, _html} = live(sign_in(conn, u1), "/wide?compact=yes")

      render_change(view, "bubble:change", %{
        "bubble" => %{"scope" => "", "element" => "bWideIn", "value" => "abc"}
      })

      render_hook(view, "bubble:page_width", %{"width" => 1024})
      Process.sleep(400)

      assert text(view, "bWideTyped") == "Typed: abc"
      assert hidden?(view, "bSideLabel", "bWideNav")
    end

    test "a page that does not read it, and a width it already has, read nothing", %{
      conn: conn,
      u1: u1
    } do
      data_access_on()
      {:ok, view, _html} = live(sign_in(conn, u1), "/")
      # The page load's own reads (its page-loaded run) are done first.
      _ = render(view)
      {_, queries} = queries(fn -> report_width(view, 1024) end)
      assert queries == []

      {:ok, view, _html} =
        sign_in(conn, u1)
        |> put_connect_params(%{"bubble_page_width" => 1024})
        |> live("/wide?compact=yes")

      _ = render(view)
      {_, queries} = queries(fn -> report_width(view, 1024) end)
      assert queries == []

      {_, queries} = queries(fn -> report_width(view, 600) end)
      refute queries == []
      refute hidden?(view, "bSideLabel", "bWideNav")
    end
  end

  describe "an element not migrated" do
    test "a plugin's or a native one not lowered is an empty box, marked only in dev", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/wide")
      html = view |> element(selector("bSideIcon", "bWideNav")) |> render()
      assert html =~ ~s(data-bubble-placeholder="plugin")
      refute html =~ "data-bubble-dev-marker"
      refute html =~ "title="
      assert text(view, "bSideIcon", "bWideNav") == ""
      video = view |> element(selector("bSideVideo", "bWideNav")) |> render()
      assert video =~ ~s(data-bubble-placeholder="unsupported")
      refute video =~ "data-bubble-dev-marker"
      refute video =~ "title="

      Application.put_env(:phx_check, :bubble_dev_markers, true)
      {:ok, view, _html} = live(conn, "/wide")
      html = view |> element(selector("bSideIcon", "bWideNav")) |> render()
      assert html =~ "data-bubble-dev-marker"
      assert html =~ ~s|title="Plugin element (not migrated)"|
      assert text(view, "bSideIcon", "bWideNav") == ""

      # A native element not lowered: the same, titled with its type.
      html = view |> element(selector("bSideVideo", "bWideNav")) |> render()
      assert html =~ ~s(data-bubble-placeholder="unsupported")
      assert html =~ ~s|title="Video (not migrated)"|
      assert text(view, "bSideVideo", "bWideNav") == ""
    end
  end
end
