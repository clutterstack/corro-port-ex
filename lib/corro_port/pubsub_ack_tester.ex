defmodule CorroPort.PubSubAckTester do
  @moduledoc """
  Initiates PubSub-based acknowledgment tests across the cluster.
  """

  require Logger

  alias CorroPort.{AckTracker, LocalNode, NodeConfig}

  @topic "pubsub_ack_test"

  @doc """
  Broadcast an acknowledgment test request to every node in the cluster.

  Returns `{:ok, request_data}` on success or `{:error, reason}` if tracking
  fails.
  """
  @spec send_test_request(String.t()) :: {:ok, map()} | {:error, term()}
  def send_test_request(message_content \\ "PubSub cluster test") do
    local_node_id = LocalNode.get_node_id()
    request_id = generate_request_id(local_node_id)
    timestamp_iso = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    {originating_endpoint, region} = resolve_endpoint_and_region()

    request_data = %{
      request_id: request_id,
      originating_node_id: local_node_id,
      originating_endpoint: originating_endpoint,
      timestamp: timestamp_iso,
      message: "#{message_content} (from #{local_node_id})",
      region: region
    }

    track_data = %{
      pk: request_id,
      timestamp: timestamp_iso,
      node_id: local_node_id
    }

    case AckTracker.track_latest_message(track_data) do
      :ok ->
        Logger.info("PubSubAckTester: broadcasting request #{request_id} to #{@topic}")
        Phoenix.PubSub.broadcast(CorroPort.PubSub, @topic, {:pubsub_ack_request, request_data})
        {:ok, request_data}

      {:error, reason} ->
        Logger.warning(
          "PubSubAckTester: failed to track request #{request_id}: #{inspect(reason)}"
        )

        {:error, {:tracking_failed, reason}}
    end
  end

  defp generate_request_id(local_node_id) do
    sequence = System.system_time(:millisecond)
    "pubsub_#{local_node_id}_#{sequence}"
  end

  defp resolve_endpoint_and_region do
    node_config = NodeConfig.app_node_config()

    endpoint =
      case node_config[:environment] do
        :prod ->
          private_ip = node_config[:private_ip] || node_config[:fly_private_ip] || "127.0.0.1"
          ack_api_port = node_config[:ack_api_port] || 8081

          if String.contains?(private_ip, ":") do
            "[#{private_ip}]:#{ack_api_port}"
          else
            "#{private_ip}:#{ack_api_port}"
          end

        _ ->
          ack_api_port = node_config[:ack_api_port] || default_dev_port(node_config[:node_id])
          "127.0.0.1:#{ack_api_port}"
      end

    {endpoint, LocalNode.get_region()}
  end

  defp default_dev_port(nil), do: 5001
  defp default_dev_port(node_id), do: 5000 + node_id
end