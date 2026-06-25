defmodule BubbleEx.HTTPTest do
  use ExUnit.Case, async: true

  alias BubbleEx.HTTP
  alias BubbleEx.HTTP.{Error, Response}

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      HTTP.delete_process_options()
    end)

    :ok
  end

  test "wraps successful responses" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.text(conn, "ok")
    end)

    assert {:ok, %Response{status_code: 200, body: "ok", request_url: "https://example.com"}} =
             HTTP.get("https://example.com")
  end

  test "converts transport errors" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, %Error{reason: :timeout}} = HTTP.get("https://example.com")
  end
end
