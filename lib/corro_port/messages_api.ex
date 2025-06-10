defmodule CorroPort.MessagesAPI do
  @moduledoc """
  API for managing user data in the node_messages table.

  This module provides functions for reading, writing, and maintaining
  messages in the node_messages user table within the Corrosion database.

  Uses `CorroPort.CorrosionClient` for the underlying HTTP transport.
  """
  require Logger

  alias CorroPort.CorrosionClient

  ## Node Messaging

  @doc """
  Gets all messages from the node_messages table, ordered by timestamp.
  """
  def get_node_messages(port \\ nil) do
    query = "SELECT * FROM node_messages ORDER BY timestamp DESC"

    case CorrosionClient.execute_query(query, port) do
      {:ok, response} ->
        {:ok, CorrosionClient.parse_query_response(response)}
      error ->
        error
    end
  end

  @doc """
  Gets the latest message for each node from the node_messages table.
  """
  def get_latest_node_messages(port \\ nil) do
    query = """
    SELECT message, node_id, timestamp, sequence
    FROM node_messages
    WHERE (node_id, timestamp) IN (
      SELECT node_id, MAX(timestamp)
      FROM node_messages
      GROUP BY node_id
    )
    ORDER BY timestamp DESC
    """

    case CorrosionClient.execute_query(query, port) do
      {:ok, response} ->
        {:ok, CorrosionClient.parse_query_response(response)}
      error ->
        error
    end
  end

  @doc """
  Inserts a new message into the node_messages table.

  ## Parameters
  - `node_id`: Identifier for the node sending the message
  - `message`: Message content
  - `port`: API port (optional)

  ## Returns
  - `{:ok, message_data}` on success with inserted message details
  - `{:error, reason}` on failure
  """
  def insert_message(node_id, message, port \\ nil) do
    sequence = System.system_time(:millisecond)
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    sql = """
    INSERT INTO node_messages (pk, node_id, message, sequence, timestamp)
    VALUES ('#{node_id}_#{sequence}', '#{node_id}', '#{message}', #{sequence}, '#{timestamp}')
    """

    Logger.debug("Inserting: node_id=#{node_id}, message=#{message}")

    case CorrosionClient.execute_transaction([sql], port) do
      {:ok, _response} ->
        {:ok, %{node_id: node_id, message: message, sequence: sequence, timestamp: timestamp}}
      error ->
        error
    end
  end

  ## Utility and Maintenance

  @doc """
  Cleanup function to remove malformed messages from the node_messages table.

  Specifically targets messages where the message field contains port numbers,
  which indicates a data corruption issue.
  """
  def cleanup_bad_messages(port \\ nil) do
    cleanup_sql = """
    DELETE FROM node_messages
    WHERE message IN ('8081', '8082', '8083', '8084', '8085')
    """

    case CorrosionClient.execute_transaction([cleanup_sql], port) do
      {:ok, _} ->
        Logger.info("Cleaned up malformed messages")
        {:ok, :cleaned}
      error ->
        Logger.warning("Failed to cleanup messages: #{inspect(error)}")
        error
    end
  end

  @doc """
  Test function to insert a known good message.

  Useful for verifying that the message insertion mechanism is working correctly.
  """
  def test_insert(port \\ nil) do
    node_id = CorroPort.NodeConfig.get_corrosion_node_id()
    test_message = "Test message from #{node_id} at #{DateTime.utc_now() |> DateTime.to_iso8601()}"

    insert_message(node_id, test_message, port)
  end
end
