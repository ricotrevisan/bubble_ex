defmodule BubbleEx.Editor.ReadSafetyTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Editor
  alias BubbleEx.Editor.{Client, Plan, Snapshot, Target}
  alias BubbleEx.Error

  test "test and live are explicit readable targets, not mutation targets" do
    for version <- ["test", "live"] do
      assert {:ok, target} = Target.readable("demo", version, "cookie")

      post = fn url, _, _, _ ->
        cond do
          String.ends_with?(url, "/get_versions") ->
            {:ok, %{version => %{"deleted" => false}}}

          String.contains?(url, "/load_multiple_paths/") ->
            {:ok, %{"last_change" => 12, "data" => [%{"data" => "value"}]}}

          true ->
            flunk("read reached mutation transport")
        end
      end

      assert {:ok, snapshot} = Editor.read(target, [["%p3", "key"]], post_fun: post)
      assert Snapshot.fetch(snapshot, ["%p3", "key"]) == {:ok, "value"}

      no_call = fn _, _, _, _ -> flunk("protected target reached network") end

      assert {:error, %Error{context: %{reason: :protected_version}}} =
               Client.write(target, [%{}], post_fun: no_call)

      assert {:error, %Error{context: %{reason: :protected_version}}} =
               Client.create_savepoint(target, "marker", "session", post_fun: no_call)

      assert {:error, %Error{context: %{reason: :protected_version}}} =
               Editor.create_savepoint(target, "marker", post_fun: no_call)

      source = %{
        "appname" => "demo",
        "version" => version,
        "base_last_change" => 12,
        "operations" => [
          %{
            "op" => "set",
            "path" => ["%p3", "key", "%nm"],
            "expected" => "Before",
            "value" => "After"
          }
        ]
      }

      {:ok, plan} = Plan.new(source)

      assert {:error, %Error{context: %{reason: :protected_version}}} =
               Editor.apply(plan, "cookie", post_fun: no_call)

      assert {:error, %Error{context: %{reason: :protected_version}}} =
               Editor.check(plan, "cookie", post_fun: no_call)
    end
  end

  test "read rejects missing or deleted versions without loading paths" do
    {:ok, target} = Target.readable("demo", "test", "cookie")

    for versions <- [%{}, %{"test" => %{"deleted" => true}}] do
      post = fn url, _, _, _ ->
        assert String.ends_with?(url, "/get_versions")
        {:ok, versions}
      end

      assert {:error, %Error{}} = Editor.read(target, [["%p3", "key"]], post_fun: post)
    end
  end

  test "a child deleted between preflight and submission is refused without a write or reconciliation" do
    {:ok, target} = Target.readable("demo", "child", "cookie")

    source = %{
      "appname" => "demo",
      "version" => "child",
      "base_last_change" => 12,
      "operations" => [
        %{
          "op" => "set",
          "path" => ["%p3", "key", "%nm"],
          "expected" => "Before",
          "value" => "After"
        }
      ]
    }

    {:ok, plan} = Plan.new(source)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    post = fn url, _, _, _ ->
      call = Agent.get_and_update(calls, &{&1, &1 + 1})

      case call do
        0 ->
          {:ok, %{"child" => %{"parent_version" => "test"}}}

        1 ->
          {:ok, %{"last_change" => 12, "data" => [%{"data" => "Before"}]}}

        2 ->
          assert String.ends_with?(url, "/get_versions")
          {:ok, %{"child" => %{"deleted" => true, "parent_version" => "test"}}}

        _ ->
          flunk("refused mutation reached write/reconciliation")
      end
    end

    assert {:error, %Error{kind: :invalid_input}} = Editor.apply(plan, "cookie", post_fun: post)
    assert Agent.get(calls, & &1) == 3

    assert {:error, %Error{}} =
             Client.write(target, [%{}],
               post_fun: fn _, _, _, _ -> {:ok, %{"child" => %{"deleted" => true}}} end
             )
  end

  test "direct mutations require a current active child parented by test" do
    {:ok, target} = Target.readable("demo", "child", "cookie")

    for record <- [
          nil,
          %{"deleted" => true, "parent_version" => "test"},
          %{"parent_version" => "live"},
          %{},
          %{"parent_version" => "other"}
        ] do
      post = fn url, _, _, _ ->
        assert String.ends_with?(url, "/get_versions")
        {:ok, if(is_nil(record), do: %{}, else: %{"child" => record})}
      end

      assert {:error, %Error{}} = Client.write(target, [%{}], post_fun: post)

      assert {:error, %Error{}} =
               Client.create_savepoint(target, "marker", "session", post_fun: post)
    end
  end
end
