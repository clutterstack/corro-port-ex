defmodule CorroPort.ClusterConfigCoordinator do
  @moduledoc """
  Coordinates cluster-wide bootstrap configuration changes via Elixir PubSub.

  ## Why PubSub instead of Corrosion gossip?

  Using Corrosion's node_configs table creates a chicken-and-egg problem:
  - Bad bootstrap config breaks Corrosion gossip
  - Broken gossip prevents distributing the fix
  - Nodes can't coordinate recovery

  Using Elixir clustering (via libcluster/DNSCluster) solves this:
  - Config changes broadcast via PubSub (independent of Corrosion state)
  - Each node independently validates and applies changes
  - Can coordinate even when Corrosion cluster is partitioned
  - Easy rollback by broadcasting previous config

  ## Architecture

  1. User clicks "Update All Nodes" in NodeLive
  2. NodeLive calls `broadcast_config_update/1`
  3. PubSub broadcasts `{:update_bootstrap, hosts, from_node}` to all Elixir nodes
  4. Each node's ClusterConfigCoordinator receives the message
  5. Validates, updates local TOML, restarts Corrosion
  6. Reports success/failure back to originating node via PubSub

  ## Safety

  - Each node validates bootstrap hosts before applying
  - Failed updates don't affect other nodes
  - Can broadcast rollback if needed
  - Auto-rollback can be added later (detect partition → revert)
  """

  use GenServer
  require Logger

  alias CorroPort.{ConfigManager, NodeConfig}

  @pubsub_topic "cluster_config_coordination"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Broadcasts a bootstrap config update to all nodes in the Elixir cluster.

  Returns {:ok, node_ids} where node_ids is the list of connected Elixir nodes
  that should receive the update (including local node).
  """
  def broadcast_config_update(bootstrap_hosts) do
    GenServer.call(__MODULE__, {:broadcast_update, bootstrap_hosts})
  end

  @doc """
  Gets the current status of the last config update.
  Returns a map of node_id => %{status: :pending | :success | :error, message: "..."}
  """
  def get_update_status do
    GenServer.call(__MODULE__, :get_status)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Subscribe to cluster config coordination topic
    Phoenix.PubSub.subscribe(CorroPort.PubSub, @pubsub_topic)
    Logger.info("ClusterConfigCoordinator: Started and subscribed to #{@pubsub_topic}")

    {:ok, %{
      update_status: %{},  # node_id => %{status, message, timestamp}
      last_update: nil
    }}
  end

  @impl true
  def handle_call({:broadcast_update, bootstrap_hosts}, _from, state) do
    local_node_id = NodeConfig.get_corrosion_node_id()
    timestamp = DateTime.utc_now()

    Logger.info("ClusterConfigCoordinator: Broadcasting config update from #{local_node_id}")

    # Get all connected Elixir nodes (including self)
    connected_nodes = [Node.self() | Node.list()]
    node_count = length(connected_nodes)

    Logger.info("ClusterConfigCoordinator: Broadcasting to #{node_count} Elixir nodes: #{inspect(connected_nodes)}")

    # Broadcast to all nodes via PubSub
    Phoenix.PubSub.broadcast(
      CorroPort.PubSub,
      @pubsub_topic,
      {:update_bootstrap, bootstrap_hosts, local_node_id, timestamp}
    )

    # Initialize status tracking for expected responses
    # We'll get responses from all nodes (including ourselves)
    initial_status = Map.new(connected_nodes, fn node ->
      {node, %{status: :pending, message: "Waiting for response", timestamp: timestamp}}
    end)

    state = %{state |
      update_status: initial_status,
      last_update: %{hosts: bootstrap_hosts, from: local_node_id, timestamp: timestamp}
    }

    {:reply, {:ok, connected_nodes}, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.update_status, state}
  end

  @impl true
  def handle_info({:update_bootstrap, bootstrap_hosts, from_node, timestamp}, state) do
    local_node_id = NodeConfig.get_corrosion_node_id()

    Logger.info(
      "ClusterConfigCoordinator: Received config update from #{from_node} at #{timestamp}. " <>
      "Applying to local node #{local_node_id}"
    )

    # Apply the config update locally
    result = ConfigManager.update_bootstrap(bootstrap_hosts, true)

    # Broadcast result back
    response = case result do
      {:ok, message} ->
        Logger.info("ClusterConfigCoordinator: Successfully applied config update on #{local_node_id}")
        {:update_success, Node.self(), local_node_id, message, timestamp}

      {:error, reason} ->
        Logger.error("ClusterConfigCoordinator: Failed to apply config update on #{local_node_id}: #{inspect(reason)}")
        {:update_error, Node.self(), local_node_id, reason, timestamp}
    end

    Phoenix.PubSub.broadcast(CorroPort.PubSub, @pubsub_topic, response)

    {:noreply, state}
  end

  @impl true
  def handle_info({:update_success, elixir_node, node_id, message, timestamp}, state) do
    Logger.info("ClusterConfigCoordinator: Received success from #{elixir_node} (#{node_id}): #{message}")

    # Update status tracking
    state = if Map.has_key?(state.update_status, elixir_node) do
      put_in(state, [:update_status, elixir_node], %{
        status: :success,
        message: message,
        timestamp: timestamp,
        node_id: node_id
      })
    else
      state
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:update_error, elixir_node, node_id, reason, timestamp}, state) do
    Logger.error("ClusterConfigCoordinator: Received error from #{elixir_node} (#{node_id}): #{inspect(reason)}")

    # Update status tracking
    state = if Map.has_key?(state.update_status, elixir_node) do
      put_in(state, [:update_status, elixir_node], %{
        status: :error,
        message: inspect(reason),
        timestamp: timestamp,
        node_id: node_id
      })
    else
      state
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("ClusterConfigCoordinator: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end
end
