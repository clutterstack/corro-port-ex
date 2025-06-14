defmodule CorroPortWeb.ClusterLive.DataFetcher do
  require Logger
  alias CorroPort.{ClusterAPI, MessagesAPI}

  def fetch_all_data() do
    # Fetch all the data
    cluster_result = ClusterAPI.get_cluster_info()
    local_result = ClusterAPI.get_info()
    messages_result = MessagesAPI.get_latest_node_messages()

    # Determine error state
    error =
      case cluster_result do
        {:error, error} -> "Failed to connect to Corrosion API: #{error}"
        _ -> nil
      end

    # Return a map of updates for the LiveView to apply
    %{
      cluster_info:
        case cluster_result do
          {:ok, info} ->
            info

          {:error, error} ->
            Logger.warning("Failed to fetch cluster info: #{error}")
            nil
        end,
      local_info:
        case local_result do
          {:ok, info} ->
            info

          {:error, error} ->
            Logger.warning("Failed to fetch local info: #{error}")
            nil
        end,
      node_messages:
        case messages_result do
          {:ok, messages} ->
            messages

          {:error, error} ->
            Logger.debug("Failed to fetch node messages (table might not exist yet): #{error}")
            []
        end,
      error: error,
      last_updated: DateTime.utc_now()
    }
  end

  def fetch_node_messages_data() do
    case MessagesAPI.get_latest_node_messages() do
      {:ok, messages} ->
        messages

      {:error, error} ->
        Logger.debug("Failed to fetch node messages (table might not exist yet): #{error}")
        []
    end
  end
end
