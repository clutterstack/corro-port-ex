defmodule CorroPortWeb.ClusterLive.MessageHandler do
  require Logger
  alias CorroPort.{CorrosionAPI, NodeConfig}

  def send_message(api_port) do
    node_id = NodeConfig.get_corrosion_node_id()
    message = "Hello from #{node_id} at #{DateTime.utc_now() |> DateTime.to_iso8601()}"

    case CorrosionAPI.insert_message(node_id, message, api_port) do
      {:ok, result} ->
        Logger.info("Successfully sent message: #{inspect(result)}")
        {:ok, "Message sent successfully!"}
      {:error, error} ->
        Logger.warning("Failed to send message: #{error}")
        {:error, "Failed to send message: #{error}"}
    end
  end

  def debug_messages(api_port) do
    case CorrosionAPI.get_all_node_messages_debug(api_port) do
      {:ok, debug_data} ->
        case CorrosionAPI.get_latest_node_messages(api_port) do
          {:ok, messages} ->
            Logger.warning("=== COMPARISON ===")
            Logger.warning("Debug query result: #{inspect(debug_data)}")
            Logger.warning("Latest messages result: #{inspect(messages)}")
            Logger.warning("=== END COMPARISON ===")
            {:ok, "Debug data logged - check the console!"}
          error ->
            {:error, "Latest messages query failed: #{inspect(error)}"}
        end
      {:error, error} ->
        {:error, "Debug query failed: #{inspect(error)}"}
    end
  end

  def cleanup_messages(api_port) do
    case CorrosionAPI.cleanup_bad_messages(api_port) do
      {:ok, :cleaned} ->
        {:ok, "Cleaned up malformed messages"}
      {:error, error} ->
        {:error, "Cleanup failed: #{inspect(error)}"}
    end
  end

  def test_insert(api_port) do
    case CorrosionAPI.test_insert(api_port) do
      {:ok, _result} ->
        {:ok, "Test message inserted successfully!"}
      {:error, error} ->
        {:error, "Test insert failed: #{inspect(error)}"}
    end
  end
end
