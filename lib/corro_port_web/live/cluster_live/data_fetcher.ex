defmodule CorroPortWeb.ClusterLive.DataFetcher do
  require Logger
  alias CorroPort.{ClusterAPI, MessagesAPI, MessageWatcher}

  def fetch_all_data(socket) do
    api_port = socket.assigns.api_port

    # Fetch all the data
    cluster_result = ClusterAPI.get_cluster_info(api_port)
    local_result = ClusterAPI.get_info(api_port)
    messages_result = MessagesAPI.get_latest_node_messages(api_port)
    subscription_status = get_subscription_status_safe()

    # Determine error state
    error = case cluster_result do
      {:error, error} -> "Failed to connect to Corrosion API: #{error}"
      _ -> nil
    end

    # Return a map of updates for the LiveView to apply
    %{
      cluster_info: case cluster_result do
        {:ok, info} -> info
        {:error, error} ->
          Logger.warning("Failed to fetch cluster info: #{error}")
          nil
      end,
      local_info: case local_result do
        {:ok, info} -> info
        {:error, error} ->
          Logger.warning("Failed to fetch local info: #{error}")
          nil
      end,
      node_messages: case messages_result do
        {:ok, messages} -> messages
        {:error, error} ->
          Logger.debug("Failed to fetch node messages (table might not exist yet): #{error}")
          []
      end,
      error: error,
      subscription_status: subscription_status,
      last_updated: DateTime.utc_now()
    }
  end

  def fetch_node_messages_data(api_port) do
    case MessagesAPI.get_latest_node_messages(api_port) do
      {:ok, messages} -> messages
      {:error, error} ->
        Logger.debug("Failed to fetch node messages (table might not exist yet): #{error}")
        []
    end
  end

def get_subscription_status_safe do
  Logger.warning("DataFetcher: Attempting to get MessageWatcher status...")

  try do
    # Check if the process is alive first
    case Process.whereis(CorroPort.MessageWatcher) do
      nil ->
        Logger.warning("DataFetcher: MessageWatcher process not found")
        %{
          subscription_active: false,
          status: :not_started,
          watch_id: nil,
          reconnect_attempts: 0,
          error: "MessageWatcher process not running"
        }

      pid when is_pid(pid) ->
        Logger.warning("DataFetcher: MessageWatcher process found at #{inspect(pid)}, calling get_status...")

        # Try with a longer timeout
        status = MessageWatcher.get_status()
        Logger.warning("DataFetcher: Got status from MessageWatcher: #{inspect(status)}")
        status
    end
  catch
    :exit, {:timeout, _} ->
      Logger.warning("DataFetcher: MessageWatcher status call timed out")
      %{
        subscription_active: false,
        status: :timeout,
        watch_id: nil,
        reconnect_attempts: 0,
        error: "Status check timed out"
      }
    :exit, {:noproc, _} ->
      Logger.warning("DataFetcher: MessageWatcher process not found (noproc)")
      %{
        subscription_active: false,
        status: :not_started,
        watch_id: nil,
        reconnect_attempts: 0,
        error: "MessageWatcher not running"
      }
    type, reason ->
      Logger.warning("DataFetcher: Error getting subscription status: #{type} - #{inspect(reason)}")
      %{
        subscription_active: false,
        status: :error,
        watch_id: nil,
        reconnect_attempts: 0,
        error: "Error: #{type} - #{inspect(reason)}"
      }
  end
end

end
