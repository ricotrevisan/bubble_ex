defmodule BubbleEx.Server do
  @moduledoc """
  GenServer for managing asynchronous Trufflehog scans.

  This server allows you to run Trufflehog scans asynchronously and track their progress.
  Each scan is assigned a unique reference that can be used to check status or cancel
  the scan.

  ## Usage

  Start the server in your supervision tree:

      children = [
        {BubbleEx.Server, []}
      ]

  Or start it manually:

      {:ok, pid} = BubbleEx.Server.start_link()

  Then use the public API functions:

      # Start a scan
      payload = %{"_id" => "app_123", "data" => "content"}
      {:ok, ref} = BubbleEx.start_scan_for_secrets(payload)

      # Check status
      {:ok, status} = BubbleEx.scan_status(ref)

      # Cancel a scan
      :ok = BubbleEx.cancel_scan(ref)

  ## Messages

  The calling process will receive the following messages during a scan:

    * `{:scan_started, ref}` - Scan has begun
    * `{:scan_output, ref, output}` - Progress output from Trufflehog
    * `{:scan_completed, ref, results}` - Scan completed successfully
    * `{:scan_error, ref, error}` - Scan failed with error
    * `{:scan_cancelled, ref}` - Scan was cancelled

  """

  use GenServer
  require Logger

  alias BubbleEx.Secrets

  # Client API

  @doc """
  Starts the BubbleEx server.

  ## Options

    * `:name` - The name to register the server under. Defaults to `__MODULE__`.

  ## Examples

      {:ok, pid} = BubbleEx.Server.start_link()
      {:ok, pid} = BubbleEx.Server.start_link(name: MyApp.Scanner)

  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Starts an asynchronous scan for secrets in the given payload.

  ## Parameters

    * `payload` - A map containing the payload to scan. Must include an "_id" field.
    * `opts` - Options for the scan (currently unused)

  ## Returns

    * `{:ok, reference()}` - Success with a unique reference for the scan
    * `{:error, term()}` - Error starting the scan

  ## Examples

      payload = %{"_id" => "app_123", "data" => "content to scan"}
      {:ok, ref} = BubbleEx.Server.start_scan(payload)

  """
  def start_scan(payload, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:start_scan, payload, self()})
  end

  @doc """
  Gets the status of a scan.

  ## Parameters

    * `ref` - The reference returned by `start_scan/2`
    * `opts` - Options (currently unused)

  ## Returns

    * `{:ok, status}` - Where status is `:pending`, `:running`, `:completed`, `:failed`, or `:cancelled`
    * `{:error, :not_found}` - If the scan reference is not found

  ## Examples

      {:ok, :running} = BubbleEx.Server.scan_status(ref)

  """
  def scan_status(ref, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:scan_status, ref})
  end

  @doc """
  Cancels a running scan.

  ## Parameters

    * `ref` - The reference returned by `start_scan/2`
    * `opts` - Options (currently unused)

  ## Returns

    * `:ok` - Scan was cancelled or already completed
    * `{:error, :not_found}` - If the scan reference is not found

  ## Examples

      :ok = BubbleEx.Server.cancel_scan(ref)

  """
  def cancel_scan(ref, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:cancel_scan, ref})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    {:ok, task_sup} = Task.Supervisor.start_link()

    {:ok,
     %{
       scans: %{},
       tasks: %{},
       task_sup: task_sup,
       adapter: Keyword.get(opts, :adapter)
     }}
  end

  @impl true
  def handle_call({:start_scan, payload, client_pid}, _from, state) do
    ref = make_ref()

    scan_info = %{
      ref: ref,
      payload: payload,
      client_pid: client_pid,
      status: :pending,
      start_time: System.system_time(:millisecond),
      task: nil
    }

    # Run the scan in a supervised, unlinked task so a crash is reported via a
    # :DOWN message instead of taking down the server.
    server_pid = self()
    scan_opts = scan_opts(state.adapter, server_pid, ref)

    task =
      Task.Supervisor.async_nolink(state.task_sup, fn ->
        Secrets.scan(payload, scan_opts)
      end)

    scan_info = %{scan_info | task: task, status: :running}

    new_state = %{
      state
      | scans: Map.put(state.scans, ref, scan_info),
        tasks: Map.put(state.tasks, task.ref, ref)
    }

    # Notify client that scan started
    send(client_pid, {:scan_started, ref})

    Logger.info("Started scan with ref #{inspect(ref)} for payload ID: #{payload["_id"]}")

    {:reply, {:ok, ref}, new_state}
  end

  @impl true
  def handle_call({:scan_status, ref}, _from, state) do
    case Map.get(state.scans, ref) do
      nil ->
        {:reply, {:error, :not_found}, state}

      scan_info ->
        status_info = %{
          status: scan_info.status,
          start_time: scan_info.start_time,
          payload_id: scan_info.payload["_id"]
        }

        {:reply, {:ok, status_info}, state}
    end
  end

  @impl true
  def handle_call({:cancel_scan, ref}, _from, state) do
    case Map.get(state.scans, ref) do
      nil ->
        {:reply, {:error, :not_found}, state}

      scan_info when scan_info.status in [:completed, :failed, :cancelled] ->
        {:reply, :ok, state}

      scan_info ->
        # Stop the supervised task if it is still running.
        if scan_info.task do
          Process.demonitor(scan_info.task.ref, [:flush])
          Task.Supervisor.terminate_child(state.task_sup, scan_info.task.pid)
        end

        updated_scan = %{scan_info | status: :cancelled}

        new_state = %{
          state
          | scans: Map.put(state.scans, ref, updated_scan),
            tasks: Map.delete(state.tasks, scan_info.task.ref)
        }

        # Notify client
        send(scan_info.client_pid, {:scan_cancelled, ref})

        Logger.info("Cancelled scan with ref #{inspect(ref)}")

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_info({:scan_output, ref, output}, state) do
    case Map.get(state.scans, ref) do
      nil ->
        Logger.warning("Received scan output for unknown ref #{inspect(ref)}")
        {:noreply, state}

      scan_info ->
        send(scan_info.client_pid, {:scan_output, ref, output})
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    # A supervised scan task finished and returned its result.
    case Map.get(state.tasks, task_ref) do
      nil ->
        {:noreply, state}

      scan_ref ->
        Process.demonitor(task_ref, [:flush])
        scan_info = Map.get(state.scans, scan_ref)
        {updated_scan, new_state} = handle_scan_completion(scan_info, result, state)

        new_state = %{
          new_state
          | scans: Map.put(new_state.scans, scan_ref, updated_scan),
            tasks: Map.delete(new_state.tasks, task_ref)
        }

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:DOWN, task_ref, :process, _pid, reason}, state) do
    # Task died unexpectedly
    case Map.get(state.tasks, task_ref) do
      nil ->
        {:noreply, state}

      scan_ref ->
        case Map.get(state.scans, scan_ref) do
          nil ->
            {:noreply, state}

          scan_info ->
            # Update scan status
            updated_scan = %{scan_info | status: :failed}

            new_state = %{
              state
              | scans: Map.put(state.scans, scan_ref, updated_scan),
                tasks: Map.delete(state.tasks, task_ref)
            }

            # Notify client
            error_msg = "Task died unexpectedly: #{inspect(reason)}"
            send(scan_info.client_pid, {:scan_error, scan_ref, error_msg})

            Logger.error("Scan task died unexpectedly: #{inspect(reason)}")

            {:noreply, new_state}
        end
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private helpers

  defp scan_opts(nil, server_pid, ref), do: [server_pid: server_pid, ref: ref]

  defp scan_opts(adapter, server_pid, ref),
    do: [server_pid: server_pid, ref: ref, adapter: adapter]

  defp handle_scan_completion(scan_info, result, state) do
    case result do
      {:ok, scan_results} ->
        updated_scan = %{scan_info | status: :completed}
        send(scan_info.client_pid, {:scan_completed, scan_info.ref, scan_results})
        Logger.info("Scan completed successfully for ref #{inspect(scan_info.ref)}")
        {updated_scan, state}

      {:error, error} ->
        updated_scan = %{scan_info | status: :failed}
        send(scan_info.client_pid, {:scan_error, scan_info.ref, error})
        Logger.error("Scan failed for ref #{inspect(scan_info.ref)}: #{inspect(error)}")
        {updated_scan, state}
    end
  end
end
