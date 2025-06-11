defmodule CorroPortWeb.ClusterLive.SubscriptionMonitor do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  def subscription_monitor(assigns) do
    ~H"""
    <div class="card bg-gradient-to-br from-blue-50 to-indigo-100 dark:from-blue-900/20 dark:to-indigo-900/20 border border-blue-200 dark:border-blue-800">
      <div class="card-body">
        <div class="flex items-center justify-between">
          <h3 class="card-title text-lg">
            <.icon name="hero-signal" class="w-5 h-5 text-blue-600 dark:text-blue-400" />
            Real-time Subscription Monitor
          </h3>
          <.subscription_status_badge status={@subscription_status} />
        </div>

        <!-- Connection Status -->
        <.connection_status_section subscription_status={@subscription_status} />

        <!-- Stream Activity -->
        <.stream_activity_section
          subscription_status={@subscription_status}
          stream_events={@stream_events}
        />

        <!-- Recent Messages -->
        <.recent_messages_section recent_messages={@recent_messages} />
      </div>
    </div>
    """
  end

  def subscription_status_badge(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <%= case @status && @status.status do %>
        <% :connected -> %>
          <div class="flex items-center gap-2">
            <div class="w-3 h-3 bg-green-500 rounded-full animate-pulse"></div>
            <span class="badge badge-success">Connected</span>
          </div>
        <% :connecting -> %>
          <div class="flex items-center gap-2">
            <div class="loading loading-spinner loading-xs"></div>
            <span class="badge badge-warning">Connecting</span>
          </div>
        <% :reconnecting -> %>
          <div class="flex items-center gap-2">
            <div class="loading loading-spinner loading-xs"></div>
            <span class="badge badge-warning">Reconnecting</span>
          </div>
        <% :error -> %>
          <div class="flex items-center gap-2">
            <div class="w-3 h-3 bg-red-500 rounded-full"></div>
            <span class="badge badge-error">Error</span>
          </div>
        <% :failed -> %>
          <div class="flex items-center gap-2">
            <div class="w-3 h-3 bg-red-500 rounded-full"></div>
            <span class="badge badge-error">Failed</span>
          </div>
        <% _ -> %>
          <div class="flex items-center gap-2">
            <div class="w-3 h-3 bg-gray-400 rounded-full"></div>
            <span class="badge badge-neutral">Unknown</span>
          </div>
      <% end %>
    </div>
    """
  end

  def connection_status_section(assigns) do
    ~H"""
    <div class="bg-white/50 dark:bg-black/20 rounded-lg p-4 space-y-3">
      <h4 class="font-semibold text-sm text-gray-700 dark:text-gray-300">Connection Details</h4>

      <div class="grid grid-cols-2 gap-4 text-sm">
        <div>
          <span class="text-gray-600 dark:text-gray-400">Watch ID:</span>
          <div class="font-mono text-xs">
            <%= if @subscription_status && @subscription_status.watch_id do %>
              <%= String.slice(@subscription_status.watch_id, 0, 12) %>...
            <% else %>
              <span class="text-gray-400">None</span>
            <% end %>
          </div>
        </div>

        <div>
          <span class="text-gray-600 dark:text-gray-400">Reconnect Attempts:</span>
          <div class="font-semibold">
            <%= if @subscription_status do %>
              <%= @subscription_status.reconnect_attempts || 0 %>
            <% else %>
              0
            <% end %>
          </div>
        </div>

        <div>
          <span class="text-gray-600 dark:text-gray-400">Last Data:</span>
          <div class="text-xs">
            <%= if @subscription_status && @subscription_status.last_data_received do %>
              <%= format_relative_time(@subscription_status.last_data_received) %>
            <% else %>
              <span class="text-gray-400">Never</span>
            <% end %>
          </div>
        </div>

        <div>
          <span class="text-gray-600 dark:text-gray-400">Messages Processed:</span>
          <div class="font-semibold">
            <%= if @subscription_status do %>
              <%= @subscription_status.total_messages_processed || 0 %>
            <% else %>
              0
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def stream_activity_section(assigns) do
    ~H"""
    <div :if={@stream_events && length(@stream_events) > 0} class="bg-white/50 dark:bg-black/20 rounded-lg p-4">
      <div class="flex items-center justify-between mb-3">
        <h4 class="font-semibold text-sm text-gray-700 dark:text-gray-300">
          Recent Stream Events
        </h4>
        <span class="badge badge-info badge-sm">
          Last <%= min(length(@stream_events), 10) %> events
        </span>
      </div>

      <div class="space-y-2 max-h-48 overflow-y-auto">
        <div :for={event <- Enum.take(@stream_events, 10)} class="flex items-start gap-3 text-xs">
          <span class="text-gray-500 dark:text-gray-400 font-mono min-w-[60px]">
            <%= format_time_only(event.timestamp) %>
          </span>
          <.stream_event_icon type={event.type} />
          <div class="flex-1">
            <div class="font-medium text-gray-800 dark:text-gray-200">
              <%= event.type %>
            </div>
            <div class="text-gray-600 dark:text-gray-400">
              <%= event.description %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def stream_event_icon(assigns) do
    ~H"""
    <%= case @type do %>
      <% "new_message" -> %>
        <.icon name="hero-plus-circle" class="w-4 h-4 text-green-600 dark:text-green-400 flex-shrink-0" />
      <% "message_change" -> %>
        <.icon name="hero-arrow-path" class="w-4 h-4 text-blue-600 dark:text-blue-400 flex-shrink-0" />
      <% "columns" -> %>
        <.icon name="hero-table-cells" class="w-4 h-4 text-purple-600 dark:text-purple-400 flex-shrink-0" />
      <% "eoq" -> %>
        <.icon name="hero-check-circle" class="w-4 h-4 text-gray-600 dark:text-gray-400 flex-shrink-0" />
      <% _ -> %>
        <.icon name="hero-information-circle" class="w-4 h-4 text-gray-600 dark:text-gray-400 flex-shrink-0" />
    <% end %>
    """
  end

  def recent_messages_section(assigns) do
    ~H"""
    <div :if={@recent_messages && length(@recent_messages) > 0} class="bg-white/50 dark:bg-black/20 rounded-lg p-4">
      <div class="flex items-center justify-between mb-3">
        <h4 class="font-semibold text-sm text-gray-700 dark:text-gray-300">
          Live Message Updates
        </h4>
        <span class="badge badge-success badge-sm animate-pulse">
          <.icon name="hero-bolt" class="w-3 h-3 mr-1" />
          Live
        </span>
      </div>

      <div class="space-y-2 max-h-32 overflow-y-auto">
        <div :for={msg <- Enum.take(@recent_messages, 5)} class="flex items-center gap-3 text-xs p-2 bg-green-50 dark:bg-green-900/20 rounded border border-green-200 dark:border-green-800">
          <span class="text-green-600 dark:text-green-400 font-mono text-[10px]">
            <%= format_time_only(msg.timestamp) %>
          </span>
          <span class="font-medium text-green-800 dark:text-green-200">
            <%= msg.node_id %>
          </span>
          <span class="text-green-700 dark:text-green-300 flex-1 truncate">
            <%= msg.message %>
          </span>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions
  defp format_relative_time(datetime) when is_struct(datetime, DateTime) do
    seconds_ago = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      seconds_ago < 60 -> "#{seconds_ago}s ago"
      seconds_ago < 3600 -> "#{div(seconds_ago, 60)}m ago"
      true -> "#{div(seconds_ago, 3600)}h ago"
    end
  end
  defp format_relative_time(_), do: "Unknown"

  defp format_time_only(datetime) when is_struct(datetime, DateTime) do
    Calendar.strftime(datetime, "%H:%M:%S")
  end
  defp format_time_only(_), do: "--:--:--"
end
