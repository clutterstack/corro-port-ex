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
  import CorroPortWeb.AnalyticsLive.Helpers

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
              Times relative to message send (requires same-node comparison for accuracy).
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

  @doc """
  Renders overall receipt time statistics.
  """
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

  @doc """
  Renders per-node receipt statistics table.
  """
  attr :nodes, :list, required: true

  defp per_node_receipt_stats(assigns) do
    ~H"""
    <%= if @nodes != [] do %>
      <div class="card bg-base-200">
        <div class="card-body">
          <h4 class="card-title text-md mb-4">Per-Node Propagation Delay Analysis</h4>
          <p class="text-sm text-base-content/70 mb-4">
            Propagation time from message send to receipt at each node (measured from originating node clock)
          </p>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="bg-base-300">
                  <th class="text-base-content">Node ID</th>
                  <th class="text-base-content">Messages</th>
                  <th class="text-base-content">Min Delay</th>
                  <th class="text-base-content">Median</th>
                  <th class="text-base-content">Avg Delay</th>
                  <th class="text-base-content">P95</th>
                  <th class="text-base-content">Max Delay</th>
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
                        <span class={delay_colour_class(node.propagation_delay_stats.min_delay_ms)}>
                          {node.propagation_delay_stats.min_delay_ms}ms
                        </span>
                      </td>
                      <td class="font-mono text-xs">
                        <span class={delay_colour_class(node.propagation_delay_stats.median_delay_ms)}>
                          {node.propagation_delay_stats.median_delay_ms}ms
                        </span>
                      </td>
                      <td class="font-mono text-xs font-medium">
                        <span class={delay_colour_class(node.propagation_delay_stats.avg_delay_ms)}>
                          {node.propagation_delay_stats.avg_delay_ms}ms
                        </span>
                      </td>
                      <td class="font-mono text-xs">
                        <span class={delay_colour_class(node.propagation_delay_stats.p95_delay_ms)}>
                          {node.propagation_delay_stats.p95_delay_ms}ms
                        </span>
                      </td>
                      <td class="font-mono text-xs">
                        <span class={delay_colour_class(node.propagation_delay_stats.max_delay_ms)}>
                          {node.propagation_delay_stats.max_delay_ms}ms
                        </span>
                      </td>
                      <td class="font-mono text-xs">
                        <span class={jitter_colour_class(calculate_jitter(node.propagation_delay_stats))}>
                          ±{calculate_jitter(node.propagation_delay_stats)}ms
                        </span>
                      </td>
                    <% else %>
                      <td colspan="6" class="text-xs text-base-content/50">No propagation data</td>
                    <% end %>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <div class="mt-6">
            <h5 class="font-medium mb-2">Propagation Delay Distribution</h5>
            <%= for node <- @nodes do %>
              <%= if node.propagation_delay_stats && length(node.propagation_delay_stats.delays) > 0 do %>
                <.delay_distribution_chart
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
              Standard deviation of propagation delays, showing consistency of message delivery.
              Lower jitter indicates more predictable propagation patterns.
            </p>
            <p class="mt-2">
              <strong>Note:</strong>
              These measurements use the originating node's clock for both send and receipt times,
              eliminating clock skew issues and providing accurate propagation delay data.
            </p>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders a horizontal bar chart showing delay distribution for a single node.
  """
  attr :node_id, :string, required: true
  attr :delays, :list, required: true
  attr :stats, :map, required: true

  defp delay_distribution_chart(assigns) do
    ~H"""
    <div class="mb-4 p-4 bg-base-300 rounded-lg">
      <div class="flex items-center justify-between mb-2">
        <span class="font-mono font-medium text-sm">{@node_id}</span>
        <span class="text-xs text-base-content/70">
          {@stats.avg_delay_ms}ms avg, ±{calculate_jitter(@stats)}ms jitter
        </span>
      </div>

      <!-- Histogram with indexed bars -->
      <div class="flex items-center gap-1 h-8">
        <%= for {delay, index} <- Enum.with_index(@delays) do %>
          <div
            class="flex-1 rounded-sm transition-all hover:opacity-80"
            style={"background-color: #{delay_to_colour(delay, @stats.max_delay_ms)}; height: #{delay_to_height(delay, @stats.max_delay_ms)}%"}
            title={"Message #{index + 1}: #{delay}ms"}
          >
          </div>
        <% end %>
      </div>

      <!-- X-axis with message indices -->
      <div class="flex justify-between mt-1 text-xs text-base-content/50">
        <span>msg 1</span>
        <%= if length(@delays) > 10 do %>
          <span>msg {div(length(@delays), 4)}</span>
          <span>msg {div(length(@delays), 2)}</span>
          <span>msg {div(length(@delays) * 3, 4)}</span>
        <% end %>
        <span>msg {length(@delays)}</span>
      </div>

      <!-- Delay statistics below -->
      <div class="flex justify-between mt-2 text-xs text-base-content/50 border-t border-base-content/10 pt-2">
        <span>min: {@stats.min_delay_ms}ms</span>
        <span>median: {@stats.median_delay_ms}ms</span>
        <span>max: {@stats.max_delay_ms}ms</span>
      </div>
    </div>
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

  defp time_span_colour_class(seconds) when is_number(seconds) do
    ms = seconds * 1000

    cond do
      ms < 1000 -> "text-success"
      ms < 5000 -> "text-warning"
      true -> "text-base-content"
    end
  end

  defp time_span_colour_class(_), do: ""

  defp format_time_span_ms(seconds) when is_number(seconds) do
    ms = round(seconds * 1000)

    cond do
      ms < 1000 -> "#{ms}ms"
      ms < 60_000 -> "#{Float.round(ms / 1000, 1)}s"
      true -> "#{div(ms, 60_000)}m #{Float.round(rem(ms, 60_000) / 1000, 1)}s"
    end
  end

  defp format_time_span_ms(_), do: "-"

  defp delay_colour_class(ms) when is_number(ms) do
    cond do
      ms < 50 -> "text-success"
      ms < 200 -> "text-warning"
      ms < 500 -> "text-[#F97316]"
      true -> "text-error"
    end
  end

  defp delay_colour_class(_), do: ""

  defp jitter_colour_class(jitter) when is_number(jitter) do
    cond do
      jitter < 20 -> "text-success"
      jitter < 50 -> "text-warning"
      true -> "text-error"
    end
  end

  defp jitter_colour_class(_), do: ""

  defp delay_to_colour(delay, max_delay) when max_delay > 0 do
    # Normalize delay to 0-1 range
    normalized = delay / max_delay

    # Green to yellow to red gradient
    cond do
      normalized < 0.33 -> "#10B981"
      normalized < 0.67 -> "#F59E0B"
      true -> "#EF4444"
    end
  end

  defp delay_to_colour(_, _), do: "#9CA3AF"

  defp delay_to_height(delay, max_delay) when max_delay > 0 do
    # Normalize to percentage (50-100% range for visibility)
    min_height = 50
    normalized = delay / max_delay
    min_height + normalized * 50
  end

  defp delay_to_height(_, _), do: 50
end
