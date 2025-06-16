defmodule CorroPort.AckSender do
  @moduledoc """
  Sends acknowledgments directly to originating nodes using their endpoint info.

  In production: Uses fly.io 6PN private IPv6 addresses for direct communication
  In development: Uses localhost with different API ports per node
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

    {:ok,
     %{
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
          Logger.info(
            "AckSender: 🤝 Sending acknowledgment for message from #{originating_node_id}"
          )

          # Send acknowledgment in background using direct endpoint communication
          spawn(fn -> send_acknowledgment_to_endpoint(message_map) end)

          final_state = %{new_state | acknowledgments_sent: new_state.acknowledgments_sent + 1}
          {:noreply, final_state}
        else
          Logger.debug("AckSender: Ignoring message from self (#{local_node_id})")
          {:noreply, new_state}
        end
    end
  end

  def handle_info({:initial_row, _message_map}, state) do
    # For initial state, we probably don't want to send acks
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

        spawn(fn -> send_acknowledgment_to_endpoint(message_map) end)

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

  defp send_acknowledgment_to_endpoint(message_map) do
    local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()
    originating_endpoint = Map.get(message_map, "originating_endpoint")
    message_pk = Map.get(message_map, "pk")
    message_timestamp = Map.get(message_map, "timestamp")

    if originating_endpoint && message_pk do
      case parse_endpoint(originating_endpoint) do
        {:ok, api_url} ->
          send_http_acknowledgment(
            api_url,
            originating_endpoint,
            message_pk,
            message_timestamp,
            local_node_id
          )

        {:error, reason} ->
          Logger.warning("AckSender: Could not parse endpoint #{originating_endpoint}: #{reason}")
      end
    else
      Logger.warning(
        "AckSender: Message missing originating_endpoint or pk: #{inspect(message_map)}"
      )
    end
  end

  defp parse_endpoint(endpoint) when is_binary(endpoint) do
    case endpoint do
      # IPv6 with brackets: [2001:db8::1]:8081
      "[" <> rest ->
        case String.split(rest, "]:") do
          [ipv6, port_str] ->
            case Integer.parse(port_str) do
              {_port, ""} -> {:ok, "http://[#{ipv6}]:#{port_str}"}
              _ -> {:error, "Invalid port in IPv6 endpoint: #{endpoint}"}
            end

          _ ->
            {:error, "Invalid IPv6 endpoint format: #{endpoint}"}
        end

      # IPv4 or hostname: 127.0.0.1:8081
      _ ->
        case String.split(endpoint, ":") do
          [ip, port_str] ->
            case Integer.parse(port_str) do
              {_port, ""} -> {:ok, "http://#{ip}:#{port_str}"}
              _ -> {:error, "Invalid port in endpoint: #{endpoint}"}
            end

          _ ->
            {:error, "Invalid endpoint format: #{endpoint}"}
        end
    end
  end

  defp parse_endpoint(endpoint) do
    {:error, "Endpoint must be a string, got: #{inspect(endpoint)}"}
  end

  defp send_http_acknowledgment(
         api_url,
         originating_endpoint,
         message_pk,
         message_timestamp,
         local_node_id
       ) do
    ack_url = "#{api_url}/api/v1/acknowledge"

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
        Logger.info("AckSender: ✅ Successfully sent acknowledgment to #{originating_endpoint}")
        Logger.debug("AckSender: Response: #{inspect(body)}")

      {:ok, %{status: 404}} ->
        # Target node isn't tracking this message - not an error
        Logger.info(
          "AckSender: Target endpoint #{originating_endpoint} is not tracking message #{message_pk} (404)"
        )

      {:ok, %{status: status, body: body}} ->
        Logger.warning(
          "AckSender: Acknowledgment failed to #{originating_endpoint}: HTTP #{status}: #{inspect(body)}"
        )

      {:error, %{reason: :timeout}} ->
        Logger.warning(
          "AckSender: Acknowledgment timed out to #{originating_endpoint} after #{@ack_timeout}ms"
        )

      {:error, %{reason: :econnrefused}} ->
        Logger.warning("AckSender: Connection refused to #{originating_endpoint} at #{ack_url}")

      {:error, reason} ->
        Logger.warning(
          "AckSender: Acknowledgment failed to #{originating_endpoint}: #{inspect(reason)}"
        )
    end
  end
end
