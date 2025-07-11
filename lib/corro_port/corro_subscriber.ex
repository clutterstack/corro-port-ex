defmodule CorroPort.CorroSubscriber do
  @moduledoc """
  Watches for changes in the node_messages table via Corrosion's subscription API.

  This GenServer wraps CorroClient.Subscriber and provides proper supervision
  and state management for database subscriptions.
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
    Phoenix.PubSub.broadcast(CorroPort.PubSub, "message_updates", event)
  end
end
