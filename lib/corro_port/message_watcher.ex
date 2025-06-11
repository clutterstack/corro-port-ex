defmodule CorroPort.MessageWatcher do
  @moduledoc """
  Watches for changes in the node_messages table via Corrosion's subscription API.

  This GenServer manages a long-running HTTP streaming connection to Corrosion's
  subscription endpoint. The stream stays open indefinitely and sends us updates
  as they happen.
  """

  use GenServer
  require Logger

  @subscription_topic "message_updates"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    Logger.warning("MessageWatcher starting up...")
    # Start the subscription after a short delay to ensure Corrosion is ready
    Process.send_after(self(), :start_subscription, 1000)

    {:ok, %{
      stream_pid: nil,
      reconnect_attempts: 0,
      max_reconnect_attempts: 50,
      status: :initializing,
      last_data_received: nil,
      total_messages_processed: 0,
      connection_established_at: nil,
      columns: nil,
      initial_state_received: false
    }}
  end

  def handle_info(:start_subscription, state) do
    Logger.warning("MessageWatcher: Attempting to start subscription (attempt #{state.reconnect_attempts + 1})")

    # Kill any existing stream process
    if state.stream_pid do
      Process.exit(state.stream_pid, :kill)
    end

    # Start the streaming connection in a separate process
    parent_pid = self()
    stream_pid = spawn_link(fn -> run_subscription_stream(parent_pid) end)

    new_state = %{state |
      stream_pid: stream_pid,
      status: :connecting,
      reconnect_attempts: state.reconnect_attempts + 1,
      columns: nil,
      initial_state_received: false
    }

    {:noreply, new_state}
  end

  def handle_info(:reconnect, state) do
    if state.reconnect_attempts < state.max_reconnect_attempts do
      Logger.warning("MessageWatcher: Attempting to reconnect (attempt #{state.reconnect_attempts + 1})")
      send(self(), :start_subscription)
      {:noreply, state}
    else
      Logger.error("MessageWatcher: Max reconnection attempts reached")
      {:noreply, %{state | status: :failed}}
    end
  end

  # Handle messages from the streaming process
  def handle_info({:subscription_connected}, state) do
    Logger.warning("MessageWatcher: ✅ Subscription stream connected")
    {:noreply, %{state |
      status: :connected,
      reconnect_attempts: 0,
      connection_established_at: DateTime.utc_now()
    }}
  end

  def handle_info({:subscription_data, data}, state) do
    Logger.warning("MessageWatcher: 📨 Received stream data (#{byte_size(data)} bytes)")

    updated_state = process_streaming_data(data, state)

    new_state = %{updated_state |
      last_data_received: DateTime.utc_now()
    }

    {:noreply, new_state}
  end

  def handle_info({:subscription_error, error}, state) do
    Logger.warning("MessageWatcher: ❌ Subscription error: #{inspect(error)}")
    new_state = %{state | status: :error, stream_pid: nil}
    schedule_reconnect(new_state)
  end

  def handle_info({:subscription_closed, reason}, state) do
    Logger.warning("MessageWatcher: 🔌 Subscription closed: #{inspect(reason)}")
    new_state = %{state | status: :disconnected, stream_pid: nil}
    schedule_reconnect(new_state)
  end

  # Handle process exits from the stream process
  def handle_info({:EXIT, pid, reason}, %{stream_pid: pid} = state) do
    Logger.warning("MessageWatcher: ❌ Stream process crashed: #{inspect(reason)}")
    new_state = %{state | status: :error, stream_pid: nil}
    schedule_reconnect(new_state)
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # Some other process exited, ignore
    {:noreply, state}
  end

  def handle_info({:new_message, message_map}, socket) do
  Logger.info("MessageWatcher received new message: #{inspect(message_map)}")

  local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()
  originating_node_id = message_map["node_id"]

  # Handle acknowledgment logic
  cond do
    # Message is from another node - send acknowledgment
    originating_node_id != local_node_id ->
      Logger.info("MessageWatcher: Received message from #{originating_node_id}, sending acknowledgment")
      send_acknowledgment_async(originating_node_id, message_map)

    # Message is from our local node - track it for acknowledgment monitoring
    originating_node_id == local_node_id ->
      Logger.info("MessageWatcher: Our message propagated back, tracking for acknowledgments")
      track_our_message(message_map)

    true ->
      Logger.warning("MessageWatcher: Could not determine message origin: #{inspect(message_map)}")
  end

  # Broadcast to LiveView (existing logic)
  Phoenix.PubSub.broadcast(CorroPort.PubSub, "live_updates", {:new_message, message_map})

  {:noreply, socket}
