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
  Clears any previous acknowledgments
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
  Reset tracking - clears the latest message and all acknowledgments.
  This will cause all nodes to show as "expected" (orange) again.
  """
  def reset_tracking do
    GenServer.call(__MODULE__, :reset_tracking)
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
  def get_dns_nodes do
    GenServer.call(__MODULE__, :get_dns_nodes)
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
        Logger.warning(
          "AckTracker: Received acknowledgment from #{ack_node_id} but no latest message is being tracked"
        )

        {:reply, {:error, :no_message_tracked}, state}
    end
  end

  def handle_call(:reset_tracking, _from, state) do
    Logger.info("AckTracker: Resetting message tracking")

    # Clear the latest message
    :ets.delete(@table_name, :latest_message)

    # Clear all acknowledgments
    clear_acknowledgments()

    # Broadcast the update (this will show no message being tracked)
    broadcast_update()

    {:reply, :ok, state}
  end

  def handle_call(:get_status, _from, state) do
    status = build_status()
    {:reply, status, state}
  end

  def terminate(_reason, _state) do
    Logger.info("AckTracker shutting down")
    :ok
  end

  def member_to_node_id(member) do
    if is_map(member) do
      if CorroPort.NodeConfig.production?() do
        production_member_to_node_id(member)
      else
        development_member_to_node_id(member)
      end
    else
      Logger.warning("AckTracker.member_to_node_id: member has to be a map")
      ""
    end
  end

  # Private Functions

  defp production_member_to_node_id(member) do
    # In production, we can't easily map gossip addresses back to machine IDs
    # since machine IDs are UUIDs like "91851e13e45e58"
    # For now, we'll use the gossip address IP as a unique identifier
    case Map.get(member, "display_addr") || get_in(member, ["state", "addr"]) do
      addr when is_binary(addr) ->
        case String.split(addr, ":") do
          [ip, _port] ->
            # Use the last part of the IPv6 address as a readable identifier
            case String.split(ip, ":") do
              parts when length(parts) > 1 ->
                # Take last 2 parts of IPv6 address
                suffix = parts |> Enum.take(-2) |> Enum.join(":")
                "machine-#{suffix}"

              _ ->
                "machine-#{ip}"
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp development_member_to_node_id(member) do
    # In development, extract node ID from the member's gossip address
    case Map.get(member, "display_addr") || get_in(member, ["state", "addr"]) do
      addr when is_binary(addr) ->
        case String.split(addr, ":") do
          [_ip, port_str] ->
            case Integer.parse(port_str) do
              {port, _} -> gossip_port_to_node_id(port)
              _ -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  # Convert gossip port to node ID using our standard mapping (development only)
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

    Logger.debug(
      "AckTracker: Found #{length(acknowledgments)} acknowledgments from #{inspect(Enum.map(acknowledgments, & &1.node_id))}"
    )

    %{
      latest_message: latest_message,
      acknowledgments: acknowledgments,
      ack_count: length(acknowledgments),
    }
  end

  defp broadcast_update do
    status = build_status()
    Phoenix.PubSub.broadcast(CorroPort.PubSub, @pubsub_topic, {:ack_update, status})
  end
end
