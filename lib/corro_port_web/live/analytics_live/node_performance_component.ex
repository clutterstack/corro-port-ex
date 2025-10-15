defmodule CorroPortWeb.AnalyticsLive.NodePerformanceComponent do
  @moduledoc """
  Phoenix Component for displaying node performance statistics.

  Shows per-node RTT (round-trip time) metrics from Corrosion write
  (via gossip) to acknowledgment receipt, including:
  - Total acknowledgments per node
  - Min/Max/Average latency
  - Percentiles (P50, P95, P99)
  - Colour-coded latency indicators
  """

  use Phoenix.Component
  import CorroPortWeb.AnalyticsLive.Helpers

  @doc """
  Renders the node performance statistics table showing RTT metrics per node.
  """
  attr :node_performance_stats, :list, required: true

  def node_performance_table(assigns) do
    ~H"""
    <%= if @node_performance_stats != [] do %>
      <div class="card bg-base-200 mb-6">
        <div class="card-body">
          <h3 class="card-title text-lg mb-4">Node Performance (RTT)</h3>
          <p class="text-sm text-base-content/70 mb-4">
            Round-trip time from Corrosion write (via gossip) to acknowledgement receipt
          </p>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="bg-base-300">
                  <th class="text-base-content">Node ID</th>
                  <th class="text-base-content">Total Acks</th>
                  <th class="text-base-content">Min RTT</th>
                  <th class="text-base-content">Avg RTT</th>
                  <th class="text-base-content">Max RTT</th>
                  <th class="text-base-content">P50</th>
                  <th class="text-base-content">P95</th>
                  <th class="text-base-content">P99</th>
                </tr>
              </thead>
              <tbody>
                <%= for {node_stat, index} <- Enum.with_index(@node_performance_stats) do %>
                  <tr class={if(rem(index, 2) == 0, do: "", else: "bg-base-300/30")}>
                    <td class="font-mono font-medium">{node_stat.node_id}</td>
                    <td>{node_stat.ack_count}</td>
                    <td>
                      <span class={latency_colour_class(node_stat.min_latency_ms)}>
                        {node_stat.min_latency_ms}ms
                      </span>
                    </td>
                    <td class="font-medium">
                      <span class={latency_colour_class(node_stat.avg_latency_ms)}>
                        {node_stat.avg_latency_ms}ms
                      </span>
                    </td>
                    <td>
                      <span class={latency_colour_class(node_stat.max_latency_ms)}>
                        {node_stat.max_latency_ms}ms
                      </span>
                    </td>
                    <td>{node_stat.p50_latency_ms}ms</td>
                    <td>{node_stat.p95_latency_ms}ms</td>
                    <td>{node_stat.p99_latency_ms}ms</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <div class="mt-4 flex items-center gap-4 text-xs text-base-content/70">
            <div class="flex items-center gap-2">
              <span class="inline-block w-3 h-3 rounded-full bg-success"></span>
              <span>&lt; 300ms (Excellent)</span>
            </div>
            <div class="flex items-center gap-2">
              <span class="inline-block w-3 h-3 rounded-full bg-warning"></span>
              <span>300-600ms (Good)</span>
            </div>
            <div class="flex items-center gap-2">
              <span class="inline-block w-3 h-3 rounded-full bg-[#F97316]"></span>
              <span>600-900ms (Fair)</span>
            </div>
            <div class="flex items-center gap-2">
              <span class="inline-block w-3 h-3 rounded-full bg-error"></span>
              <span>&gt;= 900ms (Slow)</span>
            </div>
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
