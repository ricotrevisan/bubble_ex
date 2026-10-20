defmodule PhxCheckWeb.ApiCallsBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # WTF-533: API Connector calls lowered to Req clients, from
  # test/support/target/phoenix/api_calls.json (all data invented), run by
  # scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/api_calls_behavior_test.exs, with a database), with privacy: :omit
  # and :enforced. The API's host (api.example.test) is never reached: every
  # request goes to a Req.Test stub. A backend workflow and two page buttons
  # call it; secrets come only from the application environment
  # (config/runtime.exs), never from a step or the page.
  use PhxCheckWeb.ConnCase, async: false

  # `live/2` waits for the first load (WTF-559, behavior_helpers.exs).
  use PhxCheckWeb.BubbleBehavior

  alias PhxCheck.Workflows.Runtime

  @stub PhxCheck.ApiClients.Example
  @rows [
    %{"id" => "a", "name" => "Alpha", "tags" => ["x", "y"]},
    %{"id" => "b", "name" => "Beta", "tags" => []}
  ]
  @secrets %{
    "BUBBLE_API_EXAMPLE_API_KEY" => "test-key",
    "BUBBLE_API_EXAMPLE_GET_ITEM_X_TENANT" => "test-tenant",
    "BUBBLE_API_EXAMPLE_POST_NOTE_SIGNING" => "test-signing"
  }

  setup do
    clients = Application.get_env(:phx_check, PhxCheck.ApiClients)
    group = Application.get_env(:phx_check, @stub)

    on_exit(fn ->
      restore(PhxCheck.ApiClients, clients)
      restore(@stub, group)
    end)

    # The LiveView process makes the page's calls: the stub is shared.
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Application.put_env(:phx_check, @stub, plug: {Req.Test, @stub})
    secrets(@secrets)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:phx_check, key)
  defp restore(key, value), do: Application.put_env(:phx_check, key, value)

  defp secrets(env), do: Application.put_env(:phx_check, PhxCheck.ApiClients, env: env)

  # Responds with `respond`, telling the test about each request.
  defp stub(respond) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, body})
      respond.(conn)
    end)
  end

  defp requests(acc \\ []) do
    receive do
      {:request, conn, body} -> requests([{conn, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp click(view, id), do: render_click(view, "bubble:click", %{"scope" => "", "element" => id})
  defp label(view), do: view |> element(~s([data-bubble-id="bLabel"])) |> render()

  describe "a backend workflow" do
    test "calls the API on the server with the step's values and the configured secrets" do
      stub(&Req.Test.json(&1, %{"id" => "42", "name" => "Widget", "price" => 9.5}))

      assert {:ok, %{status: :returned, data: data}} = Runtime.run("wFetch", %{"item" => "42"})
      assert data == %{"name" => "Widget", "price" => 9.5}

      assert [{conn, ""}] = requests()
      assert conn.method == "GET"
      assert conn.host == "api.example.test"
      assert conn.request_path == "/v1/items/42"
      assert conn.query_string == "lang=en"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]
      # The private header is the configured value, never the step's.
      assert Plug.Conn.get_req_header(conn, "x-tenant") == ["test-tenant"]
    end

    test "is refused, sending nothing, until its secrets are set" do
      stub(&Req.Test.json(&1, %{}))
      secrets(Map.delete(@secrets, "BUBBLE_API_EXAMPLE_API_KEY"))

      assert {:error, error} = Runtime.run("wFetch", %{"item" => "42"})
      assert inspect(error) =~ "api_env_missing"
      assert inspect(error) =~ "BUBBLE_API_EXAMPLE_API_KEY"
      assert requests() == []

      # An empty value is not set either.
      secrets(Map.put(@secrets, "BUBBLE_API_EXAMPLE_API_KEY", ""))
      assert {:error, _} = Runtime.run("wFetch", %{"item" => "42"})
      assert requests() == []
    end

    test "a response that is not 2xx fails the step, and no secret is in the error" do
      stub(&Plug.Conn.send_resp(&1, 500, "echo test-key"))

      assert {:error, error} = Runtime.run("wFetch", %{"item" => "42"})
      assert inspect(error) =~ "{:status, 500}"
      refute inspect(error) =~ "test-key"
    end

    test "a timeout fails the step; an action is never retried, a GET included" do
      stub(&Req.Test.transport_error(&1, :timeout))

      assert {:error, error} = Runtime.run("wFetch", %{"item" => "42"})
      assert inspect(error) =~ ":timeout"
      assert length(requests()) == 1
    end
  end

  describe "a page workflow" do
    test "calls the API on the server; the result reaches the page, the secrets never", %{
      conn: conn
    } do
      stub(&Req.Test.json(&1, %{"id" => "42", "name" => "Widget", "price" => 9.5}))
      {:ok, view, html} = live(conn, "/")
      assert label(view) =~ "Label: start"

      click(view, "bFetch")
      assert label(view) =~ "Label: item Widget"

      assert [{conn, _}] = requests()
      assert conn.request_path == "/v1/items/42"
      assert conn.query_string == "lang=fr"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]

      for secret <- Map.values(@secrets) do
        refute html =~ secret
        refute render(view) =~ secret
      end
    end

    test "a call with errors in its response continues with them", %{conn: conn} do
      stub(&Plug.Conn.send_resp(&1, 404, "missing"))
      {:ok, view, _html} = live(conn, "/")

      click(view, "bPost")
      assert label(view) =~ "Label: status 404 Not Found"

      assert [{conn, body}] = requests()
      assert conn.method == "POST"
      # The private body parameter is the configured value; the page's
      # value for it is never sent.
      assert Jason.decode!(body) == %{"text" => "hello", "signature" => "test-signing"}
    end

    test "a POST is never retried; a transport error fails the step", %{conn: conn} do
      stub(&Req.Test.transport_error(&1, :timeout))
      {:ok, view, _html} = live(conn, "/")

      click(view, "bPost")
      assert label(view) =~ "Label: start"
      assert length(requests()) == 1
    end

    test "unset secrets refuse the workflow with the page's notice, sending nothing", %{
      conn: conn
    } do
      stub(&Req.Test.json(&1, %{"name" => "Widget"}))
      secrets(%{})
      {:ok, view, _html} = live(conn, "/")

      click(view, "bFetch")
      assert_push_event(view, "bubble:notice", %{text: "This action isn't available yet."})
      assert label(view) =~ "Label: start"
      assert requests() == []
    end
  end

  test "mix bubble.api_env lists the missing variables by name only" do
    secrets(Map.delete(@secrets, "BUBBLE_API_EXAMPLE_POST_NOTE_SIGNING"))

    # The status call's private header is never set in these tests (a data call's
    # missing secret, below).
    assert PhxCheck.ApiClients.missing_env() == [
             "BUBBLE_API_EXAMPLE_GET_STATUS_X_STATUS_TOKEN",
             "BUBBLE_API_EXAMPLE_POST_NOTE_SIGNING"
           ]

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.Bubble.ApiEnv.run([])) == {:shutdown, 1}
      end)

    assert output =~ "BUBBLE_API_EXAMPLE_POST_NOTE_SIGNING"
    refute output =~ "test-"

    secrets(@secrets)
    assert PhxCheck.ApiClients.missing_env() == ["BUBBLE_API_EXAMPLE_GET_STATUS_X_STATUS_TOKEN"]
  end

  # WTF-533, slice 2: calls used as data ("Get data from an external API")
  # are page data, made by the page through the same clients, off its
  # LiveView process (a task), cached for every page for a TTL, within a
  # budget per page and a cap per API, only with the data-access opt-in.
  describe "data calls on a page" do
    @data PhxCheck.ApiClients.Data

    setup do
      workflows = Application.get_env(:phx_check, PhxCheckWeb.BubbleWorkflows)
      markers = Application.get_env(:phx_check, :bubble_dev_markers)
      data = Application.get_env(:phx_check, @data)

      on_exit(fn ->
        restore(PhxCheckWeb.BubbleWorkflows, workflows)
        restore(:bubble_dev_markers, markers)
        restore(@data, data)
        @data.clear()
      end)

      Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
      Application.put_env(:phx_check, :bubble_dev_markers, false)
      @data.clear()
      :ok
    end

    defp data_config(opts), do: Application.put_env(:phx_check, @data, opts)

    defp catalog(items \\ &Req.Test.json(&1, @rows)) do
      stub(fn conn ->
        case conn.request_path do
          "/v1/items" -> items.(conn)
          "/v1/prices/base" -> Req.Test.json(conn, %{"amount" => 3})
          _ -> Req.Test.json(conn, %{"amount" => 99})
        end
      end)
    end

    defp paths(requests), do: Enum.map(requests, fn {conn, _} -> conn.request_path end)

    defp listed(requests, q) do
      Enum.count(requests, fn {conn, _} ->
        conn.request_path == "/v1/items" and
          URI.decode_query(conn.query_string)["q"] == q
      end)
    end

    defp shown(view, id), do: view |> element(~s([data-bubble-id="#{id}"])) |> render()

    # The calls end in tasks: the page shows their values when they do.
    defp eventually(fun, ms \\ 3_000) do
      cond do
        fun.() ->
          :ok

        ms <= 0 ->
          flunk("not shown in time")

        true ->
          Process.sleep(25)
          eventually(fun, ms - 25)
      end
    end

    defp loaded(view), do: eventually(fn -> render(view) =~ "Item: Alpha" end)

    test "a repeating group, a group's first item and another surface share one call", %{
      conn: conn
    } do
      catalog()
      {:ok, view, html} = live(conn, "/catalog")
      loaded(view)
      eventually(fn -> render(view) =~ "Rows: 2" end)
      eventually(fn -> length(Regex.scan(~r/Base: 3/, render(view))) == 2 end)
      page = render(view)

      assert page =~ "Item: Beta"
      # `:first item` over the list, and a list field of it.
      assert shown(view, "bFirstName") =~ "First: Alpha tags 2"

      # The list (the page's two sources and the reusable element's, with
      # the same values): one call; the key from the configuration.
      requests = requests()
      assert listed(requests, "") == 1
      {items, _} = Enum.find(requests, fn {c, _} -> c.query_string == "q=" end)
      assert items.method == "GET"
      assert Plug.Conn.get_req_header(items, "x-api-key") == ["test-key"]

      # A call in a cell with the same values in every cell (and the base
      # of a conditional source) is made once; one whose values read the
      # cell would be made once per cell, and is not loaded
      # (page_data_in_cell).
      assert Enum.count(paths(requests), &(&1 == "/v1/prices/base")) == 1
      refute Enum.any?(paths(requests), &(&1 in ["/v1/prices/a", "/v1/prices/b"]))

      # Nothing of the calls but what the page shows reaches the browser.
      for secret <- Map.values(@secrets), do: refute(html =~ secret or page =~ secret)
    end

    test "an input a parameter reads calls again with its value, and only what reads it", %{
      conn: conn
    } do
      catalog(fn conn ->
        case URI.decode_query(conn.query_string) do
          %{"q" => "gam"} ->
            Req.Test.json(conn, [%{"id" => "g", "name" => "Gamma", "tags" => []}])

          _ ->
            Req.Test.json(conn, @rows)
        end
      end)

      {:ok, view, _html} = live(conn, "/catalog")
      loaded(view)
      Process.sleep(50)
      _ = requests()

      render_change(view, "bubble:change", %{
        "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "gam", "on" => "blur"}
      })

      eventually(fn -> shown(view, "bFirstName") =~ "First: Gamma tags 0" end)
      eventually(fn -> shown(view, "bPick") =~ "Pick: 99" end)
      page = render(view)
      assert page =~ "Item: Gamma"
      refute page =~ "Item: Alpha"

      requests = requests()
      assert listed(requests, "gam") == 1
      # The conditional source's winning state reads the input.
      assert Enum.count(paths(requests), &(&1 == "/v1/prices/gam")) == 1
      # A list parameter (the input split by commas) is sent as a JSON array.
      assert listed(requests, ~s(["gam"])) == 1
      # The calls that do not read the input are not made again.
      refute Enum.any?(paths(requests), &(&1 in ["/v1/prices/base", "/v1/status"]))
      assert listed(requests, "") == 0
    end

    test "a mount, a whole reload and another page within the TTL make no call", %{
      conn: conn
    } do
      catalog()
      {:ok, view, _html} = live(conn, "/catalog")
      loaded(view)
      Process.sleep(50)
      _ = requests()

      # Another page mounting: the shared cache, already in its first render.
      {:ok, other, html} = live(conn, "/catalog")
      assert html =~ "Item: Alpha"

      # A whole read of the page (as a change notification makes).
      render_patch(other, "/catalog?again=1")
      Process.sleep(100)
      assert render(other) =~ "Item: Alpha"
      assert listed(requests(), "") == 0
    end

    test "a slow API blocks neither the mount, the render nor input handling", %{conn: conn} do
      catalog(fn conn ->
        Process.sleep(1_500)
        Req.Test.json(conn, @rows)
      end)

      {micros, {:ok, view, _html}} = :timer.tc(fn -> live(conn, "/catalog") end)
      assert micros < 1_000_000
      refute render(view) =~ "Item: Alpha"

      {micros, _} =
        :timer.tc(fn ->
          render_change(view, "bubble:change", %{
            "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "x"}
          })
        end)

      assert micros < 1_000_000
      eventually(fn -> render(view) =~ "Item: Alpha" end, 6_000)
    end

    test "a keystroke burst past the page's budget keeps what it has and logs once", %{
      conn: conn
    } do
      data_config(budget: {6, 60_000})
      catalog()
      {:ok, view, _html} = live(conn, "/catalog")
      loaded(view)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for i <- 1..10 do
            render_change(view, "bubble:change", %{
              "bubble" => %{
                "scope" => "",
                "element" => "bQuery",
                "value" => "k#{i}",
                "on" => "blur"
              }
            })

            Process.sleep(60)
          end

          Process.sleep(200)
          _ = render(view)
        end)

      # The mount's calls and the burst's together: never past the budget
      # (the status call is refused before sending and still counts).
      assert length(requests()) <= 6
      assert length(Regex.scan(~r/API call budget used/, log)) == 1
      assert render(view) =~ "Item:"
    end

    test "at most :max_in_flight calls of an API are in flight, all pages together", %{
      conn: conn
    } do
      data_config(max_in_flight: 1)
      counter = :counters.new(2, [])

      catalog(fn conn ->
        :counters.add(counter, 1, 1)
        now = :counters.get(counter, 1)
        if now > :counters.get(counter, 2), do: :counters.put(counter, 2, now)
        Process.sleep(80)
        :counters.sub(counter, 1, 1)
        Req.Test.json(conn, @rows)
      end)

      {:ok, view, _html} = live(conn, "/catalog")
      eventually(fn -> render(view) =~ "Item: Alpha" and render(view) =~ "Rows: 2" end, 6_000)
      eventually(fn -> render(view) =~ "Base: 3" end, 6_000)
      assert :counters.get(counter, 2) == 1
    end

    test "a call whose secrets are not set is never sent: empty, marked in dev; others load", %{
      conn: conn
    } do
      catalog()
      {:ok, view, _html} = live(conn, "/catalog")
      loaded(view)
      Process.sleep(100)

      assert shown(view, "bState") =~ "State:"
      refute shown(view, "bStatus") =~ "data-bubble-api-error"
      refute Enum.any?(requests(), fn {c, _} -> c.request_path == "/v1/status" end)

      Application.put_env(:phx_check, :bubble_dev_markers, true)
      {:ok, view, _html} = live(conn, "/catalog")

      eventually(fn ->
        shown(view, "bStatus") =~ "BUBBLE_API_EXAMPLE_GET_STATUS_X_STATUS_TOKEN"
      end)

      status = shown(view, "bStatus")
      assert status =~ "data-bubble-api-error"
      # The variable's name, never a value (and no notice); the other
      # calls of the same read still show.
      refute status =~ "test-"
      assert render(view) =~ "Item: Alpha"
      refute render(view) =~ "isn&#39;t available"
    end

    test "a call that fails shows as empty, without a notice; marked only in dev", %{conn: conn} do
      catalog(&Plug.Conn.send_resp(&1, 500, "echo test-key"))
      {:ok, view, _html} = live(conn, "/catalog")
      eventually(fn -> Enum.any?(paths(requests()), &(&1 == "/v1/items")) end)
      Process.sleep(150)

      refute render(view) =~ "Item:"
      refute shown(view, "bItems") =~ "data-bubble-api-error"

      Application.put_env(:phx_check, :bubble_dev_markers, true)
      {:ok, view, _html} = live(conn, "/catalog")
      eventually(fn -> shown(view, "bItems") =~ "{:status, 500}" end)
      page = render(view)
      refute page =~ "Item:"
      assert shown(view, "bFirstName") =~ "First:"
      refute page =~ "test-key"
      refute page =~ "isn&#39;t available"
    end

    defp page_results(view) do
      {:dictionary, dict} = Process.info(view.pid, :dictionary)

      case List.keyfind(dict, {PhxCheckWeb.BubbleData, :api_state}, 0) do
        {_, state} -> map_size(state.results)
        nil -> 0
      end
    end

    test "a page keeps the results of the calls its latest read asked for, not every value", %{
      conn: conn
    } do
      data_config(budget: {100, 1_000})
      catalog()
      {:ok, view, _html} = live(conn, "/catalog")
      loaded(view)

      for i <- 1..15 do
        render_change(view, "bubble:change", %{
          "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "v#{i}", "on" => "blur"}
        })

        Process.sleep(40)
      end

      Process.sleep(300)
      _ = render(view)
      # The calls the page shows (the list with its value and as a list,
      # the base and the picked price, the status), never one per keystroke.
      assert page_results(view) <= 8
    end

    test "pages mounting together share one call in flight", %{conn: conn} do
      catalog(fn conn ->
        Process.sleep(300)
        Req.Test.json(conn, @rows)
      end)

      # The second mounts while the first's call is in flight: it waits
      # for that one.
      {:ok, a, _html} = live(conn, "/catalog")
      {:ok, b, _html} = live(conn, "/catalog")

      eventually(fn -> render(a) =~ "Item: Alpha" and render(b) =~ "Item: Alpha" end, 5_000)
      assert listed(requests(), "") == 1
    end

    test "a killed call frees its place and the page shows it failed", %{conn: conn} do
      Application.put_env(:phx_check, :bubble_dev_markers, true)
      test = self()

      catalog(fn conn ->
        send(test, {:calling, self()})
        Process.sleep(10_000)
        Req.Test.json(conn, @rows)
      end)

      {:ok, view, _html} = live(conn, "/catalog")
      # The list's two calls (its value, and split as a list).
      assert_receive {:calling, one}, 2_000
      assert_receive {:calling, two}, 2_000
      Process.exit(one, :kill)
      Process.exit(two, :kill)

      eventually(fn -> shown(view, "bItems") =~ ":crashed" end)

      # Their places are free: what is counted in flight is what runs.
      eventually(fn ->
        PhxCheck.ApiClients.Data.in_flight(PhxCheck.ApiClients.Example) ==
          length(Task.Supervisor.children(PhxCheck.ApiClients.Data.Tasks))
      end)

      refute render(view) =~ "Item:"
    end

    test "a stale response is shown for a while only, and a 4xx forgets it", %{conn: conn} do
      data_config(ttl: 50, max_stale: 400)
      catalog()
      {:ok, view, _html} = live(conn, "/catalog")
      loaded(view)

      # Past the TTL the API fails transiently: the stale response stays.
      Process.sleep(80)
      catalog(&Plug.Conn.send_resp(&1, 503, "busy"))
      render_patch(view, "/catalog?a=1")
      Process.sleep(150)
      assert render(view) =~ "Item: Alpha"

      # Past :max_stale it is no longer shown.
      Process.sleep(400)
      render_patch(view, "/catalog?a=2")
      eventually(fn -> not (render(view) =~ "Item: Alpha") end)

      # A 4xx other than 429 forgets a cached response at once.
      PhxCheck.ApiClients.Data.clear()
      data_config(ttl: 50, max_stale: 60_000)
      catalog()
      {:ok, view, _html} = live(conn, "/catalog")
      loaded(view)
      Process.sleep(80)
      catalog(&Plug.Conn.send_resp(&1, 404, "gone"))
      render_patch(view, "/catalog?b=1")
      eventually(fn -> not (render(view) =~ "Item: Alpha") end)

      assert PhxCheck.ApiClients.Data.cached({PhxCheck.ApiClients.Example, :list_items, %{q: ""}}) ==
               :miss
    end

    test "with data access off, a page makes no call, not even on an input change", %{
      conn: conn
    } do
      Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: false)
      catalog()
      {:ok, view, _html} = live(conn, "/catalog")

      render_change(view, "bubble:change", %{
        "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "z", "on" => "blur"}
      })

      Process.sleep(200)
      refute render(view) =~ "Item:"
      assert requests() == []
    end
  end
end
