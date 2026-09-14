defmodule BubbleEx.EditorTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Editor
  alias BubbleEx.Editor.Plan
  alias BubbleEx.Error

  @path ["%p3", "page", "%el", "text", "%nm"]

  test "applies one property, verifies it fresh, and produces a guarded inverse" do
    {:ok, plan} = Plan.new(plan([op(@path, "Before", "After")]))

    {post_fun, calls} =
      queued([
        ok_versions(),
        read(100, ["Before"]),
        {:ok, %{"last_change" => "101", "last_change_date" => "1", "id_counter" => "20"}},
        read(101, ["After"])
      ])

    assert {:ok, receipt} =
             Editor.apply(plan, "session=secret", post_fun: post_fun, session_id: "session-id")

    assert receipt["status"] == "applied"
    assert receipt["verified_last_change"] == 101

    assert receipt["inverse_plan"]["operations"] == [
             %{"op" => "set", "path" => @path, "expected" => "After", "value" => "Before"}
           ]

    requests = Agent.get(calls, & &1.calls) |> Enum.reverse()
    writes = Enum.filter(requests, &String.ends_with?(&1.url, "/appeditor/write"))
    assert [write] = writes
    assert get_in(write.body, ["changes", Access.at(0), "path_array"]) == @path
    assert get_in(write.body, ["changes", Access.at(0), "body"]) == "After"
    refute inspect(Enum.map(requests, &Map.drop(&1, [:opts]))) =~ "session=secret"
  end

  test "rejects a stale revision before sending any write" do
    {:ok, plan} = Plan.new(plan([op(@path, "Before", "After")]))
    {post_fun, calls} = queued([ok_versions(), read(101, ["Before"])])

    assert {:error, %Error{context: %{reason: :stale_revision}}} =
             Editor.apply(plan, "session=secret", post_fun: post_fun)

    requests = Agent.get(calls, & &1.calls)
    refute Enum.any?(requests, &String.ends_with?(&1.url, "/appeditor/write"))
  end

  test "reconciles timeout after commit without retrying" do
    {:ok, plan} = Plan.new(plan([op(@path, "Before", "After")]))

    {post_fun, calls} =
      queued([
        ok_versions(),
        read(100, ["Before"]),
        {:error, Error.new(:request_failed, "timeout")},
        read(101, ["After"])
      ])

    assert {:ok, %{"status" => "reconciled_applied"}} =
             Editor.apply(plan, "session=secret", post_fun: post_fun)

    assert Agent.get(calls, fn state ->
             Enum.count(state.calls, &String.ends_with?(&1.url, "/appeditor/write"))
           end) == 1
  end

  test "reconciles timeout before commit as not applied" do
    {:ok, plan} = Plan.new(plan([op(@path, "Before", "After")]))

    {post_fun, _calls} =
      queued([
        ok_versions(),
        read(100, ["Before"]),
        {:error, Error.new(:request_failed, "timeout")},
        read(100, ["Before"])
      ])

    assert {:error,
            %Error{kind: :request_failed, context: %{reason: :not_applied, safe_to_replan: true}}} =
             Editor.apply(plan, "session=secret", post_fun: post_fun)
  end

  test "reports a partial outcome as ambiguous" do
    second = ["%p3", "page", "%el", "button", "%nm"]
    {:ok, plan} = Plan.new(plan([op(@path, "Before", "After"), op(second, "Old", "New")]))

    {post_fun, _calls} =
      queued([
        ok_versions(),
        read(100, ["Before", "Old"]),
        {:error, Error.new(:request_failed, "connection closed")},
        read(101, ["After", "Old"])
      ])

    assert {:error,
            %Error{context: %{reason: :ambiguous_write, operation_states: [:intended, :prior]}}} =
             Editor.apply(plan, "session=secret", post_fun: post_fun)
  end

  test "creates a native savepoint on the resolved child and verifies a new revision" do
    {:ok, target} = BubbleEx.Editor.Target.new("tiptap-plugin", "43jvs", "session=secret")

    {post_fun, calls} =
      queued([
        ok_versions(),
        read(100, [nil]),
        {:ok, %{"earliest_change_date" => 1, "annotations" => []}},
        {:ok, %{"last_change" => "101"}},
        read(101, [nil]),
        {:ok,
         %{
           "earliest_change_date" => 1,
           "annotations" => [%{"message" => "acceptance point", "timestamp" => 2}]
         }}
      ])

    assert {:ok, result} =
             Editor.create_savepoint(target, "acceptance point",
               post_fun: post_fun,
               session_id: "session-id"
             )

    assert result.status == "created"
    assert result.before_last_change == 100
    assert result.verified_last_change == 101

    requests = Agent.get(calls, & &1.calls)
    assert Enum.count(requests, &String.ends_with?(&1.url, "/appeditor/commit_test_version")) == 1
  end

  test "lists savepoints without exposing editor user details" do
    {:ok, target} = BubbleEx.Editor.Target.new("tiptap-plugin", "43jvs", "session=secret")

    {post_fun, _calls} =
      queued([
        ok_versions(),
        {:ok,
         %{
           "earliest_change_date" => 1,
           "annotations" => [
             %{
               "message" => "commit:acceptance point",
               "timestamp" => 2,
               "user" => %{"email" => "private@example.invalid"}
             }
           ]
         }}
      ])

    assert {:ok,
            %{
              "earliest_change_date" => 1,
              "annotations" => [
                %{"message" => "commit:acceptance point", "timestamp" => 2}
              ]
            }} = Editor.savepoints(target, post_fun: post_fun)
  end

  test "reconciles a non-object savepoint acknowledgement from new history without retrying" do
    {:ok, target} = BubbleEx.Editor.Target.new("tiptap-plugin", "43jvs", "session=secret")

    {post_fun, calls} =
      queued([
        ok_versions(),
        read(100, [nil]),
        {:ok, %{"earliest_change_date" => 1, "annotations" => []}},
        {:error, Error.new(:parse_failed, "non-object acknowledgement")},
        read(101, [nil]),
        {:ok,
         %{
           "earliest_change_date" => 1,
           "annotations" => [%{"message" => "commit:acceptance point", "timestamp" => 2}]
         }}
      ])

    assert {:ok, %{status: "reconciled_created", verified_last_change: 101}} =
             Editor.create_savepoint(target, "acceptance point", post_fun: post_fun)

    assert Agent.get(calls, fn state ->
             Enum.count(state.calls, &String.ends_with?(&1.url, "/appeditor/commit_test_version"))
           end) == 1
  end

  defp plan(operations) do
    %{
      "appname" => "tiptap-plugin",
      "version" => "43jvs",
      "base_last_change" => 100,
      "operations" => operations
    }
  end

  defp op(path, expected, value),
    do: %{"op" => "set", "path" => path, "expected" => expected, "value" => value}

  defp ok_versions do
    {:ok,
     %{
       "test" => %{"display" => "Development"},
       "43jvs" => %{
         "display" => "wtf-271-editor-diff",
         "parent_version" => "test",
         "deleted" => false
       }
     }}
  end

  defp read(last_change, values) do
    {:ok, %{"last_change" => last_change, "data" => Enum.map(values, &%{"data" => &1})}}
  end

  defp queued(responses) do
    {:ok, agent} = Agent.start_link(fn -> %{responses: responses, calls: []} end)

    post_fun = fn url, encoded, headers, opts ->
      body = Jason.decode!(encoded)

      Agent.get_and_update(agent, fn %{responses: [response | rest]} = state ->
        call = %{url: url, body: body, header_names: Enum.map(headers, &elem(&1, 0)), opts: opts}
        {response, %{state | responses: rest, calls: [call | state.calls]}}
      end)
    end

    {post_fun, agent}
  end
end
