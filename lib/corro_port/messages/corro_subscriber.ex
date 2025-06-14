defmodule CorroPort.CorroSubscriber do
  @moduledoc """
  Watches for changes in the node_messages table via Corrosion's subscription API.

  This GenServer manages a long-running HTTP streaming connection to Corrosion's
  subscription endpoint. The stream stays open indefinitely and sends us updates
  as they happen.

  Now also handles acknowledgment sending when receiving messages from other nodes.
  """

  use GenServer
  require Logger

  @subscription_topic "message_updates"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Start the subscription after a short delay to ensure Corrosion is ready
    Process.send_after(self(), :start_subscription, 1000)

    {:ok,
     %{
       stream_pid: nil,
       reconnect_attempts: 0,
       max_reconnect_attempts: 50,
       status: :initializing,
       last_data_received: nil,
       total_messages_processed: 0,
       connection_established_at: nil,
       columns: nil,
       initial_state_received: false,
       # Track acknowledgments sent
       acknowledgments_sent: 0,
       last_ack_sent: nil,
       # Add watch_id tracking like CorroWatch
       watch_id: nil
     }}
  end

  def handle_info(:start_subscription, state) do
    # Kill any existing stream process
    if state.stream_pid do
      Process.exit(state.stream_pid, :kill)
    end

    # Start the streaming connection in a separate process
    parent_pid = self()
    stream_pid = spawn_link(fn -> run_subscription_stream(parent_pid) end)

    new_state = %{
      state
      | stream_pid: stream_pid,
        status: :connecting,
        reconnect_attempts: state.reconnect_attempts + 1,
        columns: nil,
        initial_state_received: false,
        watch_id: nil
    }

    {:noreply, new_state}
  end

  def handle_info(:reconnect, state) do
    if state.reconnect_attempts < state.max_reconnect_attempts do
      send(self(), :start_subscription)
      {:noreply, state}
    else
      Logger.error("CorroSubscriber: Max reconnection attempts reached")
      {:noreply, %{state | status: :failed}}
    end
  end

  # Handle messages from the streaming process
  def handle_info({:subscription_connected, watch_id}, state) do
    Logger.info("CorroSubscriber: ✅ Subscription stream connected with watch_id: #{watch_id}")

    {:noreply,
     %{
       state
       | status: :connected,
         reconnect_attempts: 0,
         connection_established_at: DateTime.utc_now(),
         watch_id: watch_id
     }}
  end

  def handle_info({:subscription_data, data}, state) do
    updated_state = process_streaming_data(data, state)
    new_state = %{updated_state | last_data_received: DateTime.utc_now()}
    {:noreply, new_state}
  end

  def handle_info({:subscription_error, error}, state) do
    Logger.warning("CorroSubscriber: ❌ Subscription error: #{inspect(error)}")
    new_state = %{state | status: :error, stream_pid: nil, watch_id: nil}
    schedule_reconnect(new_state)
  end

  def handle_info({:subscription_closed, reason}, state) do
    Logger.warning("CorroSubscriber: 🔌 Subscription closed: #{inspect(reason)}")
    new_state = %{state | status: :disconnected, stream_pid: nil, watch_id: nil}
    schedule_reconnect(new_state)
  end

  # Handle process exits from the stream process
  def handle_info({:EXIT, pid, reason}, %{stream_pid: pid} = state) do
    Logger.warning("CorroSubscriber: ❌ Stream process crashed: #{inspect(reason)}")
    new_state = %{state | status: :error, stream_pid: nil, watch_id: nil}
    schedule_reconnect(new_state)
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # Some other process exited, ignore
    {:noreply, state}
  end

  def handle_info({:new_message, message_map}, socket) do
    local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()
    originating_node_id = message_map["node_id"]

    # Handle acknowledgment logic
    cond do
      # Message is from another node - send acknowledgment
      originating_node_id != local_node_id ->
        send_ack_async(originating_node_id, message_map)

      # Message is from our local node - track it for acknowledgment monitoring
      originating_node_id == local_node_id ->
        track_our_message(message_map)

      true ->
        Logger.warning("CorroSubscriber: Could not determine message origin: #{inspect(message_map)}")
    end

    # Broadcast to LiveView (existing logic)
    Phoenix.PubSub.broadcast(CorroPort.PubSub, "live_updates", {:new_message, message_map})

    {:noreply, socket}
  end

  def handle_info(msg, state) do
    Logger.warning("CorroSubscriber: ❓ Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  def handle_call(:restart_subscription, _from, state) do
    Logger.info("CorroSubscriber: 🔄 Manual restart requested")

    # Kill existing stream if any
    if state.stream_pid do
      Process.exit(state.stream_pid, :kill)
    end

    send(self(), :start_subscription)

    new_state = %{state | stream_pid: nil, status: :restarting, reconnect_attempts: 0, watch_id: nil}

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
      stream_pid: state.stream_pid,
      watch_id: state.watch_id,
      # New acknowledgment stats
      acknowledgments_sent: state.acknowledgments_sent,
      last_ack_sent: state.last_ack_sent
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

  # Private functions - REWRITTEN to follow CorroWatch pattern

  defp run_subscription_stream(parent_pid) do
    api_port = CorroPort.CorrosionClient.get_api_port()
    url = "http://127.0.0.1:#{api_port}/v1/subscriptions"
    query = "SELECT * FROM node_messages ORDER BY timestamp DESC"

    # Encode query as JSON string like CorroWatch does
    json_query = Jason.encode!(query)

    Logger.info("CorroSubscriber: 🚀 Starting subscription stream to #{url}")

    # Use the proven CorroWatch streaming pattern
    finch_fun = fn request, finch_req, finch_name, finch_opts ->
      finch_acc = fn
        {:status, status}, response ->
          if status == 200 do
            # Don't send connected until we get the watch_id
            %Req.Response{response | status: status}
          else
            send(parent_pid, {:subscription_error, {:http_status, status}})
            %Req.Response{response | status: status}
          end

        {:headers, headers}, response ->
          # Extract watch_id like CorroWatch does
          case Enum.find(headers, fn {key, _} -> key == "corro-query-id" end) do
            {"corro-query-id", watch_id} ->
              send(parent_pid, {:subscription_connected, watch_id})
              %Req.Response{response | headers: headers}
            _ ->
              Logger.warning("CorroSubscriber: No corro-query-id found in headers")
              %Req.Response{response | headers: headers}
          end

        {:data, data}, response ->
          # Process data like CorroWatch does
          send(parent_pid, {:subscription_data, data})
          response
      end

      case Finch.stream(finch_req, finch_name, Req.Response.new(), finch_acc, [finch_opts, receive_timeout: :infinity]) do
        {:ok, response} ->
          Logger.info("CorroSubscriber: ✅ Finch.stream completed successfully")
          send(parent_pid, {:subscription_closed, :normal})
          {request, response}

        {:error, exception} ->
          Logger.error("CorroSubscriber: ❌ Finch.stream error: #{inspect(exception)}")
          send(parent_pid, {:subscription_error, {:finch_error, exception}})
          {request, exception}
      end
    end

    try do
      # Use Req.post! with custom finch_request like CorroWatch
      Req.post!(
        url,
        headers: [{"content-type", "application/json"}],
        body: json_query,
        connect_options: [transport_opts: [inet6: true]],
        finch_request: finch_fun
      )
    rescue
      e ->
        Logger.error("CorroSubscriber: ❌ Exception in subscription: #{inspect(e)}")
        Logger.error("CorroSubscriber: ❌ Exception stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}")
        send(parent_pid, {:subscription_error, {:exception, e}})
    end
  end

  defp process_streaming_data(data, state) do
    # Split by newlines and process each JSON object like CorroWatch
    lines = String.split(data, "\n", trim: true)

    # Process lines sequentially, maintaining state across them
    final_state =
      Enum.reduce(lines, state, fn line, acc_state ->
        trimmed_line = String.trim(line)

        if trimmed_line == "" do
          acc_state
        else
          case Jason.decode(trimmed_line) do
            {:ok, json_data} ->
              # Add watch_id to the data like CorroWatch does
              json_with_watch_id = Map.put(json_data, "watch_id", state.watch_id)
              handle_message_event(json_with_watch_id, acc_state)

            {:error, reason} ->
              Logger.warning("CorroSubscriber: ❌ Failed to decode JSON: #{String.slice(trimmed_line, 0, 100)}..., error: #{inspect(reason)}")
              acc_state
          end
        end
      end)

    final_state
  end

  defp handle_message_event(data, state) do
    case data do
      %{"eoq" => _time} ->
        Logger.info("CorroSubscriber: 🏁 End of initial query - subscription is now live")
        broadcast_event({:subscription_ready})

        %{
          state
          | initial_state_received: true,
            status: :connected,
            connection_established_at: DateTime.utc_now(),
            reconnect_attempts: 0
        }

      %{"columns" => columns} ->
        Logger.info("CorroSubscriber: 📊 Got column names: #{inspect(columns)}")
        broadcast_event({:columns_received, columns})
        %{state | columns: columns}

      %{"row" => [_row_id, values]} when not is_nil(state.columns) ->
        message_map = build_message_map(values, state.columns)

        if state.initial_state_received do
          # This is a new row after initial state was loaded
          broadcast_event({:new_message, message_map})
          handle_new_message_acknowledgment(message_map, state)
        else
          # This is part of the initial state dump
          broadcast_event({:initial_row, message_map})
          state
        end

      %{"change" => [change_type, _change_id, values, _version]} when not is_nil(state.columns) ->
        message_map = build_message_map(values, state.columns)
        broadcast_event({:message_change, String.upcase(change_type), message_map})

        new_state = %{state | total_messages_processed: state.total_messages_processed + 1}

        if String.upcase(change_type) == "INSERT" do
          handle_new_message_acknowledgment(message_map, new_state)
        else
          new_state
        end

      %{"row" => _} ->
        Logger.warning("CorroSubscriber: ⚠️ Got row data but no columns stored yet")
        state

      %{"change" => _} ->
        Logger.warning("CorroSubscriber: ⚠️ Got change data but no columns stored yet")
        state

      %{"error" => error_msg} ->
        Logger.error("CorroSubscriber: ❌ Subscription error: #{error_msg}")
        state

      other ->
        Logger.warning("CorroSubscriber: ❓ Unhandled message event: #{inspect(other)}")
        state
    end
  end

  # [Rest of the functions remain the same...]

  defp handle_new_message_acknowledgment(message_map, state) do
    if map_size(message_map) == 0 do
      state
    else
      local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()
      message_node_id = Map.get(message_map, "node_id")
      message_pk = Map.get(message_map, "pk")

      case {message_node_id, message_pk} do
        {nil, _} ->
          state

        {_, nil} ->
          state

        {^local_node_id, _} ->
          state

        {other_node_id, pk} ->
          message_data = %{
            pk: pk,
            timestamp: Map.get(message_map, "timestamp"),
            node_id: other_node_id
          }

          spawn(fn ->
            case CorroPort.AcknowledgmentSender.send_acknowledgment(other_node_id, message_data) do
              :ok ->
                Logger.info("CorroSubscriber: ✅ Successfully sent acknowledgment to #{other_node_id}")

              {:error, reason} ->
                Logger.warning("CorroSubscriber: ❌ Failed to send acknowledgment to #{other_node_id}: #{inspect(reason)}")
            end
          end)

          %{
            state
            | total_messages_processed: state.total_messages_processed + 1,
              acknowledgments_sent: state.acknowledgments_sent + 1,
              last_ack_sent: DateTime.utc_now()
          }
      end
    end
  end

  defp build_message_map(values, columns) when is_list(values) and is_list(columns) do
    if length(values) == length(columns) do
      Enum.zip(columns, values) |> Enum.into(%{})
    else
      Logger.warning("CorroSubscriber: ⚠️ Mismatch: #{length(values)} values vs #{length(columns)} columns")
      %{}
    end
  end

  defp build_message_map(values, columns) do
    Logger.warning("CorroSubscriber: ⚠️ Unable to build message map from values: #{inspect(values)} and columns: #{inspect(columns)}")
    %{}
  end

  defp broadcast_event(event) do
    Phoenix.PubSub.broadcast(CorroPort.PubSub, @subscription_topic, event)
  end

  defp schedule_reconnect(state) do
    # Exponential backoff with jitter, capped at 30 seconds
    base_delay = min(2000 * :math.pow(2, state.reconnect_attempts), 30_000)
    jitter = :rand.uniform(1000)
    delay = round(base_delay + jitter)

    Logger.warning("CorroSubscriber: ⏰ Scheduling reconnect in #{delay}ms")
    Process.send_after(self(), :reconnect, delay)
    {:noreply, %{state | status: :reconnecting}}
  end

  defp calculate_uptime(nil), do: nil

  defp calculate_uptime(connection_time) do
    DateTime.diff(DateTime.utc_now(), connection_time, :second)
  end

  defp send_ack_async(originating_node_id, message_map) do
    Task.start(fn ->
      message_data = %{
        pk: message_map["pk"],
        timestamp: message_map["timestamp"],
        node_id: message_map["node_id"]
      }

      case CorroPort.AcknowledgmentSender.send_acknowledgment(originating_node_id, message_data) do
        :ok ->
          Logger.info("CorroSubscriber: Successfully sent acknowledgment to #{originating_node_id}")

        {:error, reason} ->
          Logger.warning("CorroSubscriber: Failed to send acknowledgment to #{originating_node_id}: #{inspect(reason)}")
      end
    end)
  end

  defp track_our_message(message_map) do
    current_status = CorroPort.AckTracker.get_status()
    message_pk = Map.get(message_map, "pk")

    case current_status.latest_message do
      %{pk: current_pk} ->
        if current_pk == message_pk do
          # Already tracking this message, skip
        else
          track_new_message(message_map)
        end

      _ ->
        track_new_message(message_map)
    end
  end

  defp track_new_message(message_map) do
    local_node_id = CorroPort.NodeConfig.get_corrosion_node_id()

    if is_our_ui_message?(message_map, local_node_id) do
      message_data = %{
        pk: message_map["pk"],
        timestamp: message_map["timestamp"],
        node_id: message_map["node_id"]
      }

      CorroPort.AckTracker.track_latest_message(message_data)
    end
  end

  defp is_our_ui_message?(message_map, local_node_id) do
    message_map["node_id"] == local_node_id and
      not is_nil(message_map["message"]) and
      not is_nil(message_map["pk"]) and
      not is_nil(message_map["timestamp"])
  end
end
