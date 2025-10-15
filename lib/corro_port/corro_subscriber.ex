defmodule CorroPort.CorroSubscriber do
  @moduledoc """
  Watches for changes in the node_messages table via Corrosion's subscription API.

  This GenServer wraps CorroClient.Subscriber and provides supervision
  and state management for database subscriptions.

  ## Architecture: Library vs Application Layers

  This module demonstrates clean separation of concerns between library and application code:

  **CorroClient.Subscriber (Library Layer):**
  - Generic subscription client for Corrosion databases
  - Handles HTTP streaming, reconnection logic with exponential backoff, error handling
  - Callback-based API: `on_event`, `on_connect`, `on_error`, `on_disconnect`
  - No application-specific logic or dependencies
  - Reusable across any Elixir application

  **CorroPort.CorroSubscriber (Application Layer):**
  - Wraps CorroClient.Subscriber in a supervised GenServer
  - Translates generic callbacks into Phoenix PubSub broadcasts for LiveViews
  - Performs application-specific event transformation (e.g., `{:new_row}` → `{:new_message}`)
  - Named process registration for easy access throughout the application
  - Integrates with CorroPort's supervision tree and PubSub infrastructure

  ### The Callback-to-Message Pattern

  This module uses a two-step pattern to bridge the library's callbacks into its GenServer state:

  1. Callbacks from CorroClient.Subscriber run in the subscriber's process
  2. These callbacks send messages to this GenServer via `send(__MODULE__, ...)`
  3. The GenServer handles these messages in `handle_info/2` with proper state management

  This pattern ensures all state mutations happen in the GenServer's process, maintaining
  proper concurrency guarantees and enabling supervision.

  ## Connection Resilience

  The underlying `CorroClient.Subscriber` handles automatic reconnection with
  exponential backoff (2s, 5s, 10s, 15s, 30s) when connections are lost. This
  module simply tracks connection state and broadcasts events to LiveViews.

  ### States

  - `:initializing` - Initial state on startup
  - `:connected` - Active subscription running normally
  - `:disconnected` - Subscription lost (CorroClient.Subscriber will auto-reconnect)
  - `:error` - Subscription error occurred (CorroClient.Subscriber will retry)

  ## Corrosion Restarts

  When Corrosion is restarted (e.g., for configuration changes), the subscription
  will disconnect and automatically reconnect once Corrosion is available again.
  You may see "connection refused" or "unable to open database" errors in logs
  during the restart window - this is expected behaviour while the reconnection
  logic waits for Corrosion to become available.

  No coordination is needed between ConfigManager (which restarts Corrosion) and
  this subscriber - each component handles its own responsibility independently.
  """

  use GenServer
  require Logger
  alias CorroPort.ConnectionManager

  defstruct [
    :subscriber_pid,
    :status,
    :columns,
    :initial_state_received,
    :watch_id
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{status: :initializing}, {:continue, :start_subscription}}
  end

  # Limit initial message fetch to avoid full table scan on reconnection
  # Real-time updates will still arrive for all new messages after subscription starts
  @initial_fetch_limit 100

  @impl true
  def handle_continue(:start_subscription, state) do
    Logger.info("CorroSubscriber: Starting subscription")

    conn = ConnectionManager.get_subscription_connection()
    query = "SELECT * FROM node_messages ORDER BY sequence DESC LIMIT #{@initial_fetch_limit}"

    case CorroClient.Subscriber.start_subscription(conn,
           query: query,
           on_event: &handle_subscription_event/1,
           on_connect: &handle_subscription_connect/1,
           on_error: &handle_subscription_error/1,
           on_disconnect: &handle_subscription_disconnect/1
         ) do
      {:ok, subscriber_pid} ->
        Logger.info("CorroSubscriber: Subscription started successfully")
        new_state = %{state | subscriber_pid: subscriber_pid, status: :connected}
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("CorroSubscriber: Failed to start subscription: #{inspect(reason)}")
        broadcast_event({:subscription_error, reason})
        new_state = %{state | status: :error}
        {:noreply, new_state}
    end
  end

  # Public API
  def status do
    try do
      GenServer.call(__MODULE__, :status, 1000)
    rescue
      _ -> %{status: :unknown, connected: false}
    end
  end

  def restart do
    GenServer.call(__MODULE__, :restart)
  end

  @impl true
  def handle_call(:status, _from, state) do
    subscriber_status =
      if state.subscriber_pid do
        CorroClient.Subscriber.get_status(state.subscriber_pid)
      else
        %{status: :not_started, connected: false}
      end

    status = %{
      genserver_status: state.status,
      subscriber_status: subscriber_status.status,
      connected: subscriber_status.connected,
      watch_id: state.watch_id,
      initial_state_received: state.initial_state_received
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:restart, _from, state) do
    Logger.info("CorroSubscriber: Manual restart requested")

    if state.subscriber_pid do
      CorroClient.Subscriber.restart(state.subscriber_pid)
    end

    {:reply, :ok, state}
  end

  # Callback functions for CorroClient.Subscriber - these send messages to the GenServer

  def handle_subscription_event(event) do
    send(__MODULE__, {:subscription_event, event})
  end

  def handle_subscription_connect(watch_id) do
    send(__MODULE__, {:subscription_connected, watch_id})
  end

  def handle_subscription_error(error) do
    send(__MODULE__, {:subscription_error, error})
  end

  def handle_subscription_disconnect(reason) do
    send(__MODULE__, {:subscription_disconnected, reason})
  end

  @impl true
  def handle_info({:subscription_event, event}, state) do
    new_state = process_subscription_event(event, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:subscription_connected, watch_id}, state) do
    Logger.info("CorroSubscriber: Connected with watch_id: #{watch_id}")
    broadcast_event({:subscription_connected, watch_id})
    new_state = %{state | watch_id: watch_id, status: :connected}
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:subscription_error, error}, state) do
    Logger.warning("CorroSubscriber: Subscription error: #{inspect(error)}")
    broadcast_event({:subscription_error, error})
    new_state = %{state | status: :error}
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:subscription_disconnected, reason}, state) do
    Logger.warning("CorroSubscriber: Subscription closed: #{inspect(reason)}")
    broadcast_event({:subscription_closed, reason})
    new_state = %{state | status: :disconnected}
    {:noreply, new_state}
  end

  defp process_subscription_event(event, state) do
    case event do
      {:subscription_ready} ->
        Logger.info("CorroSubscriber: End of initial query - subscription is now live")
        broadcast_event({:subscription_ready})
        %{state | initial_state_received: true}

      {:columns_received, columns} ->
        Logger.info("CorroSubscriber: Got column names: #{inspect(columns)}")
        broadcast_event({:columns_received, columns})
        %{state | columns: columns}

      {:initial_row, row_data} ->
        broadcast_event({:initial_row, row_data})
        state

      {:new_row, row_data} ->
        broadcast_event({:new_message, row_data})
        state

      {:change, change_type, row_data} ->
        broadcast_event({:message_change, String.upcase(change_type), row_data})
        state

      other ->
        Logger.warning("CorroSubscriber: Unhandled subscription event: #{inspect(other)}")
        state
    end
  end

  defp broadcast_event(event) do
    Phoenix.PubSub.local_broadcast(CorroPort.PubSub, "message_updates", event)
  end
end
