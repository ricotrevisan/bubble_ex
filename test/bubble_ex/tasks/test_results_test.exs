defmodule BubbleEx.Tasks.TestResultsTest do
  # Sets WTF_TASK_TEST_RESULTS in the VM's environment.
  use ExUnit.Case, async: false

  alias BubbleEx.Tasks.TestResults

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "results.etf")
    System.put_env(TestResults.env(), path)
    on_exit(fn -> System.delete_env(TestResults.env()) end)
    %{path: path}
  end

  test "records each test's bubble tag and outcome when the suite finishes", %{path: path} do
    assert TestResults.read(path) == :error
    assert TestResults.preload() == :ok
    assert TestResults.read(path) == :loaded

    # A VM the tests start inherits the flags: the marker is not rewritten.
    File.write!(path, "kept")
    assert TestResults.preload() == :ok
    assert File.read!(path) == "kept"
    File.rm!(path)

    {:ok, pid} = GenServer.start_link(TestResults, [])

    for {tags, state} <- [
          {%{bubble: "api_call:g/a"}, nil},
          {%{bubble: "api_call:g/b"}, {:failed, []}},
          {%{bubble: "api_call:g/c"}, {:skipped, "due to skip tag"}},
          {%{bubble: "api_call:g/d"}, {:excluded, "due to bubble filter"}},
          {%{bubble: "api_call:g/e"}, {:invalid, SomeModule}},
          {%{}, nil}
        ],
        do: GenServer.cast(pid, {:test_finished, %{tags: tags, state: state}})

    GenServer.cast(pid, {:suite_finished, %{run: 1}})
    GenServer.stop(pid)

    assert TestResults.read(path) ==
             {:ok,
              [
                {"api_call:g/a", :passed},
                {"api_call:g/b", :failed},
                {"api_call:g/c", :skipped},
                {"api_call:g/d", :excluded},
                {"api_call:g/e", :invalid},
                {nil, :passed}
              ]}
  end

  test "refuses what is not a results file", %{path: path} do
    File.write!(path, "not a term")
    assert TestResults.read(path) == :error
    File.write!(path, :erlang.term_to_binary({:wtf_task_test_results, 1, [{:x, :passed}]}))
    assert TestResults.read(path) == :error
    File.write!(path, :erlang.term_to_binary({:wtf_task_test_results, 1, [{"s", :won}]}))
    assert TestResults.read(path) == :error
  end

  test "erl_flags/1 loads the module at boot; write_beam/1 writes it", %{tmp_dir: dir} do
    ebin = Path.join(dir, "ebin")

    assert TestResults.erl_flags(ebin) ==
             "-pa #{ebin} -s Elixir.BubbleEx.Tasks.TestResults preload"

    assert TestResults.erl_flags("/a b/ebin") == nil
    assert TestResults.write_beam(ebin) == :ok
    assert File.exists?(Path.join(ebin, "Elixir.BubbleEx.Tasks.TestResults.beam"))
  end
end
