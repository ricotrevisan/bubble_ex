defmodule BubbleEx.ContributorsTest do
  use ExUnit.Case, async: false

  alias BubbleEx.Contributors
  alias BubbleEx.HTTP
  alias Plug.Conn

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> HTTP.delete_process_options() end)
    :ok
  end

  defp stub_html(html) do
    Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 200, html) end)
  end

  test "extracts the contributor name from the page title" do
    stub_html("<html><head><title>Jane Doe Contributor Profile | Bubble</title></head></html>")

    assert {:ok, %{bubble_id: "jane", name: "Jane Doe"}} = Contributors.fetch_contributor("jane")
  end

  test "falls back to the bubble id for a private profile" do
    stub_html("<html><head><title>Bubble | No Code</title></head></html>")

    assert {:ok, %{bubble_id: "secret", name: "secret"}} =
             Contributors.fetch_contributor("secret")
  end

  test "returns a parse error when the page has no title" do
    stub_html("<html><body>nothing here</body></html>")

    assert {:error, %BubbleEx.Error{kind: :parse_failed}} =
             Contributors.fetch_contributor("notitle")
  end

  test "returns the upstream HTTP error instead of parsing its body" do
    Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 429, "error code: 1015\n") end)

    assert {:error,
            %BubbleEx.Error{
              kind: :http_error,
              message: "HTTP 429",
              context: %{
                status: 429,
                body: "error code: 1015\n",
                url: "https://bubble.io/contributor/rate-limited"
              }
            }} = Contributors.fetch_contributor("rate-limited")
  end

  test "returns transport failures as request errors" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error,
            %BubbleEx.Error{
              kind: :request_failed,
              context: %{
                reason: :timeout,
                url: "https://bubble.io/contributor/timeout"
              }
            }} = Contributors.fetch_contributor("timeout")
  end
end
