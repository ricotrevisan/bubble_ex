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
    assert PhxCheck.ApiClients.missing_env() == ["BUBBLE_API_EXAMPLE_POST_NOTE_SIGNING"]

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.Bubble.ApiEnv.run([])) == {:shutdown, 1}
      end)

    assert output =~ "BUBBLE_API_EXAMPLE_POST_NOTE_SIGNING"
    refute output =~ "test-"

    secrets(@secrets)
    assert PhxCheck.ApiClients.missing_env() == []
  end
end
