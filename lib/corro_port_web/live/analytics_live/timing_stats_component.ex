defmodule CorroPortWeb.AnalyticsLive.TimingStatsComponent do
  @moduledoc """
  Phoenix Component for displaying message timing statistics.

  Shows per-message timing details including:
  - Message ID
  - Send time
  - Acknowledgment count
  - Min/Max/Average latency
  - Number of responding nodes
  """

  use Phoenix.Component
  import CorroPortWeb.AnalyticsLive.Helpers

  @doc """
  Renders the message timing statistics table.
  """
  attr :timing_stats, :list, required: true

  def timing_stats_table(assigns) do
    ~H"""
    <div class="card bg-base-200 mb-6">
      <div class="card-body">
        <h3 class="card-title text-lg mb-4">Message Timing Statistics</h3>

        <%= if @timing_stats != [] do %>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="bg-base-300">
                  <th class="text-base-content">Message ID</th>
                  <th class="text-base-content">Send Time</th>
                  <th class="text-base-content">Acks</th>
                  <th class="text-base-content">Min Latency</th>
                  <th class="text-base-content">Max Latency</th>
                  <th class="text-base-content">Avg Latency</th>
                  <th class="text-base-content">Nodes</th>
                </tr>
              </thead>
              <tbody>
                <%= for stat <- @timing_stats do %>
                  <tr class="hover:bg-base-300/50">
                    <td class="font-mono">{stat.message_id}</td>
                    <td>{format_datetime(stat.send_time)}</td>
                    <td>{stat.ack_count}</td>
                    <td>
                      <%= if stat.min_latency_ms do %>
                        {stat.min_latency_ms}ms
                      <% else %>
                        <span class="text-base-content/40">-</span>
                      <% end %>
                    </td>
                    <td>
                      <%= if stat.max_latency_ms do %>
                        {stat.max_latency_ms}ms
                      <% else %>
                        <span class="text-base-content/40">-</span>
                      <% end %>
                    </td>
                    <td>
                      <%= if stat.avg_latency_ms do %>
                        {stat.avg_latency_ms}ms
                      <% else %>
                        <span class="text-base-content/40">-</span>
                      <% end %>
                    </td>
                    <td>{length(stat.acknowledgments)}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% else %>
          <div class="text-base-content/50 text-center py-8">
            No timing statistics available
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
