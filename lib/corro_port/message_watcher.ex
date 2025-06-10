defmodule CorroPort.MessageWatcher do
  @moduledoc """
  Watches for changes in the node_messages table via Corrosion's subscription API.

  This GenServer subscribes to changes in the node_messages table and broadcasts
  updates via Phoenix.PubSub so that LiveViews can update in real-time.
  """

  use GenServer
  require Logger

  @subscription_topic "node_messages_updates"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Start the subscription after a short delay to ensure Corrosion is ready
    Process.send_after(self(), :start_subscription, 1000)

    {:ok, %{
      watch_id: nil,
      reconnect_attempts: 0,
      max_reconnect_attempts: 10
    }}
  end

  def handle_info(:start_subscription, state) do
    case start_message_subscription() do
      {:ok, watch_id, _pid} ->
        Logger.info("Started node_messages subscription with ID: #{watch_id}")
        {:noreply, %{state | watch_id: watch_id, reconnect_attempts: 0}}

      {:error, reason} ->
        Logger.warning("Failed to start node_messages subscription: #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  def handle_info(:reconnect, state) do
    if state.reconnect_attempts < state.max_reconnect_attempts do
      Logger.info("Attempting to reconnect to Corrosion subscription (attempt #{state.reconnect_attempts + 1})")
      send(self(), :start_subscription)
      {:noreply, %{state | reconnect_attempts: state.reconnect_attempts + 1}}
    else
      Logger.error("Max reconnection attempts reached for Corrosion subscription")
      {:noreply, state}
    end
  end

  # Handle streaming data from Corrosion
  def handle_info({:stream_data, data}, state) do
    process_streaming_data(data, state.watch_id)
    {:noreply, state}
  end

  # Handle stream headers (to extract watch_id)
  def handle_info({:stream_headers, headers}, state) do
    case List.keyfind(headers, "corro-query-id", 0) do
      {"corro-query-id", watch_id} ->
        Logger.debug("Got watch ID from headers: #{watch_id}")
        {:noreply, %{state | watch_id: watch_id}}
      nil ->
        {:noreply, state}
    end
  end

  # Handle stream status
  def handle_info({:stream_status, status}, state) do
    Logger.debug("Subscription stream status: #{status}")
    {:noreply, state}
  end

  # Handle stream errors or completion
  def handle_info({:stream_error, error}, state) do
    Logger.warning("Stream error in node_messages subscription: #{inspect(error)}")
    schedule_reconnect(state)
  end

  def handle_info({:stream_done, _reason}, state) do
    Logger.info("Node_messages subscription stream completed")
    schedule_reconnect(state)
  end

  # Public API to get the current subscription status
  def get_status do
    GenServer.call(__MODULE__, :get_status, 5000)
  end

  def handle_call(:get_status, _from, state) do
    status = %{
      watch_id: state.watch_id,
      subscription_active: !is_nil(state.watch_id),
      reconnect_attempts: state.reconnect_attempts
    }
    {:reply, status, state}
  end

  # Private functions

  defp start_message_subscription do
    # Get the API port from our configuration
    api_port = CorroPort.CorrosionAPI.get_api_port()
    base_url = "http://127.0.0.1:#{api_port}/v1"
    url = "#{base_url}/subscriptions"

    # SQL query to watch for changes in node_messages table
    # This should be sent as a JSON string, just like other Corrosion API calls
    query = "SELECT * FROM node_messages ORDER BY timestamp DESC"

    parent_pid = self()

    # Streaming function that processes the HTTP stream
    stream_fun = fn
      {:data, data}, acc ->
        send(parent_pid, {:stream_data, data})
        {:cont, acc}

      {:status, status}, acc ->
        send(parent_pid, {:stream_status, status})
        {:cont, acc}

      {:headers, headers}, acc ->
        send(parent_pid, {:stream_headers, headers})
        {:cont, acc}

      {:error, error}, acc ->
        send(parent_pid, {:stream_error, error})
        {:halt, acc}

      {:done, reason}, acc ->
        send(parent_pid, {:stream_done, reason})
        {:halt, acc}

      other, acc ->
        Logger.debug("Unhandled stream event: #{inspect(other)}")
        {:cont, acc}
    end

    Logger.debug("Starting subscription to: #{url} with query: #{query}")

    # Start the subscription request - send the SQL as JSON just like /v1/queries
    case Req.post(url,
           json: query,
           headers: [{"content-type", "application/json"}],
           into: stream_fun,
           receive_timeout: :infinity,
           connect_options: [timeout: 5000]
         ) do
      {:ok, %Req.Response{status: 200, headers: headers}} ->
        case List.keyfind(headers, "corro-query-id", 0) do
          {"corro-query-id", watch_id} ->
            Logger.info("Successfully started subscription with watch ID: #{watch_id}")
            {:ok, watch_id, nil}
          nil ->
            Logger.error("No corro-query-id header in subscription response")
            {:error, :no_watch_id}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Subscription failed with HTTP #{status}: #{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("Failed to start subscription: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_streaming_data(data, watch_id) do
    # Split by newlines and process each JSON object
    data
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      case Jason.decode(line) do
        {:ok, json_data} ->
          enhanced_data = Map.put(json_data, "watch_id", watch_id)
          handle_message_event(enhanced_data)

        {:error, reason} ->
          Logger.debug("Failed to decode JSON line in stream: #{line}, error: #{inspect(reason)}")
      end
    end)
  end

  defp handle_message_event(data) do
    case data do
      %{"eoq" => _time} ->
        Logger.debug("End of query for node_messages subscription")

      %{"columns" => columns} ->
        Logger.debug("Got column names for node_messages: #{inspect(columns)}")

      %{"row" => [_row_id | values]} ->
        Logger.debug("Got new row in node_messages: #{inspect(values)}")
        broadcast_message_update({:new_message, values})

      %{"change" => [change_type, _row_id, values, _change_id]} ->
        Logger.debug("Got #{change_type} change in node_messages: #{inspect(values)}")
        broadcast_message_update({:message_change, change_type, values})

      %{"error" => error_msg} ->
        Logger.error("Error in node_messages subscription: #{error_msg}")

      other ->
        Logger.debug("Unhandled message event: #{inspect(other)}")
    end
  end

  defp broadcast_message_update(update) do
    Phoenix.PubSub.broadcast(CorroPort.PubSub, @subscription_topic, update)
  end

  defp schedule_reconnect(state) do
    # Exponential backoff with jitter
    base_delay = min(1000 * :math.pow(2, state.reconnect_attempts), 30_000)
    jitter = :rand.uniform(1000)
    delay = round(base_delay + jitter)

    Process.send_after(self(), :reconnect, delay)
    {:noreply, %{state | watch_id: nil}}
  end

  # Public function to get the subscription topic for LiveViews
  def subscription_topic, do: @subscription_topic
end
