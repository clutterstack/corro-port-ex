defmodule CorroPort.CorroSubscriber do
  @moduledoc """
  Watches for changes in the node_messages table via Corrosion's subscription API.

  This GenServer wraps CorroClient.Subscriber and provides proper supervision
  and state management for database subscriptions.

  ## Coordinated Restart Handling

  This module coordinates with `CorroPort.ConfigManager` during Corrosion restarts
  to prevent race conditions and database corruption. It subscribes to the
  `"corrosion_lifecycle"` PubSub topic to receive restart notifications.

  ### Restart States

  - `:initializing` - Initial state on startup
  - `:connected` - Active subscription running normally
  - `:paused_for_restart` - Gracefully paused during Corrosion restart
  - `:disconnected` - Subscription lost (will attempt reconnect via CorroClient.Subscriber)
  - `:error` - Subscription error occurred

  ### Coordinated Restart Flow

  1. **Receives `{:corrosion_restarting}`** from ConfigManager
     - Stops active subscription via `CorroClient.Subscriber.stop/1`
     - Sets state to `:paused_for_restart`
     - Broadcasts `{:subscription_paused_for_restart}` event

  2. **Ignores disconnect/error callbacks**
     - While in `:paused_for_restart` state, ignores `{:subscription_disconnected}` and `{:subscription_error}`
     - Prevents stopped subscriber's callbacks from corrupting the coordinated state

  3. **Receives `{:corrosion_ready}`** from ConfigManager
     - Only processes if currently in `:paused_for_restart` state
     - Triggers subscription restart via `handle_continue(:start_subscription)`
     - Returns to `:connected` state once subscription is live

  ### Why This Is Necessary

  Without coordination, Corrosion restarts while subscriptions are active would cause:
  - Subscription database creation failures (unable to open database file errors)
  - Connection refused errors from premature reconnection attempts
  - Race conditions between subscriber reconnect logic and Corrosion initialisation

  The coordinated pause/resume ensures clean shutdown before restart and only resumes
  once Corrosion's subscription endpoint is fully operational.
  """

  use GenServer
  require Logger
  alias CorroPort.ConnectionManager

  @corrosion_lifecycle_topic "corrosion_lifecycle"

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
    # Subscribe to Corrosion lifecycle events for coordinated restarts
    Phoenix.PubSub.subscribe(CorroPort.PubSub, @corrosion_lifecycle_topic)
    {:ok, %__MODULE__{status: :initializing}, {:continue, :start_subscription}}
  end

  @impl true
  def handle_continue(:start_subscription, state) do
    Logger.info("CorroSubscriber: Starting subscription")

    conn = ConnectionManager.get_subscription_connection()
    query = "SELECT * FROM node_messages ORDER BY timestamp DESC"

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
    subscriber_status = if state.subscriber_pid do
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
    # Ignore errors when paused for restart - we're coordinating with ConfigManager
    if state.status == :paused_for_restart do
      Logger.debug("CorroSubscriber: Ignoring error during paused_for_restart: #{inspect(error)}")
      {:noreply, state}
    else
      Logger.warning("CorroSubscriber: Subscription error: #{inspect(error)}")
      broadcast_event({:subscription_error, error})
      new_state = %{state | status: :error}
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:subscription_disconnected, reason}, state) do
    # Ignore disconnection when paused for restart - we're coordinating with ConfigManager
    if state.status == :paused_for_restart do
      Logger.debug("CorroSubscriber: Ignoring disconnection during paused_for_restart: #{inspect(reason)}")
      {:noreply, state}
    else
      Logger.warning("CorroSubscriber: Subscription closed: #{inspect(reason)}")
      broadcast_event({:subscription_closed, reason})
      new_state = %{state | status: :disconnected}
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:corrosion_restarting}, state) do
    Logger.info("CorroSubscriber: Corrosion restart initiated - pausing subscription")

    # Gracefully stop the subscriber if it exists
    if state.subscriber_pid do
      CorroClient.Subscriber.stop(state.subscriber_pid)
    end

    broadcast_event({:subscription_paused_for_restart})

    new_state = %{
      state
      | status: :paused_for_restart,
        subscriber_pid: nil,
        watch_id: nil
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:corrosion_ready}, state) do
    Logger.info("CorroSubscriber: Corrosion ready - resuming subscription")

    # Only resume if we were paused for restart
    if state.status == :paused_for_restart do
      # Trigger subscription restart using the existing continuation
      {:noreply, state, {:continue, :start_subscription}}
    else
      # Ignore if we're in another state
      Logger.debug("CorroSubscriber: Ignoring :corrosion_ready in state #{state.status}")
      {:noreply, state}
    end
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
