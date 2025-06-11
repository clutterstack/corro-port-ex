defmodule CorroPortWeb.AcknowledgmentCard do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  def acknowledgment_status_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h3 class="card-title text-sm flex items-center">
          Message Acknowledgments
          <.button
            phx-click="test_connectivity"
            class="btn btn-xs btn-outline ml-2"
          >
            Test
          </.button>
        </h3>

        <div :if={@ack_status} class="space-y-3">
          <!-- Latest Message Info -->
          <div :if={@ack_status.latest_message} class="border-l-4 border-primary pl-3">
            <div class="text-xs font-semibold text-primary">Latest Tracked Message:</div>
            <div class="font-mono text-xs">
              <%= String.slice(@ack_status.latest_message.pk, 0, 20) %>...
            </div>
            <div class="text-xs text-base-content/70">
              Sent: <%= format_timestamp(@ack_status.latest_message.timestamp) %>
            </div>
          </div>

          <!-- No message being tracked -->
          <div :if={!@ack_status.latest_message} class="text-center text-base-content/70 py-2">
            No message currently being tracked
            <div class="text-xs mt-1">Click "Send Message" to start tracking</div>
          </div>

          <!-- Acknowledgment Progress -->
          <div :if={@ack_status.latest_message} class="space-y-2">
            <div class="flex items-center justify-between text-sm">
              <span class="font-semibold">Acknowledgments:</span>
              <span class={ack_progress_class(@ack_status.ack_count, @ack_status.expected_count)}>
                <%= @ack_status.ack_count %>/<%= @ack_status.expected_count %>
              </span>
            </div>

            <!-- Progress Bar -->
            <div class="w-full bg-base-300 rounded-full h-2">
              <div
                class={["h-2 rounded-full transition-all duration-300", ack_progress_bar_class(@ack_status.ack_count, @ack_status.expected_count)]}
                style={"width: #{if @ack_status.expected_count > 0, do: (@ack_status.ack_count / @ack_status.expected_count * 100), else: 0}%"}
              >
              </div>
            </div>

            <!-- Expected Nodes -->
            <div class="space-y-1">
              <div class="text-xs font-semibold">Expected from:</div>
              <div class="flex flex-wrap gap-1">
                <span
                  :for={node_id <- @ack_status.expected_nodes}
                  class={["badge badge-xs", if(node_acknowledged?(node_id, @ack_status.acknowledgments), do: "badge-success", else: "badge-outline")]}
                >
                  <%= node_id %>
                  <span :if={node_acknowledged?(node_id, @ack_status.acknowledgments)} class="ml-1">✓</span>
                </span>
              </div>
            </div>

            <!-- Recent Acknowledgments -->
            <div :if={@ack_status.acknowledgments != []} class="space-y-1">
              <div class="text-xs font-semibold">Recent acknowledgments:</div>
              <div class="space-y-1 max-h-20 overflow-y-auto">
                <div
                  :for={ack <- Enum.take(@ack_status.acknowledgments, 3)}
                  class="flex items-center justify-between text-xs bg-base-300 rounded px-2 py-1"
                >
                  <span class="font-mono"><%= ack.node_id %></span>
                  <span class="text-base-content/70"><%= format_timestamp(ack.timestamp) %></span>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Loading state -->
        <div :if={!@ack_status} class="flex items-center justify-center py-4">
          <div class="loading loading-spinner loading-sm"></div>
          <span class="ml-2 text-sm">Loading acknowledgment status...</span>
        </div>

        <!-- MessageWatcher Stats -->
        <div :if={@message_watcher_status} class="mt-4 pt-3 border-t border-base-300">
          <div class="text-xs font-semibold mb-2">MessageWatcher Stats:</div>
          <div class="grid grid-cols-2 gap-2 text-xs">
            <div>
              <span class="text-base-content/70">Acks sent:</span>
              <%= @message_watcher_status.acknowledgments_sent || 0 %>
            </div>
            <div>
              <span class="text-base-content/70">Messages:</span>
              <%= @message_watcher_status.total_messages_processed || 0 %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions
  defp node_acknowledged?(node_id, acknowledgments) when is_list(acknowledgments) do
    Enum.any?(acknowledgments, fn ack -> ack.node_id == node_id end)
  end

  defp ack_progress_class(ack_count, expected_count) when expected_count > 0 do
    cond do
      ack_count == expected_count -> "text-success font-bold"
      ack_count > 0 -> "text-warning font-semibold"
      true -> "text-base-content/70"
    end
  end
  defp ack_progress_class(_ack_count, _expected_count), do: "text-base-content/70"

  defp ack_progress_bar_class(ack_count, expected_count) when expected_count > 0 do
    cond do
      ack_count == expected_count -> "bg-success"
      ack_count > 0 -> "bg-warning"
      true -> "bg-base-content/20"
    end
  end
  defp ack_progress_bar_class(_ack_count, _expected_count), do: "bg-base-content/20"

  defp format_timestamp(nil), do: "Unknown"
  defp format_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> timestamp
    end
  end
  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end
  defp format_timestamp(_), do: "Unknown"
end
