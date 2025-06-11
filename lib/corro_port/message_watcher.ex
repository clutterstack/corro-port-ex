defmodule CorroPort.MessageWatcher do
  @moduledoc """
  Watches for changes in the node_messages table via Corrosion's subscription API.

  This GenServer subscribes to changes in the node_messages table and broadcasts
  updates via Phoenix.PubSub so that LiveViews can update in real-time.
  """

  use GenServer
  require Logger

  @subscription_topic "SELECT * FROM node_messages ORDER BY timestamp DESC"
  @status_topic "message_watcher_status"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Start the subscription after a short delay to ensure Corrosion is ready
    Process.send_after(self(), :start_subscription, 1000)

    {:ok, %{
      watch_id: nil,
      reconnect_attempts: 0,
      max_reconnect_attempts: 10,
      subscription_task: nil,
      status: :initializing,
      columns: nil,
      last_data_received: nil,
      total_messages_processed: 0
    }}
  end

  def handle_info(:start_subscription, state) do
    # Cancel any existing subscription task
    if state.subscription_task do
      Task.shutdown(state.subscription_task, :brutal_kill)
    end

    # Broadcast status update
    broadcast_status_update(:connecting, state.reconnect_attempts)

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
      Logger.warning("Attempting to reconnect to Corrosion subscription (attempt #{state.reconnect_attempts + 1})")
      send(self(), :start_subscription)
      {:noreply, state}
    else
      Logger.error("Max reconnection attempts reached for Corrosion subscription")
      new_state = %{state | status: :failed}
      broadcast_status_update(:failed, state.reconnect_attempts)
      {:noreply, new_state}
    end
  end

  # Handle task completion
  def handle_info({ref, result}, %{subscription_task: %Task{ref: ref}} = state) do
    # Demonitor the task to prevent DOWN message
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, watch_id} ->
        Logger.info("✅ Started node_messages subscription with ID: #{watch_id}")
        new_state = %{state |
          watch_id: watch_id,
          reconnect_attempts: 0,
          subscription_task: nil,
          status: :connected
        }
        broadcast_status_update(:connected, 0)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("❌ Failed to start node_messages subscription: #{inspect(reason)}")
        new_state = %{state | subscription_task: nil, status: :error}
        broadcast_status_update(:error, state.reconnect_attempts)
        schedule_reconnect(new_state)
    end
  end

  # Handle task failure
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{subscription_task: %Task{ref: ref}} = state) do
    Logger.warning("Subscription task crashed: #{inspect(reason)}")
    new_state = %{state | subscription_task: nil, status: :error}
    broadcast_status_update(:error, state.reconnect_attempts)
    schedule_reconnect(new_state)
  end

  # Handle streaming data from Corrosion
  def handle_info({:stream_data, data}, state) do
    new_state = process_streaming_data(data, state)
    {:noreply, new_state}
  end

  # Handle stream headers (to extract watch_id)
  def handle_info({:stream_headers, headers}, state) do
    case List.keyfind(headers, "corro-query-id", 0) do
      {"corro-query-id", watch_id} ->
        Logger.info("🔗 Got watch ID from headers: #{watch_id}")
        {:noreply, %{state | watch_id: watch_id}}
      nil ->
        {:noreply, state}
    end
  end

  # Handle stream status
  def handle_info({:stream_status, status}, state) do
    Logger.debug("📡 Subscription stream status: #{status}")
    {:noreply, state}
  end

  # Handle stream errors or completion
  def handle_info({:stream_error, error}, state) do
    Logger.warning("💥 Stream error in node_messages subscription: #{inspect(error)}")
    new_state = %{state | status: :error}
    broadcast_status_update(:error, state.reconnect_attempts)
    schedule_reconnect(new_state)
  end

  def handle_info({:stream_done, reason}, state) do
    Logger.info("🏁 Node_messages subscription stream completed: #{inspect(reason)}")
    new_state = %{state | status: :disconnected}
    broadcast_status_update(:disconnected, state.reconnect_attempts)
    schedule_reconnect(new_state)
  end

  def handle_info(:heartbeat, state) do
    Logger.debug("💓 Subscription heartbeat")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("❓ Unhandled message in MessageWatcher: #{inspect(msg)}")
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
          error: "GenServer call timed out",
          last_data_received: nil,
          total_messages_processed: 0
        }
    end
  end

  def handle_call(:get_status, _from, state) do
    status = %{
      watch_id: state.watch_id,
      subscription_active: !is_nil(state.watch_id) && state.status == :connected,
      reconnect_attempts: state.reconnect_attempts,
      status: state.status,
      last_data_received: state.last_data_received,
      total_messages_processed: state.total_messages_processed
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
    query = "SELECT pk, node_id, message, sequence, timestamp FROM node_messages ORDER BY timestamp DESC"

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

    Logger.info("🚀 Starting subscription to: #{url}")
    Logger.debug("   Query: #{query}")

    try do
      # Use persistent connection options to prevent timeouts
      case Req.post(url,
             json: query,
             headers: [
               {"content-type", "application/json"},
               {"connection", "keep-alive"}
             ],
             into: stream_fun,
             receive_timeout: :infinity,
             connect_options: [
               timeout: 10_000,
               protocols: [:http1]  # Force HTTP/1.1 for better streaming
             ],
             pool_timeout: 5_000,
             retry: false  # Don't retry automatically, we handle reconnection
           ) do
        {:ok, %Req.Response{status: 200, headers: headers}} ->
          case List.keyfind(headers, "corro-query-id", 0) do
            {"corro-query-id", watch_id} ->
              Logger.info("✅ Successfully started subscription with watch ID: #{watch_id}")

              # Send a heartbeat to keep the connection alive
              spawn_link(fn -> subscription_heartbeat(parent_pid) end)

              {:ok, watch_id}
            nil ->
              Logger.error("❌ No corro-query-id header in subscription response")
              {:error, :no_watch_id}
          end

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("❌ Subscription failed with HTTP #{status}: #{inspect(body)}")
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          Logger.error("❌ Failed to start subscription: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("💥 Exception in subscription request: #{inspect(e)}")
        {:error, {:exception, e}}
    end
  end

  # Send periodic heartbeats to keep connection alive
  defp subscription_heartbeat(parent_pid) do
    Process.sleep(30_000)  # Every 30 seconds

    if Process.alive?(parent_pid) do
      send(parent_pid, :heartbeat)
      subscription_heartbeat(parent_pid)
    end
  end

  defp process_streaming_data(data, state) do
    # Update last data received timestamp
    updated_state = %{state | last_data_received: DateTime.utc_now()}

    # Split by newlines and process each JSON object
    data
    |> String.split("\n", trim: true)
    |> Enum.reduce(updated_state, fn line, acc_state ->
      case Jason.decode(line) do
        {:ok, json_data} ->
          enhanced_data = Map.put(json_data, "watch_id", state.watch_id)
          handle_message_event(enhanced_data)
          %{acc_state | total_messages_processed: acc_state.total_messages_processed + 1}

        {:error, reason} ->
          Logger.debug("Failed to decode JSON line in stream: #{line}, error: #{inspect(reason)}")
          acc_state
      end
    end)
  end

  defp handle_message_event(data) do
    case data do
      %{"eoq" => time} ->
        Logger.debug("📄 End of query for node_messages subscription at #{time}")

      %{"columns" => columns} ->
        Logger.info("📋 Got column names for node_messages: #{inspect(columns)}")

      %{"row" => [row_id | values]} ->
        Logger.info("📝 Got new row in node_messages: row_id=#{row_id}, values=#{inspect(values)}")
        broadcast_message_update({:new_message, %{row_id: row_id, values: values}})

      %{"change" => [change_type, row_id, values, change_id]} ->
        Logger.info("🔄 Got #{change_type} change in node_messages: row_id=#{row_id}, change_id=#{change_id}")
        Logger.debug("   Values: #{inspect(values)}")
        broadcast_message_update({:message_change, change_type, %{row_id: row_id, values: values, change_id: change_id}})

      %{"error" => error_msg} ->
        Logger.error("❌ Error in node_messages subscription: #{error_msg}")

      other ->
        Logger.debug("❓ Unhandled message event: #{inspect(other)}")
    end
  end

  defp broadcast_message_update(update) do
    Phoenix.PubSub.broadcast(CorroPort.PubSub, @subscription_topic, update)
  end

  defp broadcast_status_update(status, reconnect_attempts) do
    status_data = %{
      status: status,
      reconnect_attempts: reconnect_attempts,
      timestamp: DateTime.utc_now()
    }
    Phoenix.PubSub.broadcast(CorroPort.PubSub, @status_topic, {:status_update, status_data})
  end

  defp schedule_reconnect(state) do
    # Exponential backoff with jitter, but cap the delay
    base_delay = min(1000 * :math.pow(2, state.reconnect_attempts), 10_000)  # Cap at 10s
    jitter = :rand.uniform(1000)
    delay = round(base_delay + jitter)

    Logger.debug("⏰ Scheduling reconnect in #{delay}ms")
    Process.send_after(self(), :reconnect, delay)
    {:noreply, %{state | watch_id: nil, status: :reconnecting}}
  end

  # Public functions for LiveViews
  def subscription_topic, do: @subscription_topic
  def status_topic, do: @status_topic
end
