defmodule CorroPort.AckTracker do
  @moduledoc """
  Tracks acknowledgments for the latest message sent by this node.

  Features:
  - Region extraction from acknowledgments
  - Experiment ID tracking for analytics
  - Analytics event recording
  """

  use GenServer
  require Logger

  alias CorroPort.RegionExtractor

  @table_name :ack_tracker

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
  def add_acknowledgment(message_pk, ack_node_id) do
    GenServer.call(__MODULE__, {:add_acknowledgment, message_pk, ack_node_id})
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
    Logger.info("AckTracker starting...")

    table =
      :ets.new(@table_name, [
        :set,
        :named_table,
        :public,
        read_concurrency: true
      ])

    Logger.info("AckTracker ETS table created: #{@table_name}")

    {:ok, %{table: table, experiment_id: nil}}
  end

  def handle_call({:track_latest_message, message_data}, _from, state) do
    Logger.info("AckTracker: Tracking new message #{message_data.pk}")

    message_pk = message_data.pk
    experiment_id =
      Map.get(message_data, :experiment_id) ||
        state.experiment_id

    tracked_message =
      message_data
      |> Map.put(:tracked_at, DateTime.utc_now())
      |> Map.put(:experiment_id, experiment_id)

    # Update the latest message pointer and reset acknowledgments for this message
    :ets.insert(@table_name, {:latest_message, message_pk})
    clear_acknowledgments(message_pk)

    # Store message metadata so acknowledgments can be matched even if newer messages are tracked
    :ets.insert(@table_name, {{:message, message_pk}, tracked_message})

    prune_old_messages()

    # Broadcast the update
    broadcast_update()

    {:reply, :ok, state}
  end

  def handle_call({:add_acknowledgment, message_pk, ack_node_id}, _from, state) do
    current_time = DateTime.utc_now()

    Logger.info("AckTracker: Adding acknowledgment from #{ack_node_id}")

    ack_key = {:ack, message_pk, ack_node_id}

    case :ets.lookup(@table_name, {:message, message_pk}) do
      [{{:message, ^message_pk}, message_data}] ->
        case :ets.lookup(@table_name, ack_key) do
          [{^ack_key, _existing}] ->
            Logger.info(
              "AckTracker: Duplicate acknowledgment from #{ack_node_id} for #{message_pk}; ignoring"
            )

            {:reply, :ok, state}

          [] ->
            ack_value = %{timestamp: current_time, node_id: ack_node_id}

            :ets.insert(@table_name, {ack_key, ack_value})

            record_ack_event(
              message_pk,
              message_data.node_id,
              ack_node_id,
              current_time,
              message_data.experiment_id
            )

            broadcast_update()
            {:reply, :ok, state}
        end

      [] ->
        Logger.warning(
          "AckTracker: Received acknowledgment for #{message_pk} but no matching message is being tracked"
        )

        {:reply, {:error, :unknown_message}, state}
    end
  end

  def handle_call(:reset_tracking, _from, state) do
    Logger.info("AckTracker: Resetting message tracking")

    # Clear the latest message
    :ets.delete(@table_name, :latest_message)

    # Clear all tracked message metadata and acknowledgments
    clear_tracked_messages()
    clear_acknowledgments()

    # Broadcast the update (this will show no message being tracked)
    broadcast_update()

    {:reply, :ok, state}
  end

  def handle_call(:get_status, _from, state) do
    status = build_status()
    {:reply, status, state}
  end

  def handle_call({:set_experiment_id, experiment_id}, _from, state) do
    Logger.info("AckTracker: Set experiment ID to #{experiment_id}")
    {:reply, :ok, %{state | experiment_id: experiment_id}}
  end

  def handle_call(:get_experiment_id, _from, state) do
    {:reply, state.experiment_id, state}
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
      8787 -> "dev-node1"
      8788 -> "dev-node2"
      8789 -> "dev-node3"
      8790 -> "dev-node4"
      8791 -> "dev-node5"
      # General formula for higher node numbers
      p when p > 8786 -> "dev-node#{p - 8786}"
      _ -> nil
    end
  end

  defp clear_tracked_messages do
    :ets.match_delete(@table_name, {{:message, :_}, :_})
  end

  @message_retention_limit 100

  defp prune_old_messages do
    message_entries = :ets.match(@table_name, {{:message, :"$1"}, :"$2"})

    if length(message_entries) > @message_retention_limit do
      message_entries
      |> Enum.map(fn [message_pk, data] ->
        tracked_at = Map.get(data, :tracked_at) || ~U[1970-01-01 00:00:00Z]
        {message_pk, tracked_at}
      end)
      |> Enum.sort_by(fn {_pk, tracked_at} -> tracked_at end, {:desc, DateTime})
      |> Enum.drop(@message_retention_limit)
      |> Enum.each(fn {message_pk, _tracked_at} ->
        :ets.delete(@table_name, {:message, message_pk})
        clear_acknowledgments(message_pk)
      end)
    end
  end

  defp clear_acknowledgments(message_pk \\ :all)

  defp clear_acknowledgments(:all) do
    :ets.match_delete(@table_name, {{:ack, :_, :_}, :_})
  end

  defp clear_acknowledgments(message_pk) do
    :ets.match_delete(@table_name, {{:ack, message_pk, :_}, :_})
  end

  defp build_status do
    latest_message =
      case :ets.lookup(@table_name, :latest_message) do
        [{:latest_message, message_pk}] ->
          case :ets.lookup(@table_name, {:message, message_pk}) do
            [{{:message, ^message_pk}, message_data}] -> message_data
            _ -> nil
          end

        [] ->
          nil
      end

    {acknowledgments, regions} =
      case latest_message do
        %{pk: message_pk} ->
          ack_pattern = {{:ack, message_pk, :"$1"}, :"$2"}
          ack_matches = :ets.match(@table_name, ack_pattern)

          acks =
            ack_matches
            |> Enum.map(fn [node_id, ack_data] ->
              %{
                node_id: node_id,
                timestamp: ack_data.timestamp
              }
            end)
            |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})

          {acks, RegionExtractor.extract_from_acks(acks)}

        _ ->
          {[], []}
      end

    Logger.debug(fn ->
      tracked = case latest_message do
        %{pk: pk} -> pk
        _ -> "none"
      end

      nodes = Enum.map(acknowledgments, & &1.node_id)
      "AckTracker: Found #{length(acknowledgments)} acknowledgments for #{tracked} from #{inspect(nodes)}"
    end)

    %{
      latest_message: latest_message,
      acknowledgments: acknowledgments,
      ack_count: length(acknowledgments),
      regions: regions
    }
  end

  defp broadcast_update do
    status = build_status()
    Phoenix.PubSub.broadcast(CorroPort.PubSub, "ack_events", {:ack_update, status})
  end

  defp record_ack_event(message_id, originating_node, ack_node_id, timestamp, experiment_id) do
    # Only record if we have an active experiment
    if experiment_id do
      # Extract region from ack_node_id if possible
      region = CorroPort.NodeNaming.extract_region_from_node_id(ack_node_id)

      # Record the acknowledgment event
      CorroPort.AnalyticsStorage.record_message_event(
        message_id,
        experiment_id,
        originating_node,
        # target_node is the ack sender
        ack_node_id,
        :acked,
        timestamp,
        region
      )
    else
      # No active experiment, skip analytics
      :ok
    end
  end
end
