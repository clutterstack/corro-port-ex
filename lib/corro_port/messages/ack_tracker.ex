defmodule CorroPort.AckTracker do
  @moduledoc """
  Tracks acknowledgments for the latest message sent by this node.

  Uses ETS for fast local storage. Only tracks one message at a time
  (the most recent one sent via the "Send Message" button).

  ETS table structure:
  - {:latest_message, %{pk: "message_pk", timestamp: "iso8601", node_id: "node1"}}
  - {:ack, ack_node_id, %{timestamp: timestamp, node_id: ack_node_id}}
  """

  use GenServer
  require Logger

  @table_name :ack_tracker
  @pubsub_topic "ack_updates"

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
    Logger.info("AckTracker starting...")

    # Create ETS table
    table =
      :ets.new(@table_name, [
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

    # Check if we have a latest message to acknowledge
    case :ets.lookup(@table_name, :latest_message) do
      [{:latest_message, _message_data}] ->
        # Add the acknowledgment with node_id as part of the key
        # This ensures each node can only have one acknowledgment entry
        ack_key = {:ack, ack_node_id}
        ack_value = %{timestamp: current_time, node_id: ack_node_id}

        Logger.info(
          "AckTracker: Inserting ETS entry: #{inspect(ack_key)} -> #{inspect(ack_value)}"
        )

        :ets.insert(@table_name, {ack_key, ack_value})

        # Debug: Show all current acknowledgments in ETS
        all_acks = :ets.match(@table_name, {{:ack, :"$1"}, :"$2"})
        Logger.info("AckTracker: All acknowledgments in ETS: #{inspect(all_acks)}")

        # Broadcast the update
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
    expected_nodes = calculate_expected_nodes()
    {:reply, expected_nodes, state}
  end

  def handle_call(:clear_all, _from, state) do
    Logger.info("AckTracker: Clearing all data")
    :ets.delete_all_objects(@table_name)
    broadcast_update()
    {:reply, :ok, state}
  end

  def terminate(_reason, _state) do
    Logger.info("AckTracker shutting down")
    :ok
  end

  # Private Functions

  defp clear_acknowledgments do
    # Delete all acknowledgment entries (those with {:ack, _} as key)
    :ets.match_delete(@table_name, {{:ack, :_}, :_})
  end

  defp build_status do
    # Get latest message
    latest_message =
      case :ets.lookup(@table_name, :latest_message) do
        [{:latest_message, message_data}] -> message_data
        [] -> nil
      end

    # Get all acknowledgments - now using the corrected pattern
    ack_pattern = {{:ack, :"$1"}, :"$2"}
    ack_matches = :ets.match(@table_name, ack_pattern)

    Logger.debug("AckTracker: Raw ETS matches: #{inspect(ack_matches)}")

    acknowledgments =
      Enum.map(ack_matches, fn [node_id, ack_data] ->
        %{
          node_id: node_id,
          timestamp: ack_data.timestamp
        }
      end)
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})

    expected_nodes = calculate_expected_nodes()

    Logger.info(
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

  defp calculate_expected_nodes do
    # Get the local node's configuration
    local_node_config = Application.get_env(:corro_port, :node_config, %{node_id: 1})
    local_node_id = local_node_config[:node_id] || 1
    local_node_string = "node#{local_node_id}"

    # Try to get cluster members to determine expected nodes dynamically
    case CorroPort.ClusterAPI.get_cluster_members() do
      {:ok, members} ->
        # Extract active nodes from cluster members
        active_ports =
          members
          |> Enum.filter(fn member ->
            Map.get(member, "member_state") == "Alive"
          end)
          |> Enum.map(fn member ->
            case Map.get(member, "member_addr") do
              addr when is_binary(addr) ->
                case String.split(addr, ":") do
                  [_ip, port_str] ->
                    case Integer.parse(port_str) do
                      {port, _} -> port
                      _ -> nil
                    end

                  _ ->
                    nil
                end

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        # Convert gossip ports to node IDs (8787 -> node1, 8788 -> node2, etc)
        expected_node_ids =
          active_ports
          |> Enum.map(fn port -> "node#{port - 8786}" end)
          # Exclude ourselves
          |> Enum.reject(fn node_id -> node_id == local_node_string end)
          |> Enum.sort()

        Logger.debug(
          "AckTracker: Calculated expected nodes from cluster: #{inspect(expected_node_ids)}"
        )

        expected_node_ids

      {:error, reason} ->
        Logger.warning(
          "AckTracker: Could not get cluster members (#{inspect(reason)}), falling back to static list"
        )

        # Fallback to the old hardcoded approach
        # Include node 4 in fallback
        all_node_ids = [1, 2, 3, 4]
        expected_node_ids = Enum.reject(all_node_ids, fn id -> id == local_node_id end)
        Enum.map(expected_node_ids, fn id -> "node#{id}" end)
    end
  end

  defp broadcast_update do
    status = build_status()

    Phoenix.PubSub.broadcast(
      CorroPort.PubSub,
      @pubsub_topic,
      {:ack_update, status}
    )
  end
end
