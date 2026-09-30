defmodule BubbleEx.Tasks.TestResults do
  @moduledoc """
  An ExUnit formatter that records, per test, its `bubble` tag and how it
  ended, so one `mix test` run of several subjects' tagged tests can be
  attributed per subject (WTF-449, `BubbleEx.Target.Phoenix.Checks`).

  It runs inside the owner's test VM, not in BubbleEx: its object code is
  written to a scratch directory and loaded at boot (`erl_flags/1`), before
  Mix prunes the code path. So it uses nothing but Elixir and Erlang.
  The file named by `WTF_TASK_TEST_RESULTS` tells how far the run got
  (`read/1`):

    * loaded: the VM booted with the formatter (written at boot, unless
      the file exists)
    * the results: when the suite finishes, `[{subject | nil, outcome}]`,
      `outcome` being `:passed`, `:failed`, `:invalid`, `:skipped` or
      `:excluded`

  No file means the formatter never loaded (e.g. an Erlang/OTP release
  older than the one that compiled it): the caller falls back to one run
  per subject.

  The file is written by code running next to the owner's tests, so it is
  as advisory as the rest (see "Threat model" in `BubbleEx.Tasks`).
  """

  use GenServer

  @env "WTF_TASK_TEST_RESULTS"
  @env_charlist String.to_charlist(@env)

  @doc "The environment variable naming the results file."
  def env, do: @env

  @doc false
  # Called by `-s` at boot, before Elixir starts: loading the module is
  # the point; the marker says it happened. Erlang only. A VM the tests
  # start inherits the flags: the marker is written only once.
  def preload do
    with path when is_list(path) <- :os.getenv(@env_charlist),
         {:ok, file} <- :file.open(path, [:write, :exclusive, :binary]) do
      :ok = :file.write(file, :erlang.term_to_binary({:wtf_task_test_results, 1, :loaded}))
      :file.close(file)
    end

    :ok
  end

  @doc """
  The `ERL_AFLAGS` fragment that loads this module from `ebin` at boot:
  `-pa <ebin> -s <module> preload`. `nil` when `ebin` contains whitespace
  (the flags are split on it).
  """
  @spec erl_flags(Path.t()) :: String.t() | nil
  def erl_flags(ebin) do
    if String.match?(ebin, ~r/\s/),
      do: nil,
      else: "-pa #{ebin} -s #{Atom.to_string(__MODULE__)} preload"
  end

  @doc """
  Writes this module's object code into `ebin`. `:error` when it is not
  available (e.g. loaded from memory).
  """
  @spec write_beam(Path.t()) :: :ok | :error
  def write_beam(ebin) do
    with {mod, binary, _file} <- :code.get_object_code(__MODULE__),
         :ok <- File.mkdir_p(ebin),
         :ok <- File.write(Path.join(ebin, Atom.to_string(mod) <> ".beam"), binary) do
      :ok
    else
      _ -> :error
    end
  end

  @doc """
  Reads a results file: `{:ok, [{subject | nil, outcome}]}` when the suite
  finished, `:loaded` when the formatter loaded but the suite never
  finished (the run failed before or while running the tests), `:error`
  when there is no (valid) file.
  """
  @spec read(Path.t()) :: {:ok, [{String.t() | nil, atom()}]} | :loaded | :error
  def read(path) do
    with {:ok, bytes} <- File.read(path),
         {:wtf_task_test_results, 1, tests} <- decode(bytes) do
      cond do
        tests == :loaded -> :loaded
        is_list(tests) and Enum.all?(tests, &entry?/1) -> {:ok, tests}
        true -> :error
      end
    else
      _ -> :error
    end
  end

  defp decode(bytes) do
    :erlang.binary_to_term(bytes, [:safe])
  rescue
    ArgumentError -> :error
  end

  defp entry?({subject, outcome}),
    do:
      (is_binary(subject) or is_nil(subject)) and
        outcome in [:passed, :failed, :invalid, :skipped, :excluded]

  defp entry?(_), do: false

  # --- the formatter ---------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{path: System.get_env(@env), tests: []}}

  @impl true
  def handle_cast({:test_finished, %{tags: tags, state: state}}, s) do
    subject = if is_binary(tags[:bubble]), do: tags[:bubble]
    {:noreply, %{s | tests: [{subject, outcome(state)} | s.tests]}}
  end

  def handle_cast({:suite_finished, _times}, %{path: path} = s) when is_binary(path) do
    term = {:wtf_task_test_results, 1, Enum.reverse(s.tests)}
    File.write!(path, :erlang.term_to_binary(term))
    {:noreply, s}
  end

  def handle_cast(_event, s), do: {:noreply, s}

  defp outcome(nil), do: :passed
  defp outcome({:failed, _}), do: :failed
  defp outcome({:invalid, _}), do: :invalid
  defp outcome({:skipped, _}), do: :skipped
  defp outcome({:excluded, _}), do: :excluded
  defp outcome(_), do: :invalid
end
