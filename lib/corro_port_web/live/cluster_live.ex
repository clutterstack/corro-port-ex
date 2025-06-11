defmodule CorroPortWeb.ClusterLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPort.{MessagesAPI, CorrosionClient}
  alias CorroPort.MessageWatcher
  alias CorroPortWeb.ClusterLive.{Components, SubscriptionMonitor}

  @refresh_interval 5000

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to both message updates and status updates
      Phoenix.PubSub.subscribe(CorroPort.PubSub, MessageWatcher.subscription_topic())
      Phoenix.PubSub.subscribe(CorroPort.PubSub, MessageWatcher.status_topic())
      schedule_refresh()
    end

    detected_port = CorrosionClient.detect_api_port()
    phoenix_port = Application.get_env(:corro_port, CorroPortWeb.Endpoint)[:http][:port] || 4000

    socket = assign(socket, %{
      page_title: "Cluster Status",
      cluster_info: nil,
      local_info: nil,
      node_messages: [],
      error: nil,
      last_updated: nil,
      api_port: detected_port,
      phoenix_port: phoenix_port,
      refresh_interval: @refresh_interval,
      subscription_status: %{subscription_active: false, status: :unknown},
      # New assigns for stream visualization
      stream_events: [],
      recent_messages: [],
      status_updates: []
    })

    {:ok, fetch_cluster_data(socket)}
  end

  # Handle real-time message updates from subscription
  def handle_info({:new_message, data}, socket) do
    Logger.info("🆕 LiveView received new_message: #{inspect(data)}")

    # Add to stream events
    event = %{
      type: "new_message",
      timestamp: DateTime.utc_now(),
      description: "New message row: #{inspect(data.row_id)}"
    }

    # Parse message data and add to recent messages if valid
    {new_recent_messages, updated_socket} =
      case parse_message_from_values(data.values) do
        {:ok, parsed_msg} ->
          recent_msgs = [parsed_msg | socket.assigns.recent_messages] |> Enum.take(10)
          {recent_msgs, socket}
        {:error, _} ->
          {socket.assigns.recent_messages, socket}
      end

    socket =
      socket
      |> add_stream_event(event)
      |> assign(:recent_messages, new_recent_messages)
      |> fetch_node_messages()

    {:noreply, socket}
  end

  def handle_info({:message_change, change_type, data}, socket) do
    Logger.info("🔄 LiveView received message_change: #{change_type} - #{inspect(data)}")

    event = %{
      type: "message_change",
      timestamp: DateTime.utc_now(),
      description: "#{String.upcase(change_type)} on row #{data.row_id}"
    }

    socket =
      socket
      |> add_stream_event(event)
      |> fetch_node_messages()

    {:noreply, socket}
  end

  # Handle subscription status updates
  def handle_info({:status_update, status_data}, socket) do
    Logger.debug("📊 LiveView received status update: #{inspect(status_data)}")

    # Add to status updates history
    status_updates = [status_data | socket.assigns.status_updates] |> Enum.take(5)

    socket = assign(socket, :status_updates, status_updates)
    {:noreply, socket}
  end

  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, fetch_cluster_data(socket)}
  end

  # Event handlers
  def handle_event("refresh", _params, socket) do
    updates = CorroPortWeb.ClusterLive.DataFetcher.fetch_all_data(socket)
    socket =
      socket
      |> assign(:cluster_info, updates.cluster_info)
      |> assign(:local_info, updates.local_info)
      |> assign(:node_messages, updates.node_messages)
      |> assign(:error, updates.error)
      |> assign(:subscription_status, updates.subscription_status)
      |> assign(:last_updated, updates.last_updated)
    {:noreply, socket}
  end

  def handle_event("send_message", _params, socket) do
    case CorroPortWeb.ClusterLive.MessageHandler.send_message(socket.assigns.api_port) do
      {:ok, message} ->
        socket = put_flash(socket, :info, message)
        {:noreply, socket}
      {:error, error} ->
        socket = put_flash(socket, :error, "Failed to send message: #{error}")
        {:noreply, socket}
    end
  end

  def handle_event("check_subscription", _params, socket) do
    status = CorroPortWeb.ClusterLive.DataFetcher.get_subscription_status_safe()
    socket = assign(socket, :subscription_status, status)
    {:noreply, socket}
  end

  def handle_event("cleanup_messages", _params, socket) do
    case CorroPortWeb.ClusterLive.MessageHandler.cleanup_messages(socket.assigns.api_port) do
      {:ok, message} ->
        new_messages = CorroPortWeb.ClusterLive.DataFetcher.fetch_node_messages_data(socket.assigns.api_port)
        socket =
          socket
          |> put_flash(:info, message)
          |> assign(:node_messages, new_messages)
        {:noreply, socket}
      {:error, error} ->
        socket = put_flash(socket, :error, error)
        {:noreply, socket}
    end
  end

  def handle_event("clear_stream_events", _params, socket) do
    socket = assign(socket, :stream_events, [])
    {:noreply, socket}
  end

  def handle_event("clear_recent_messages", _params, socket) do
    socket = assign(socket, :recent_messages, [])
    {:noreply, socket}
  end

  # Private functions
  defp fetch_cluster_data(socket) do
    updates = CorroPortWeb.ClusterLive.DataFetcher.fetch_all_data(socket)

    socket
    |> assign(%{
      cluster_info: updates.cluster_info,
      local_info: updates.local_info,
      node_messages: updates.node_messages,
      error: updates.error,
      subscription_status: updates.subscription_status,
      last_updated: updates.last_updated,
    })
  end

  defp fetch_node_messages(socket) do
    new_messages = CorroPortWeb.ClusterLive.DataFetcher.fetch_node_messages_data(socket.assigns.api_port)
    assign(socket, :node_messages, new_messages)
  end

  defp add_stream_event(socket, event) do
    events = [event | socket.assigns.stream_events] |> Enum.take(20)
    assign(socket, :stream_events, events)
  end

  defp parse_message_from_values(values) when is_list(values) do
    # Expected columns: pk, node_id, message, sequence, timestamp
    case values do
      [_pk, node_id, message, _sequence, timestamp] when is_binary(node_id) and is_binary(message) ->
        {:ok, %{
          node_id: node_id,
          message: message,
          timestamp: parse_timestamp(timestamp)
        }}
      _ ->
        {:error, :invalid_format}
    end
  end
  defp parse_message_from_values(_), do: {:error, :not_list}

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
  defp parse_timestamp(_), do: DateTime.utc_now()

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <Components.cluster_header
        subscription_status={@subscription_status}
      />

      <Components.error_alerts
        error={@error}
        subscription_status={@subscription_status}
      />

      <!-- New Subscription Monitor -->
      <SubscriptionMonitor.subscription_monitor
        subscription_status={@subscription_status}
        stream_events={@stream_events}
        recent_messages={@recent_messages}
      />

      <Components.status_cards
        local_info={@local_info}
        cluster_info={@cluster_info}
        node_messages={@node_messages}
        last_updated={@last_updated}
        phoenix_port={@phoenix_port}
        api_port={@api_port}
        refresh_interval={@refresh_interval}
        subscription_status={@subscription_status}
        error={@error}
      />

      <!-- Action buttons for testing -->
      <div class="flex gap-2 flex-wrap">
        <.button phx-click="clear_stream_events" class="btn btn-outline btn-sm">
          <.icon name="hero-trash" class="w-4 h-4 mr-1" />
          Clear Stream Events
        </.button>
        <.button phx-click="clear_recent_messages" class="btn btn-outline btn-sm">
          <.icon name="hero-x-mark" class="w-4 h-4 mr-1" />
          Clear Recent Messages
        </.button>
      </div>

      <Components.node_messages_table
        node_messages={@node_messages}
        subscription_status={@subscription_status}
      />

      <Components.cluster_members_table
        cluster_info={@cluster_info}
      />

      <Components.debug_section
        cluster_info={@cluster_info}
        local_info={@local_info}
        node_messages={@node_messages}
        subscription_status={@subscription_status}
      />
    </div>
    """
  end
end
