defmodule CorroPortWeb.MessagesTable do
  use Phoenix.Component

  def node_messages_table(assigns) do
    ~H"""
    <div :if={@node_messages != []} class="card bg-base-100">
      <div class="card-body">
        <h3 class="card-title">
          Latest Messages from Each Node
        </h3>
        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Node ID</th>
                <th>Message</th>
                <th>Timestamp</th>
                <th>Sequence</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={message <- @node_messages}>
                <td class="font-mono text-sm">
                  <%= Map.get(message, "node_id", "Unknown") %>
                </td>
                <td class="max-w-md truncate">
                  <%= Map.get(message, "message", "") %>
                </td>
                <td class="text-xs">
                  <%= format_timestamp(Map.get(message, "timestamp")) %>
                </td>
                <td class="font-mono text-xs">
                  <%= Map.get(message, "sequence", "") %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

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
