defmodule CorroPort.MessageWatcher do
  @moduledoc """
  Watches for changes in the node_messages table via Corrosion's subscription API.

  This GenServer subscribes to changes in the node_messages table and broadcasts
  updates via Phoenix.PubSub so that LiveViews can update in real-time.
  """

  use GenServer
  require Logger

  # Use a simple topic name instead of the SQL query
  @subscription_topic "message_updates"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

def init(_opts) do
  Logger.warning("MessageWatcher starting up...")
  # Start the subscription after a short delay to ensure Corrosion is ready
  Process.send_after(self(), :start_subscription, 1000)

  {:ok, %{
    watch_id: nil,
    reconnect_attempts: 0,
    max_reconnect_attempts: 50,
    subscription_task: nil,
    status: :initializing,
    last_heartbeat: nil,
    # New metrics for better status tracking
    last_data_received: nil,
    total_messages_processed: 0,
    connection_established_at: nil
  }}
end

  def handle_info(:start_subscription, state) do
    Logger.warning("MessageWatcher: Attempting to start subscription (attempt #{state.reconnect_attempts + 1})")

    # Cancel any existing subscription task
    if state.subscription_task do
      Task.shutdown(state.subscription_task, :brutal_kill)
    end

    # Start subscription in a separate task to avoid blocking the GenServer
    task = Task.async(fn -> start_message_subscription() end)

    new_state = %{state |
      subscription_task: task,
      status: :connecting,
      reconnect_attempts: state.reconnect_attempts + 1
    }

    {:noreply, new_state}
  end

  def handle_info(:reconnect, state) do
    if state.reconnect_attempts < state.max_reconnect_attempts do
      Logger.warning("MessageWatcher: Attempting to reconnect to Corrosion subscription (attempt #{state.reconnect_attempts + 1})")
      send(self(), :start_subscription)
      {:noreply, state}
    else
      Logger.error("MessageWatcher: Max reconnection attempts reached for Corrosion subscription")
      {:noreply, %{state | status: :failed}}
    end
  end

  # Handle task completion
  def handle_info({ref, result}, %{subscription_task: %Task{ref: ref}} = state) do
  # Demonitor the task to prevent DOWN message
  Process.demonitor(ref, [:flush])

  case result do
    {:ok, watch_id} ->
      Logger.warning("MessageWatcher: ✅ Started node_messages subscription with ID: #{watch_id}")
      # Schedule a heartbeat check
      Process.send_after(self(), :check_heartbeat, 30_000)
      {:noreply, %{state |
        watch_id: watch_id,
        reconnect_attempts: 0,
        subscription_task: nil,
        status: :connected,
        last_heartbeat: System.monotonic_time(:millisecond),
        connection_established_at: DateTime.utc_now()
      }}

    {:error, reason} ->
      Logger.warning("MessageWatcher: ❌ Failed to start node_messages subscription: #{inspect(reason)}")
      new_state = %{state | subscription_task: nil, status: :error}
      schedule_reconnect(new_state)
  end
end

  # Handle task failure
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{subscription_task: %Task{ref: ref}} = state) do
    Logger.warning("MessageWatcher: ❌ Subscription task crashed: #{inspect(reason)}")
    new_state = %{state | subscription_task: nil, status: :error}
    schedule_reconnect(new_state)
  end

  # Heartbeat check to detect dead connections
  def handle_info(:check_heartbeat, state) do
    current_time = System.monotonic_time(:millisecond)

    if state.last_heartbeat && (current_time - state.last_heartbeat) > 120_000 do
      Logger.warning("MessageWatcher: 💔 No heartbeat for >2 minutes, reconnecting...")
      new_state = %{state | status: :stale}
      schedule_reconnect(new_state)
    else
      # Schedule next heartbeat check
      Process.send_after(self(), :check_heartbeat, 30_000)
      {:noreply, state}
    end
  end

  # Handle streaming data from Corrosion
  def handle_info({:stream_data, data}, state) do
  Logger.warning("MessageWatcher: 📨 Received stream data: #{inspect(data)}")

  # Count actual message events (not just any data)
  message_count_increase = count_actual_messages(data)

  new_state = %{state |
    last_heartbeat: System.monotonic_time(:millisecond),
    last_data_received: DateTime.utc_now(),
    total_messages_processed: state.total_messages_processed + message_count_increase
  }

  process_streaming_data(data, state.watch_id)
  {:noreply, new_state}
