defmodule BubbleEx.TelemetryHygieneTest do
  use ExUnit.Case, async: false

  setup do
    handler = {__MODULE__, make_ref()}

    events =
      for suffix <- [[:demo], [:apps, :fetch_app]],
          phase <- [:start, :stop, :exception],
          do: [:bubble_ex | suffix] ++ [phase]

    :telemetry.attach_many(
      handler,
      events,
      fn event, _, metadata, pid -> send(pid, {event, metadata}) end,
      self()
    )

    BubbleEx.HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    Req.Test.stub(__MODULE__, fn _ -> flunk("credentials reached HTTP") end)

    on_exit(fn ->
      :telemetry.detach(handler)
      BubbleEx.HTTP.delete_process_options()
    end)

    :ok
  end

  test "direct app inputs and rejected validation errors never emit credentials" do
    for input <- [
          "https://user:synthetic-secret@example.com/path?token=synthetic-secret#synthetic-secret",
          "https://user%3Asynthetic-secret@example.com",
          "bad synthetic-secret"
        ] do
      assert {:error, _} = BubbleEx.Apps.fetch_app(input)
      assert_receive {[:bubble_ex, :apps, :fetch_app, :start], start}
      assert_receive {[:bubble_ex, :apps, :fetch_app, :stop], stop}
      refute inspect({start, stop}) =~ "synthetic-secret"
    end
  end

  test "charlist and iodata secrets are redacted in start stop and exception metadata" do
    raw = %{
      reason: ~c"token=synthetic-secret",
      context: [~c"synthetic-secret", [?s, ?e, [?c, ?r], "et"]]
    }

    assert :ok = BubbleEx.Telemetry.span([:demo], raw, fn -> {:ok, raw} end)
    assert_receive {[:bubble_ex, :demo, :start], start}
    assert_receive {[:bubble_ex, :demo, :stop], stop}
    refute inspect({start, stop}) =~ "synthetic-secret"
    refute start.reason == raw.reason
    assert catch_throw(BubbleEx.Telemetry.span([:demo], %{}, fn -> throw(raw) end)) == raw
    assert_receive {[:bubble_ex, :demo, :exception], exception}
    refute inspect(exception) =~ "synthetic-secret"
    refute exception.reason.reason == raw.reason
  end

  test "tuples at the depth boundary preserve start, stop and exception semantics" do
    for depth <- 0..10 do
      nested =
        Enum.reduce(1..depth//1, {:error, "synthetic-secret"}, fn _, acc -> %{nested: acc} end)

      assert :result =
               BubbleEx.Telemetry.span([:demo], %{nested: nested}, fn ->
                 {:result, %{nested: nested}}
               end)

      assert_receive {[:bubble_ex, :demo, :start], start}
      assert_receive {[:bubble_ex, :demo, :stop], stop}
      refute inspect({start, stop}) =~ "synthetic-secret"
      assert catch_throw(BubbleEx.Telemetry.span([:demo], %{}, fn -> throw(nested) end)) == nested
      assert_receive {[:bubble_ex, :demo, :start], _}
      assert_receive {[:bubble_ex, :demo, :exception], exception}
      refute inspect(exception) =~ "synthetic-secret"
    end
  end

  test "deep structs and large metadata are bounded without failing emission" do
    assert BubbleEx.SafeMetadata.sanitize(["synthetic-secret" | :tail]) == [
             "[redacted]",
             "[redacted]"
           ]

    assert %{__struct__: :unknown_struct, message: "[redacted]"} =
             BubbleEx.SafeMetadata.sanitize(%{
               __struct__: :unknown_struct,
               message: "synthetic-secret"
             })

    error =
      Enum.reduce(1..20, %RuntimeError{message: "synthetic-secret"}, fn _, acc ->
        %BubbleEx.Error{
          kind: :request_failed,
          message: "synthetic-secret",
          context: %{error: acc}
        }
      end)

    sanitized =
      BubbleEx.SafeMetadata.sanitize(%{
        error: error,
        values: List.duplicate("synthetic-secret", 1000)
      })

    refute inspect(sanitized) =~ "synthetic-secret"
    assert length(sanitized.values) == 50
    assert :ok = BubbleEx.Telemetry.span([:demo], %{}, fn -> {:ok, sanitized} end)
    assert_receive {[:bubble_ex, :demo, :start], %{telemetry_span_context: ref}}
    assert_receive {[:bubble_ex, :demo, :stop], %{telemetry_span_context: ^ref}}
  end

  test "nested stop errors and thrown exception metadata are safe without changing results" do
    raw = %{
      context: %{
        url:
          "https://user:synthetic-secret@example.com/a?token=synthetic-secret#synthetic-secret",
        body: "synthetic-secret"
      }
    }

    assert :ok =
             BubbleEx.Telemetry.span(
               [:demo],
               %{input: "https://example.com/a?token=synthetic-secret"},
               fn -> {:ok, %{error: raw}} end
             )

    assert_receive {[:bubble_ex, :demo, :start], start}
    assert_receive {[:bubble_ex, :demo, :stop], stop}
    refute inspect({start, stop}) =~ "synthetic-secret"
    assert catch_throw(BubbleEx.Telemetry.span([:demo], %{}, fn -> throw(raw) end)) == raw
    assert_receive {[:bubble_ex, :demo, :exception], exception}
    refute inspect(exception) =~ "synthetic-secret"
    assert exception.kind == :throw
  end
end
