defmodule CorroPort.ConfigSubscriber do
  @moduledoc """
  Subscribes to bootstrap config changes in the node_configs Corrosion table.

  This GenServer monitors the node_configs table for changes to this node's
  bootstrap configuration. When a change is detected, it automatically updates
  the local Corrosion config file and restarts the Corrosion agent.

  ## Architecture

  Each node subscribes to changes filtered by its own node_id. When another node
  (or this node) writes a new bootstrap config to the node_configs table:

  1. Corrosion gossips the change to all nodes
  2. This subscriber receives the change notification
  3. Parses the new bootstrap_hosts (JSON array)
  4. Calls ConfigManager.update_bootstrap/2 with restart=true
  5. ConfigManager handles the coordinated restart flow

  ## Coordinated Restart

  This module reuses the existing coordinated restart mechanism in ConfigManager
  which broadcasts on the "corrosion_lifecycle" PubSub topic to pause subscriptions
  before restarting Corrosion.

  ## Data Flow Example

  1. User edits bootstrap config in NodeLive for "dev-node2"
  2. NodeLive writes to node_configs: {"dev-node2", "["127.0.0.1:8787"]", ...}
  3. Corrosion gossips the change to all nodes
  4. dev-node2's ConfigSubscriber receives notification
  5. ConfigSubscriber extracts bootstrap_hosts
  6. Calls ConfigManager.update_bootstrap(["127.0.0.1:8787"], true)
  7. ConfigManager updates config file and restarts Corrosion
  """

  use GenServer
  require Logger
  alias CorroPort.{ConnectionManager, ConfigManager, NodeConfig}

  defstruct [
    :subscriber_pid,
    :status,
    :local_node_id,
    :last_config
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    local_node_id = NodeConfig.get_corrosion_node_id()
    Logger.info("ConfigSubscriber: Starting for node #{local_node_id}")

    {:ok, %__MODULE__{status: :initialising, local_node_id: local_node_id},
     {:continue, :start_subscription}}
  end

  @impl true
  def handle_continue(:start_subscription, state) do
    Logger.info("ConfigSubscriber: Starting subscription for node #{state.local_node_id}")

    conn = ConnectionManager.get_subscription_connection()

    # Subscribe only to this node's config changes
    query = """
    SELECT node_id, bootstrap_hosts, updated_at, updated_by
    FROM node_configs
    WHERE node_id = '#{state.local_node_id}'
    ORDER BY updated_at DESC
    """

    case CorroClient.Subscriber.start_subscription(conn,
           query: query,
           on_event: &handle_subscription_event/1,
           on_connect: &handle_subscription_connect/1,
           on_error: &handle_subscription_error/1,
           on_disconnect: &handle_subscription_disconnect/1
         ) do
      {:ok, subscriber_pid} ->
        Logger.info("ConfigSubscriber: Subscription started successfully")
        new_state = %{state | subscriber_pid: subscriber_pid, status: :connected}
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("ConfigSubscriber: Failed to start subscription: #{inspect(reason)}")
        new_state = %{state | status: :error}
        {:noreply, new_state}
    end
  end

  # Subscription event handlers

  defp handle_subscription_connect(info) do
    Logger.info("ConfigSubscriber: Connected to Corrosion subscription")
    Logger.debug("ConfigSubscriber: Connection info: #{inspect(info)}")
    send(__MODULE__, {:subscription_connected, info})
  end

  defp handle_subscription_event(event) do
    Logger.info("ConfigSubscriber: Received config change event")
    Logger.debug("ConfigSubscriber: Event data: #{inspect(event)}")
    send(__MODULE__, {:config_changed, event})
  end

  defp handle_subscription_error(error) do
    Logger.error("ConfigSubscriber: Subscription error: #{inspect(error)}")
    send(__MODULE__, {:subscription_error, error})
  end

  defp handle_subscription_disconnect(reason) do
    Logger.warning("ConfigSubscriber: Subscription disconnected: #{inspect(reason)}")
    send(__MODULE__, {:subscription_disconnected, reason})
  end

  # GenServer message handlers

  @impl true
  def handle_info({:subscription_connected, _info}, state) do
    {:noreply, %{state | status: :connected}}
  end

  @impl true
  def handle_info({:config_changed, event}, state) do
    case parse_config_event(event) do
      {:ok, :meta_event} ->
        # Subscription meta-events like columns_received, subscription_ready
        Logger.debug("ConfigSubscriber: Meta event received, no action needed")
        {:noreply, state}

      {:ok, config} ->
        Logger.info(
          "ConfigSubscriber: Config change for #{config.node_id} by #{config.updated_by} at #{config.updated_at}"
        )

        # Only process if this is truly a new config (avoid restart loops)
        if config_changed?(state.last_config, config) do
          Logger.info("ConfigSubscriber: Applying new bootstrap config: #{inspect(config.bootstrap_hosts)}")

          case apply_config_change(config) do
            :ok ->
              Logger.info("ConfigSubscriber: Successfully applied config change")
              {:noreply, %{state | last_config: config}}

            {:error, reason} ->
              Logger.error("ConfigSubscriber: Failed to apply config: #{inspect(reason)}")
              {:noreply, state}
          end
        else
          Logger.debug("ConfigSubscriber: Config unchanged, skipping update")
          {:noreply, state}
        end

      {:error, reason} ->
        Logger.error("ConfigSubscriber: Failed to parse config event: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:subscription_error, error}, state) do
    Logger.error("ConfigSubscriber: Subscription error: #{inspect(error)}")
    {:noreply, %{state | status: :error}}
  end

  @impl true
  def handle_info({:subscription_disconnected, reason}, state) do
    Logger.warning("ConfigSubscriber: Subscription disconnected: #{inspect(reason)}")
    {:noreply, %{state | status: :disconnected}}
  end

  # Private functions

  # Handle subscription meta-events (not config changes)
  defp parse_config_event({:columns_received, _columns}), do: {:ok, :meta_event}
  defp parse_config_event({:subscription_ready}), do: {:ok, :meta_event}

  # Handle actual data events
  defp parse_config_event({:initial_row, row}), do: parse_row(row)
  defp parse_config_event({:new_row, row}), do: parse_row(row)
  defp parse_config_event({:change, _change_type, row}), do: parse_row(row)

  defp parse_config_event(event) do
    Logger.debug("ConfigSubscriber: Unhandled event type: #{inspect(event)}")
    {:error, :unknown_event_type}
  end

  defp parse_row(%{"node_id" => node_id, "bootstrap_hosts" => hosts_json} = row) do
    updated_at = Map.get(row, "updated_at", "")
    updated_by = Map.get(row, "updated_by", "unknown")

    # Parse JSON array of bootstrap hosts
    case Jason.decode(hosts_json) do
      {:ok, hosts} when is_list(hosts) ->
        {:ok,
         %{
           node_id: node_id,
           bootstrap_hosts: hosts,
           updated_at: updated_at,
           updated_by: updated_by
         }}

      {:error, reason} ->
        Logger.error(
          "ConfigSubscriber: Failed to parse bootstrap_hosts JSON: #{inspect(reason)}"
        )

        {:error, :invalid_json}
    end
  end

  defp parse_row(_row) do
    {:error, :missing_required_fields}
  end

  defp config_changed?(nil, _new_config), do: true

  defp config_changed?(last_config, new_config) do
    last_config.bootstrap_hosts != new_config.bootstrap_hosts
  end

  defp apply_config_change(config) do
    case ConfigManager.update_bootstrap(config.bootstrap_hosts, true) do
      {:ok, _message} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
