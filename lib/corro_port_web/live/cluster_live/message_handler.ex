defmodule CorroPortWeb.ClusterLive.MessageHandler do
  require Logger
  alias CorroPort.{MessagesAPI, NodeConfig}

  def send_message(api_port) do
    node_id = NodeConfig.get_corrosion_node_id()
    message = "Hello from #{node_id} at #{DateTime.utc_now() |> DateTime.to_iso8601()}"

    case MessagesAPI.insert_message(node_id, message, api_port) do
      {:ok, result} ->
        Logger.info("Successfully sent message: #{inspect(result)}")

        # NEW: Start tracking this message for acknowledgments
        # The MessagesAPI.insert_message returns %{node_id, message, sequence, timestamp}
        # but doesn't include pk, so we construct it the same way the SQL does
        message_pk = "#{node_id}_#{result.sequence}"
        message_data = %{
          pk: message_pk,
          timestamp: result.timestamp,
          node_id: result.node_id
        }

        case CorroPort.AcknowledgmentTracker.track_latest_message(message_data) do
          :ok ->
            Logger.info("MessageHandler: Started tracking message #{message_data.pk} for acknowledgments")
            {:ok, "Message sent successfully! Now tracking acknowledgments..."}
          {:error, track_error} ->
            Logger.warning("MessageHandler: Failed to track message for acknowledgments: #{inspect(track_error)}")
            # Still return success since the message was sent successfully
            {:ok, "Message sent successfully! (Note: acknowledgment tracking failed)"}
        end

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
