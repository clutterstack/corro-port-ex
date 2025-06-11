defmodule CorroPortWeb.SubscriptionDebugLive do
  use CorroPortWeb, :live_view
  require Logger

  alias CorroPort.{MessageWatcher, MessagesAPI, NodeConfig}

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to both topics
      Phoenix.PubSub.subscribe(CorroPort.PubSub, MessageWatcher.subscription_topic())
      # Phoenix.PubSub.subscribe(CorroPort.PubSub, MessageWatcher.status_topic())
    end

    {:ok, assign(socket, %{
      page_title: "Subscription Debug",
      raw_events: [],
      status_events: [],
      message_count: 0,
      last_event_time: nil
    })}
  end

  # Handle all subscription events and log them verbatim
  def handle_info(message, socket) when is_tuple(message) do
    timestamp = DateTime.utc_now()

    case message do
      {:new_message, data} ->
        event = %{
          type: :new_message,
          data: data,
          timestamp: timestamp,
          raw: inspect(message)
        }
        Logger.info("🔴 RAW NEW_MESSAGE: #{inspect(message)}")

        socket =
          socket
          |> add_raw_event(event)
          |> assign(:message_count, socket.assigns.message_count + 1)
          |> assign(:last_event_time, timestamp)

        {:noreply, socket}

      {:message_change, change_type, data} ->
        event = %{
          type: :message_change,
          change_type: change_type,
          data: data,
          timestamp: timestamp,
          raw: inspect(message)
        }
        Logger.info("🔵 RAW MESSAGE_CHANGE: #{inspect(message)}")

        socket =
          socket
          |> add_raw_event(event)
          |> assign(:message_count, socket.assigns.message_count + 1)
          |> assign(:last_event_time, timestamp)

        {:noreply, socket}

      {:status_update, status_data} ->
        event = %{
          type: :status_update,
          data: status_data,
          timestamp: timestamp,
          raw: inspect(message)
        }
        Logger.info("🟡 RAW STATUS_UPDATE: #{inspect(message)}")

        socket =
          socket
          |> add_status_event(event)
          |> assign(:last_event_time, timestamp)

        {:noreply, socket}

      other ->
        event = %{
          type: :unknown,
          data: other,
          timestamp: timestamp,
          raw: inspect(message)
        }
        Logger.info("⚪ RAW UNKNOWN: #{inspect(message)}")

        socket =
          socket
          |> add_raw_event(event)
          |> assign(:last_event_time, timestamp)

        {:noreply, socket}
    end
  end

  def handle_info(message, socket) do
    Logger.warning("Non-tuple message received: #{inspect(message)}")
    {:noreply, socket}
  end

  def handle_event("send_test_message", _params, socket) do
    node_id = NodeConfig.get_corrosion_node_id()
    message = "DEBUG TEST #{System.system_time(:millisecond)}"
    api_port = CorroPort.CorrosionClient.get_api_port()

    case MessagesAPI.insert_message(node_id, message, api_port) do
      {:ok, _} ->
        socket = put_flash(socket, :info, "Test message sent!")
        {:noreply, socket}
      {:error, error} ->
        socket = put_flash(socket, :error, "Failed: #{error}")
        {:noreply, socket}
    end
  end

  def handle_event("check_watcher_status", _params, socket) do
    status = MessageWatcher.get_status()
    Logger.info("Current MessageWatcher status: #{inspect(status)}")
    socket = put_flash(socket, :info, "Status logged - check console")
    {:noreply, socket}
  end

  def handle_event("clear_events", _params, socket) do
    socket = assign(socket, %{
      raw_events: [],
      status_events: [],
      message_count: 0
    })
    {:noreply, socket}
  end

  defp add_raw_event(socket, event) do
    events = [event | socket.assigns.raw_events] |> Enum.take(50)
    assign(socket, :raw_events, events)
  end

  defp add_status_event(socket, event) do
    events = [event | socket.assigns.status_events] |> Enum.take(20)
    assign(socket, :status_events, events)
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Subscription Debug Console
        <:subtitle>
          Raw event stream from MessageWatcher subscription
        </:subtitle>
        <:actions>
          <.button phx-click="send_test_message" class="btn btn-primary">
            Send Test Message
          </.button>
          <.button phx-click="check_watcher_status" class="btn btn-secondary">
            Check Status
          </.button>
          <.button phx-click="clear_events" class="btn btn-outline">
            Clear All
          </.button>
        </:actions>
      </.header>

      <!-- Summary Stats -->
      <div class="stats shadow">
        <div class="stat">
          <div class="stat-title">Total Events</div>
          <div class="stat-value text-primary"><%= @message_count %></div>
        </div>
        <div class="stat">
          <div class="stat-title">Last Event</div>
          <div class="stat-value text-xs">
            <%= if @last_event_time do %>
              <%= Calendar.strftime(@last_event_time, "%H:%M:%S") %>
            <% else %>
              None
            <% end %>
          </div>
        </div>
        <div class="stat">
          <div class="stat-title">Raw Events</div>
          <div class="stat-value text-secondary"><%= length(@raw_events) %></div>
        </div>
        <div class="stat">
          <div class="stat-title">Status Events</div>
          <div class="stat-value text-accent"><%= length(@status_events) %></div>
        </div>
      </div>

      <!-- Raw Events -->
      <div class="card bg-base-200">
        <div class="card-body">
          <h3 class="card-title">Raw Subscription Events</h3>

          <div :if={@raw_events == []} class="text-center text-gray-500 py-8">
            No events received yet. Try sending a test message.
          </div>

          <div :if={@raw_events != []} class="space-y-2 max-h-96 overflow-y-auto">
            <div :for={event <- @raw_events} class="bg-base-100 rounded p-3 border">
              <div class="flex items-center justify-between mb-2">
                <span class={[
                  "badge",
                  case event.type do
                    :new_message -> "badge-success"
                    :message_change -> "badge-warning"
                    :status_update -> "badge-info"
                    _ -> "badge-neutral"
                  end
                ]}>
                  <%= event.type %>
                </span>
                <span class="text-xs text-gray-500">
                  <%= Calendar.strftime(event.timestamp, "%H:%M:%S.%f") %>
                </span>
              </div>

              <div class="space-y-2">
                <%= if event.type == :message_change do %>
                  <div><strong>Change Type:</strong> <%= event.change_type %></div>
                <% end %>

                <div><strong>Data:</strong></div>
                <pre class="text-xs bg-base-200 p-2 rounded overflow-x-auto"><%= inspect(event.data, pretty: true) %></pre>

                <details class="text-xs">
                  <summary class="cursor-pointer text-gray-600">Raw Message</summary>
                  <pre class="bg-base-300 p-2 rounded mt-1 overflow-x-auto"><%= event.raw %></pre>
                </details>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Status Events -->
      <div :if={@status_events != []} class="card bg-base-200">
        <div class="card-body">
          <h3 class="card-title">Status Updates</h3>

          <div class="space-y-2 max-h-64 overflow-y-auto">
            <div :for={event <- @status_events} class="bg-base-100 rounded p-3 border">
              <div class="flex items-center justify-between mb-2">
                <span class="badge badge-info">status_update</span>
                <span class="text-xs text-gray-500">
                  <%= Calendar.strftime(event.timestamp, "%H:%M:%S") %>
                </span>
              </div>

              <pre class="text-xs bg-base-200 p-2 rounded overflow-x-auto"><%= inspect(event.data, pretty: true) %></pre>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
