defmodule CorroPortWeb.AnalyticsLive.ReceiptTimeComponent do
  @moduledoc """
  Phoenix Component for displaying message receipt time distribution.

  Shows propagation patterns from when messages arrive at remote nodes via gossip:
  - Per-node receipt timelines visualised as staircase charts
  - Aggregate receipt counts across the cluster
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

        <!-- Per-Node Visualisations -->
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
        <h4 class="card-title text-md mb-4">Cluster Receipt Summary</h4>
        <p class="text-sm text-base-content/70 mb-4">
          Snapshot of the receipt dataset using clock-skew-safe counts. Use the per-node charts above when you need to reason about propagation behaviour.
        </p>

        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <div class="stat bg-base-300 rounded-lg p-4">
            <div class="stat-title text-xs">Total Messages</div>
            <div class="stat-value text-2xl">{@stats.total_messages}</div>
            <div class="stat-desc">{@stats.total_events} receipts</div>
          </div>

          <div class="stat bg-base-300 rounded-lg p-4">
            <div class="stat-title text-xs">Receipt Events</div>
            <div class="stat-value text-2xl">{@stats.total_events}</div>
            <div class="stat-desc">acked deliveries</div>
          </div>

          <div class="stat bg-base-300 rounded-lg p-4">
            <div class="stat-title text-xs">Avg Receipts / Message</div>
            <div class="stat-value text-2xl">
              {@stats.avg_receipts_per_message}
            </div>
            <div class="stat-desc">rounded to 0.1</div>
          </div>

          <div class="stat bg-base-300 rounded-lg p-4">
            <div class="stat-title text-xs">Nodes Receiving</div>
            <div class="stat-value text-2xl">{@stats.receiving_nodes}</div>
            <div class="stat-desc">unique targets</div>
          </div>
        </div>

        <div class="mt-4 text-xs text-base-content/60">
          <p>
            <strong>Note:</strong> Cross-node timing comparisons have been retired because clock skew made them unreliable. The counts above remain trustworthy regardless of drift.
          </p>
        </div>
      </div>
    </div>
    """
  end

  # Renders per-node receipt staircase visuals
  attr :nodes, :list, required: true

  defp per_node_receipt_stats(assigns) do
    ~H"""
    <%= if @nodes != [] do %>
      <div class="card bg-base-200">
        <div class="card-body">
          <h4 class="card-title text-md mb-4">Per-Node Receipt Patterns</h4>
          <p class="text-sm text-base-content/70 mb-6">
            Each chart shows how quickly a node received batched gossip messages after the experiment started.
            Focus on the staircase profile to spot bunching and stragglers without wading through numeric summaries.
          </p>

          <div class="space-y-4">
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
        </div>
      </div>
    <% end %>
    """
  end

  # Helper functions

  defp has_receipt_data?(%{overall_stats: %{total_events: count}}) when count > 0, do: true
  defp has_receipt_data?(_), do: false
end
