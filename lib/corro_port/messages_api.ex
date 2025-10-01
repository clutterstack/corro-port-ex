defmodule CorroPort.MessagesAPI do
  @moduledoc """
  API for managing user data in the node_messages table.
  Now includes originating_endpoint and region fields for geographic tracking.
  """
  require Logger
  alias CorroPort.{ConnectionManager, AckTracker, AnalyticsStorage, LocalNode}

  @doc """
  Send a message and start tracking acknowledgments.

  This is the high-level API that combines:
  - Inserting the message into the database
  - Starting acknowledgment tracking
  - Recording analytics if an experiment is active

  ## Parameters
  - `content`: Message content to send

  ## Returns
  - `{:ok, message_data}` on success
  - `{:error, reason}` on failure
  """
  def send_and_track_message(content) do
    local_node_id = LocalNode.get_node_id()
    message_content = "#{content} (from #{local_node_id} at #{DateTime.utc_now() |> DateTime.to_iso8601()})"
    send_timestamp = DateTime.utc_now()

    case insert_message(local_node_id, message_content) do
      {:ok, result} ->
        Logger.info("MessagesAPI: Successfully sent message: #{inspect(result)}")

        # Track this message for acknowledgments
        message_pk = "#{local_node_id}_#{result.sequence}"

        track_message_data = %{
          pk: message_pk,
          timestamp: result.timestamp,
          node_id: result.node_id
        }

        case AckTracker.track_latest_message(track_message_data) do
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

            {:ok, message_data}

          {:error, reason} ->
            Logger.warning("MessagesAPI: Failed to track message: #{inspect(reason)}")
            {:error, {:tracking_failed, reason}}
        end

      {:error, reason} ->
        Logger.warning("MessagesAPI: Failed to send message: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Inserts a new message into the node_messages table with originating endpoint and region.

  ## Parameters
  - `node_id`: Identifier for the node sending the message
  - `message`: Message content

  ## Returns
  - `{:ok, message_data}` on success with inserted message details
  - `{:error, reason}` on failure
  """
  def insert_message(node_id, message) do
    sequence = System.system_time(:millisecond)
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    {originating_endpoint, region} = get_originating_endpoint_and_region()

    sql = """
    INSERT INTO node_messages (pk, node_id, message, sequence, timestamp, originating_endpoint, region)
    VALUES ('#{node_id}_#{sequence}', '#{node_id}', '#{message}', #{sequence}, '#{timestamp}', '#{originating_endpoint}', '#{region}')
    """

    Logger.debug(
      "Inserting: node_id=#{node_id}, message=#{message}, originating_endpoint=#{originating_endpoint}, region=#{region}"
    )

    conn = ConnectionManager.get_connection()
    case CorroClient.transaction(conn, [sql]) do
      {:ok, _response} ->
        {:ok,
         %{
           node_id: node_id,
           message: message,
           sequence: sequence,
           timestamp: timestamp,
           originating_endpoint: originating_endpoint,
           region: region
         }}

      error ->
        error
    end
  end

  @doc """
  Gets all messages from the node_messages table, ordered by timestamp.
  """
  def get_node_messages do
    query = "SELECT * FROM node_messages ORDER BY timestamp DESC"
    conn = ConnectionManager.get_connection()
    case CorroClient.query(conn, query) do
      {:ok, results} -> {:ok, results}
      error -> error
    end
  end

  @doc """
  Gets the latest message for each node from the node_messages table.
  """
  def get_latest_node_messages() do
    query = """
    SELECT message, node_id, timestamp, sequence, originating_endpoint, region
    FROM node_messages
    WHERE (node_id, timestamp) IN (
      SELECT node_id, MAX(timestamp)
      FROM node_messages
      GROUP BY node_id
    )
    ORDER BY timestamp DESC
    """
    conn = ConnectionManager.get_connection()
    case CorroClient.query(conn, query) do
      {:ok, results} -> {:ok, results}
      error -> error
    end
  end

  @doc """
  Gets active regions from recent node messages.
  Returns a list of region codes for nodes that have sent messages recently.
  """
  def get_active_regions(minutes_ago \\ 60) do
    cutoff_time = DateTime.add(DateTime.utc_now(), -minutes_ago, :minute) |> DateTime.to_iso8601()

    query = """
    SELECT DISTINCT region
    FROM node_messages
    WHERE timestamp > '#{cutoff_time}'
    AND region != 'unknown'
    AND region != ''
    ORDER BY region
    """

    conn = ConnectionManager.get_connection()
    case CorroClient.query(conn, query) do
      {:ok, result} ->
        regions =
          result
          |> Enum.map(&Map.get(&1, "region"))
          |> Enum.reject(&is_nil/1)
        {:ok, regions}

      error ->
        Logger.warning("Failed to get active regions: #{inspect(error)}")
        {:ok, []}
    end
  end

  @doc """
  Gets messages from a specific region.
  """
  def get_messages_by_region(region) do
    query = "SELECT * FROM node_messages WHERE region = '#{region}' ORDER BY timestamp DESC"
    conn = ConnectionManager.get_connection()
    case CorroClient.query(conn, query) do
      {:ok, results} -> {:ok, results}
      error -> error
    end
  end

  # Private functions

  defp get_originating_endpoint_and_region do
    node_config = CorroPort.NodeConfig.app_node_config()
    region = get_current_region(node_config)

    endpoint =
      case node_config[:environment] do
        :prod ->
          # In production, use the fly.io private IP with API port
          private_ip = node_config[:private_ip] || node_config[:fly_private_ip] || "127.0.0.1"
          ack_api_port = node_config[:ack_api_port] || 8081

          if String.contains?(private_ip, ":") do
            # IPv6 address, wrap in brackets
            "[#{private_ip}]:#{ack_api_port}"
          else
            # IPv4 address
            "#{private_ip}:#{ack_api_port}"
          end

        _ ->
          # In development, use localhost with calculated API port
          ack_api_port = node_config[:ack_api_port] || 5000 + (node_config[:node_id] || 1)
          "127.0.0.1:#{ack_api_port}"
      end

    {endpoint, region}
  end

  defp get_current_region(node_config) do
    case node_config[:environment] do
      :prod ->
        # In production, get from config or environment
        node_config[:fly_region] || System.get_env("FLY_REGION") || "unknown"

      _ ->
        # In development
        "dev"
    end
  end

  @doc """
  Cleanup function to remove malformed messages from the node_messages table.
  """
  def cleanup_bad_messages() do
    cleanup_sql = """
    DELETE FROM node_messages
    WHERE message IN ('8081', '8082', '8083', '8084', '8085')
    """

    conn = ConnectionManager.get_connection()
    case CorroClient.transaction(conn, [cleanup_sql]) do
      {:ok, _} ->
        Logger.info("Cleaned up malformed messages")
        {:ok, :cleaned}

      error ->
        Logger.warning("Failed to cleanup messages: #{inspect(error)}")
        error
    end
  end

  defp record_send_event(message_id, originating_node, timestamp, region) do
    # Only record if AckTracker has an active experiment
    case AckTracker.get_experiment_id() do
      nil ->
        # No active experiment, skip analytics
        :ok

      experiment_id ->
        # Record the send event
        AnalyticsStorage.record_message_event(
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
