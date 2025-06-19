defmodule CorroPortWeb.AllMessagesTable do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  def all_messages_table(assigns) do
    ~H"""
    <div class="card bg-base-100">
      <div class="card-body">
        <div class="flex items-center justify-between mb-4">
          <h3 class="card-title">
            <.icon name="hero-chat-bubble-left-right" class="w-5 h-5 mr-2" /> All Messages
          </h3>
          <div class="flex items-center gap-2">
            <.button phx-click="refresh_messages" class="btn btn-xs btn-outline">
              <.icon name="hero-arrow-path" class="w-3 h-3 mr-1" /> Refresh
            </.button>
            <span class="text-xs text-base-content/70">
              {length(@all_messages)} messages
            </span>
          </div>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Node</th>
                <th>Message</th>
                <th>Timestamp</th>
                <th>Sequence</th>
                <th>Primary Key</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={message <- @all_messages} class={message_row_class(message, @local_node_id)}>
                <td>
                  <div class="flex items-center gap-2">
                    <span class="font-mono text-sm">{Map.get(message, "node_id", "Unknown")}</span>
                    <span
                      :if={Map.get(message, "node_id") == @local_node_id}
                      class="badge badge-primary badge-xs"
                    >
                      Local
                    </span>
                  </div>
                </td>
                <td class="max-w-md">
                  <div class="truncate" title={Map.get(message, "message", "")}>
                    {Map.get(message, "message", "")}
                  </div>
                </td>
                <td class="text-xs font-mono">
                  {format_timestamp(Map.get(message, "timestamp"))}
                </td>
                <td class="font-mono text-xs">
                  {format_sequence(Map.get(message, "sequence", ""))}
                </td>
                <td class="font-mono text-xs text-base-content/50">
                  <div class="truncate max-w-24" title={Map.get(message, "pk", "")}>
                    {String.slice(Map.get(message, "pk", ""), 0, 12)}...
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        
    <!-- Empty state -->
        <div :if={@all_messages == []} class="text-center py-8">
          <.icon
            name="hero-chat-bubble-left-right"
            class="w-12 h-12 mx-auto text-base-content/30 mb-4"
          />
          <div class="text-base-content/70">
            No messages found in the database
          </div>
          <div class="text-xs text-base-content/50 mt-1">
            Click "Send Message" to create the first message
          </div>
        </div>
        
    <!-- Loading state -->
        <div :if={@loading_messages} class="text-center py-8">
          <div class="loading loading-spinner loading-md mb-2"></div>
          <div class="text-sm text-base-content/70">Loading messages...</div>
        </div>
        
    <!-- Error state -->
        <div :if={@messages_error} class="alert alert-warning">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <div>
            <div class="font-semibold">Could not load messages</div>
            <div class="text-sm">{@messages_error}</div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions
  defp message_row_class(message, local_node_id) do
    base_class = ""

    if Map.get(message, "node_id") == local_node_id do
      # Highlight local node messages
      "#{base_class} bg-primary/5"
    else
      base_class
    end
  end

  defp format_timestamp(nil), do: "Unknown"

  defp format_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} ->
        # Show both date and time for full table
        Calendar.strftime(dt, "%m-%d %H:%M:%S")

      _ ->
        timestamp
    end
  end

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%m-%d %H:%M:%S")
  end

  defp format_timestamp(_), do: "Unknown"

  defp format_sequence(sequence) when is_integer(sequence) do
    # Convert millisecond timestamp to something more readable
    if sequence > 1_000_000_000_000 do
      # Looks like a millisecond timestamp, show last 6 digits
      sequence |> Integer.to_string() |> String.slice(-6..-1)
    else
      Integer.to_string(sequence)
    end
  end

  defp format_sequence(sequence) when is_binary(sequence) do
    if String.length(sequence) > 10 do
      String.slice(sequence, -6..-1)
    else
      sequence
    end
  end

  defp format_sequence(_), do: ""
end
