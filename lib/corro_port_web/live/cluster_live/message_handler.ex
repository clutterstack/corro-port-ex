defmodule CorroPortWeb.ClusterLive.MessageHandler do
  require Logger
  alias CorroPort.{MessagesAPI, NodeConfig}

  def send_message() do
    node_id = NodeConfig.get_corrosion_node_id()
    message = "Hello from #{node_id} at #{DateTime.utc_now() |> DateTime.to_iso8601()}"

    case MessagesAPI.insert_message(node_id, message) do
      {:ok, result} ->
        Logger.info("Successfully sent message: #{inspect(result)}")

        # Construct the primary key the same way the SQL does
        message_pk = "#{node_id}_#{result.sequence}"

        # Return enhanced result with pk included
        message_data = %{
          pk: message_pk,
          timestamp: result.timestamp,
          node_id: result.node_id,
          message: result.message,
          sequence: result.sequence
        }

        {:ok, "Message sent successfully! Now tracking acknowledgments...", message_data}

      {:error, error} ->
        Logger.warning("Failed to send message: #{error}")
        {:error, "Failed to send message: #{error}"}
    end
  end

  def cleanup_messages() do
    case MessagesAPI.cleanup_bad_messages() do
      {:ok, :cleaned} ->
        {:ok, "Cleaned up malformed messages"}

      {:error, error} ->
        {:error, "Cleanup failed: #{inspect(error)}"}
    end
  end
end
