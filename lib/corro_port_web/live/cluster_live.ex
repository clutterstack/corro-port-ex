defmodule CorroPortWeb.ClusterLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPort.{MessageWatcher, CorrosionClient}
  alias CorroPortWeb.{ClusterCards, MembersTable, MessagesTable, DebugSection}

  @refresh_interval 300_000  # 5 minutes to avoid interference with testing

  def mount(_params, _session, socket) do
    Logger.warning("ClusterLive: Mounting...")

    if connected?(socket) do
      Logger.warning("ClusterLive: Connected - subscribing to PubSub topic: #{MessageWatcher.subscription_topic()}")
      Phoenix.PubSub.subscribe(CorroPort.PubSub, MessageWatcher.subscription_topic())
      schedule_refresh()
    else
      Logger.warning("ClusterLive: Not connected yet (static render)")
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
      replication_status: nil,
      # Track real-time subscription state
      subscription_columns: nil,
      initial_load_complete: false,
      pending_initial_rows: []
    })

    {:ok, fetch_cluster_data(socket)}
  end

  # Handle subscription metadata
  def handle_info({:columns_received, columns}, socket) do
    Logger.warning("ClusterLive: 📊 Received column metadata: #{inspect(columns)}")
    socket = assign(socket, :subscription_columns, columns)
    {:noreply, socket}
  end

  # Handle subscription ready (end of initial state)
  def handle_info({:subscription_ready}, socket) do
    Logger.warning("ClusterLive: 🎉 Subscription is ready for real-time updates")
    {:noreply, socket}
  end

  # Handle initial state rows (during subscription startup)
  def handle_info({:initial_row, message_map}, socket) do
    Logger.warning("ClusterLive: 📦 Received initial row: #{inspect(message_map)}")

    # Collect initial rows until we get the end-of-query
    if socket.assigns.initial_load_complete do
      # Shouldn't happen, but handle gracefully
      Logger.warning("ClusterLive: ⚠️ Got initial row after initial load was complete")
      socket = update_node_messages_with_new_message(socket, message_map)
      {:noreply, socket}
    else
      # Add to pending initial rows
      updated_pending = [message_map | socket.assigns.pending_initial_rows]
      socket = assign(socket, :pending_initial_rows, updated_pending)
      {:noreply, socket}
    end
  end

  # Handle real-time message updates (new messages after subscription is established)
  def handle_info({:new_message, message_map}, socket) do
    Logger.warning("ClusterLive: 📨 Received new real-time message: #{inspect(message_map)}")

    if map_size(message_map) == 0 do
      Logger.warning("ClusterLive: ⚠️ Received empty message map, skipping update")
      {:noreply, socket}
    else
      socket = update_node_messages_with_new_message(socket, message_map)
      {:noreply, socket}
    end
  end

  # Handle incremental changes (updates/deletes)
  def handle_info({:message_change, change_type, message_map}, socket) do
    Logger.warning("ClusterLive: 🔄 Received message #{change_type}: #{inspect(message_map)}")

    if map_size(message_map) == 0 do
      Logger.warning("ClusterLive: ⚠️ Received empty message map for #{change_type}, skipping update")
      {:noreply, socket}
    else
      socket = case change_type do
        "DELETE" -> remove_message_from_state(socket, message_map)
        "UPDATE" -> update_message_in_state(socket, message_map)
        "INSERT" -> update_node_messages_with_new_message(socket, message_map)
        _ ->
          Logger.warning("ClusterLive: ❓ Unknown change type: #{change_type}")
          socket
      end

      {:noreply, socket}
    end
  end

  def handle_info(:refresh, socket) do
    Logger.warning("ClusterLive: 🔄 Auto refresh triggered")
    schedule_refresh()
    {:noreply, fetch_cluster_data(socket)}
  end

  def handle_info(msg, socket) do
    Logger.warning("ClusterLive: ❓ Unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Event handlers
  def handle_event("refresh", _params, socket) do
    Logger.warning("ClusterLive: 🔄 Manual refresh triggered")
    updates = CorroPortWeb.ClusterLive.DataFetcher.fetch_all_data(socket)
    socket =
      socket
      |> assign(:cluster_info, updates.cluster_info)
      |> assign(:local_info, updates.local_info)
      |> assign(:node_messages, updates.node_messages)
      |> assign(:error, updates.error)
      |> assign(:last_updated, updates.last_updated)
      |> assign(:initial_load_complete, true)  # Mark as complete after manual refresh
      |> assign(:pending_initial_rows, [])     # Clear pending rows
    {:noreply, socket}
  end

  def handle_event("send_message", _params, socket) do
    Logger.warning("ClusterLive: 📤 Send message button clicked")
    case CorroPortWeb.ClusterLive.MessageHandler.send_message(socket.assigns.api_port) do
      {:ok, message} ->
        Logger.warning("ClusterLive: ✅ Message sent successfully")
        socket = put_flash(socket, :info, message)
        {:noreply, socket}
      {:error, error} ->
        Logger.warning("ClusterLive: ❌ Failed to send message: #{error}")
        socket = put_flash(socket, :error, "Failed to send message: #{error}")
        {:noreply, socket}
    end
  end

  def handle_event("cleanup_messages", _params, socket) do
    Logger.warning("ClusterLive: 🧹 Cleanup messages button clicked")
    case CorroPortWeb.ClusterLive.MessageHandler.cleanup_messages(socket.assigns.api_port) do
      {:ok, message} ->
        # Refresh node messages after cleanup
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

  def handle_event("check_replication", _params, socket) do
    Logger.warning("ClusterLive: 🔍 Checking replication status...")

    # Run diagnostics in background
    spawn(fn ->
      CorroPort.DiagnosticTools.check_replication_state(socket.assigns.api_port)
    end)

    # Get basic replication stats
    replication_status = get_replication_status(socket.assigns.api_port)

    socket = assign(socket, :replication_status, replication_status)
    {:noreply, socket}
  end

  # Private functions for efficient message state updates

  defp update_node_messages_with_new_message(socket, new_message) do
    current_messages = socket.assigns.node_messages
    node_id = Map.get(new_message, "node_id")

    if is_nil(node_id) do
      Logger.warning("ClusterLive: ⚠️ Received message without node_id: #{inspect(new_message)}")
      socket
    else
      Logger.warning("ClusterLive: 📝 Updating messages for node: #{node_id}")

      # Since we want latest messages per node, replace the existing message for this node
      # or add it if it doesn't exist
      updated_messages =
        current_messages
        |> Enum.reject(fn msg -> Map.get(msg, "node_id") == node_id end)
        |> List.insert_at(0, new_message)  # Insert at beginning (most recent first)
        |> Enum.sort_by(fn msg ->
          case Map.get(msg, "timestamp") do
            nil -> ""
            ts -> ts
          end
        end, :desc)  # Sort by timestamp descending

      Logger.warning("ClusterLive: 📊 Updated node_messages: #{length(current_messages)} -> #{length(updated_messages)} messages")
      assign(socket, :node_messages, updated_messages)
    end
  end

  defp update_message_in_state(socket, updated_message) do
    current_messages = socket.assigns.node_messages
    message_pk = Map.get(updated_message, "pk")

    if is_nil(message_pk) do
      Logger.warning("ClusterLive: ⚠️ Received message update without pk: #{inspect(updated_message)}")
      socket
    else
      Logger.warning("ClusterLive: 📝 Updating message with pk: #{message_pk}")

      updated_messages =
        Enum.map(current_messages, fn msg ->
          if Map.get(msg, "pk") == message_pk do
            updated_message
          else
            msg
          end
        end)

      assign(socket, :node_messages, updated_messages)
    end
  end

  defp remove_message_from_state(socket, deleted_message) do
    current_messages = socket.assigns.node_messages
    message_pk = Map.get(deleted_message, "pk")

    if is_nil(message_pk) do
      Logger.warning("ClusterLive: ⚠️ Received message deletion without pk: #{inspect(deleted_message)}")
      socket
    else
      Logger.warning("ClusterLive: 🗑️ Removing message with pk: #{message_pk}")

      updated_messages =
        Enum.reject(current_messages, fn msg ->
          Map.get(msg, "pk") == message_pk
        end)

      Logger.warning("ClusterLive: 📊 Removed message: #{length(current_messages)} -> #{length(updated_messages)} messages")
      assign(socket, :node_messages, updated_messages)
    end
  end

  defp fetch_cluster_data(socket) do
    updates = CorroPortWeb.ClusterLive.DataFetcher.fetch_all_data(socket)

    socket
    |> assign(%{
      cluster_info: updates.cluster_info,
      local_info: updates.local_info,
      node_messages: updates.node_messages,
      error: updates.error,
      last_updated: updates.last_updated,
      # Preserve replication_status if it exists, otherwise keep it nil
      replication_status: socket.assigns[:replication_status],
      # Mark initial load as complete when we do a full fetch
      initial_load_complete: true,
      # Clear any pending initial rows since we just did a full fetch
      pending_initial_rows: []
    })
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  # Helper functions for replication status
  defp get_replication_status(port) do
    %{
      last_check: DateTime.utc_now(),
      total_messages: get_total_messages(port),
      has_gaps: check_for_gaps(port),
      conflicts: count_conflicts(port)
    }
  end

  defp get_total_messages(port) do
    case CorrosionClient.execute_query("SELECT COUNT(*) as total FROM node_messages", port) do
      {:ok, response} ->
        rows = CorrosionClient.parse_query_response(response)
        get_in(rows, [Access.at(0), "total"]) || 0
      _ -> nil
    end
  end

  defp check_for_gaps(port) do
    # Since we're using timestamps as sequences, we can't really check for "gaps"
    # in the traditional sense. Instead, let's check if we have a reasonable
    # distribution of messages over time
    case CorrosionClient.execute_query("""
      SELECT COUNT(*) as nodes_with_messages
      FROM (SELECT DISTINCT node_id FROM node_messages)
    """, port) do
      {:ok, response} ->
        rows = CorrosionClient.parse_query_response(response)
        nodes_count = get_in(rows, [Access.at(0), "nodes_with_messages"]) || 0
        # Consider it a "gap" if we have fewer than 2 nodes with messages
        nodes_count < 2
      _ -> false
    end
  end

  defp count_conflicts(port) do
    case CorrosionClient.execute_query("""
      SELECT COUNT(*) as conflicts
      FROM (
        SELECT pk FROM node_messages GROUP BY pk HAVING COUNT(*) > 1
      )
    """, port) do
      {:ok, response} ->
        rows = CorrosionClient.parse_query_response(response)
        get_in(rows, [Access.at(0), "conflicts"]) || 0
      _ -> 0
    end
  end

  def render(assigns) do
    # Ensure replication_status exists in assigns
    assigns = assign_new(assigns, :replication_status, fn -> nil end)

    ~H"""
    <div class="space-y-6">
      <ClusterCards.cluster_header
      />

      <ClusterCards.error_alerts
        error={@error}
      />

      <ClusterCards.status_cards
        local_info={@local_info}
        cluster_info={@cluster_info}
        node_messages={@node_messages}
        last_updated={@last_updated}
        phoenix_port={@phoenix_port}
        api_port={@api_port}
        refresh_interval={@refresh_interval}
        replication_status={@replication_status}
        error={@error}
      />

      <MessagesTable.node_messages_table
        node_messages={@node_messages}
      />

      <MembersTable.cluster_members_table
        cluster_info={@cluster_info}
      />

      <DebugSection.debug_section
        cluster_info={@cluster_info}
        local_info={@local_info}
        node_messages={@node_messages}
      />
    </div>
    """
  end
end
