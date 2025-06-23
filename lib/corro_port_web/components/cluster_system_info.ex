defmodule CorroPort.ClusterSystemInfo do
  @moduledoc """
  Manages cluster system information including database info and basic cluster stats.

  Provides a clean interface for cluster-specific data that supplements the core
  membership and propagation tracking.
  """

  use GenServer
  require Logger

  alias CorroPort.{ConnectionManager, MessagesAPI}

  @refresh_interval 60_000  # 1 minute for system info

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get cluster system information.

  Returns:
  %{
    cluster_info: %{...} | nil,
    database_info: %{...} | nil,
    latest_messages: [...] | [],
    cache_status: %{last_updated: dt, error: nil | reason}
  }
  """
  def get_system_data do
    GenServer.call(__MODULE__, :get_system_data)
  end

  @doc """
  Force refresh of cluster system data.
  """
  def refresh_cache do
    GenServer.cast(__MODULE__, :refresh_cache)
  end

  @doc """
  Subscribe to system info updates.
  Receives: {:cluster_system_updated, system_data}
  """
  def subscribe do
    Phoenix.PubSub.subscribe(CorroPort.PubSub, "cluster_system_info")
  end

  @doc """
  Get cache status for debugging.
  """
  def get_cache_status do
    GenServer.call(__MODULE__, :get_cache_status)
  end

  # GenServer Implementation

  def init(opts) do
    refresh_interval = Keyword.get(opts, :refresh_interval, @refresh_interval)

    Logger.info("ClusterSystemInfo starting with #{refresh_interval}ms refresh interval")

    state = %{
      cluster_info: nil,
      database_info: nil,
      latest_messages: [],
      last_updated: nil,
      last_error: nil,
      refresh_interval: refresh_interval,
      fetch_task: nil
    }

    # Schedule initial fetch
    Process.send_after(self(), :fetch_system_data, 1000)

    {:ok, state}
  end

  def handle_call(:get_system_data, _from, state) do
    system_data = build_system_data(state)
    {:reply, system_data, state}
  end

  def handle_call(:get_cache_status, _from, state) do
    status = %{
      last_updated: state.last_updated,
      error: state.last_error,
      has_cluster_info: !is_nil(state.cluster_info),
      has_database_info: !is_nil(state.database_info),
      message_count: length(state.latest_messages)
    }

    {:reply, status, state}
  end

  def handle_cast(:refresh_cache, state) do
    Logger.info("ClusterSystemInfo: Manual cache refresh requested")

    # Cancel any existing task
    state = cancel_existing_task(state)

    # Start new fetch
    new_state = start_fetch_task(state)

    {:noreply, new_state}
  end

  def handle_info(:fetch_system_data, state) do
    # Periodic fetch
    state =
      state
      |> cancel_existing_task()
      |> start_fetch_task()

    # Schedule next periodic fetch
    Process.send_after(self(), :fetch_system_data, state.refresh_interval)

    {:noreply, state}
  end

  def handle_info({task_ref, result}, %{fetch_task: {task_ref, _}} = state) do
    Logger.debug("ClusterSystemInfo: Fetch task completed")

    new_state = process_fetch_result(result, state)

    # Broadcast update
    broadcast_update(new_state)

    {:noreply, new_state}
  end

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, %{fetch_task: {task_ref, _}} = state) do
    Logger.debug("ClusterSystemInfo: Task process ended: #{inspect(reason)}")

    new_state = %{state | fetch_task: nil}
    {:noreply, new_state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Ignore DOWN messages from other processes
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("ClusterSystemInfo: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  def terminate(reason, _state) do
    Logger.info("ClusterSystemInfo shutting down: #{inspect(reason)}")
    :ok
  end

  # Private Functions

  defp start_fetch_task(state) do
    Logger.debug("ClusterSystemInfo: Starting fetch task")

    task =
      Task.async(fn ->
        fetch_all_system_data()
      end)

    task_ref = task.ref

    %{state | fetch_task: {task_ref, task}}
  end

  defp cancel_existing_task(%{fetch_task: nil} = state), do: state

  defp cancel_existing_task(%{fetch_task: {_task_ref, task}} = state) do
    Logger.debug("ClusterSystemInfo: Cancelling existing fetch task")
    Task.shutdown(task, :brutal_kill)
    %{state | fetch_task: nil}
  end

  defp fetch_all_system_data do
    # Fetch all cluster system data concurrently
    cluster_task = Task.async(fn ->
      conn = ConnectionManager.get_connection()
      CorroClient.get_cluster_info(conn)
    end)
    database_task = Task.async(fn ->
      conn = ConnectionManager.get_connection()
      CorroClient.get_database_info(conn)
    end)
    messages_task = Task.async(fn -> MessagesAPI.get_latest_node_messages() end)

    # Wait for all results with timeout
    cluster_result = Task.await(cluster_task, 10_000)
    database_result = Task.await(database_task, 5_000)
    messages_result = Task.await(messages_task, 5_000)

    %{
      cluster_info: cluster_result,
      database_info: database_result,
      latest_messages: messages_result
    }
  rescue
    e ->
      Logger.warning("ClusterSystemInfo: Exception during fetch: #{inspect(e)}")
      {:error, {:fetch_exception, e}}
  end

  defp process_fetch_result({:error, reason}, state) do
    Logger.warning("ClusterSystemInfo: Fetch failed: #{inspect(reason)}")

    %{
      state |
      last_error: reason,
      last_updated: DateTime.utc_now(),
      fetch_task: nil
    }
  end

  defp process_fetch_result(fetch_results, state) when is_map(fetch_results) do
    # Process individual results
    cluster_info = case fetch_results.cluster_info do
      {:ok, info} -> info
      {:error, _} -> nil
    end

    database_info = case fetch_results.database_info do
      {:ok, info} when is_map(info) -> info
      _ -> nil
    end

    latest_messages = case fetch_results.latest_messages do
      {:ok, messages} when is_list(messages) -> messages
      _ -> []
    end

    # Determine if there were any critical errors
    error = determine_fetch_error(fetch_results)

    %{
      state |
      cluster_info: cluster_info,
      database_info: database_info,
      latest_messages: latest_messages,
      last_error: error,
      last_updated: DateTime.utc_now(),
      fetch_task: nil
    }
  end

  defp determine_fetch_error(fetch_results) do
    # Only treat complete API failure as an error
    case fetch_results.cluster_info do
      {:error, reason} ->
        # If we can't get basic cluster info, that's a problem
        {:cluster_api_failed, reason}

      {:ok, _} ->
        # If cluster info works, other failures are less critical
        nil
    end
  end

  defp build_system_data(state) do
    %{
      cluster_info: state.cluster_info,
      database_info: state.database_info,
      latest_messages: state.latest_messages,
      cache_status: %{
        last_updated: state.last_updated,
        error: state.last_error
      }
    }
  end

  defp broadcast_update(state) do
    system_data = build_system_data(state)
    Phoenix.PubSub.broadcast(CorroPort.PubSub, "cluster_system_info", {:cluster_system_updated, system_data})

    Logger.debug(
      "ClusterSystemInfo: Broadcasted update - cluster_info: #{!is_nil(state.cluster_info)}, " <>
      "database_info: #{!is_nil(state.database_info)}, messages: #{length(state.latest_messages)}"
    )
  end
end
