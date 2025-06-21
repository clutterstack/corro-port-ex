defmodule CorroPort.MessagePropagation do
  @moduledoc """
  Manages message sending and real-time acknowledgment tracking with regions.

  This module wraps the existing AckTracker and MessagesAPI with a cleaner
  interface and built-in region extraction.
  """

  use GenServer
  require Logger

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send a message and start tracking acknowledgments.

  Returns:
  {:ok, message_data} | {:error, reason}
  """
  def send_message(content) do
    GenServer.call(__MODULE__, {:send_message, content})
  end

  @doc """
  Get current acknowledgment status with computed regions.

  Returns:
  %{
    latest_message: %{pk: "...", timestamp: "..."} | nil,
    acks: [%{node_id: "...", timestamp: "..."}],
    ack_count: 1,
    regions: ["ams"]  # Regions that have acknowledged
  }
  """
  def get_ack_data do
    GenServer.call(__MODULE__, :get_ack_data)
  end

  @doc """
  Reset acknowledgment tracking.
  """
  def reset_tracking do
    GenServer.call(__MODULE__, :reset_tracking)
  end

  @doc """
  Subscribe to acknowledgment updates.
  Receives: {:ack_status_updated, ack_data}
  """
  def subscribe do
    Phoenix.PubSub.subscribe(CorroPort.PubSub, "message_propagation")
  end

  @doc """
  Set the current experiment ID for analytics tracking.
  """
  def set_experiment_id(experiment_id) do
    GenServer.call(__MODULE__, {:set_experiment_id, experiment_id})
  end

  @doc """
  Get the current experiment ID.
  """
  def get_experiment_id do
    GenServer.call(__MODULE__, :get_experiment_id)
  end

  # GenServer Implementation

  def init(_opts) do
    Logger.info("MessagePropagation starting...")

    # Subscribe to AckTracker updates
    Phoenix.PubSub.subscribe(CorroPort.PubSub, "ack_events")

    # Get initial state
    initial_ack_status = CorroPort.AckTracker.get_status()

    state = %{
      ack_data: build_ack_data(initial_ack_status),
      experiment_id: nil
    }

    {:ok, state}
  end

  def handle_call({:send_message, content}, _from, state) do
    local_node_id = CorroPort.LocalNode.get_node_id()
    message_content = "#{content} (from #{local_node_id} at #{DateTime.utc_now() |> DateTime.to_iso8601()})"
    send_timestamp = DateTime.utc_now()

    case CorroPort.MessagesAPI.insert_message(local_node_id, message_content) do
      {:ok, result} ->
        Logger.info("MessagePropagation: Successfully sent message: #{inspect(result)}")

        # Track this message for acknowledgments
        message_pk = "#{local_node_id}_#{result.sequence}"

        track_message_data = %{
          pk: message_pk,
          timestamp: result.timestamp,
          node_id: result.node_id
        }

        case CorroPort.AckTracker.track_latest_message(track_message_data) do
          :ok ->
            # Record send event in analytics if experiment is active
            record_send_event(message_pk, local_node_id, send_timestamp, result.region)

            message_data = %{
              pk: message_pk,
              timestamp: result.timestamp,
              node_id: result.node_id,
              message: result.message,
              sequence: result.sequence
            }

            {:reply, {:ok, message_data}, state}

          {:error, reason} ->
            Logger.warning("MessagePropagation: Failed to track message: #{inspect(reason)}")
            {:reply, {:error, {:tracking_failed, reason}}, state}
        end

      {:error, reason} ->
        Logger.warning("MessagePropagation: Failed to send message: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_ack_data, _from, state) do
    {:reply, state.ack_data, state}
  end

  def handle_call({:set_experiment_id, experiment_id}, _from, state) do
    Logger.info("MessagePropagation: Set experiment ID to #{experiment_id}")
    {:reply, :ok, %{state | experiment_id: experiment_id}}
  end

  def handle_call(:get_experiment_id, _from, state) do
    {:reply, state.experiment_id, state}
  end

  def handle_call(:reset_tracking, _from, state) do
    case CorroPort.AckTracker.reset_tracking() do
      :ok ->
        Logger.info("MessagePropagation: Tracking reset successfully")

        # Update our state immediately
        new_ack_data = build_ack_data(CorroPort.AckTracker.get_status())
        new_state = %{state | ack_data: new_ack_data}

        # Broadcast the update
        broadcast_update(new_state)

        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.warning("MessagePropagation: Failed to reset tracking: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  # Handle updates from AckTracker
  def handle_info({:ack_update, ack_status}, state) do
    Logger.debug("MessagePropagation: Received ack update from AckTracker")

    new_ack_data = build_ack_data(ack_status)
    new_state = %{state | ack_data: new_ack_data}

    # Broadcast our own update with region data
    broadcast_update(new_state)

    {:noreply, new_state}
  end

  # Private Functions

  defp build_ack_data(ack_status) do
    # Extract regions from acknowledgments
    ack_regions = CorroPort.RegionExtractor.extract_from_acks(ack_status.acknowledgments)

    %{
      latest_message: ack_status.latest_message,
      acks: ack_status.acknowledgments,
      ack_count: ack_status.ack_count,
      regions: ack_regions
    }
  end

  defp broadcast_update(state) do
    Phoenix.PubSub.broadcast(CorroPort.PubSub, "message_propagation", {:ack_status_updated, state.ack_data})
  end

  defp record_send_event(message_id, originating_node, timestamp, region) do
    # Only record if SystemMetrics has an active experiment
    case CorroPort.SystemMetrics.get_experiment_id() do
      nil -> 
        # No active experiment, skip analytics
        :ok
        
      experiment_id ->
        # Record the send event
        CorroPort.AnalyticsStorage.record_message_event(
          message_id,
          experiment_id,
          originating_node,
          nil,  # target_node is nil for send events
          :sent,
          timestamp,
          region
        )
    end
  end
end
