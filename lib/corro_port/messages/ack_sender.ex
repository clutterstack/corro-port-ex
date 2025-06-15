defmodule CorroPort.AckSender do
  @moduledoc """
  Automatically sends acknowledgments to other nodes when we receive their messages.

  Listens to CorroSubscriber's message updates and sends HTTP acknowledgments
  to the originating node when we see a message from another node.

  Supports both development (localhost with different ports) and production
  (fly.io with machine discovery) environments.
  """

  use GenServer
  require Logger

  @ack_timeout 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    Logger.info("AckSender starting...")

    # Subscribe to CorroSubscriber's message updates
    Phoenix.PubSub.subscribe(CorroPort.PubSub, CorroPort.CorroSubscriber.subscription_topic())

    {:ok, %{
      acknowledgments_sent: 0,
      total_messages_processed: 0
    }}
  end

  # Handle new messages from CorroSubscriber
  def handle_info({:new_message, message_map}, state) do
    new_state = %{state | total_messages_processed: state.total_messages_processed + 1}

    case Map.get(message_map, "node_id") do
      nil ->
        Logger.debug("AckSender: Received message without node_id, skipping")
        {:noreply, new_state}

      originating_node_id ->
        local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

        if originating_node_id != local_node_id do
          Logger.info("AckSender: 🤝 Sending acknowledgment for message from #{originating_node_id}")

          # Send acknowledgment in background (fire-and-forget)
          spawn(fn -> send_acknowledgment_async(originating_node_id, message_map) end)

          final_state = %{new_state | acknowledgments_sent: new_state.acknowledgments_sent + 1}
          {:noreply, final_state}
        else
          Logger.debug("AckSender: Ignoring message from self (#{local_node_id})")
          {:noreply, new_state}
        end
    end
  end

  def handle_info({:initial_row, message_map}, state) do
    # For initial state, we probably don't want to send acks
    # But let's log and count for stats
    new_state = %{state | total_messages_processed: state.total_messages_processed + 1}
    {:noreply, new_state}
  end

  # Handle message changes (updates/deletes)
  def handle_info({:message_change, change_type, message_map}, state) do
    new_state = %{state | total_messages_processed: state.total_messages_processed + 1}

    # Only send acks for INSERTs (new messages), not UPDATEs or DELETEs
    if change_type == "INSERT" do
      originating_node_id = Map.get(message_map, "node_id")
      local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

      if originating_node_id && originating_node_id != local_node_id do
        Logger.info("AckSender: 🤝 Sending acknowledgment for INSERT from #{originating_node_id}")

        spawn(fn -> send_acknowledgment_async(originating_node_id, message_map) end)

        final_state = %{new_state | acknowledgments_sent: new_state.acknowledgments_sent + 1}
        {:noreply, final_state}
      else
        {:noreply, new_state}
      end
    else
      Logger.debug("AckSender: Ignoring #{change_type} change")
      {:noreply, new_state}
    end
  end

  # Ignore other CorroSubscriber events
  def handle_info({:columns_received, _}, state), do: {:noreply, state}
  def handle_info({:subscription_ready}, state), do: {:noreply, state}
  def handle_info({:subscription_connected, _}, state), do: {:noreply, state}
  def handle_info({:subscription_error, _}, state), do: {:noreply, state}
  def handle_info({:subscription_closed, _}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("AckSender: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Public API for stats/debugging
  def get_status do
    try do
      GenServer.call(__MODULE__, :get_status, 1000)
    catch
      :exit, _ -> %{status: :unavailable}
    end
  end

  def handle_call(:get_status, _from, state) do
    status = %{
      acknowledgments_sent: state.acknowledgments_sent,
      total_messages_processed: state.total_messages_processed,
      status: :running
    }
    {:reply, status, state}
  end

  def terminate(reason, _state) do
    Logger.info("AckSender shutting down: #{inspect(reason)}")
    :ok
  end

  # Private Functions

  defp send_acknowledgment_async(originating_node_id, message_map) do
    local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

    # Build the acknowledgment payload
    message_pk = Map.get(message_map, "pk")
    message_timestamp = Map.get(message_map, "timestamp")

    if message_pk do
      case discover_node_endpoint(originating_node_id) do
        {:ok, base_url} ->
          send_http_acknowledgment(base_url, originating_node_id, message_pk, message_timestamp, local_node_id)

        {:error, reason} ->
          Logger.warning("AckSender: Could not discover endpoint for #{originating_node_id}: #{reason}")
      end
    else
      Logger.warning("AckSender: Message missing pk, cannot send acknowledgment: #{inspect(message_map)}")
    end
  end

  defp discover_node_endpoint(node_id) do
    if CorroPort.NodeConfig.production?() do
      discover_production_endpoint(node_id)
    else
      discover_development_endpoint(node_id)
    end
  end

  defp discover_production_endpoint(node_id) do
    # In production on fly.io, all machines use the same Phoenix port (8080)
    # and we can reach them via the app's internal DNS
    fly_config = CorroPort.NodeConfig.get_fly_config()

    case fly_config do
      %{app_name: app_name} when is_binary(app_name) ->
        # Use fly.io's internal DNS to reach other machines
        # All machines expose Phoenix on port 8080
        base_url = "http://#{app_name}.internal:8080"
        Logger.debug("AckSender: Production endpoint for #{node_id}: #{base_url}")
        {:ok, base_url}

      _ ->
        Logger.warning("AckSender: Missing fly.io configuration for production endpoint discovery")
        {:error, "Missing fly.io configuration"}
    end
  end

  defp discover_development_endpoint(node_id) do
    # In development, use the existing logic with different ports per node
    case extract_node_number(node_id) do
      {:ok, node_number} ->
        # Calculate Phoenix port: base port 4000 + node_number
        phoenix_port = 4000 + node_number
        base_url = "http://127.0.0.1:#{phoenix_port}"

        Logger.debug("AckSender: Development endpoint for #{node_id}: #{base_url}")
        {:ok, base_url}

      {:error, reason} ->
        Logger.warning("AckSender: Could not extract node number from #{node_id}: #{reason}")
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

  defp send_http_acknowledgment(base_url, originating_node_id, message_pk, message_timestamp, local_node_id) do
    ack_url = "#{base_url}/api/acknowledge"

    payload = %{
      "message_pk" => message_pk,
      "ack_node_id" => local_node_id,
      "message_timestamp" => message_timestamp
    }

    Logger.debug("AckSender: Sending POST to #{ack_url} with payload: #{inspect(payload)}")

    case Req.post(ack_url,
           json: payload,
           headers: [{"content-type", "application/json"}],
           receive_timeout: @ack_timeout
         ) do
      {:ok, %{status: 200, body: body}} ->
        Logger.info("AckSender: ✅ Successfully sent acknowledgment to #{originating_node_id}")
        Logger.debug("AckSender: Response: #{inspect(body)}")

      {:ok, %{status: 404}} ->
        # Target node isn't tracking this message - not an error
        Logger.info("AckSender: Target node #{originating_node_id} is not tracking message #{message_pk} (404)")

      {:ok, %{status: status, body: body}} ->
        Logger.warning("AckSender: Acknowledgment failed to #{originating_node_id}: HTTP #{status}: #{inspect(body)}")

      {:error, %{reason: :timeout}} ->
        Logger.warning("AckSender: Acknowledgment timed out to #{originating_node_id} after #{@ack_timeout}ms")

      {:error, %{reason: :econnrefused}} ->
        Logger.warning("AckSender: Connection refused to #{originating_node_id} at #{ack_url}")

      {:error, reason} ->
        Logger.warning("AckSender: Acknowledgment failed to #{originating_node_id}: #{inspect(reason)}")
    end
  end
end
