defmodule CorroPortWeb.AckStatusCard do
  use Phoenix.Component

  attr :ack_status, :map, required: true
  attr :ack_sender_status, :map, default: nil
  attr :expected_nodes, :list, default: []

  def ack_status_card(assigns) do
    assigns = assign(assigns, :expected_count, length(assigns.expected_nodes))

    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <div :if={@ack_status} class="space-y-3">
          <!-- Latest Message Info -->
          <div class="border-l-4 border-primary pl-3">
            <div class="text-xs font-semibold text-primary">Latest Tracked Message:</div>
            <div class="font-mono text-xs">
              {format_message_id(@ack_status.latest_message)}
            </div>
            <div class="text-xs text-base-content/70">
              Sent: {format_message_timestamp(@ack_status.latest_message)}
            </div>
          </div>

    <!-- Acknowledgment Progress -->
          <div class="space-y-2">
            <div class="flex items-center justify-between text-sm">
              <span class="font-semibold">Acknowledgments:</span>
              <span class={ack_progress_class(@ack_status.ack_count, @expected_count)}>
                {@ack_status.ack_count}/{@expected_count}
              </span>
            </div>
          </div>

    <!-- Node Acknowledgment Status -->
          <div class="space-y-1">
            <div class="text-xs font-semibold">Node Status:</div>
            <div class="space-y-1">
              <div
                :for={node_id <- @expected_nodes}
                class={[
                  "flex items-center justify-between text-xs rounded px-2 py-1",
                  if(get_node_ack(node_id, @ack_status.acknowledgments),
                    do: "bg-success/20 border border-success/50",
                    else: "bg-base-300 border border-base-content/20"
                  )
                ]}
              >
                <span class="font-mono">{node_id}</span>
                <span class={[
                  if(get_node_ack(node_id, @ack_status.acknowledgments),
                    do: "text-success",
                    else: "text-base-content/50"
                  )
                ]}>
                  {format_node_status(
                    get_node_ack(node_id, @ack_status.acknowledgments),
                    @ack_status.latest_message
                  )}
                </span>
              </div>
            </div>
          </div>
        </div>

    <!-- Loading state -->
        <div :if={!@ack_status} class="flex items-center justify-center py-4">
          <div class="loading loading-spinner loading-sm"></div>
          <span class="ml-2 text-sm">Loading acknowledgment status...</span>
        </div>

    <!-- AckSender Status -->
        <div
          :if={@ack_sender_status && @ack_sender_status.status == :running}
          class="mt-4 pt-3 border-t border-base-300"
        >
          <div class="text-xs text-base-content/70">
            <span class="text-success">●</span> AckSender running
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions
  defp get_node_ack(node_id, acknowledgments) when is_list(acknowledgments) do
    Enum.find(acknowledgments, fn ack -> ack.node_id == node_id end)
  end

  defp format_message_id(nil), do: "N/A"
  defp format_message_id(message), do: String.slice(message.pk, 0, 20) <> "..."

  defp format_message_timestamp(nil), do: "—"
  defp format_message_timestamp(message), do: format_timestamp(message.timestamp)

  defp format_node_status(nil, nil), do: "Ready"
  defp format_node_status(nil, _message), do: "Waiting..."

  defp format_node_status(ack, _message) do
    format_timestamp(ack.timestamp)
  end

  defp ack_progress_class(ack_count, expected_count) when expected_count > 0 do
    cond do
      ack_count == expected_count -> "text-success font-bold"
      ack_count > 0 -> "text-warning font-semibold"
      true -> "text-base-content/70"
    end
  end

  defp ack_progress_class(_ack_count, _expected_count), do: "text-base-content/70"

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
