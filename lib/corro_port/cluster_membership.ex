defmodule CorroPort.ClusterMembership do
  @moduledoc """
  Manages active cluster membership via CLI and computes their regions.

  This module tracks which nodes are actually active and responding,
  using the existing ClusterMemberStore but with a cleaner interface.
  """

  use GenServer
  require Logger

  @pubsub_topic "cluster_membership"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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
    GenServer.call(__MODULE__, :get_active_data)
  end

  @doc """
  Force refresh of the CLI member data.
  """
  def refresh_cache do
    GenServer.cast(__MODULE__, :refresh_cache)
  end

  @doc """
  Subscribe to active member updates.
  Receives: {:active_members_updated, active_data}
  """
  def subscribe do
    Phoenix.PubSub.subscribe(CorroPort.PubSub, @pubsub_topic)
  end

  @doc """
  Get cache status for debugging.
  """
  def get_cache_status do
    GenServer.call(__MODULE__, :get_cache_status)
  end

  # GenServer Implementation

  def init(_opts) do
    Logger.info("ClusterMembership starting...")

    # Subscribe to the existing ClusterMemberStore updates
    CorroPort.ClusterMemberStore.subscribe()

    # Get initial state from store
    initial_store_data = CorroPort.ClusterMemberStore.get_members()

    state = %{
      members_result: build_members_result(initial_store_data),
      regions: compute_regions_from_store_data(initial_store_data),
      cache_status: build_cache_status(initial_store_data)
    }

    {:ok, state}
  end

  def handle_call(:get_active_data, _from, state) do
    data = build_active_data(state)
    {:reply, data, state}
  end

  def handle_call(:get_cache_status, _from, state) do
    {:reply, state.cache_status, state}
  end

  def handle_cast(:refresh_cache, state) do
    Logger.info("ClusterMembership: Manual cache refresh requested")
    CorroPort.ClusterMemberStore.refresh_members()
    {:noreply, state}
  end

  # Handle updates from ClusterMemberStore
  def handle_info({:cluster_members_updated, store_data}, state) do
    Logger.debug("ClusterMembership: Received update from ClusterMemberStore")

    new_state = %{
      state |
      members_result: build_members_result(store_data),
      regions: compute_regions_from_store_data(store_data),
      cache_status: build_cache_status(store_data)
    }

    # Broadcast our own update
    broadcast_update(new_state)

    {:noreply, new_state}
  end

  # Private Functions

  defp build_members_result(store_data) do
    case store_data.last_error do
      nil ->
        {:ok, store_data.members}

      error ->
        # Convert store errors to our error format
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

  defp compute_regions_from_store_data(store_data) do
    case store_data.last_error do
      nil ->
        # Extract regions from successful member data
        CorroPort.RegionExtractor.extract_from_members({:ok, store_data.members})

      _error ->
        # Return empty list on any error
        []
    end
  end

  defp build_cache_status(store_data) do
    %{
      last_updated: store_data.last_updated,
      error: store_data.last_error,
      status: store_data.status,
      member_count: store_data.member_count
    }
  end

  defp build_active_data(state) do
    %{
      members: state.members_result,
      regions: state.regions,
      cache_status: state.cache_status
    }
  end

  defp broadcast_update(state) do
    active_data = build_active_data(state)
    Phoenix.PubSub.broadcast(CorroPort.PubSub, @pubsub_topic, {:active_members_updated, active_data})
  end
end
