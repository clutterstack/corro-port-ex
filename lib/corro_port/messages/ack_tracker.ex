defmodule CorroPort.AckTracker do
  @moduledoc """
  Tracks acknowledgments for the latest message sent by this node.

  Uses CLI-based node discovery via `corrosion cluster members` for more
  accurate and up-to-date cluster membership information.
  """

  use GenServer
  require Logger

  @table_name :ack_tracker
  @pubsub_topic "ack_events"
  @cli_timeout 3_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track a new message as the "latest" message expecting acknowledgments.
  Clears any previous acknowledgments and refreshes expected nodes.
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
  Force refresh of expected nodes from CLI.
  """
  def refresh_expected_nodes do
    GenServer.call(__MODULE__, :refresh_expected_nodes)
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

    # Cache expected nodes on startup
    initial_expected_nodes = fetch_expected_nodes_via_cli()
    :ets.insert(@table_name, {:expected_nodes, initial_expected_nodes})

    Logger.info("AckTracker ETS table created: #{@table_name}")
    Logger.info("AckTracker initial expected nodes: #{inspect(initial_expected_nodes)}")

    {:ok, %{table: table, last_cli_fetch: DateTime.utc_now()}}
  end

  def handle_call({:track_latest_message, message_data}, _from, state) do
    Logger.info("AckTracker: Tracking new message #{message_data.pk}")

    # Clear previous acknowledgments
    clear_acknowledgments()

    # Store the latest message
    :ets.insert(@table_name, {:latest_message, message_data})

    # Refresh expected nodes when tracking a new message
    expected_nodes = fetch_expected_nodes_via_cli()
    :ets.insert(@table_name, {:expected_nodes, expected_nodes})

    Logger.info("AckTracker: Updated expected nodes: #{inspect(expected_nodes)}")

    # Broadcast the update
    broadcast_update()

    new_state = %{state | last_cli_fetch: DateTime.utc_now()}
    {:reply, :ok, new_state}
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
    expected_nodes = get_cached_expected_nodes()
    {:reply, expected_nodes, state}
  end

  def handle_call(:refresh_expected_nodes, _from, state) do
    Logger.info("AckTracker: Manual refresh of expected nodes requested")

    expected_nodes = fetch_expected_nodes_via_cli()
    :ets.insert(@table_name, {:expected_nodes, expected_nodes})

    Logger.info("AckTracker: Refreshed expected nodes: #{inspect(expected_nodes)}")
    broadcast_update()

    new_state = %{state | last_cli_fetch: DateTime.utc_now()}
    {:reply, expected_nodes, new_state}
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

    expected_nodes = get_cached_expected_nodes()

    Logger.debug("AckTracker: Found #{length(acknowledgments)} acknowledgments from #{inspect(Enum.map(acknowledgments, & &1.node_id))}")

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

  defp fetch_expected_nodes_via_cli do
    Logger.debug("AckTracker: Fetching expected nodes via CLI")

    case CorroPort.CorrosionCLI.cluster_members(timeout: @cli_timeout) do
      {:ok, raw_output} ->
        case CorroPort.CorrosionParser.parse_cluster_members(raw_output) do
          {:ok, members} ->
            active_nodes = extract_active_node_ids(members)
            Logger.debug("AckTracker: CLI returned #{length(members)} members, #{length(active_nodes)} active")
            active_nodes

          {:error, parse_error} ->
            Logger.warning("AckTracker: Failed to parse CLI output: #{inspect(parse_error)}")
            fallback_node_discovery()
        end

      {:error, cli_error} ->
        Logger.warning("AckTracker: CLI command failed: #{inspect(cli_error)}")
        fallback_node_discovery()
    end
  end

  defp extract_active_node_ids(members) when is_list(members) do
    local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

    active_node_ids = members
    |> Enum.filter(&is_active_member?/1)
    |> Enum.map(&member_to_node_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(fn node_id -> node_id == local_node_id end)
    |> Enum.sort()

    Logger.debug("AckTracker: Extracted active node IDs: #{inspect(active_node_ids)} (excluding local: #{local_node_id})")
    active_node_ids
  end

  defp extract_active_node_ids(_), do: []

  defp is_active_member?(member) when is_map(member) do
    # Use the parser's built-in active check
    CorroPort.CorrosionParser.active_member?(member)
  end

  defp member_to_node_id(member) when is_map(member) do
    # Extract node ID from the member's gossip address
    case Map.get(member, "display_addr") || get_in(member, ["state", "addr"]) do
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
  end

  # Convert gossip port to node ID using our standard mapping
  defp gossip_port_to_node_id(port) do
    case port do
      8787 -> "node1"
      8788 -> "node2"
      8789 -> "node3"
      8790 -> "node4"
      8791 -> "node5"
      # General formula for higher node numbers
      p when p > 8786 -> "node#{p - 8786}"
      _ -> nil
    end
  end

  defp fallback_node_discovery do
    Logger.info("AckTracker: Using fallback node discovery")

    # Get our local node configuration
    local_node_config = Application.get_env(:corro_port, :node_config, %{node_id: 1})
    local_node_id = local_node_config[:node_id] || 1
    local_node_string = "node#{local_node_id}"

    # Try to determine cluster size from bootstrap configuration
    bootstrap_list = local_node_config[:corrosion_bootstrap_list] || "[]"

    # Parse bootstrap list to estimate cluster size
    estimated_cluster_size = case extract_ports_from_bootstrap(bootstrap_list) do
      ports when length(ports) > 0 ->
        # Add 1 for the local node
        length(ports) + 1
      _ ->
        # Default fallback: assume 3-node cluster
        3
    end

    Logger.debug("AckTracker: Estimated cluster size: #{estimated_cluster_size}")

    # Generate expected node IDs
    all_node_ids = 1..estimated_cluster_size |> Enum.map(fn id -> "node#{id}" end)
    expected_nodes = Enum.reject(all_node_ids, fn id -> id == local_node_string end)

    Logger.info("AckTracker: Fallback generated expected nodes: #{inspect(expected_nodes)}")
    expected_nodes
  end

  defp extract_ports_from_bootstrap(bootstrap_str) when is_binary(bootstrap_str) do
    # Extract port numbers from bootstrap list like ["127.0.0.1:8788", "127.0.0.1:8789"]
    try do
      bootstrap_str
      |> String.replace(~r/[\[\]"]/, "")  # Remove brackets and quotes
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(fn addr -> String.contains?(addr, ":") end)
      |> Enum.map(fn addr ->
        case String.split(addr, ":") do
          [_ip, port_str] ->
            case Integer.parse(port_str) do
              {port, _} -> port
              _ -> nil
            end
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    rescue
      _ -> []
    end
  end

  defp extract_ports_from_bootstrap(_), do: []

  defp broadcast_update do
    status = build_status()
    Phoenix.PubSub.broadcast(CorroPort.PubSub, @pubsub_topic, {:ack_update, status})
  end
end
