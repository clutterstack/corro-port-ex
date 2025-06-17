defmodule CorroPort.AckTracker do
  @moduledoc """
  Tracks acknowledgments for the latest message sent by this node.

  Uses DNS-based node discovery to get the authoritative list of cluster nodes
  from Fly.io's DNS TXT records. Much simpler than the previous fallback-heavy approach.
  """

  use GenServer
  require Logger

  @table_name :ack_tracker
  @pubsub_topic "ack_events"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track a new message as the "latest" message expecting acknowledgments.
  Clears any previous acknowledgments and gets expected nodes from DNS.
  """
  def track_latest_message(message_data) do
    GenServer.call(__MODULE__, {:track_latest_message, message_data})
  end

  @doc """
  Add an acknowledgment from another node for the current latest message.
  """
  def add_acknowledgment(ack_node_id) do
    GenServer.call(__MODULE__, {:add_acknowledgment, ack_node_id})
  end

  @doc """
  Get the current tracking status.
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Get the list of nodes we expect acknowledgments from.
  """
  def get_expected_nodes do
    GenServer.call(__MODULE__, :get_expected_nodes)
  end

  @doc """
  Force refresh of expected nodes from DNS.
  """
  def refresh_expected_nodes do
    GenServer.cast(__MODULE__, :refresh_expected_nodes)
  end

  def get_pubsub_topic, do: @pubsub_topic

  # GenServer Implementation

  def init(_opts) do
    Logger.info("AckTracker starting...")

    table =
      :ets.new(@table_name, [
        :set,
        :named_table,
        :public,
        read_concurrency: true
      ])

    # Initialize with empty expected nodes - will be populated on first message
    :ets.insert(@table_name, {:expected_nodes, []})

    Logger.info("AckTracker ETS table created: #{@table_name}")

    {:ok, %{table: table}}
  end

  def handle_call({:track_latest_message, message_data}, _from, state) do
    Logger.info("AckTracker: Tracking new message #{message_data.pk}")

    # Clear previous acknowledgments
    clear_acknowledgments()

    # Store the latest message
    :ets.insert(@table_name, {:latest_message, message_data})

    # Get expected nodes from DNS
    case CorroPort.DNSNodeDiscovery.get_expected_nodes() do
      {:ok, expected_nodes} ->
        :ets.insert(@table_name, {:expected_nodes, expected_nodes})
        Logger.info("AckTracker: Expected acknowledgments from #{length(expected_nodes)} nodes: #{inspect(expected_nodes)}")

      {:error, reason} ->
        Logger.warning("AckTracker: Failed to get expected nodes from DNS: #{inspect(reason)}")
        # Set empty list - it's fine if we don't track any expected nodes
        :ets.insert(@table_name, {:expected_nodes, []})
    end

    # Broadcast the update
    broadcast_update()

    {:reply, :ok, state}
  end

  def handle_call({:add_acknowledgment, ack_node_id}, _from, state) do
    current_time = DateTime.utc_now()

    Logger.info("AckTracker: Adding acknowledgment from #{ack_node_id}")

    case :ets.lookup(@table_name, :latest_message) do
      [{:latest_message, _message_data}] ->
        ack_key = {:ack, ack_node_id}
        ack_value = %{timestamp: current_time, node_id: ack_node_id}

        :ets.insert(@table_name, {ack_key, ack_value})
        broadcast_update()

        {:reply, :ok, state}

      [] ->
        Logger.warning(
          "AckTracker: Received acknowledgment from #{ack_node_id} but no latest message is being tracked"
        )

        {:reply, {:error, :no_message_tracked}, state}
    end
  end

  def handle_call(:get_status, _from, state) do
    status = build_status()
    {:reply, status, state}
  end

  def handle_call(:get_expected_nodes, _from, state) do
    expected_nodes = get_cached_expected_nodes()
    {:reply, expected_nodes, state}
  end

  def handle_cast(:refresh_expected_nodes, state) do
    Logger.info("AckTracker: Manual refresh of expected nodes requested")

    # Trigger DNS cache refresh
    CorroPort.DNSNodeDiscovery.refresh_cache()

    # Update our expected nodes
    case CorroPort.DNSNodeDiscovery.get_expected_nodes() do
      {:ok, expected_nodes} ->
        :ets.insert(@table_name, {:expected_nodes, expected_nodes})
        Logger.info("AckTracker: Updated expected nodes: #{inspect(expected_nodes)}")
        broadcast_update()

      {:error, reason} ->
        Logger.warning("AckTracker: Failed to refresh expected nodes: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def terminate(_reason, _state) do
    Logger.info("AckTracker shutting down")
    :ok
  end

  # Private Functions

  defp clear_acknowledgments do
    :ets.match_delete(@table_name, {{:ack, :_}, :_})
  end

  defp build_status do
    # Get latest message
    latest_message =
      case :ets.lookup(@table_name, :latest_message) do
        [{:latest_message, message_data}] -> message_data
        [] -> nil
      end

    # Get all acknowledgments
    ack_pattern = {{:ack, :"$1"}, :"$2"}
    ack_matches = :ets.match(@table_name, ack_pattern)

    acknowledgments =
      Enum.map(ack_matches, fn [node_id, ack_data] ->
        %{
          node_id: node_id,
          timestamp: ack_data.timestamp
        }
      end)
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})

    expected_nodes = get_cached_expected_nodes()

    Logger.debug(
      "AckTracker: Found #{length(acknowledgments)} acknowledgments from #{inspect(Enum.map(acknowledgments, & &1.node_id))}"
    )

    %{
      latest_message: latest_message,
      acknowledgments: acknowledgments,
      expected_nodes: expected_nodes,
      ack_count: length(acknowledgments),
      expected_count: length(expected_nodes)
    }
  end

  defp get_cached_expected_nodes do
    case :ets.lookup(@table_name, :expected_nodes) do
      [{:expected_nodes, nodes}] -> nodes
      [] -> []
    end
  end

  defp broadcast_update do
    status = build_status()
    Phoenix.PubSub.broadcast(CorroPort.PubSub, @pubsub_topic, {:ack_update, status})
  end
end