end

  # Handle stream headers (to extract watch_id)
  def handle_info({:stream_headers, headers}, state) do
    Logger.warning("MessageWatcher: 📋 Received headers: #{inspect(headers)}")
    case List.keyfind(headers, "corro-query-id", 0) do
      {"corro-query-id", watch_id} ->
        Logger.warning("MessageWatcher: 🆔 Got watch ID from headers: #{watch_id}")
        {:noreply, %{state | watch_id: watch_id}}
      nil ->
        Logger.warning("MessageWatcher: ⚠️ No corro-query-id in headers")
        {:noreply, state}
    end
  end

  # Handle stream status
  def handle_info({:stream_status, status}, state) do
    Logger.warning("MessageWatcher: 📡 Subscription stream status: #{status}")
    {:noreply, state}
  end

  # Handle stream errors or completion
  def handle_info({:stream_error, error}, state) do
    Logger.warning("MessageWatcher: ❌ Stream error in node_messages subscription: #{inspect(error)}")
    new_state = %{state | status: :error}
    schedule_reconnect(new_state)
  end

  def handle_info({:stream_done, reason}, state) do
    Logger.warning("MessageWatcher: ✅ Node_messages subscription stream completed: #{inspect(reason)}")
    new_state = %{state | status: :disconnected}
    schedule_reconnect(new_state)
  end

  def handle_info(msg, state) do
    Logger.warning("MessageWatcher: ❓ Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Public API to get the current subscription status
  def get_status do
    try do
      GenServer.call(__MODULE__, :get_status, 1000)
    catch
      :exit, {:timeout, _} ->
        %{
          watch_id: nil,
          subscription_active: false,
          reconnect_attempts: 0,
          status: :timeout,
          error: "GenServer call timed out"
        }
    end
  end

  def handle_call(:get_status, _from, state) do
  status = %{
    watch_id: state.watch_id,
    subscription_active: !is_nil(state.watch_id) && state.status == :connected,
    reconnect_attempts: state.reconnect_attempts,
    status: state.status,
    last_heartbeat: state.last_heartbeat,
    last_data_received: state.last_data_received,
    total_messages_processed: state.total_messages_processed,
    connection_established_at: state.connection_established_at,
    uptime_seconds: calculate_uptime(state.connection_established_at)
  }
  {:reply, status, state}
end

  # Private functions

defp start_message_subscription do
  # Get the API port from our configuration
  api_port = CorroPort.CorrosionClient.get_api_port()
  base_url = "http://127.0.0.1:#{api_port}/v1"
  url = "#{base_url}/subscriptions"

  # SQL query to watch for changes in node_messages table
  query = "SELECT * FROM node_messages ORDER BY timestamp DESC"

  parent_pid = self()

  Logger.warning("MessageWatcher: 🚀 Starting subscription to: #{url} with query: #{query}")

  # Track the watch_id from headers
  watch_id_ref = :atomics.new(1, [])

  # Streaming function that processes the HTTP stream
  stream_fun = fn
    {:data, data}, acc ->
      Logger.warning("MessageWatcher: 📨 Stream data received: #{inspect(data)}")
      send(parent_pid, {:stream_data, data})
      {:cont, acc}

    {:status, status}, acc ->
      Logger.warning("MessageWatcher: 📡 Stream status: #{status}")
      send(parent_pid, {:stream_status, status})
      {:cont, acc}

    {:headers, headers}, acc ->
      Logger.warning("MessageWatcher: 📋 Stream headers: #{inspect(headers)}")
      send(parent_pid, {:stream_headers, headers})

      # Extract watch_id from headers and store it
      case List.keyfind(headers, "corro-query-id", 0) do
        {"corro-query-id", watch_id} ->
          :atomics.put(watch_id_ref, 1, :erlang.binary_to_term(:erlang.term_to_binary(watch_id)))
          Logger.warning("MessageWatcher: 🆔 Stored watch ID: #{watch_id}")
        nil ->
          Logger.warning("MessageWatcher: ⚠️ No corro-query-id in headers")
      end

      {:cont, acc}

    {:error, error}, acc ->
      Logger.warning("MessageWatcher: ❌ Stream error: #{inspect(error)}")
      send(parent_pid, {:stream_error, error})
      {:halt, acc}

    {:done, reason}, acc ->
      Logger.warning("MessageWatcher: ✅ Stream done: #{inspect(reason)}")
      send(parent_pid, {:stream_done, reason})
      {:halt, acc}

    other, acc ->
      Logger.warning("MessageWatcher: ❓ Unhandled stream event: #{inspect(other)}")
      {:cont, acc}
  end

  try do
    # Start the subscription request with better connection settings
    case Req.post(url,
           json: query,
           headers: [
             {"content-type", "application/json"},
             {"connection", "keep-alive"},
             {"cache-control", "no-cache"}
           ],
           into: stream_fun,
           receive_timeout: :infinity,
           connect_options: [
             timeout: 5000,
             protocols: [:http1]  # Force HTTP/1.1 for better streaming
           ],
           pool_timeout: 5000,
           retry: false  # Don't retry automatically, we handle reconnection
         ) do
      {:ok, %Req.Response{status: 200, headers: headers}} ->
        # Extract watch_id from response headers
        case List.keyfind(headers, "corro-query-id", 0) do
          {"corro-query-id", watch_id} ->
            Logger.warning("MessageWatcher: ✅ Successfully started subscription with watch ID: #{watch_id}")
            {:ok, watch_id}
          nil ->
            # Try to get it from the atomic reference (in case it came through the stream)
            try do
              stored_id = :atomics.get(watch_id_ref, 1)
              if stored_id != 0 do
                watch_id = :erlang.binary_to_term(:erlang.term_to_binary(stored_id))
                Logger.warning("MessageWatcher: ✅ Got watch ID from stream: #{watch_id}")
                {:ok, watch_id}
              else
                Logger.error("MessageWatcher: ❌ No corro-query-id header in subscription response")
                {:error, :no_watch_id}
              end
            rescue
              _ ->
                Logger.error("MessageWatcher: ❌ No corro-query-id header in subscription response")
                {:error, :no_watch_id}
            end
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("MessageWatcher: ❌ Subscription failed with HTTP #{status}: #{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("MessageWatcher: ❌ Failed to start subscription: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("MessageWatcher: ❌ Exception in subscription request: #{inspect(e)}")
      {:error, {:exception, e}}
  end
end

defp process_streaming_data(data, watch_id) do
    Logger.warning("MessageWatcher: 🔍 Processing streaming data: #{inspect(data)}")

    # Split by newlines and process each JSON object
    data
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      Logger.warning("MessageWatcher: 📝 Processing line: #{line}")
      case Jason.decode(line) do
        {:ok, json_data} ->
          Logger.warning("MessageWatcher: ✅ Decoded JSON: #{inspect(json_data)}")
          enhanced_data = Map.put(json_data, "watch_id", watch_id)
          handle_message_event(enhanced_data)

        {:error, reason} ->
          Logger.warning("MessageWatcher: ❌ Failed to decode JSON line: #{line}, error: #{inspect(reason)}")
      end
    end)
  end

  defp handle_message_event(data) do
    Logger.warning("MessageWatcher: 🎯 Handling message event: #{inspect(data)}")

    case data do
      %{"eoq" => _time} ->
        Logger.warning("MessageWatcher: 🏁 End of query for node_messages subscription")

      %{"columns" => columns} ->
        Logger.warning("MessageWatcher: 📊 Got column names for node_messages: #{inspect(columns)}")

      %{"row" => [_row_id | values]} ->
        Logger.warning("MessageWatcher: 📨 Got new row in node_messages: #{inspect(values)}")
        broadcast_message_update({:new_message, values})

      %{"change" => [change_type, _row_id, values, _change_id]} ->
        Logger.warning("MessageWatcher: 🔄 Got #{change_type} change in node_messages: #{inspect(values)}")
        broadcast_message_update({:message_change, change_type, values})

      %{"error" => error_msg} ->
        Logger.error("MessageWatcher: ❌ Error in node_messages subscription: #{error_msg}")

      other ->
        Logger.warning("MessageWatcher: ❓ Unhandled message event: #{inspect(other)}")
    end
  end

  defp broadcast_message_update(update) do
    Logger.warning("MessageWatcher: 📢 Broadcasting update: #{inspect(update)} on topic: #{@subscription_topic}")
    result = Phoenix.PubSub.broadcast(CorroPort.PubSub, @subscription_topic, update)
    Logger.warning("MessageWatcher: 📢 Broadcast result: #{inspect(result)}")
  end

  defp schedule_reconnect(state) do
    # Shorter, more aggressive reconnection schedule
    base_delay = min(2000 * state.reconnect_attempts, 30_000)  # Cap at 30s
    jitter = :rand.uniform(1000)
    delay = round(base_delay + jitter)

    Logger.warning("MessageWatcher: ⏰ Scheduling reconnect in #{delay}ms")
    Process.send_after(self(), :reconnect, delay)
    {:noreply, %{state | watch_id: nil, status: :reconnecting}}
  end


  # Helper function to count actual message events vs metadata
defp count_actual_messages(data) do
  data
  |> String.split("\n", trim: true)
  |> Enum.count(fn line ->
    case Jason.decode(line) do
      {:ok, %{"row" => _}} -> true
      {:ok, %{"change" => _}} -> true
      _ -> false
    end
  end)
end


defp calculate_uptime(nil), do: nil
defp calculate_uptime(connection_time) do
  DateTime.diff(DateTime.utc_now(), connection_time, :second)
end

  # Public function to get the subscription topic for LiveViews
  def subscription_topic, do: @subscription_topic
end
