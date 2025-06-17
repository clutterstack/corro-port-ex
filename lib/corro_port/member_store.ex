defmodule CorroPort.ClusterMemberStore do
  @moduledoc """
  Centralized store for cluster member data fetched via CLI.

  Manages periodic fetching of cluster members via CLI and broadcasts
  updates to subscribed LiveViews. Provides both automatic periodic
  updates and manual refresh capability.
  """

  use GenServer
  require Logger

  alias CorroPort.{CorrosionCLI, CorrosionParser}

  # Default refresh interval: 5 minutes
  @default_refresh_interval 300_000
  @pubsub_topic "cluster_members"
  @cli_timeout 15_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the current cluster member data.
  Returns cached data immediately if available.
  """
  def get_members do
    try do
      GenServer.call(__MODULE__, :get_members, 1000)
    catch
      :exit, _ ->
        Logger.warning("ClusterMemberStore: Call timeout, returning empty state")
        empty_state()
    end
  end

  @doc """
  Trigger a manual refresh of cluster member data.
  Returns immediately, broadcasts result when complete.
  """
  def refresh_members do
    GenServer.cast(__MODULE__, :refresh_members)
  end

  @doc """
  Get the PubSub topic for subscribing to member updates.
  """
  def pubsub_topic, do: @pubsub_topic

  @doc """
  Subscribe to cluster member updates.
  Subscribers will receive: {:cluster_members_updated, member_data}
  """
  def subscribe do
    Phoenix.PubSub.subscribe(CorroPort.PubSub, @pubsub_topic)
  end

  # GenServer Implementation

  def init(opts) do
    refresh_interval = Keyword.get(opts, :refresh_interval, @default_refresh_interval)

    Logger.info("ClusterMemberStore starting with #{refresh_interval}ms refresh interval")

    # Start with empty state
    state = %{
      members: [],
      last_updated: nil,
      last_error: nil,
      refresh_interval: refresh_interval,
      fetch_task: nil,
      status: :initializing
    }

    # Schedule initial fetch
    Process.send_after(self(), :fetch_members, 1000)

    {:ok, state}
  end

  def handle_call(:get_members, _from, state) do
    member_data = build_member_data(state)
    {:reply, member_data, state}
  end

  def handle_cast(:refresh_members, state) do
    Logger.info("ClusterMemberStore: Manual refresh requested")

    # Cancel any existing task
    state = cancel_existing_task(state)

    # Start new fetch
    new_state = start_fetch_task(state)

    {:noreply, new_state}
  end

  def handle_info(:fetch_members, state) do
    # Periodic fetch
    state =
      state
      |> cancel_existing_task()
      |> start_fetch_task()

    # Schedule next periodic fetch
    Process.send_after(self(), :fetch_members, state.refresh_interval)

    {:noreply, state}
  end

  def handle_info({task_ref, {:ok, raw_output}}, %{fetch_task: {task_ref, _}} = state) do
    Logger.debug("ClusterMemberStore: CLI fetch completed successfully")

    # Parse the output
    {members, error} = parse_cli_output(raw_output)

    # Determine status: single node setup is OK, not an error
    status = cond do
      error != nil -> :error
      members == [] -> :ok  # Single node is OK
      true -> :ok
    end

    new_state = %{
      state |
      members: members,
      last_updated: DateTime.utc_now(),
      last_error: error,
      fetch_task: nil,
      status: status
    }

    # Broadcast update
    broadcast_update(new_state)

    {:noreply, new_state}
  end

  def handle_info({task_ref, {:error, reason}}, %{fetch_task: {task_ref, _}} = state) do
    Logger.warning("ClusterMemberStore: CLI fetch failed: #{inspect(reason)}")

    new_state = %{
      state |
      last_error: {:cli_error, reason},
      fetch_task: nil,
      status: :error,
      last_updated: DateTime.utc_now()
    }

    # Keep existing members on error, just update error state
    broadcast_update(new_state)

    {:noreply, new_state}
  end

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, %{fetch_task: {task_ref, _}} = state) do
    Logger.debug("ClusterMemberStore: Task process ended: #{inspect(reason)}")

    new_state = %{state | fetch_task: nil}
    {:noreply, new_state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Ignore DOWN messages from other processes
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("ClusterMemberStore: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  def terminate(reason, _state) do
    Logger.info("ClusterMemberStore shutting down: #{inspect(reason)}")
    :ok
  end

  # Private Functions

  defp start_fetch_task(state) do
    Logger.debug("ClusterMemberStore: Starting CLI fetch task")

    task = Task.async(fn ->
      CorrosionCLI.cluster_members(timeout: @cli_timeout)
    end)

    task_ref = task.ref

    %{state | fetch_task: {task_ref, task}, status: :fetching}
  end

  defp cancel_existing_task(%{fetch_task: nil} = state), do: state

  defp cancel_existing_task(%{fetch_task: {_task_ref, task}} = state) do
    Logger.debug("ClusterMemberStore: Cancelling existing fetch task")
    Task.shutdown(task, :brutal_kill)
    %{state | fetch_task: nil}
  end

  defp parse_cli_output(raw_output) do
    case CorrosionParser.parse_cluster_members(raw_output) do
      {:ok, []} ->
        Logger.info("ClusterMemberStore: No cluster members found - single node setup")
        {[], nil}

      {:ok, members} ->
        Logger.info("ClusterMemberStore: Parsed #{length(members)} cluster members")
        {members, nil}

      {:error, reason} ->
        Logger.warning("ClusterMemberStore: Failed to parse CLI output: #{inspect(reason)}")
        {[], {:parse_error, reason}}
    end
  end

  defp build_member_data(state) do
    %{
      members: state.members,
      last_updated: state.last_updated,
      last_error: state.last_error,
      status: state.status,
      member_count: length(state.members)
    }
  end

  defp empty_state do
    %{
      members: [],
      last_updated: nil,
      last_error: {:service_unavailable, "ClusterMemberStore not responding"},
      status: :unavailable,
      member_count: 0
    }
  end

  defp broadcast_update(state) do
    member_data = build_member_data(state)

    Phoenix.PubSub.broadcast(
      CorroPort.PubSub,
      @pubsub_topic,
      {:cluster_members_updated, member_data}
    )

    Logger.debug("ClusterMemberStore: Broadcasted update - #{length(state.members)} members, status: #{state.status}")
  end
end
