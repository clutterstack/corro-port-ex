defmodule CorroPort.AcknowledgmentSender do
  @moduledoc """
  Sends HTTP acknowledgments to originating nodes when we receive their messages.

  This module handles:
  - Node discovery (figuring out which Phoenix port a node is running on)
  - HTTP POST requests to other nodes' /api/acknowledge endpoints
  - Error handling and logging for failed acknowledgments
  """

  require Logger

  @acknowledgment_timeout 5_000  # 5 seconds

  @doc """
  Send an acknowledgment to the originating node for a received message.

  ## Parameters
  - originating_node_id: String like "node1", "node2" etc
  - message_data: Map with keys :pk, :timestamp, :node_id

  ## Returns
  - :ok on success
  - {:error, reason} on failure
  """
  def send_acknowledgment(originating_node_id, message_data) do
    local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

    # Don't send acknowledgments to ourselves
    if originating_node_id == local_node_id do
      Logger.debug("AcknowledgmentSender: Skipping acknowledgment to self (#{originating_node_id})")
      :ok
    else
      Logger.info("AcknowledgmentSender: Sending acknowledgment to #{originating_node_id} for message #{message_data.pk}")
      do_send_acknowledgment(originating_node_id, message_data, local_node_id)
    end
  end

  @doc """
  Test connectivity to another node's acknowledgment endpoint.

  ## Parameters
  - target_node_id: String like "node1", "node2" etc

  ## Returns
  - {:ok, response_data} on success
  - {:error, reason} on failure
  """
  def test_connectivity(target_node_id) do
    case discover_node_endpoint(target_node_id) do
      {:ok, base_url} ->
        health_url = "#{base_url}/api/acknowledge/health"

        Logger.info("AcknowledgmentSender: Testing connectivity to #{target_node_id} at #{health_url}")

        case Req.get(health_url, receive_timeout: @acknowledgment_timeout) do
          {:ok, %{status: 200, body: body}} ->
            Logger.info("AcknowledgmentSender: Successfully connected to #{target_node_id}")
            {:ok, body}

          {:ok, %{status: status, body: body}} ->
            error = "HTTP #{status}: #{inspect(body)}"
            Logger.warning("AcknowledgmentSender: Health check failed for #{target_node_id}: #{error}")
            {:error, error}

          {:error, reason} ->
            Logger.warning("AcknowledgmentSender: Connection failed to #{target_node_id}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get a list of all expected nodes and test connectivity to each.
  Useful for debugging cluster connectivity.

  ## Returns
  Map of node_id => connectivity_result
  """
  def test_all_connectivity do
    expected_nodes = CorroPort.AcknowledgmentTracker.get_expected_nodes()

    Logger.info("AcknowledgmentSender: Testing connectivity to all expected nodes: #{inspect(expected_nodes)}")

    results = Enum.reduce(expected_nodes, %{}, fn node_id, acc ->
      result = test_connectivity(node_id)
      Map.put(acc, node_id, result)
    end)

    # Log summary
    successful = Enum.count(results, fn {_node, result} -> match?({:ok, _}, result) end)
    total = length(expected_nodes)

    Logger.info("AcknowledgmentSender: Connectivity test complete: #{successful}/#{total} nodes reachable")

    results
  end

  # Private Functions

  defp do_send_acknowledgment(originating_node_id, message_data, local_node_id) do
    case discover_node_endpoint(originating_node_id) do
      {:ok, base_url} ->
        send_http_acknowledgment(base_url, originating_node_id, message_data, local_node_id)

      {:error, reason} ->
        Logger.warning("AcknowledgmentSender: Could not discover endpoint for #{originating_node_id}: #{reason}")
        {:error, reason}
    end
  end

  def discover_node_endpoint(node_id) do
    case extract_node_number(node_id) do
      {:ok, node_number} ->
        # Calculate Phoenix port: base port 4000 + node_number
        phoenix_port = 4000 + node_number
        base_url = "http://127.0.0.1:#{phoenix_port}"

        Logger.debug("AcknowledgmentSender: Discovered endpoint for #{node_id}: #{base_url}")
        {:ok, base_url}

      {:error, reason} ->
        Logger.warning("AcknowledgmentSender: Could not extract node number from #{node_id}: #{reason}")
        {:error, reason}
    end
  end

  defp extract_node_number(node_id) when is_binary(node_id) do
    # Extract number from strings like "node1", "node2" etc
    case Regex.run(~r/^node(\d+)$/, node_id) do
      [_full_match, number_str] ->
        case Integer.parse(number_str) do
          {number, ""} -> {:ok, number}
          _ -> {:error, "Invalid number format in #{node_id}"}
        end

      nil ->
        {:error, "Node ID #{node_id} does not match expected format 'nodeN'"}
    end
  end

  defp extract_node_number(node_id) do
    {:error, "Node ID must be a string, got: #{inspect(node_id)}"}
  end

  defp send_http_acknowledgment(base_url, originating_node_id, message_data, local_node_id) do
    ack_url = "#{base_url}/api/acknowledge"

    payload = %{
      "message_pk" => message_data.pk,
      "ack_node_id" => local_node_id,
      "message_timestamp" => message_data.timestamp
    }

    Logger.debug("AcknowledgmentSender: Sending POST to #{ack_url} with payload: #{inspect(payload)}")

    case Req.post(ack_url,
           json: payload,
           headers: [{"content-type", "application/json"}],
           receive_timeout: @acknowledgment_timeout) do

      {:ok, %{status: 200, body: body}} ->
        Logger.info("AcknowledgmentSender: Successfully sent acknowledgment to #{originating_node_id}")
        Logger.debug("AcknowledgmentSender: Response: #{inspect(body)}")
        :ok

      {:ok, %{status: 404}} ->
        # The target node isn't tracking this message anymore - not necessarily an error
        Logger.info("AcknowledgmentSender: Target node #{originating_node_id} is not tracking message #{message_data.pk} (404)")
        :ok

      {:ok, %{status: status, body: body}} ->
        error = "HTTP #{status}: #{inspect(body)}"
        Logger.warning("AcknowledgmentSender: Acknowledgment failed to #{originating_node_id}: #{error}")
        {:error, error}

      {:error, %{reason: :timeout}} ->
        Logger.warning("AcknowledgmentSender: Acknowledgment timed out to #{originating_node_id} after #{@acknowledgment_timeout}ms")
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
