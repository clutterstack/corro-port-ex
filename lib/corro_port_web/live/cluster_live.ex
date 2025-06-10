defmodule CorroPortWeb.ClusterLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPort.{MessagesAPI, CorrosionClient}
  alias CorroPort.MessageWatcher
  alias CorroPortWeb.ClusterLive.Components

  @refresh_interval 5000

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CorroPort.PubSub, MessageWatcher.subscription_topic())
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
    subscription_status: %{subscription_active: false, status: :unknown}
  })

  {:ok, fetch_cluster_data(socket)}
end

  # Handle real-time message updates
  def handle_info({:new_message, values}, socket) do
    Logger.debug("Received new message via subscription: #{inspect(values)}")
    socket = fetch_node_messages(socket)
    {:noreply, socket}
  end

  def handle_info({:message_change, change_type, values}, socket) do
    Logger.debug("Received message #{change_type} via subscription: #{inspect(values)}")
    socket = fetch_node_messages(socket)
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
        # Refresh node messages after cleanup
        new_messages = CorroPortWeb.ClusterLive.DataFetcher.fetch_node_messages_data(socket.assigns.api_port)
        socket =
          socket
          |> put_flash(:info, message)
          |> assign(:node_messages, new_messages)
      {:error, error} ->
        socket = put_flash(socket, :error, error)
    end
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

  defp get_subscription_status_safe do
    CorroPortWeb.ClusterLive.DataFetcher.get_subscription_status_safe()
  end

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
