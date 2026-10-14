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

  import Phoenix.LiveViewTest

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
  # are page data, read by the page's LiveView on the server through the
  # same clients, only with the data-access opt-in.
  describe "data calls on a page" do
    setup do
      workflows = Application.get_env(:phx_check, PhxCheckWeb.BubbleWorkflows)
      markers = Application.get_env(:phx_check, :bubble_dev_markers)

      on_exit(fn ->
        restore(PhxCheckWeb.BubbleWorkflows, workflows)
        restore(:bubble_dev_markers, markers)
      end)

      Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
      Application.put_env(:phx_check, :bubble_dev_markers, false)
      :ok
    end

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
    defp shown(view, id), do: view |> element(~s([data-bubble-id="#{id}"])) |> render()

    test "a repeating group and a group's first item show the call's list, called once", %{
      conn: conn
    } do
      catalog()
      {:ok, view, html} = live(conn, "/catalog")
      page = render(view)

      assert page =~ "Item: Alpha"
      assert page =~ "Item: Beta"
      # `:first item` over the list, and a list field of it.
      assert shown(view, "bFirstName") =~ "First: Alpha tags 2"

      # Both read the same call with the same values: one request per read,
      # with the input's (empty) value, the key from the configuration.
      requests = requests()
      assert Enum.count(paths(requests), &(&1 == "/v1/items")) == 1
      {items, _} = Enum.find(requests, fn {c, _} -> c.request_path == "/v1/items" end)
      assert items.method == "GET"
      assert Plug.Conn.get_req_header(items, "x-api-key") == ["test-key"]

      # A call in a cell with the same values in every cell is made once;
      # one whose values read the cell would be made once per cell, and is
      # not loaded (page_data_in_cell).
      assert Enum.count(paths(requests), &(&1 == "/v1/prices/base")) == 1
      assert length(Regex.scan(~r/Base: 3/, page)) == 2
      refute Enum.any?(paths(requests), &(&1 in ["/v1/prices/a", "/v1/prices/b"]))

      # Nothing of the calls but what the page shows reaches the browser.
      for secret <- Map.values(@secrets), do: refute(html =~ secret or page =~ secret)
    end

    test "an input a parameter reads calls again with its value, and only what reads it", %{
      conn: conn
    } do
      catalog(fn conn ->
        case Plug.Conn.fetch_query_params(conn).query_params do
          %{"q" => "gam"} ->
            Req.Test.json(conn, [%{"id" => "g", "name" => "Gamma", "tags" => []}])

          _ ->
            Req.Test.json(conn, @rows)
        end
      end)

      {:ok, view, _html} = live(conn, "/catalog")
      _ = render(view)
      _ = requests()

      render_change(view, "bubble:change", %{
        "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "gam", "on" => "blur"}
      })

      Process.sleep(200)
      page = render(view)
      assert page =~ "Item: Gamma"
      refute page =~ "Item: Alpha"
      assert shown(view, "bFirstName") =~ "First: Gamma tags 0"

      # One call for the list and the group's first item (the same values);
      # the list's cells are read again (their call is made once). The
      # sources that do not read the input are not read again.
      requests = requests()
      assert Enum.sort(paths(requests)) == ["/v1/items", "/v1/prices/base"]
      {items, _} = Enum.find(requests, fn {c, _} -> c.request_path == "/v1/items" end)
      assert items.query_string == "q=gam"
    end

    test "a call whose secrets are not set is never sent: empty, marked in dev", %{conn: conn} do
      catalog()
      {:ok, view, _html} = live(conn, "/catalog")

      assert shown(view, "bState") =~ "State:"
      refute shown(view, "bStatus") =~ "data-bubble-api-error"
      refute Enum.any?(requests(), fn {c, _} -> c.request_path == "/v1/status" end)

      Application.put_env(:phx_check, :bubble_dev_markers, true)
      {:ok, view, _html} = live(conn, "/catalog")
      status = shown(view, "bStatus")
      assert status =~ "data-bubble-api-error"
      assert status =~ "BUBBLE_API_EXAMPLE_GET_STATUS_X_STATUS_TOKEN"
      # The variable's name, never a value (and no notice).
      refute status =~ "test-"
      refute render(view) =~ "isn&#39;t available"
    end

    test "a call that fails shows as empty, without a notice, marked in dev", %{conn: conn} do
      Application.put_env(:phx_check, :bubble_dev_markers, true)
      catalog(&Plug.Conn.send_resp(&1, 500, "echo test-key"))
      {:ok, view, _html} = live(conn, "/catalog")
      page = render(view)

      refute page =~ "Item:"
      assert shown(view, "bFirstName") =~ "First:"
      refute shown(view, "bFirstName") =~ "Alpha"
      items = shown(view, "bItems")
      assert items =~ "{:status, 500}"
      refute page =~ "test-key"
      refute page =~ "isn&#39;t available"

      # A data GET is retried only on a refused connection, a 429 or a 503.
      assert Enum.count(paths(requests()), &(&1 == "/v1/items")) == 1
    end

    test "with data access off, a page makes no call", %{conn: conn} do
      Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: false)
      catalog()
      {:ok, view, _html} = live(conn, "/catalog")

      refute render(view) =~ "Item:"
      assert requests() == []
    end
  end
end
