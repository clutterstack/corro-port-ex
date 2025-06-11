defmodule CorroPort.AcknowledgmentTracker do
  @moduledoc """
  Tracks acknowledgments for the latest message sent by this node.

  Uses ETS for fast local storage. Only tracks one message at a time
  (the most recent one sent via the "Send Message" button).

  ETS table structure:
  - {:latest_message, %{pk: "message_pk", timestamp: "iso8601", node_id: "node1"}}
  - {"ack", ack_node_id, ack_timestamp}
  """

  use GenServer
  require Logger

  @table_name :acknowledgment_tracker
  @pubsub_topic "acknowledgment_updates"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track a new message as the "latest" message that we're expecting acknowledgments for.
  Clears any previous acknowledgments.

  ## Parameters
  - message_data: Map with keys :pk, :timestamp, :node_id
  """
  def track_latest_message(message_data) do
    GenServer.call(__MODULE__, {:track_latest_message, message_data})
  end

  @doc """
  Add an acknowledgment from another node for the current latest message.

  ## Parameters
  - ack_node_id: String identifier of the acknowledging node
  """
  def add_acknowledgment(ack_node_id) do
    GenServer.call(__MODULE__, {:add_acknowledgment, ack_node_id})
  end

  @doc """
  Get the current tracking status including latest message and all acknowledgments.

  ## Returns
  %{
    latest_message: %{pk: ..., timestamp: ..., node_id: ...} | nil,
    acknowledgments: [%{node_id: ..., timestamp: ...}],
    expected_nodes: [...],
    ack_count: integer,
    expected_count: integer
  }
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Get the list of nodes we expect acknowledgments from.
  Currently based on a simple calculation from node configuration.
  """
  def get_expected_nodes do
    GenServer.call(__MODULE__, :get_expected_nodes)
  end

  @doc """
  Clear all tracking data (useful for testing).
  """
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  def get_pubsub_topic, do: @pubsub_topic

  # GenServer Implementation

  def init(_opts) do
    Logger.info("AcknowledgmentTracker starting...")

    # Create ETS table
    table = :ets.new(@table_name, [
      :set,
      :named_table,
      :public,
      read_concurrency: true
    ])

    Logger.info("AcknowledgmentTracker ETS table created: #{@table_name}")

    {:ok, %{table: table}}
  end

  def handle_call({:track_latest_message, message_data}, _from, state) do
    Logger.info("AcknowledgmentTracker: Tracking new message #{message_data.pk}")

    # Clear previous acknowledgments
    clear_acknowledgments()

    # Store the latest message
    :ets.insert(@table_name, {:latest_message, message_data})

    # Broadcast the update
    broadcast_update()

    {:reply, :ok, state}
  end

  def handle_call({:add_acknowledgment, ack_node_id}, _from, state) do
    current_time = DateTime.utc_now()

    Logger.info("AcknowledgmentTracker: Adding acknowledgment from #{ack_node_id}")

    # Check if we have a latest message to acknowledge
    case :ets.lookup(@table_name, :latest_message) do
      [{:latest_message, _message_data}] ->
        # Add the acknowledgment
        :ets.insert(@table_name, {"ack", ack_node_id, current_time})

        # Broadcast the update
        broadcast_update()

        {:reply, :ok, state}

      [] ->
        Logger.warning("AcknowledgmentTracker: Received acknowledgment from #{ack_node_id} but no latest message is being tracked")
        {:reply, {:error, :no_message_tracked}, state}
    end
  end

  def handle_call(:get_status, _from, state) do
    status = build_status()
    {:reply, status, state}
  end

  def handle_call(:get_expected_nodes, _from, state) do
    expected_nodes = calculate_expected_nodes()
    {:reply, expected_nodes, state}
  end

  def handle_call(:clear_all, _from, state) do
    Logger.info("AcknowledgmentTracker: Clearing all data")
    :ets.delete_all_objects(@table_name)
    broadcast_update()
    {:reply, :ok, state}
  end

  def terminate(_reason, _state) do
    Logger.info("AcknowledgmentTracker shutting down")
    :ok
  end

  # Private Functions

  defp clear_acknowledgments do
    # Delete all acknowledgment entries (those starting with "ack")
    :ets.match_delete(@table_name, {"ack", :_, :_})
  end

  defp build_status do
    # Get latest message
    latest_message = case :ets.lookup(@table_name, :latest_message) do
      [{:latest_message, message_data}] -> message_data
      [] -> nil
    end

    # Get all acknowledgments
    ack_pattern = {"ack", :"$1", :"$2"}
    ack_matches = :ets.match(@table_name, ack_pattern)

    acknowledgments = Enum.map(ack_matches, fn [node_id, timestamp] ->
      %{
        node_id: node_id,
        timestamp: timestamp
      }
    end)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})

    expected_nodes = calculate_expected_nodes()

    %{
      latest_message: latest_message,
      acknowledgments: acknowledgments,
      expected_nodes: expected_nodes,
      ack_count: length(acknowledgments),
      expected_count: length(expected_nodes)
    }
  end

  defp calculate_expected_nodes do
    # For now, use a simple approach: assume nodes 1-3 exist, exclude ourselves
    local_node_config = Application.get_env(:corro_port, :node_config, %{node_id: 1})
    local_node_id = local_node_config[:node_id] || 1

    # Generate expected node IDs (exclude our own node)
    all_node_ids = [1, 2, 3]
    expected_node_ids = Enum.reject(all_node_ids, fn id -> id == local_node_id end)

    # Convert to node_id strings like "node1", "node2" etc
    Enum.map(expected_node_ids, fn id -> "node#{id}" end)
  end

  defp broadcast_update do
    status = build_status()
    Phoenix.PubSub.broadcast(
      CorroPort.PubSub,
      @pubsub_topic,
      {:acknowledgment_update, status}
    )
  end
end
