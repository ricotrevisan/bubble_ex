defmodule BubbleEx.Tasks.Store do
  @moduledoc """
  Reads and writes the task files of an owner's repository (WTF-375):
  `.wtf/plan.json` (`BubbleEx.Plan.decode/1`) and one
  `.wtf/tasks/<task>.json` per task that has state (`BubbleEx.Tasks.State`).
  Nothing else in the repository is read for state or ever written.
  """

  alias BubbleEx.{Error, Plan}
  alias BubbleEx.Tasks.State

  @plan ".wtf/plan.json"
  @tasks ".wtf/tasks"

  @doc "The plan's path, relative to the repository root."
  @spec plan_path() :: String.t()
  def plan_path, do: @plan

  @doc "Reads the plan of the repository at `root`."
  @spec read_plan(Path.t()) :: {:ok, Plan.t()} | {:error, Error.t()}
  def read_plan(root), do: read_plan_file(Path.join(root, @plan))

  @doc "Reads and decodes a plan file."
  @spec read_plan_file(Path.t()) :: {:ok, Plan.t()} | {:error, Error.t()}
  def read_plan_file(path) do
    case File.read(path) do
      {:ok, json} -> Plan.decode(json)
      {:error, reason} -> error("cannot read the plan #{path}: #{:file.format_error(reason)}")
    end
  end

  @doc "Writes `plan` as the repository's `.wtf/plan.json` (canonical JSON)."
  @spec write_plan(Path.t(), Plan.t()) :: :ok
  def write_plan(root, %Plan{} = plan) do
    path = Path.join(root, @plan)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Plan.to_json(plan))
  end

  @doc """
  Reads every task state under `.wtf/tasks/`, keyed by task ID. A file
  whose name is not its task's (`BubbleEx.Tasks.State.filename/1`) is
  `:invalid_input`: states are never guessed.
  """
  @spec read_states(Path.t()) :: {:ok, %{String.t() => State.t()}} | {:error, Error.t()}
  def read_states(root) do
    root
    |> Path.join(@tasks)
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      case read_state(path) do
        {:ok, state} -> {:cont, {:ok, Map.put(acc, state.task, state)}}
        error -> {:halt, error}
      end
    end)
  end

  defp read_state(path) do
    with {:ok, json} <- File.read(path),
         {:ok, state} <- State.decode(json) do
      if State.filename(state.task) == Path.basename(path),
        do: {:ok, state},
        else: error("#{path} holds the state of another task", %{task: state.task})
    else
      {:error, %Error{} = e} -> {:error, %{e | message: "#{path}: #{e.message}"}}
      {:error, reason} -> error("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  @doc "Writes a task state to its file."
  @spec put(Path.t(), State.t()) :: :ok
  def put(root, %State{} = state) do
    path = Path.join(root, State.path(state.task))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, State.to_json(state))
  end

  defp error(message, context \\ %{}), do: {:error, Error.new(:invalid_input, message, context)}
end
