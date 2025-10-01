defmodule CorroPort.AckSender do
  @moduledoc """
  Sends acknowledgments directly to originating nodes using their endpoint info.

  In production: Uses fly.io 6PN private IPv6 addresses for direct communication
  In development: Uses localhost with different API ports per node

  ## Architecture

  Implemented as a supervised Task (not a GenServer) that:
  - Subscribes to PubSub `message_updates` topic
  - Runs a receive loop to handle incoming messages
  - Spawns background tasks for HTTP acknowledgment sending
  - No state management (purely reactive)

  This design eliminates GenServer overhead for what is essentially a
  message-driven task spawner with no meaningful state to maintain.
  """

  require Logger

  @ack_timeout 5_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  def start_link(opts \\ []) do
    Task.start_link(__MODULE__, :run, [opts])
  end

  def run(_opts) do
    Logger.info("AckSender starting...")

    # Subscribe to CorroSubscriber's message updates
    Phoenix.PubSub.subscribe(CorroPort.PubSub, "message_updates")

    message_loop()
  end

  # Public API for stats/debugging
  def get_status do
    %{status: :running}
  end

  # Private message handling loop
  defp message_loop do
    receive do
      {:new_message, message_map} ->
        handle_new_message(message_map)
        message_loop()

      {:initial_row, _message_map} ->
        # For initial state, we don't send acks
        message_loop()

      {:message_change, change_type, message_map} ->
        handle_message_change(change_type, message_map)
        message_loop()

      # Ignore other CorroSubscriber events
      {:columns_received, _} ->
        message_loop()

      {:subscription_ready} ->
        message_loop()

      {:subscription_connected, _} ->
        message_loop()

      {:subscription_error, _} ->
        message_loop()

      {:subscription_closed, _} ->
        message_loop()

      msg ->
        Logger.debug("AckSender: Unhandled message: #{inspect(msg)}")
        message_loop()
    end
  end

  defp handle_new_message(message_map) do
    case Map.get(message_map, "node_id") do
      nil ->
        Logger.debug("AckSender: Received message without node_id, skipping")

      originating_node_id ->
        local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

        if originating_node_id != local_node_id do
          Logger.info(
            "AckSender: 🤝 Sending acknowledgment for message from #{originating_node_id}"
          )

          # Send acknowledgment in background using direct endpoint communication
          spawn(fn -> send_acknowledgment_to_endpoint(message_map) end)
        else
          Logger.debug("AckSender: Ignoring message from self (#{local_node_id})")
        end
    end
  end

  defp handle_message_change(change_type, message_map) do
    # Only send acks for INSERTs (new messages), not UPDATEs or DELETEs
    if change_type == "INSERT" do
      originating_node_id = Map.get(message_map, "node_id")
      local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

      if originating_node_id && originating_node_id != local_node_id do
        Logger.info("AckSender: 🤝 Sending acknowledgment for INSERT from #{originating_node_id}")

        spawn(fn -> send_acknowledgment_to_endpoint(message_map) end)
      end
    else
      Logger.debug("AckSender: Ignoring #{change_type} change")
    end
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
    ack_url = "#{api_url}/api/acknowledge"

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
