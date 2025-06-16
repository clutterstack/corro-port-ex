defmodule CorroPort.MessagesAPI do
  @moduledoc """
  API for managing user data in the node_messages table.
  Now includes originating_ip field for direct node communication.
  """
  require Logger
  alias CorroPort.CorrosionClient

  @doc """
  Inserts a new message into the node_messages table with originating endpoint.

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
    originating_endpoint = get_originating_endpoint()

    sql = """
    INSERT INTO node_messages (pk, node_id, message, sequence, timestamp, originating_endpoint)
    VALUES ('#{node_id}_#{sequence}', '#{node_id}', '#{message}', #{sequence}, '#{timestamp}', '#{originating_endpoint}')
    """

    Logger.debug(
      "Inserting: node_id=#{node_id}, message=#{message}, originating_endpoint=#{originating_endpoint}"
    )

    case CorrosionClient.execute_transaction([sql]) do
      {:ok, _response} ->
        {:ok,
         %{
           node_id: node_id,
           message: message,
           sequence: sequence,
           timestamp: timestamp,
           originating_endpoint: originating_endpoint
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

    case CorrosionClient.execute_query(query) do
      {:ok, response} ->
        {:ok, CorrosionClient.parse_query_response(response)}

      error ->
        error
    end
  end

  @doc """
  Gets the latest message for each node from the node_messages table.
  """
  def get_latest_node_messages() do
    query = """
    SELECT message, node_id, timestamp, sequence, originating_endpoint
    FROM node_messages
    WHERE (node_id, timestamp) IN (
      SELECT node_id, MAX(timestamp)
      FROM node_messages
      GROUP BY node_id
    )
    ORDER BY timestamp DESC
    """

    case CorrosionClient.execute_query(query) do
      {:ok, response} ->
        {:ok, CorrosionClient.parse_query_response(response)}

      error ->
        error
    end
  end

  @doc """
  Gets messages from a specific originating endpoint.
  Useful for debugging and filtering.
  """
  def get_messages_by_originating_endpoint(endpoint) do
    query =
      "SELECT * FROM node_messages WHERE originating_endpoint = '#{endpoint}' ORDER BY timestamp DESC"

    case CorrosionClient.execute_query(query) do
      {:ok, response} ->
        {:ok, CorrosionClient.parse_query_response(response)}

      error ->
        error
    end
  end

  # Private functions

  defp get_originating_endpoint do
    node_config = CorroPort.NodeConfig.app_node_config()

    case node_config[:environment] do
      :prod ->
        # In production, use the fly.io private IP with API port
        private_ip = node_config[:private_ip] || node_config[:fly_private_ip] || "127.0.0.1"
        api_port = node_config[:api_port] || 8081

        if String.contains?(private_ip, ":") do
          # IPv6 address, wrap in brackets
          "[#{private_ip}]:#{api_port}"
        else
          # IPv4 address
          "#{private_ip}:#{api_port}"
        end

      _ ->
        # In development, use localhost with calculated API port
        api_port = node_config[:api_port] || 5000 + (node_config[:node_id] || 1)
        "127.0.0.1:#{api_port}"
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

    case CorrosionClient.execute_transaction([cleanup_sql]) do
      {:ok, _} ->
        Logger.info("Cleaned up malformed messages")
        {:ok, :cleaned}

      error ->
        Logger.warning("Failed to cleanup messages: #{inspect(error)}")
        error
    end
  end
end
