defmodule CorroPort.AcknowledgmentSender do
  @moduledoc """
  Sends HTTP acknowledgments to originating nodes when we receive their messages.

  This module handles:
  - IP-based service discovery using the originating_ip from messages
  - HTTP POST requests to other nodes' acknowledgment endpoints
  - Error handling and logging for failed acknowledgments
  """

  require Logger

  @ack_timeout 5_000  # 5 seconds

  @doc """
  Send an acknowledgment to the originating node for a received message.

  ## Parameters
  - message_data: Map with keys :pk, :timestamp, :node_id, :originating_ip

  ## Returns
  - :ok on success
  - {:error, reason} on failure
  """
  def send_acknowledgment(message_data) do
    local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()
    originating_node_id = Map.get(message_data, "node_id")
    originating_ip = Map.get(message_data, "originating_ip")

    # Don't send acknowledgments to ourselves
    if originating_node_id == local_node_id do
      Logger.debug("AcknowledgmentSender: Skipping acknowledgment to self (#{originating_node_id})")
      :ok
    else
      case originating_ip do
        ip when is_binary(ip) and ip != "" ->
          Logger.info("AcknowledgmentSender: Sending acknowledgment to #{originating_node_id} at #{ip}")
          send_http_acknowledgment(ip, originating_node_id, message_data, local_node_id)

        _ ->
          Logger.warning("AcknowledgmentSender: No originating_ip found for message from #{originating_node_id}")
          {:error, :no_originating_ip}
      end
    end
  end

  @doc """
  Test connectivity to another node's acknowledgment endpoint using IP.

  ## Parameters
  - target_ip: IP address of the target node
  - target_node_id: String like "node1", "node2" etc (for logging)

  ## Returns
  - {:ok, response_data} on success
  - {:error, reason} on failure
  """
  def test_connectivity_by_ip(target_ip, target_node_id \\ "unknown") do
    case discover_ack_endpoint_by_ip(target_ip) do
      {:ok, base_url} ->
        health_url = "#{base_url}/api/acknowledge"

        Logger.info("AcknowledgmentSender: Testing connectivity to #{target_node_id} at #{health_url}")

        # Simple GET to the acknowledge endpoint (will return method not allowed, but proves connectivity)
        case Req.get(health_url, receive_timeout: @ack_timeout) do
          {:ok, %{status: status}} when status in [200, 405] ->
            Logger.info("AcknowledgmentSender: Successfully connected to #{target_node_id} at #{target_ip}")
            {:ok, %{status: status}}

          {:ok, %{status: status, body: body}} ->
            error = "HTTP #{status}: #{inspect(body)}"
            Logger.warning("AcknowledgmentSender: Connectivity test failed for #{target_node_id} at #{target_ip}: #{error}")
            {:error, error}

          {:error, reason} ->
            Logger.warning("AcknowledgmentSender: Connection failed to #{target_node_id} at #{target_ip}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Test connectivity to all known nodes by checking recent messages for their IPs.
  """
  def test_all_connectivity do
    # Get recent messages to find originating IPs
    case CorroPort.MessagesAPI.get_latest_node_messages() do
      {:ok, messages} ->
        local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

        # Extract unique originating IPs from other nodes
        unique_endpoints =
          messages
          |> Enum.reject(fn msg -> Map.get(msg, "node_id") == local_node_id end)
          |> Enum.map(fn msg ->
            {Map.get(msg, "node_id", "unknown"), Map.get(msg, "originating_ip")}
          end)
          |> Enum.filter(fn {_node_id, ip} -> is_binary(ip) and ip != "" end)
          |> Enum.uniq()

        Logger.info("AcknowledgmentSender: Testing connectivity to #{length(unique_endpoints)} known endpoints")

        results = Enum.reduce(unique_endpoints, %{}, fn {node_id, ip}, acc ->
          result = test_connectivity_by_ip(ip, node_id)
          Map.put(acc, node_id, result)
        end)

        # Log summary
        successful = Enum.count(results, fn {_node, result} -> match?({:ok, _}, result) end)
        total = length(unique_endpoints)

        Logger.info("AcknowledgmentSender: Connectivity test complete: #{successful}/#{total} nodes reachable")

        results

      {:error, reason} ->
        Logger.warning("AcknowledgmentSender: Could not get recent messages for connectivity test: #{inspect(reason)}")
        %{}
    end
  end

  # Private Functions

  defp discover_ack_endpoint_by_ip(originating_ip) do
    # Calculate acknowledgment port (assuming same offset on target node)
    local_config = CorroPort.NodeConfig.get_node_config()
    local_main_port = Application.get_env(:corro_port, CorroPortWeb.Endpoint)[:http][:port] || 4001
    local_ack_port = local_config[:ack_port] || 5001
    port_offset = local_ack_port - local_main_port

    # Apply same offset to target node
    target_ack_port = 5001  # For now, assume standard ack port. Could be smarter later.

    base_url = "http://#{originating_ip}:#{target_ack_port}"

    Logger.debug("AcknowledgmentSender: Discovered ack endpoint: #{base_url}")
    {:ok, base_url}
  end

  defp send_http_acknowledgment(originating_ip, originating_node_id, message_data, local_node_id) do
    case discover_ack_endpoint_by_ip(originating_ip) do
      {:ok, base_url} ->
        do_send_http_acknowledgment(base_url, originating_node_id, message_data, local_node_id)

      {:error, reason} ->
        Logger.warning("AcknowledgmentSender: Could not discover ack endpoint for #{originating_ip}: #{reason}")
        {:error, reason}
    end
  end

  defp do_send_http_acknowledgment(base_url, originating_node_id, message_data, local_node_id) do
    ack_url = "#{base_url}/api/acknowledge"

    payload = %{
      "message_pk" => Map.get(message_data, "pk"),
      "ack_node_id" => local_node_id,
      "message_timestamp" => Map.get(message_data, "timestamp")
    }

    Logger.debug("AcknowledgmentSender: Sending POST to #{ack_url} with payload: #{inspect(payload)}")

    case Req.post(ack_url,
           json: payload,
           headers: [{"content-type", "application/json"}],
           receive_timeout: @ack_timeout) do

      {:ok, %{status: 200, body: body}} ->
        Logger.info("AcknowledgmentSender: Successfully sent acknowledgment to #{originating_node_id}")
        Logger.debug("AcknowledgmentSender: Response: #{inspect(body)}")
        :ok

      {:ok, %{status: 404}} ->
        # The target node isn't tracking this message anymore - not necessarily an error
        Logger.info("AcknowledgmentSender: Target node #{originating_node_id} is not tracking message anymore (404)")
        :ok

      {:ok, %{status: status, body: body}} ->
        error = "HTTP #{status}: #{inspect(body)}"
        Logger.warning("AcknowledgmentSender: Acknowledgment failed to #{originating_node_id}: #{error}")
        {:error, error}

      {:error, %{reason: :timeout}} ->
        Logger.warning("AcknowledgmentSender: Acknowledgment timed out to #{originating_node_id} after #{@ack_timeout}ms")
        {:error, :timeout}

      {:error, %{reason: :econnrefused}} ->
        Logger.warning("AcknowledgmentSender: Connection refused to #{originating_node_id} at #{ack_url}")
        {:error, :connection_refused}

      {:error, reason} ->
        Logger.warning("AcknowledgmentSender: Acknowledgment failed to #{originating_node_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
