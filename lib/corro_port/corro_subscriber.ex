defmodule CorroPort.CorroSubscriber do
  @moduledoc """
  Watches for changes in the node_messages table via Corrosion's subscription API.

  This module wraps the external CorroClient.Subscriber and maintains compatibility
  with the existing PubSub broadcasting system.
  """

  use GenServer
  require Logger
  alias CorroPort.ConnectionManager

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    Process.send_after(self(), :start_subscription, 1000)

    {:ok,
     %{
       subscriber_pid: nil,
       status: :initializing,
       columns: nil,
       initial_state_received: false,
       watch_id: nil
     }}
  end

  def handle_info(:start_subscription, state) do
    # Stop any existing subscriber
    if state.subscriber_pid do
      CorroClient.Subscriber.stop(state.subscriber_pid)
    end

    # Start new subscription using external client
    conn = ConnectionManager.get_connection()
    query = "SELECT * FROM node_messages ORDER BY timestamp DESC"
    
    case CorroClient.Subscriber.start_subscription(conn,
      query: query,
      on_event: &handle_subscription_event/1,
      on_connect: &handle_subscription_connect/1,
      on_error: &handle_subscription_error/1,
      on_disconnect: &handle_subscription_disconnect/1
    ) do
      {:ok, subscriber_pid} ->
        new_state = %{
          state
          | subscriber_pid: subscriber_pid,
            status: :connecting,
            columns: nil,
            initial_state_received: false,
            watch_id: nil
        }
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("CorroSubscriber: Failed to start subscription: #{inspect(reason)}")
        broadcast_event({:subscription_error, reason})
        Process.send_after(self(), :start_subscription, 5000)
        {:noreply, %{state | status: :error}}
    end
  end

  def handle_info(:reconnect, state) do
    Logger.info("CorroSubscriber: Reconnecting subscription")
    send(self(), :start_subscription)
    {:noreply, state}
  end

  def handle_info({:external_subscription_connected, watch_id}, state) do
    Logger.info("CorroSubscriber: Connected with watch_id: #{watch_id}")
    broadcast_event({:subscription_connected, watch_id})

    {:noreply,
     %{
       state
       | status: :connected,
         watch_id: watch_id
     }}
  end

  def handle_info({:external_subscription_event, event}, state) do
    updated_state = process_subscription_event(event, state)
    {:noreply, updated_state}
  end

  def handle_info({:external_subscription_error, error}, state) do
    Logger.warning("CorroSubscriber: Subscription error: #{inspect(error)}")
    broadcast_event({:subscription_error, error})

    new_state = %{
      state
      | status: :error,
        subscriber_pid: nil,
        watch_id: nil
    }

    schedule_reconnect()
    {:noreply, new_state}
  end

  def handle_info({:external_subscription_disconnect, reason}, state) do
    Logger.warning("CorroSubscriber: Subscription closed: #{inspect(reason)}")
    broadcast_event({:subscription_closed, reason})

    new_state = %{
      state
      | status: :disconnected,
        subscriber_pid: nil,
        watch_id: nil
    }

    schedule_reconnect()
    {:noreply, new_state}
  end

  def handle_info({:EXIT, pid, reason}, %{subscriber_pid: pid} = state) do
    Logger.warning("CorroSubscriber: Subscriber process crashed: #{inspect(reason)}")

    new_state = %{
      state
      | status: :error,
        subscriber_pid: nil,
        watch_id: nil
    }

    schedule_reconnect()
    {:noreply, new_state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("CorroSubscriber: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  def handle_call(:restart, _from, state) do
    Logger.info("CorroSubscriber: Manual restart requested")

    if state.subscriber_pid do
      CorroClient.Subscriber.stop(state.subscriber_pid)
    end

    send(self(), :start_subscription)

    new_state = %{
      state
      | subscriber_pid: nil,
        status: :restarting,
        watch_id: nil
    }

    {:reply, :ok, new_state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      status: state.status,
      connected: state.status == :connected && !is_nil(state.subscriber_pid),
      watch_id: state.watch_id,
      initial_state_received: state.initial_state_received
    }

    {:reply, status, state}
  end

  # Public API
  def status do
    GenServer.call(__MODULE__, :status, 1000)
  rescue
    _ -> %{status: :unknown, connected: false}
  end

  def restart do
    GenServer.call(__MODULE__, :restart)
  end

  # Callback functions for the external CorroClient.Subscriber

  defp handle_subscription_event(event) do
    send(__MODULE__, {:external_subscription_event, event})
  end

  defp handle_subscription_connect(watch_id) do
    send(__MODULE__, {:external_subscription_connected, watch_id})
  end

  defp handle_subscription_error(error) do
    send(__MODULE__, {:external_subscription_error, error})
  end

  defp handle_subscription_disconnect(reason) do
    send(__MODULE__, {:external_subscription_disconnect, reason})
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

  defp schedule_reconnect do
    Logger.warning("CorroSubscriber: Scheduling reconnect in 5 seconds")
    Process.send_after(self(), :reconnect, 5_000)
  end
end
