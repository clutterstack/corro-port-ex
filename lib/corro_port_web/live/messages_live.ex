defmodule CorroPortWeb.MessagesLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPort.{MessagesAPI, NodeConfig, AckTracker, AckSender}
  alias CorroPortWeb.{AllMessagesTable, AckStatusCard, NavTabs}

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to acknowledgment updates
      Phoenix.PubSub.subscribe(CorroPort.PubSub, "ack_events")

      # Subscribe to real-time message updates
      Phoenix.PubSub.subscribe(CorroPort.PubSub, "message_updates")
    end

    socket =
      assign(socket, %{
        page_title: "Messages",
        all_messages: [],
        loading_messages: false,
        messages_error: nil,
        ack_status: nil,
        ack_sender_status: nil,
        expected_nodes: [],
        local_node_id: NodeConfig.get_corrosion_node_id(),
        last_updated: nil,
        connectivity_test_results: nil
      })

    {:ok, fetch_initial_data(socket)}
  end

  # Handle acknowledgment updates
  def handle_info({:ack_update, ack_status}, socket) do
    Logger.debug(
      "MessagesLive: Received acknowledgment update: #{ack_status.ack_count} acknowledgments"
    )

    socket = assign(socket, :ack_status, ack_status)
    {:noreply, socket}
  end

  # Handle real-time message updates
  def handle_info({:new_message, message_map}, socket) do
    if map_size(message_map) > 0 do
      socket = update_all_messages_with_new_message(socket, message_map)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:initial_row, _message_map}, socket) do
    # Don't add initial rows to all_messages during subscription startup
    # We'll fetch the complete list via API
    {:noreply, socket}
  end

  def handle_info({:message_change, change_type, message_map}, socket) do
    if map_size(message_map) > 0 do
      socket =
        case change_type do
          "DELETE" -> remove_message_from_all_messages(socket, message_map)
          "UPDATE" -> update_message_in_all_messages(socket, message_map)
          "INSERT" -> update_all_messages_with_new_message(socket, message_map)
          _ -> socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Ignore other CorroSubscriber events
  def handle_info({:columns_received, _}, socket), do: {:noreply, socket}
  def handle_info({:subscription_ready}, socket), do: {:noreply, socket}
  def handle_info({:subscription_connected, _}, socket), do: {:noreply, socket}
  def handle_info({:subscription_error, _}, socket), do: {:noreply, socket}
  def handle_info({:subscription_closed, _}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    Logger.debug("MessagesLive: Unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Event handlers
  def handle_event("send_message", _params, socket) do
    case MessagesAPI.send_and_track_message("Hello from messaging page") do
      {:ok, message_data} ->
        Logger.debug("MessagesLive: ✅ Message sent successfully: #{inspect(message_data)}")

        socket =
          put_flash(socket, :info, "Message sent successfully! Now tracking acknowledgments...")

        {:noreply, socket}

      {:error, error} ->
        socket = put_flash(socket, :error, "Failed to send message: #{inspect(error)}")
        {:noreply, socket}
    end
  end

  def handle_event("refresh_messages", _params, socket) do
    Logger.debug("MessagesLive: 🔄 Manual messages refresh triggered")
    socket = fetch_all_messages(socket)
    {:noreply, socket}
  end

  def handle_event("reset_tracking", _params, socket) do
    case AckTracker.reset_tracking() do
      :ok ->
        Logger.info("MessagesLive: ✅ Message tracking reset successfully")

        socket =
          put_flash(
            socket,
            :info,
            "Message tracking reset - nodes will show as expected (orange) again"
          )

        {:noreply, socket}

      {:error, error} ->
        Logger.warning("MessagesLive: ❌ Failed to reset tracking: #{inspect(error)}")
        socket = put_flash(socket, :error, "Failed to reset tracking: #{inspect(error)}")
        {:noreply, socket}
    end
  end

  # Private functions
  defp fetch_initial_data(socket) do
    socket
    |> fetch_all_messages()
    |> fetch_ack_data()
  end

  defp fetch_all_messages(socket) do
    socket = assign(socket, :loading_messages, true)

    case MessagesAPI.get_node_messages() do
      {:ok, messages} ->
        Logger.debug("MessagesLive: Fetched #{length(messages)} total messages")

        assign(socket, %{
          all_messages: messages,
          loading_messages: false,
          messages_error: nil,
          last_updated: DateTime.utc_now()
        })

      {:error, error} ->
        Logger.warning("MessagesLive: Failed to fetch all messages: #{inspect(error)}")

        assign(socket, %{
          all_messages: [],
          loading_messages: false,
          messages_error: "Failed to load messages: #{inspect(error)}",
          last_updated: DateTime.utc_now()
        })
    end
  end

  defp fetch_ack_data(socket) do
    ack_status = AckTracker.get_status()
    ack_sender_status = AckSender.get_status()

    # Get expected nodes from DNS for the status card
    expected_nodes =
      case CorroPort.DNSLookup.get_dns_data() do
        %{nodes: {:ok, nodes}} -> nodes
        _ -> []
      end

    assign(socket, %{
      ack_status: ack_status,
      ack_sender_status: ack_sender_status,
      expected_nodes: expected_nodes
    })
  end

  # Message state update helpers
  defp update_all_messages_with_new_message(socket, new_message) do
    current_messages = socket.assigns.all_messages

    # Add new message at the beginning (most recent first)
    updated_messages =
      [new_message | current_messages]
      |> Enum.sort_by(
        fn msg ->
          case Map.get(msg, "timestamp") do
            nil -> ""
            ts -> ts
          end
        end,
        :desc
      )

    assign(socket, :all_messages, updated_messages)
  end

  defp update_message_in_all_messages(socket, updated_message) do
    current_messages = socket.assigns.all_messages
    message_pk = Map.get(updated_message, "pk")

    if is_nil(message_pk) do
      socket
    else
      updated_messages =
        Enum.map(current_messages, fn msg ->
          if Map.get(msg, "pk") == message_pk do
            updated_message
          else
            msg
          end
        end)

      assign(socket, :all_messages, updated_messages)
    end
  end

  defp remove_message_from_all_messages(socket, deleted_message) do
    current_messages = socket.assigns.all_messages
    message_pk = Map.get(deleted_message, "pk")

    if is_nil(message_pk) do
      socket
    else
      updated_messages =
        Enum.reject(current_messages, fn msg ->
          Map.get(msg, "pk") == message_pk
        end)

      assign(socket, :all_messages, updated_messages)
    end
  end

  defp connectivity_result_class(result) do
    case result do
      {:ok, _} -> "badge badge-success badge-sm"
      {:error, _} -> "badge badge-error badge-sm"
    end
  end

  defp format_connectivity_result(result) do
    case result do
      {:ok, _} -> "✓ Connected"
      {:error, :connection_refused} -> "✗ Refused"
      {:error, :timeout} -> "✗ Timeout"
      {:error, reason} when is_binary(reason) -> "✗ #{String.slice(reason, 0, 10)}..."
      {:error, _} -> "✗ Error"
    end
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Navigation Tabs -->
      <NavTabs.nav_tabs active={:messages} />
      
    <!-- Page Header -->
      <.header>
        Message Operations
        <:subtitle>
          Send messages, track acknowledgments, and browse message history
        </:subtitle>
        <:actions>
          <.button
            phx-click="reset_tracking"
            class="btn btn-warning btn-outline"
            disabled={!(@ack_status && @ack_status.latest_message)}
          >
            <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" /> Reset Tracking
          </.button>
          <.button phx-click="send_message" variant="primary">
            <.icon name="hero-paper-airplane" class="w-4 h-4 mr-2" /> Send Message
          </.button>
        </:actions>
      </.header>
      
    <!-- Acknowledgment Status -->
      <AckStatusCard.ack_status_card
        ack_status={@ack_status}
        ack_sender_status={@ack_sender_status}
        expected_nodes={@expected_nodes}
      />
      
    <!-- Connectivity Test Results -->
      <div :if={@connectivity_test_results} class="card bg-base-200">
        <div class="card-body">
          <h3 class="card-title text-sm">Connectivity Test Results</h3>
          <div class="space-y-2">
            <div
              :for={{node_id, result} <- @connectivity_test_results}
              class="flex items-center justify-between text-sm"
            >
              <span class="font-mono">{node_id}</span>
              <span class={connectivity_result_class(result)}>
                {format_connectivity_result(result)}
              </span>
            </div>
          </div>
        </div>
      </div>
      
    <!-- All Messages Table -->
      <AllMessagesTable.all_messages_table
        all_messages={@all_messages}
        loading_messages={@loading_messages}
        messages_error={@messages_error}
        local_node_id={@local_node_id}
      />
      
    <!-- Last Updated -->
      <div :if={@last_updated} class="text-xs text-base-content/70 text-center">
        Last updated: {Calendar.strftime(@last_updated, "%Y-%m-%d %H:%M:%S UTC")}
      </div>
    </div>
    """
  end
end
