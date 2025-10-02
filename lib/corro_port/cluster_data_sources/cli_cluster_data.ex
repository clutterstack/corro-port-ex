defmodule CorroPort.CLIClusterData do
  @moduledoc """
  Centralized store for cluster member data fetched via CLI.

  Manages periodic fetching of cluster members via CLI, computes their regions,
  and broadcasts updates to subscribed LiveViews. Provides both automatic periodic
  updates and manual refresh capability.
  """

  use GenServer
  require Logger

  alias CorroPort.RegionExtractor
  # alias CorroCLI

  # Default refresh interval: 5 minutes
  @default_refresh_interval 300_000
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
        Logger.warning("CLIClusterData: Call timeout, returning empty state")
        empty_state()
    end
  end

  @doc """
  Get active members data with computed regions.

  Returns:
  %{
    members: {:ok, [%{...}]} | {:error, :cli_timeout},
    regions: ["ams", "fra"],  # Always a list, empty on error
    cache_status: %{last_updated: dt, error: nil | :cli_timeout}
  }
  """
  def get_active_data do
    try do
      GenServer.call(__MODULE__, :get_active_data, 1000)
    catch
      :exit, _ ->
        Logger.warning("CLIClusterData: Call timeout, returning empty active data")
        empty_active_data()
    end
  end

  @doc """
  Get cache status for debugging.
  """
  def get_cache_status do
    try do
      GenServer.call(__MODULE__, :get_cache_status, 1000)
    catch
      :exit, _ ->
        Logger.warning("CLIClusterData: Call timeout, returning empty cache status")
        %{last_updated: nil, error: {:service_unavailable, "CLIClusterData not responding"}, status: :unavailable, member_count: 0}
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
  Subscribe to cluster member updates.
  Subscribers will receive: {:cluster_members_updated, member_data}
  """
  def subscribe do
    Phoenix.PubSub.subscribe(CorroPort.PubSub, "cluster_members")
  end

  @doc """
  Subscribe to active member updates.
  Receives: {:active_members_updated, active_data}
  """
  def subscribe_active do
    Phoenix.PubSub.subscribe(CorroPort.PubSub, "cluster_membership")
  end

  # GenServer Implementation

  def init(opts) do
    refresh_interval = Keyword.get(opts, :refresh_interval, @default_refresh_interval)

    Logger.info("CLIClusterData starting with #{refresh_interval}ms refresh interval")

    # Start with empty state
    state = %{
      members: [],
      last_updated: nil,
      last_error: nil,
      refresh_interval: refresh_interval,
      fetch_task: nil,
      status: :initializing,
      regions: []
    }

    # Schedule initial fetch
    Process.send_after(self(), :fetch_members, 1000)

    {:ok, state}
  end

  def handle_call(:get_members, _from, state) do
    member_data = build_member_data(state)
    {:reply, member_data, state}
  end

  def handle_call(:get_active_data, _from, state) do
    active_data = build_active_data(state)
    {:reply, active_data, state}
  end

  def handle_call(:get_cache_status, _from, state) do
    cache_status = build_cache_status(state)
    {:reply, cache_status, state}
  end

  def handle_cast(:refresh_members, state) do
    Logger.info("CLIClusterData: Manual refresh requested")

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
    Logger.debug("CLIClusterData: CLI fetch completed successfully")

    # Ensure we never pass nil to the parser - convert nil to empty string
    # This handles the case where System.cmd might unexpectedly return nil
    normalized_output = raw_output || ""

    # Logger.debug("CLIClusterData: Raw output type: #{inspect(raw_output)} -> #{inspect(normalized_output)}")

    # Parse the output
    {members, error} = parse_cli_output(normalized_output)

    # Compute regions from members
    regions = compute_regions(members, error)

    # Determine status: single node setup is OK, not an error
    status =
      cond do
        error != nil -> :error
        # Single node is OK
        members == [] -> :ok
        true -> :ok
      end

    new_state = %{
      state
      | members: members,
        last_updated: DateTime.utc_now(),
        last_error: error,
        fetch_task: nil,
        status: status,
        regions: regions
    }

    # Broadcast updates (both legacy and new formats)
    broadcast_update(new_state)
    broadcast_active_update(new_state)

    {:noreply, new_state}
  end

  def handle_info({task_ref, {:error, reason}}, %{fetch_task: {task_ref, _}} = state) do
    Logger.warning("CLIClusterData: CLI fetch failed: #{inspect(reason)}")

    new_state = %{
      state
      | last_error: {:cli_error, reason},
        fetch_task: nil,
        status: :error,
        last_updated: DateTime.utc_now()
    }

    # Keep existing members on error, just update error state
    broadcast_update(new_state)
    broadcast_active_update(new_state)

    {:noreply, new_state}
  end

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, %{fetch_task: {task_ref, _}} = state) do
    Logger.debug("CLIClusterData: Task process ended: #{inspect(reason)}")

    new_state = %{state | fetch_task: nil}
    {:noreply, new_state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Ignore DOWN messages from other processes
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("CLIClusterData: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  def terminate(reason, _state) do
    Logger.info("CLIClusterData shutting down: #{inspect(reason)}")
    :ok
  end

  # Private Functions

  defp start_fetch_task(state) do
    Logger.debug("CLIClusterData: Starting CLI fetch task")

    task =
      Task.async(fn ->
        CorroCLI.cluster_members(timeout: @cli_timeout)
      end)

    task_ref = task.ref

    %{state | fetch_task: {task_ref, task}, status: :fetching}
  end

  defp cancel_existing_task(%{fetch_task: nil} = state), do: state

  defp cancel_existing_task(%{fetch_task: {_task_ref, task}} = state) do
    Logger.debug("CLIClusterData: Cancelling existing fetch task")
    Task.shutdown(task, :brutal_kill)
    %{state | fetch_task: nil}
  end

  defp parse_cli_output(raw_output) do
    case CorroCLI.Parser.parse_cluster_members(raw_output) do
      {:ok, []} ->
        Logger.info("CLIClusterData: No cluster members found - single node setup")
        {[], nil}

      {:ok, members} ->
        presented_members = CorroPort.ClusterMemberPresenter.present_members(members)
        Logger.info("CLIClusterData: Parsed #{length(presented_members)} cluster members")
        {presented_members, nil}

      {:error, reason} ->
        Logger.warning("CLIClusterData: Failed to parse CLI output: #{inspect(reason)}")
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

  defp build_active_data(state) do
    members_result = build_members_result(state)
    cache_status = build_cache_status(state)

    %{
      members: members_result,
      regions: state.regions,
      cache_status: cache_status
    }
  end

  defp build_members_result(state) do
    case state.last_error do
      nil ->
        {:ok, state.members}

      error ->
        # Convert store errors to ClusterMembership error format
        mapped_error = case error do
          {:cli_error, :timeout} -> :cli_timeout
          {:cli_error, reason} -> {:cli_failed, reason}
          {:parse_error, reason} -> {:parse_failed, reason}
          {:service_unavailable, _} -> :service_unavailable
          other -> other
        end

        {:error, mapped_error}
    end
  end

  defp build_cache_status(state) do
    %{
      last_updated: state.last_updated,
      error: state.last_error,
      status: state.status,
      member_count: length(state.members)
    }
  end

  defp compute_regions(members, error) do
    case error do
      nil ->
        # Extract regions from successful member data
        RegionExtractor.extract_from_members({:ok, members})

      _error ->
        # Return empty list on any error
        []
    end
  end

  defp empty_state do
    %{
      members: [],
      last_updated: nil,
      last_error: {:service_unavailable, "CLIClusterData not responding"},
      status: :unavailable,
      member_count: 0
    }
  end

  defp empty_active_data do
    %{
      members: {:error, :service_unavailable},
      regions: [],
      cache_status: %{
        last_updated: nil,
        error: {:service_unavailable, "CLIClusterData not responding"},
        status: :unavailable,
        member_count: 0
      }
    }
  end

  defp broadcast_update(state) do
    member_data = build_member_data(state)

    Phoenix.PubSub.broadcast(
      CorroPort.PubSub,
      "cluster_members",
      {:cluster_members_updated, member_data}
    )

    Logger.debug(
      "CLIClusterData: Broadcasted update - #{length(state.members)} members, status: #{state.status}"
    )
  end

  defp broadcast_active_update(state) do
    active_data = build_active_data(state)

    Phoenix.PubSub.broadcast(
      CorroPort.PubSub,
      "cluster_membership",
      {:active_members_updated, active_data}
    )

    Logger.debug(
      "CLIClusterData: Broadcasted active update - #{length(state.regions)} regions, status: #{state.status}"
    )
  end
end
