# Update to lib/corro_port_web/live/cluster_live/message_handler.ex

defmodule CorroPortWeb.ClusterLive.MessageHandler do
  require Logger
  alias CorroPort.{MessagesAPI, NodeConfig}

  def send_message(api_port) do
    node_id = NodeConfig.get_corrosion_node_id()
    message = "Hello from #{node_id} at #{DateTime.utc_now() |> DateTime.to_iso8601()}"

    case MessagesAPI.insert_message(node_id, message, api_port) do
      {:ok, result} ->
        Logger.info("Successfully sent message: #{inspect(result)}")

        # Build the pk the same way MessagesAPI does: node_id_sequence
        pk = "#{result.node_id}_#{result.sequence}"

        # Return both success message and the message details for tracking
        {:ok, "Message sent successfully!", %{
          pk: pk,
          timestamp: result.timestamp,
          node_id: result.node_id,
          message: message
        }}

      {:error, error} ->
        Logger.warning("Failed to send message: #{error}")
        {:error, "Failed to send message: #{error}"}
    end
  end

  def cleanup_messages(api_port) do
    case MessagesAPI.cleanup_bad_messages(api_port) do
      {:ok, :cleaned} ->
        {:ok, "Cleaned up malformed messages"}
      {:error, error} ->
        {:error, "Cleanup failed: #{inspect(error)}"}
    end
  end
end
