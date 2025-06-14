defmodule CorroPort.AckTracker do
  @moduledoc """
  Tracks acknowledgments for the latest message sent by this node.

  Simplified version that only tracks one message at a time and uses
  simple port-based node discovery.
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
  Clears any previous acknowledgments.
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

  def get_pubsub_topic, do: @pubsub_topic

  # GenServer Implementation

  def init(_opts) do
    Logger.info("AckTracker starting...")

    table = :ets.new(@table_name, [
      :set,
      :named_table,
      :public,
      read_concurrency: true
    ])

    Logger.info("AckTracker ETS table created: #{@table_name}")
    {:ok, %{table: table}}
  end

  def handle_call({:track_latest_message, message_data}, _from, state) do
    Logger.info("AckTracker: Tracking new message #{message_data.pk}")

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

    Logger.info("AckTracker: Adding acknowledgment from #{ack_node_id}")

    case :ets.lookup(@table_name, :latest_message) do
      [{:latest_message, _message_data}] ->
        ack_key = {:ack, ack_node_id}
        ack_value = %{timestamp: current_time, node_id: ack_node_id}

        :ets.insert(@table_name, {ack_key, ack_value})
        broadcast_update()

        {:reply, :ok, state}

      [] ->
        Logger.warning("AckTracker: Received acknowledgment from #{ack_node_id} but no latest message is being tracked")
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
    latest_message = case :ets.lookup(@table_name, :latest_message) do
      [{:latest_message, message_data}] -> message_data
      [] -> nil
    end

    # Get all acknowledgments
    ack_pattern = {{:ack, :"$1"}, :"$2"}
    ack_matches = :ets.match(@table_name, ack_pattern)

    acknowledgments = Enum.map(ack_matches, fn [node_id, ack_data] ->
      %{
        node_id: node_id,
        timestamp: ack_data.timestamp
      }
    end)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})

    expected_nodes = calculate_expected_nodes()

    Logger.debug("AckTracker: Found #{length(acknowledgments)} acknowledgments from #{inspect(Enum.map(acknowledgments, & &1.node_id))}")

    %{
      latest_message: latest_message,
      acknowledgments: acknowledgments,
      expected_nodes: expected_nodes,
      ack_count: length(acknowledgments),
      expected_count: length(expected_nodes)
    }
  end

  defp calculate_expected_nodes do
    local_node_config = Application.get_env(:corro_port, :node_config, %{node_id: 1})
    local_node_id = local_node_config[:node_id] || 1
    local_node_string = "node#{local_node_id}"

    # Simple MVP approach: try cluster members first, fallback to hardcoded
    case try_cluster_based_discovery(local_node_string) do
      {:ok, nodes} when length(nodes) > 0 ->
        Logger.debug("AckTracker: Using cluster-based node discovery: #{inspect(nodes)}")
        nodes
      _ ->
        Logger.debug("AckTracker: Using fallback node discovery")
        fallback_node_discovery(local_node_id)
    end
  end

  defp try_cluster_based_discovery(local_node_string) do
    case CorroPort.ClusterAPI.get_cluster_members() do
      {:ok, members} ->
        active_nodes = members
        |> Enum.filter(fn member ->
          Map.get(member, "member_state") == "Alive"
        end)
        |> Enum.map(fn member ->
          case Map.get(member, "member_addr") do
            addr when is_binary(addr) ->
              case String.split(addr, ":") do
                [_ip, port_str] ->
                  case Integer.parse(port_str) do
                    {port, _} -> gossip_port_to_node_id(port)
                    _ -> nil
                  end
                _ -> nil
              end
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(fn node_id -> node_id == local_node_string end)
        |> Enum.sort()

        {:ok, active_nodes}

      {:error, reason} ->
        Logger.debug("AckTracker: Could not get cluster members: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fallback_node_discovery(local_node_id) do
    # Hardcoded fallback - assume 3 nodes for now
    all_node_ids = [1, 2, 3]
    expected_node_ids = Enum.reject(all_node_ids, fn id -> id == local_node_id end)
    Enum.map(expected_node_ids, fn id -> "node#{id}" end)
  end

  # Simple port-based mapping for MVP
  defp gossip_port_to_node_id(port) do
    case port do
      8787 -> "node1"
      8788 -> "node2"
      8789 -> "node3"
      8790 -> "node4"
      _ -> "node#{port - 8786}"  # General formula
    end
  end

  defp broadcast_update do
    status = build_status()
    Phoenix.PubSub.broadcast(CorroPort.PubSub, @pubsub_topic, {:ack_update, status})
  end
end
