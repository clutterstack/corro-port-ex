defmodule CorroPortWeb.AnalyticsLive.ReceiptTimeComponent do
  @moduledoc """
  Phoenix Component for displaying message receipt time distribution.

  Shows propagation patterns from when messages arrive at remote nodes via gossip:
  - Per-node receipt statistics (first/last receipt times)
  - Overall spread time statistics (how long messages take to reach all nodes)
  - Temporal distribution showing clustering patterns
  - Clock-skew independent analysis

  Unlike RTT metrics which measure round-trip time, receipt time analysis focuses
  on understanding gossip propagation patterns without requiring clock synchronisation
  between nodes.
  """

  use Phoenix.Component
  alias CorroPortWeb.AnalyticsLive.Charts.ReceiptStaircaseVl

  @doc """
  Renders the complete receipt time distribution analysis.
  """
  attr :receipt_time_dist, :map, required: true

  def receipt_time_distribution(assigns) do
    ~H"""
    <%= if has_receipt_data?(@receipt_time_dist) do %>
      <div class="space-y-6">
        <!-- Header Card -->
        <div class="card bg-primary text-primary-content">
          <div class="card-body">
            <h3 class="card-title text-lg">Message Receipt Time Analysis</h3>
            <p class="text-sm opacity-90">
              Per-node gossip propagation showing when messages first arrived at each node.
              Offsets are relative to the experiment start, using the originating node's clock.
            </p>
          </div>
        </div>

        <!-- Per-Node Statistics -->
        <.per_node_receipt_stats nodes={@receipt_time_dist.per_node} />

        <!-- Overall Statistics -->
        <.overall_receipt_stats stats={@receipt_time_dist.overall_stats} />
      </div>
    <% end %>
    """
  end

  # Renders overall receipt time statistics
  attr :stats, :map, required: true

  defp overall_receipt_stats(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h4 class="card-title text-md mb-4">Cluster-Wide Propagation Summary</h4>
        <p class="text-sm text-base-content/70 mb-4">
          Time from first to last node receiving each message (note: cross-node timing may be affected by clock skew)
        </p>

        <div class="grid grid-cols-2 md:grid-cols-3 gap-4">
          <div class="stat bg-base-300 rounded-lg p-4">
            <div class="stat-title text-xs">Total Messages</div>
            <div class="stat-value text-2xl">{@stats.total_messages}</div>
            <div class="stat-desc">{@stats.total_events} receipts</div>
          </div>

          <div class="stat bg-base-300 rounded-lg p-4">
            <div class="stat-title text-xs">Avg Spread</div>
            <div class="stat-value text-2xl">
              <span class={spread_colour_class(@stats.avg_spread_ms)}>{@stats.avg_spread_ms}ms</span>
            </div>
            <div class="stat-desc">mean time</div>
          </div>

          <div class="stat bg-base-300 rounded-lg p-4">
            <div class="stat-title text-xs">P95 Spread</div>
            <div class="stat-value text-2xl">
              <span class={spread_colour_class(@stats.p95_spread_ms)}>{@stats.p95_spread_ms}ms</span>
            </div>
            <div class="stat-desc">95th percentile</div>
          </div>
        </div>

        <div class="mt-4 text-xs text-base-content/60">
          <p>
            <strong>Note:</strong> Spread time calculations compare timestamps across nodes and may be
            affected by clock skew. Per-node analysis (above) is more reliable for understanding propagation patterns.
          </p>
        </div>
      </div>
    </div>
    """
  end

  # Renders per-node receipt statistics table
  attr :nodes, :list, required: true

  defp per_node_receipt_stats(assigns) do
    ~H"""
    <%= if @nodes != [] do %>
      <div class="card bg-base-200">
        <div class="card-body">
          <h4 class="card-title text-md mb-4">Per-Node Arrival Timeline</h4>
          <p class="text-sm text-base-content/70 mb-4">
            Arrival offsets from the experiment start time, helping you spot when each node first saw new messages.
          </p>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="bg-base-300">
                  <th class="text-base-content">Node ID</th>
                  <th class="text-base-content">Messages</th>
                  <th class="text-base-content">Earliest Arrival</th>
                  <th class="text-base-content">P95</th>
                  <th class="text-base-content">Latest Arrival</th>
                  <th class="text-base-content">Jitter</th>
                </tr>
              </thead>
              <tbody>
                <%= for {node, index} <- Enum.with_index(@nodes) do %>
                  <tr class={if(rem(index, 2) == 0, do: "", else: "bg-base-300/30")}>
                    <td class="font-mono font-medium">{node.node_id}</td>
                    <td>{node.total_messages}</td>
                    <%= if node.propagation_delay_stats do %>
                      <td class="font-mono text-xs">
                        <span class={arrival_colour_class(node.propagation_delay_stats.min_delay_ms)}>
                          {node.propagation_delay_stats.min_delay_ms}ms
                        </span>
                      </td>
                      <td class="font-mono text-xs">
                        <span class={arrival_colour_class(node.propagation_delay_stats.p95_delay_ms)}>
                          {node.propagation_delay_stats.p95_delay_ms}ms
                        </span>
                      </td>
                      <td class="font-mono text-xs">
                        <span class={arrival_colour_class(node.propagation_delay_stats.max_delay_ms)}>
                          {node.propagation_delay_stats.max_delay_ms}ms
                        </span>
                      </td>
                      <td class="font-mono text-xs">
                        <span class={jitter_colour_class(calculate_jitter(node.propagation_delay_stats))}>
                          ±{calculate_jitter(node.propagation_delay_stats)}ms
                        </span>
                      </td>
                    <% else %>
                      <td colspan="4" class="text-xs text-base-content/50">No arrival data</td>
                    <% end %>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <div class="mt-6">
            <h5 class="font-medium mb-2">Message Receipt Timeline</h5>
            <p class="text-xs text-base-content/70 mb-4">
              Bar height shows when each message arrived (time since experiment start). Bars with similar heights reveal batching -
              when Corrosion delivers multiple messages together via gossip, you'll see groups of bars at the same level.
            </p>
            <%= for node <- @nodes do %>
              <%= if node.propagation_delay_stats && length(node.propagation_delay_stats.delays) > 0 do %>
                <ReceiptStaircaseVl.render_staircase
                  node_id={node.node_id}
                  delays={node.propagation_delay_stats.delays}
                  stats={node.propagation_delay_stats}
                />
              <% end %>
            <% end %>
          </div>

          <div class="mt-4 text-xs text-base-content/70">
            <p>
              <strong>Jitter:</strong>
              Standard deviation of arrival offsets relative to the experiment start, showing consistency of message delivery.
              Lower jitter indicates more predictable propagation patterns.
            </p>
            <p class="mt-2">
              <strong>Note:</strong>
              These offsets use the originating node's clock for both send and receipt timestamps,
              keeping clock skew from other nodes out of the picture.
            </p>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  # Helper functions

  defp has_receipt_data?(%{overall_stats: %{total_events: count}}) when count > 0, do: true
  defp has_receipt_data?(_), do: false

  defp calculate_jitter(%{delays: delays}) when is_list(delays) and length(delays) > 1 do
    mean = Enum.sum(delays) / length(delays)
    variance = Enum.sum(Enum.map(delays, fn x -> :math.pow(x - mean, 2) end)) / length(delays)
    :math.sqrt(variance) |> Float.round(1)
  end

  defp calculate_jitter(_), do: 0

  defp spread_colour_class(ms) when is_number(ms) do
    cond do
      ms < 100 -> "text-success"
      ms < 500 -> "text-warning"
      ms < 1000 -> "text-[#F97316]"
      true -> "text-error"
    end
  end

  defp spread_colour_class(_), do: ""

  defp arrival_colour_class(ms) when is_number(ms) do
    cond do
      ms < 50 -> "text-success"
      ms < 200 -> "text-warning"
      ms < 500 -> "text-[#F97316]"
      true -> "text-error"
    end
  end

  defp arrival_colour_class(_), do: ""

  defp jitter_colour_class(jitter) when is_number(jitter) do
    cond do
      jitter < 20 -> "text-success"
      jitter < 50 -> "text-warning"
      true -> "text-error"
    end
  end

  defp jitter_colour_class(_), do: ""
end
