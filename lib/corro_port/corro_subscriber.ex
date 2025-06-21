defmodule CorroPort.CorroSubscriber do
  @moduledoc """
  Watches for changes in the node_messages table via Corrosion's subscription API.

  This GenServer manages a long-running HTTP streaming connection to Corrosion's
  subscription endpoint and broadcasts events via PubSub for other modules to handle.
  """

  use GenServer
  require Logger

  @max_reconnect_attempts 5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    Process.send_after(self(), :start_subscription, 1000)

    {:ok,
     %{
       stream_pid: nil,
       attempts_left: @max_reconnect_attempts,
       max_reconnect_attempts: @max_reconnect_attempts,
       status: :initializing,
       columns: nil,
       initial_state_received: false,
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
        attempts_left: @max_reconnect_attempts,
        columns: nil,
        initial_state_received: false,
        watch_id: nil
    }

    {:noreply, new_state}
  end

  def handle_info(:reconnect, state) do
    if state.attempts_left > 0 do
      Logger.warning(
        "CorroSubscriber: Attempting to reconnect (#{state.attempts_left} attempts remain)"
      )

      send(self(), :start_subscription)
      {:noreply, state}
    else
      Logger.error("CorroSubscriber: Max reconnection attempts reached, giving up")
      broadcast_event({:subscription_failed, :max_retries})
      {:noreply, %{state | status: :failed}}
    end
  end

  def handle_info({:subscription_connected, watch_id}, state) do
    Logger.info("CorroSubscriber: Connected with watch_id: #{watch_id}")
    broadcast_event({:subscription_connected, watch_id})

    {:noreply,
     %{
       state
       | status: :connected,
         attempts_left: @max_reconnect_attempts,
         watch_id: watch_id
     }}
  end

  def handle_info({:subscription_data, data}, state) do
    updated_state = process_streaming_data(data, state)
    {:noreply, updated_state}
  end

  def handle_info({:subscription_error, error}, state) do
    Logger.warning("CorroSubscriber handle_info: Subscription error: #{inspect(error)}")
    broadcast_event({:subscription_error, error})

    new_state = %{
      state
      | status: :error,
        stream_pid: nil,
        watch_id: nil,
        attempts_left: state.attempts_left - 1
    }

    if new_state.attempts_left > 0 do
      schedule_reconnect(new_state)
    else
      Logger.error("CorroSubscriber: Max reconnection attempts reached, giving up")
      broadcast_event({:subscription_failed, :max_retries})
      {:noreply, %{new_state | status: :failed}}
    end
  end

  def handle_info({:subscription_closed, reason}, state) do
    Logger.warning("CorroSubscriber: Subscription closed: #{inspect(reason)}")
    broadcast_event({:subscription_closed, reason})

    new_state = %{
      state
      | status: :disconnected,
        stream_pid: nil,
        watch_id: nil,
        attempts_left: state.attempts_left - 1
    }

    if new_state.attempts_left > 0 do
      schedule_reconnect(new_state)
    else
      Logger.error("CorroSubscriber: Max reconnection attempts reached, giving up")
      broadcast_event({:subscription_failed, :max_retries})
      {:noreply, %{new_state | status: :failed}}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{stream_pid: pid} = state) do
    Logger.warning("CorroSubscriber: Stream process crashed: #{inspect(reason)}")

    new_state = %{
      state
      | status: :error,
        stream_pid: nil,
        watch_id: nil,
        attempts_left: state.attempts_left - 1
    }

    if new_state.attempts_left > 0 do
      schedule_reconnect(new_state)
    else
      Logger.error("CorroSubscriber: Max reconnection attempts reached, giving up")
      broadcast_event({:subscription_failed, :max_retries})
      {:noreply, %{new_state | status: :failed}}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("CorroSubscriber: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  def handle_call(:restart, _from, state) do
    Logger.info("CorroSubscriber: Manual restart requested")

    if state.stream_pid do
      Process.exit(state.stream_pid, :kill)
    end

    send(self(), :start_subscription)

    new_state = %{
      state
      | stream_pid: nil,
        status: :restarting,
        attempts_left: @max_reconnect_attempts,
        watch_id: nil
    }

    {:reply, :ok, new_state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      status: state.status,
      connected: state.status == :connected && !is_nil(state.stream_pid),
      attempts_left: state.attempts_left,
      watch_id: state.watch_id,
      initial_state_received: state.initial_state_received
    }

    {:reply, status, state}
  end

  # Public API
  def status do
    GenServer.call(__MODULE__, :status, 1000)
  rescue
    _ -> %{status: :unknown, connected: false}
  end

  def restart do
    GenServer.call(__MODULE__, :restart)
  end

  # Private functions

  defp run_subscription_stream(parent_pid) do
    corro_api_port = CorroPort.CorrosionClient.get_corro_api_port()
    url = "http://127.0.0.1:#{corro_api_port}/v1/subscriptions"
    query = "SELECT * FROM node_messages ORDER BY timestamp DESC"
    json_query = Jason.encode!(query)

    Logger.info("CorroSubscriber: Starting subscription stream to #{url}")

    # Use CorroWatch's proven streaming pattern
    finch_fun = fn request, finch_req, finch_name, finch_opts ->
      finch_acc = fn
        {:status, status}, response ->
          if status != 200 do
            send(parent_pid, {:subscription_error, {:http_status, status}})
          end

          %Req.Response{response | status: status}

        {:headers, headers}, response ->
          case Enum.find(headers, fn {key, _} -> key == "corro-query-id" end) do
            {"corro-query-id", watch_id} ->
              send(parent_pid, {:subscription_connected, watch_id})

            _ ->
              Logger.warning("CorroSubscriber: No corro-query-id found in headers")
          end

          %Req.Response{response | headers: headers}

        {:data, data}, response ->
          send(parent_pid, {:subscription_data, data})
          response
      end

      case Finch.stream(finch_req, finch_name, Req.Response.new(), finch_acc, [
             finch_opts,
             receive_timeout: :infinity
           ]) do
        {:ok, response} ->
          send(parent_pid, {:subscription_closed, :normal})
          {request, response}

        {:error, exception} ->
          send(parent_pid, {:subscription_error, {:finch_error, exception}})
          {request, exception}
      end
    end

    try do
      Req.post!(
        url,
        headers: [{"content-type", "application/json"}],
        body: json_query,
        connect_options: [transport_opts: [inet6: true]],
        finch_request: finch_fun
      )
    rescue
      e ->
        Logger.error("CorroSubscriber: Exception in subscription: #{inspect(e)}")
        send(parent_pid, {:subscription_error, {:exception, e}})
    end
  end

  defp process_streaming_data(data, state) do
    lines = String.split(data, "\n", trim: true)

    Enum.reduce(lines, state, fn line, acc_state ->
      trimmed_line = String.trim(line)

      if trimmed_line == "" do
        acc_state
      else
        case Jason.decode(trimmed_line) do
          {:ok, json_data} ->
            json_with_watch_id = Map.put(json_data, "watch_id", state.watch_id)
            handle_message_event(json_with_watch_id, acc_state)

          {:error, reason} ->
            Logger.warning("CorroSubscriber: Failed to decode JSON: #{inspect(reason)}")
            acc_state
        end
      end
    end)
  end

  defp handle_message_event(data, state) do
    case data do
      %{"eoq" => _time} ->
        Logger.info("CorroSubscriber: End of initial query - subscription is now live")
        broadcast_event({:subscription_ready})
        %{state | initial_state_received: true}

      %{"columns" => columns} ->
        Logger.info("CorroSubscriber: Got column names: #{inspect(columns)}")
        broadcast_event({:columns_received, columns})
        %{state | columns: columns}

      %{"row" => [_row_id, values]} when not is_nil(state.columns) ->
        message_map = build_message_map(values, state.columns)

        if state.initial_state_received do
          broadcast_event({:new_message, message_map})
        else
          broadcast_event({:initial_row, message_map})
        end

        state

      %{"change" => [change_type, _change_id, values, _version]} when not is_nil(state.columns) ->
        message_map = build_message_map(values, state.columns)
        broadcast_event({:message_change, String.upcase(change_type), message_map})
        state

      %{"row" => _} ->
        Logger.warning("CorroSubscriber: Got row data but no columns stored yet")
        state

      %{"change" => _} ->
        Logger.warning("CorroSubscriber: Got change data but no columns stored yet")
        state

      %{"error" => error_msg} ->
        Logger.error("CorroSubscriber: Subscription error: #{error_msg}")
        broadcast_event({:subscription_error, {:corrosion_error, error_msg}})
        state

      other ->
        Logger.warning("CorroSubscriber: Unhandled message event: #{inspect(other)}")
        state
    end
  end

  defp build_message_map(values, columns) when is_list(values) and is_list(columns) do
    if length(values) == length(columns) do
      Enum.zip(columns, values) |> Enum.into(%{})
    else
      Logger.warning(
        "CorroSubscriber: Mismatch: #{length(values)} values vs #{length(columns)} columns"
      )

      %{}
    end
  end

  defp build_message_map(values, columns) do
    Logger.warning(
      "CorroSubscriber: Unable to build message map from values: #{inspect(values)} and columns: #{inspect(columns)}"
    )

    %{}
  end

  defp broadcast_event(event) do
    Phoenix.PubSub.broadcast(CorroPort.PubSub, "message_updates", event)
  end

  defp schedule_reconnect(state) do
    # Calculate delay based on how many attempts have been made
    attempts_made = @max_reconnect_attempts - state.attempts_left

    delay =
      case attempts_made do
        # First retry: 2 seconds
        0 -> 2_000
        # Second retry: 5 seconds
        1 -> 5_000
        # Subsequent retries: 10 seconds
        _ -> 10_000
      end

    Logger.warning(
      "CorroSubscriber: Scheduling reconnect in #{delay}ms (#{state.attempts_left} attempts left)"
    )

    Process.send_after(self(), :reconnect, delay)
    {:noreply, %{state | status: :reconnecting}}
  end
end