end


  def handle_info(msg, state) do
    Logger.warning("MessageWatcher: ❓ Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  def handle_call(:restart_subscription, _from, state) do
    Logger.warning("MessageWatcher: 🔄 Manual restart requested")

    # Kill existing stream if any
    if state.stream_pid do
      Process.exit(state.stream_pid, :kill)
    end

    send(self(), :start_subscription)

    new_state = %{state |
      stream_pid: nil,
      status: :restarting,
      reconnect_attempts: 0
    }

    {:reply, :ok, new_state}
  end

  def handle_call(:get_status, _from, state) do
    status = %{
      subscription_active: state.status == :connected && !is_nil(state.stream_pid),
      reconnect_attempts: state.reconnect_attempts,
      status: state.status,
      last_data_received: state.last_data_received,
      total_messages_processed: state.total_messages_processed,
      connection_established_at: state.connection_established_at,
      uptime_seconds: calculate_uptime(state.connection_established_at),
      columns: state.columns,
      initial_state_received: state.initial_state_received,
      stream_pid: state.stream_pid
    }
    {:reply, status, state}
  end

  # Public API
  def get_status do
    try do
      GenServer.call(__MODULE__, :get_status, 1000)
    catch
      :exit, {:timeout, _} ->
        %{
          subscription_active: false,
          status: :timeout,
          error: "GenServer call timed out"
        }
    end
  end

  def restart_subscription do
    GenServer.call(__MODULE__, :restart_subscription)
  end

  def subscription_topic, do: @subscription_topic

  # Private functions

  defp run_subscription_stream(parent_pid) do
    api_port = CorroPort.CorrosionClient.get_api_port()
    url = "http://127.0.0.1:#{api_port}/v1/subscriptions"
    query = "SELECT * FROM node_messages ORDER BY timestamp DESC"

    Logger.warning("MessageWatcher: 🚀 Starting subscription stream to #{url}")

    # Function to handle streaming data chunks
    stream_fun = fn
      {:data, data}, acc ->
        send(parent_pid, {:subscription_data, data})
        {:cont, acc}

      {:status, 200}, acc ->
        send(parent_pid, {:subscription_connected})
        {:cont, acc}

      {:status, status}, acc ->
        Logger.error("MessageWatcher: ❌ HTTP status #{status}")
        send(parent_pid, {:subscription_error, {:http_status, status}})
        {:halt, acc}

      {:headers, headers}, acc ->
        Logger.warning("MessageWatcher: 📋 Got headers: #{inspect(headers)}")
        {:cont, acc}

      {:error, error}, acc ->
        Logger.error("MessageWatcher: ❌ Stream error: #{inspect(error)}")
        send(parent_pid, {:subscription_error, error})
        {:halt, acc}

      {:done, reason}, acc ->
        Logger.warning("MessageWatcher: 🔌 Stream done: #{inspect(reason)}")
        send(parent_pid, {:subscription_closed, reason})
        {:halt, acc}

      other, acc ->
        Logger.warning("MessageWatcher: ❓ Unhandled stream event: #{inspect(other)}")
        {:cont, acc}
    end

    try do
      Logger.warning("MessageWatcher: 📡 Making subscription request...")

      result = Req.post(url,
             json: query,
             headers: [
               {"content-type", "application/json"},
               {"connection", "keep-alive"},
               {"cache-control", "no-cache"}
             ],
             into: stream_fun,
             receive_timeout: :infinity,
             connect_options: [
               timeout: 10_000,
               protocols: [:http1]
             ],
             pool_timeout: 10_000,
             retry: false
           )

      Logger.warning("MessageWatcher: 📡 Subscription request result: #{inspect(result)}")

      case result do
        {:ok, %Req.Response{status: 200}} ->
          Logger.warning("MessageWatcher: ✅ Subscription completed normally")

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("MessageWatcher: ❌ Subscription failed with HTTP #{status}: #{inspect(body)}")
          send(parent_pid, {:subscription_error, {:http_error, status, body}})

        {:error, reason} ->
          Logger.error("MessageWatcher: ❌ Subscription request failed: #{inspect(reason)}")
          send(parent_pid, {:subscription_error, reason})
      end
    rescue
      e ->
        Logger.error("MessageWatcher: ❌ Exception in subscription: #{inspect(e)}")
        Logger.error("MessageWatcher: ❌ Exception stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}")
        send(parent_pid, {:subscription_error, {:exception, e}})
    end
  end

  defp process_streaming_data(data, state) do
    # Split by newlines and process each JSON object
    lines = String.split(data, "\n", trim: true)
    Logger.warning("MessageWatcher: 🔍 Processing #{length(lines)} JSON lines")

    # Process lines sequentially, maintaining state across them
    final_state = Enum.reduce(lines, state, fn line, acc_state ->
      trimmed_line = String.trim(line)

      if trimmed_line == "" do
        acc_state
      else
        case Jason.decode(trimmed_line) do
          {:ok, json_data} ->
            handle_message_event(json_data, acc_state)

          {:error, reason} ->
            Logger.warning("MessageWatcher: ❌ Failed to decode JSON: #{String.slice(trimmed_line, 0, 100)}..., error: #{inspect(reason)}")
            acc_state
        end
      end
    end)

    final_state
  end

  defp handle_message_event(data, state) do
    case data do
      %{"eoq" => _time} ->
        Logger.warning("MessageWatcher: 🏁 End of initial query - subscription is now live")
        broadcast_event({:subscription_ready})
        %{state | initial_state_received: true}

      %{"columns" => columns} ->
        Logger.warning("MessageWatcher: 📊 Got column names: #{inspect(columns)}")
        broadcast_event({:columns_received, columns})
        %{state | columns: columns}

      %{"row" => [_row_id, values]} when not is_nil(state.columns) ->
        message_map = build_message_map(values, state.columns)
        Logger.warning("MessageWatcher: 📨 Row: #{inspect(message_map)}")

        if state.initial_state_received do
          # This is a new row after initial state was loaded
          broadcast_event({:new_message, message_map})
        else
          # This is part of the initial state dump
          broadcast_event({:initial_row, message_map})
        end

        %{state | total_messages_processed: state.total_messages_processed + 1}

      %{"change" => [change_type, _change_id, values, _version]} when not is_nil(state.columns) ->
        message_map = build_message_map(values, state.columns)
        Logger.warning("MessageWatcher: 🔄 Change #{change_type}: #{inspect(message_map)}")
        broadcast_event({:message_change, String.upcase(change_type), message_map})
        %{state | total_messages_processed: state.total_messages_processed + 1}

      %{"row" => _} ->
        Logger.warning("MessageWatcher: ⚠️ Got row data but no columns stored yet")
        state

      %{"change" => _} ->
        Logger.warning("MessageWatcher: ⚠️ Got change data but no columns stored yet")
        state

      %{"error" => error_msg} ->
        Logger.error("MessageWatcher: ❌ Subscription error: #{error_msg}")
        state

      other ->
        Logger.warning("MessageWatcher: ❓ Unhandled message event: #{inspect(other)}")
        state
    end
  end

  defp build_message_map(values, columns) when is_list(values) and is_list(columns) do
    if length(values) == length(columns) do
      result = Enum.zip(columns, values) |> Enum.into(%{})
      result
    else
      Logger.warning("MessageWatcher: ⚠️ Mismatch: #{length(values)} values vs #{length(columns)} columns")
      %{}
    end
  end

  defp build_message_map(values, columns) do
    Logger.warning("MessageWatcher: ⚠️ Unable to build message map from values: #{inspect(values)} and columns: #{inspect(columns)}")
    %{}
  end

  defp broadcast_event(event) do
    Logger.warning("MessageWatcher: 📢 Broadcasting: #{inspect(event)}")
    Phoenix.PubSub.broadcast(CorroPort.PubSub, @subscription_topic, event)
  end

  defp schedule_reconnect(state) do
    # Exponential backoff with jitter, capped at 30 seconds
    base_delay = min(2000 * :math.pow(2, state.reconnect_attempts), 30_000)
    jitter = :rand.uniform(1000)
    delay = round(base_delay + jitter)

    Logger.warning("MessageWatcher: ⏰ Scheduling reconnect in #{delay}ms")
    Process.send_after(self(), :reconnect, delay)
    {:noreply, %{state | status: :reconnecting}}
  end

  defp calculate_uptime(nil), do: nil
  defp calculate_uptime(connection_time) do
    DateTime.diff(DateTime.utc_now(), connection_time, :second)
  end

  defp send_acknowledgment_async(originating_node_id, message_map) do
  # Send acknowledgment in a separate task to avoid blocking MessageWatcher
  Task.start(fn ->
    message_data = %{
      pk: message_map["pk"],
      timestamp: message_map["timestamp"],
      node_id: message_map["node_id"]
    }

    case CorroPort.AcknowledgmentSender.send_acknowledgment(originating_node_id, message_data) do
      :ok ->
        Logger.info("MessageWatcher: Successfully sent acknowledgment to #{originating_node_id}")

      {:error, reason} ->
        Logger.warning("MessageWatcher: Failed to send acknowledgment to #{originating_node_id}: #{inspect(reason)}")
    end
  end)
end

defp track_our_message(message_map) do
  # Only track messages that originated from our "Send Message" button
  # We can identify these by checking if they match our expected format
  local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

  # Check if this looks like a message we sent via the UI
  # (vs. some other kind of corrosion message)
  if is_our_ui_message?(message_map, local_node_id) do
    message_data = %{
      pk: message_map["pk"],
      timestamp: message_map["timestamp"],
      node_id: message_map["node_id"]
    }

    Logger.info("MessageWatcher: Tracking our UI message #{message_data.pk} for acknowledgments")
    CorroPort.AcknowledgmentTracker.track_latest_message(message_data)
  else
    Logger.debug("MessageWatcher: Skipping acknowledgment tracking for non-UI message")
  end
end

defp is_our_ui_message?(message_map, local_node_id) do
  # Simple heuristic: messages from our UI contain our node_id and have the expected structure
  # In the future, we could add a special marker to UI messages to distinguish them
  message_map["node_id"] == local_node_id and
  not is_nil(message_map["message"]) and
  not is_nil(message_map["pk"]) and
  not is_nil(message_map["timestamp"])
end
end
